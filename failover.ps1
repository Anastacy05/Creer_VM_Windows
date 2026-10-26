# Bascule de la passerelle PAR DEFAUT d'une VM Windows.
# Meme logique que failover-linux.sh :
#   1. la base repond                       -> on l'utilise (retour des qu'elle revient)
#   2. sinon, la passerelle courante repond -> on la garde
#   3. sinon, apres $Fails echecs de suite  -> premiere autre passerelle qui repond
#
# Fichiers (ecrits par Cloudbase-Init) :
#   C:\ProgramData\failover\node-id         numero du noeud = index de la passerelle de base
#   C:\ProgramData\failover\gateways-list   IP des routeurs (.1 a .10), une par ligne
# Lance au demarrage par la tache planifiee "GatewayFailover" (compte SYSTEM).

$Dir      = 'C:\ProgramData\failover'
$LogFile  = Join-Path $Dir 'failover.log'
$Interval = 5      # secondes entre deux tests
$Fails    = 3      # echecs consecutifs avant de basculer

function Write-Log([string]$msg) {
    if ((Test-Path $LogFile) -and ((Get-Item $LogFile).Length -gt 1MB)) {
        Move-Item $LogFile "$LogFile.old" -Force
    }
    Add-Content -Path $LogFile -Value ("{0} {1}" -f (Get-Date -Format 's'), $msg)
}

$NodeId = [int]((Get-Content (Join-Path $Dir 'node-id') -Raw).Trim())
$GW = @(Get-Content (Join-Path $Dir 'gateways-list') |
        ForEach-Object { $_.Trim() } |
        Where-Object { $_ -match '^\d+(\.\d+){3}$' })
if ($GW.Count -eq 0 -or $NodeId -ge $GW.Count) {
    Write-Log "node-id ($NodeId) ou gateways-list invalide"
    exit 1
}

$Base = $GW[$NodeId]
$Cand = @($Base) + @($GW | Where-Object { $_ -ne $Base })
# Le vnet tenant est un /24 : l'interface a utiliser est celle dont l'IP a le meme prefixe
$Prefix = $Base.Substring(0, $Base.LastIndexOf('.') + 1)
Write-Log "passerelle de base : $Base (noeud $NodeId)"

# Ping de toutes les candidates en parallele (les .4 a .10 n'existent pas : on
# n'attend pas leur timeout une par une). Renvoie celles qui repondent, par priorite.
function Get-Alive {
    $pings = @(); $tasks = @()
    foreach ($ip in $Cand) {
        $p = New-Object System.Net.NetworkInformation.Ping
        $pings += $p
        $tasks += $p.SendPingAsync($ip, 1000)
    }
    try { [void][System.Threading.Tasks.Task]::WaitAll([System.Threading.Tasks.Task[]]$tasks) } catch { }
    $alive = @()
    for ($i = 0; $i -lt $Cand.Count; $i++) {
        if ($tasks[$i].Status -eq 'RanToCompletion' -and $tasks[$i].Result.Status -eq 'Success') {
            $alive += $Cand[$i]
        }
    }
    foreach ($p in $pings) { $p.Dispose() }
    return ,$alive
}

# Passerelle que Windows utilise vraiment (route par defaut de plus faible metrique)
function Get-CurrentGateway {
    $r = Get-NetRoute -AddressFamily IPv4 -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
         Where-Object { $_.NextHop -ne '0.0.0.0' } |
         Sort-Object { $_.RouteMetric + $_.InterfaceMetric } |
         Select-Object -First 1
    if ($r) { return $r.NextHop } else { return $null }
}

function Set-Gateway([string]$gw, [int]$ifIndex, $previous) {
    try {
        # On retire les routes par defaut de cette interface (celle du DHCP comprise),
        # sinon deux routes de meme metrique se disputeraient. ActiveStore = non
        # persistant : la tache replace la bonne route a chaque demarrage.
        Get-NetRoute -AddressFamily IPv4 -DestinationPrefix '0.0.0.0/0' -InterfaceIndex $ifIndex -ErrorAction SilentlyContinue |
            Remove-NetRoute -Confirm:$false -ErrorAction SilentlyContinue
        New-NetRoute -DestinationPrefix '0.0.0.0/0' -InterfaceIndex $ifIndex -NextHop $gw `
                     -RouteMetric 0 -PolicyStore ActiveStore -ErrorAction Stop | Out-Null
        Write-Log "route par defaut via $gw (avant : $previous)"
    } catch {
        Write-Log "echec du changement de route vers $gw : $($_.Exception.Message)"
    }
}

$fails = 0
while ($true) {
    # Pas encore d'IP dans le vnet (bail DHCP pas obtenu) : rien a faire
    $addr = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
            Where-Object { $_.IPAddress.StartsWith($Prefix) } | Select-Object -First 1
    if (-not $addr) { Start-Sleep -Seconds $Interval; continue }

    $current = Get-CurrentGateway
    $alive   = @(Get-Alive)
    $desired = $null

    if ($alive -contains $Base) {
        $desired = $Base; $fails = 0
    } elseif ($current -and ($alive -contains $current)) {
        $desired = $current; $fails = 0
    } else {
        $fails++
        if (-not $current) {
            if ($alive.Count -gt 0) { $desired = $alive[0] } else { $desired = $Base }
        } elseif ($fails -ge $Fails -and $alive.Count -gt 0) {
            $desired = $alive[0]
        }
    }

    if ($desired -and $desired -ne $current) {
        Set-Gateway -gw $desired -ifIndex $addr.InterfaceIndex -previous $(if ($current) { $current } else { 'aucune' })
    }
    Start-Sleep -Seconds $Interval
}
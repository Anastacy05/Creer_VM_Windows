terraform {
  required_providers {
    xenorchestra = {
      source  = "vatesfr/xenorchestra"
      version = "~> 0.29.0"
    }
  }
}

# =========================================================================
# CONNEXION XEN ORCHESTRA
# =========================================================================

provider "xenorchestra" {
  url      = "ws://127.0.0.1:100"
  username = "admin@admin.net"
  password = "admin"
  insecure = true
}

# =========================================================================
# RESSOURCES XCP-ng EXISTANTES
# =========================================================================

data "xenorchestra_pool" "pool" {
  name_label = "Pool"
}

data "xenorchestra_template" "template" {
  name_label = "Windows-Template-Base"
  pool_id    = data.xenorchestra_pool.pool.id
}

data "xenorchestra_sr" "sr_local" {
  name_label = "Local Storage"
  pool_id    = data.xenorchestra_pool.pool.id
}

data "xenorchestra_network" "vnet" {
  name_label = var.vnet_name
}

data "xenorchestra_host" "host" {
  name_label = var.host_name
}

# =========================================================================
# LOCALES
# =========================================================================

locals {

  hosts = [ "emilia", "ram", "rem"]

  node_id = index(local.hosts, var.host_name)

  gateways = [for k in range(1, var.gateway_number+1): cidrhost(var.gateways_cidr, k)]
  gateways_b64  = base64encode("${join("\n", local.gateways)}\n")

  script_b64    = base64encode(file("${path.root}/failover.ps1"))
  
}

# =========================================================================
# VM
# =========================================================================

resource "xenorchestra_vm" "vm_windows" {

  name_label = var.vm_name
  name_description = "VM Windows créée avec Terraform"
  host = data.xenorchestra_host.host.id

  template = data.xenorchestra_template.template.id
  cpus       = var.cpus_number
  memory_max = var.memory_size * 1073741824

  hvm_boot_firmware = "bios"

  network {
      network_id  = data.xenorchestra_network.vnet.id
  }

  cloud_config = <<EOF
      #ps1_sysnative
      $ErrorActionPreference = 'Stop'

      $dir = 'C:\ProgramData\failover'
      New-Item -ItemType Directory -Force -Path $dir | Out-Null

      Set-Content -Path "$dir\node-id" -Value '${local.node_id}' -Encoding ascii
      [IO.File]::WriteAllBytes("$dir\gateways-list", [Convert]::FromBase64String('${local.gateways_b64}'))
      [IO.File]::WriteAllBytes("$dir\failover.ps1",  [Convert]::FromBase64String('${local.script_b64}'))

      $action    = New-ScheduledTaskAction -Execute 'powershell.exe' `
             -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$dir\failover.ps1`""
      $trigger   = New-ScheduledTaskTrigger -AtStartup
      $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -RunLevel Highest
      $settings  = New-ScheduledTaskSettingsSet -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) `
                  -ExecutionTimeLimit ([TimeSpan]::Zero) -StartWhenAvailable
      Register-ScheduledTask -TaskName 'GatewayFailover' -Action $action -Trigger $trigger `
          -Principal $principal -Settings $settings -Force | Out-Null
      Start-ScheduledTask -TaskName 'GatewayFailover'
  EOF

  disk {
    name_label = "${var.vm_name}-disk"
    sr_id      = data.xenorchestra_sr.sr_local.id
    size       = var.disk_size_gb * 1024 * 1024 * 1024
  }
  
}

# Deploy a pre-baked SuperCloud collector VM.
# Does not install Node on the Hyper-V host. Does not build Ubuntu.
# Downloads the published VHDX (or uses a local template) and starts the VM.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\Deploy-SuperCloudCollectorVm.ps1 -Site bkk -Token "<reveal>"

[CmdletBinding()]
param(
  [string]$Site = $(if ($env:SUPERCLOUD_SITE) { $env:SUPERCLOUD_SITE } else { "bkk" }),
  [string]$Token = $(if ($env:SUPERCLOUD_TOKEN) { $env:SUPERCLOUD_TOKEN } else { $env:BASTION_TOKEN }),
  [string]$Master = "https://supercloud.techmarkcompany.com",
  [string]$ImageUrl = "",
  [string]$TemplatePath = "$env:ProgramData\SuperCloud\images\supercloud-collector.vhdx",
  [string]$VmName = "SuperCloud-Collector",
  [string]$SwitchName = "SuperCloud-External",
  [string]$NetAdapterName = "",
  [string]$WorkRoot = "$env:ProgramData\SuperCloud\vms",
  [int64]$MemoryBytes = 1GB,
  [int]$ProcessorCount = 1,
  [switch]$SkipStart
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}

if (-not $ImageUrl) {
  $ImageUrl = "$Master/collector/supercloud-collector.vhdx"
}

function Assert-Admin {
  $id = [Security.Principal.WindowsIdentity]::GetCurrent()
  $p = New-Object Security.Principal.WindowsPrincipal($id)
  if (-not $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw "Run elevated PowerShell."
  }
}
function Write-Step($m) { Write-Host ""; Write-Host "==> $m" -ForegroundColor Cyan }

function Get-SiteNic {
  if ($NetAdapterName) { return Get-NetAdapter -Name $NetAdapterName }
  $up = Get-NetAdapter | Where-Object {
    $_.Status -eq "Up" -and $_.Virtual -ne $true -and $_.Name -notmatch "vEthernet|Default Switch|Loopback"
  } | Sort-Object LinkSpeed -Descending
  if (-not $up) { throw "No site NIC. Pass -NetAdapterName." }
  return @($up)[0]
}

Assert-Admin
if (-not $Token) { throw "Need -Token from $Master/collectors (Reveal token)." }
if (-not (Get-Command New-VM -ErrorAction SilentlyContinue)) {
  throw "Hyper-V is not available on this host. Enable Hyper-V, reboot, re-run this deploy script. Do not install Node here."
}

New-Item -ItemType Directory -Force -Path $WorkRoot, (Split-Path $TemplatePath) | Out-Null

Write-Step "Locate pre-baked collector VHDX (do not build)"
$candidates = @()
if ($TemplatePath -and (Test-Path $TemplatePath)) { $candidates += (Resolve-Path $TemplatePath).Path }
$localGuess = @(
  ".\supercloud-collector.vhdx",
  "$PSScriptRoot\supercloud-collector.vhdx",
  "C:\VMs\supercloud-collector.vhdx"
) | Where-Object { $_ -and (Test-Path $_) }
$candidates += $localGuess
$source = $candidates | Select-Object -First 1

if (-not $source) {
  Write-Host "No local template. GET $ImageUrl"
  $dl = Join-Path (Split-Path $TemplatePath) "supercloud-collector.vhdx"
  try {
    if (Get-Command Start-BitsTransfer -ErrorAction SilentlyContinue) {
      Start-BitsTransfer -Source $ImageUrl -Destination $dl
    } else {
      Invoke-WebRequest -UseBasicParsing -Uri $ImageUrl -OutFile $dl
    }
  } catch {
    throw @"
Could not download the pre-baked VHDX from $ImageUrl
$($_.Exception.Message)

Bake once on a Hyper-V host, then pass -TemplatePath or publish the VHDX at /collector/supercloud-collector.vhdx
"@
  }
  if (-not (Test-Path $dl) -or (Get-Item $dl).Length -lt 10MB) {
    throw "Download was missing or too small: $dl"
  }
  $source = $dl
  $TemplatePath = $dl
}
Write-Host "Template $source  ($([math]::Round((Get-Item $source).Length/1MB)) MB)"

Write-Step "External switch (site LAN / DHCP)"
$sw = Get-VMSwitch -Name $SwitchName -ErrorAction SilentlyContinue
if (-not $sw) {
  $legacy = Get-VMSwitch | Where-Object { $_.SwitchType -eq "External" } | Select-Object -First 1
  if ($legacy) {
    $SwitchName = $legacy.Name
    $sw = $legacy
    Write-Host "Reusing External switch '$SwitchName'"
  } else {
    $nic = Get-SiteNic
    Write-Host "New External switch on $($nic.Name)"
    $sw = New-VMSwitch -Name $SwitchName -NetAdapterName $nic.Name -AllowManagementOS $true
  }
} elseif ($sw.SwitchType -ne "External") {
  throw "Switch '$SwitchName' is $($sw.SwitchType). Collector NIC must be External."
}

Write-Step "Copy template to VM disk (leave the published image untouched)"
$vmDir = Join-Path $WorkRoot $VmName
New-Item -ItemType Directory -Force -Path $vmDir | Out-Null
$vmDisk = Join-Path $vmDir "disk.vhdx"
$old = Get-VM -Name $VmName -ErrorAction SilentlyContinue
if ($old) {
  if ($old.State -ne "Off") { Stop-VM $VmName -TurnOff -Force }
  Remove-VM $VmName -Force
}
if (Test-Path $vmDisk) { Remove-Item -Force $vmDisk }
Copy-Item $source $vmDisk -Force

Write-Step "Small CIDATA disk (site id + token only)"
$seedDir = Join-Path $WorkRoot "cidata-$Site"
if (Test-Path $seedDir) { Remove-Item -Recurse -Force $seedDir }
New-Item -ItemType Directory -Force -Path $seedDir | Out-Null
@"
SUPERCLOUD_MASTER=$Master
SUPERCLOUD_HUB=$Master/collector/v1
SUPERCLOUD_SITE=$Site
SUPERCLOUD_TOKEN=$Token
"@ | Set-Content (Join-Path $seedDir "supercloud.env") -Encoding ascii
$seedVhd = Join-Path $vmDir "cidata.vhdx"
if (Test-Path $seedVhd) {
  Dismount-VHD $seedVhd -ErrorAction SilentlyContinue
  Remove-Item -Force $seedVhd
}
New-VHD -Path $seedVhd -SizeBytes 64MB -Dynamic | Out-Null
$disk = Mount-VHD -Path $seedVhd -Passthru | Get-Disk
if ($disk.PartitionStyle -eq "RAW") { Initialize-Disk -Number $disk.Number -PartitionStyle MBR -PassThru | Out-Null }
$part = Get-Partition -DiskNumber $disk.Number | Where-Object { $_.Type -ne "Reserved" -and $_.Size -gt 1MB } | Select-Object -First 1
if (-not $part) { $part = New-Partition -DiskNumber $disk.Number -UseMaximumSize -AssignDriveLetter -IsActive }
elseif (-not $part.DriveLetter) { Add-PartitionAccessPath -DiskNumber $disk.Number -PartitionNumber $part.PartitionNumber -AssignDriveLetter | Out-Null; $part = Get-Partition -DiskNumber $disk.Number -PartitionNumber $part.PartitionNumber }
Format-Volume -Partition $part -FileSystem FAT32 -NewFileSystemLabel "CIDATA" -Confirm:$false | Out-Null
$letter = (Get-Partition -DiskNumber $disk.Number -PartitionNumber $part.PartitionNumber).DriveLetter
Copy-Item (Join-Path $seedDir "*") "${letter}:\" -Force
Dismount-VHD $seedVhd

Write-Step "Create VM $VmName"
$vm = New-VM -Name $VmName -MemoryStartupBytes $MemoryBytes -Generation 1 -VHDPath $vmDisk -SwitchName $SwitchName
Set-VM -Name $VmName -ProcessorCount $ProcessorCount -AutomaticStartAction Start -AutomaticStopAction ShutDown -Notes "SuperCloud collector $Site"
Add-VMHardDiskDrive -VMName $VmName -Path $seedVhd
if (-not $SkipStart) { Start-VM $VmName }

Write-Host ""
Write-Host "DEPLOYED" -ForegroundColor Green
Write-Host "  VM      $VmName"
Write-Host "  Switch  $SwitchName (DHCP on site LAN)"
Write-Host "  Disk    $vmDisk"
Write-Host "  Master  $Master"
Write-Host "Open: VMConnect localhost $VmName"

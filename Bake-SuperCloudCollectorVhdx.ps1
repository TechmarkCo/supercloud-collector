# One-time bake of the SuperCloud collector VHDX.
# Output: C:\ProgramData\SuperCloud\images\supercloud-collector.vhdx
# This file does not exist until THIS script finishes on a Hyper-V host.

[CmdletBinding()]
param(
  [string]$WorkRoot = "$env:ProgramData\SuperCloud\bake",
  [string]$ImageDir = "$env:ProgramData\SuperCloud\images",
  [string]$TemplateName = "supercloud-collector.vhdx",
  [string]$BakeVmName = "SuperCloud-Collector-BAKE",
  [string]$PublishPath = "",
  [int64]$MemoryBytes = 2GB,
  [int]$WaitMinutes = 35
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}

function Assert-Admin {
  $id = [Security.Principal.WindowsIdentity]::GetCurrent()
  $p = New-Object Security.Principal.WindowsPrincipal($id)
  if (-not $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw "Run elevated PowerShell."
  }
}
function Write-Step($m) { Write-Host ""; Write-Host "==> $m" -ForegroundColor Cyan }
function Get-RemoteFile([string]$Uri, [string]$OutFile) {
  New-Item -ItemType Directory -Force -Path (Split-Path $OutFile) | Out-Null
  Write-Host "GET $Uri"
  if (Get-Command Start-BitsTransfer -ErrorAction SilentlyContinue) {
    Start-BitsTransfer -Source $Uri -Destination $OutFile
  } else {
    Invoke-WebRequest -UseBasicParsing -Uri $Uri -OutFile $OutFile
  }
  if (-not (Test-Path $OutFile) -or (Get-Item $OutFile).Length -lt 1MB) { throw "Download failed: $Uri" }
}

Assert-Admin
New-Item -ItemType Directory -Force -Path $WorkRoot, $ImageDir | Out-Null
$template = Join-Path $ImageDir $TemplateName
if (-not (Get-Command New-VM -ErrorAction SilentlyContinue)) {
  throw "Hyper-V PowerShell is not available. Enable Hyper-V, reboot, then run this bake."
}

Write-Step "Ubuntu Azure VHD (Hyper-V bootable base)"
$imgDir = Join-Path $WorkRoot "ubuntu"
New-Item -ItemType Directory -Force -Path $imgDir | Out-Null
$baseVhd = Get-ChildItem $imgDir -Recurse -Include *.vhd,*.vhdx -ErrorAction SilentlyContinue | Sort-Object Length -Descending | Select-Object -First 1
if (-not $baseVhd) {
  $urls = @(
    "https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-amd64-azure.vhd.tar.gz",
    "https://cloud-images.ubuntu.com/releases/jammy/release/jammy-server-cloudimg-amd64-azure.vhd.tar.gz"
  )
  $archive = $null
  foreach ($u in $urls) {
    $dest = Join-Path $imgDir ([IO.Path]::GetFileName($u))
    try { Get-RemoteFile $u $dest; $archive = $dest; break } catch { Write-Host $_ }
  }
  if (-not $archive) { throw "Could not download Ubuntu Azure VHD." }
  Push-Location $imgDir
  try { & tar -xf $archive } finally { Pop-Location }
  $baseVhd = Get-ChildItem $imgDir -Recurse -Include *.vhd,*.vhdx | Sort-Object Length -Descending | Select-Object -First 1
}
if (-not $baseVhd) { throw "No VHD after extract." }
Write-Host "Base $($baseVhd.FullName)"

Write-Step "Create standalone template disk"
if (Test-Path $template) {
  $running = Get-VM | Where-Object { $_.HardDrives.Path -eq $template }
  if ($running) { throw "Template attached to $($running.Name). Stop that VM first." }
  Remove-Item -Force $template
}
New-VHD -Path $template -ParentPath $baseVhd.FullName -Differencing | Out-Null
$flat = Join-Path $ImageDir ("flat-" + $TemplateName)
if (Test-Path $flat) { Remove-Item -Force $flat }
Convert-VHD -Path $template -DestinationPath $flat -VHDType Dynamic
Remove-Item -Force $template
Move-Item $flat $template

Write-Step "CIDATA seed (install Node + collector, then poweroff)"
$seed = Join-Path $WorkRoot "seed"
if (Test-Path $seed) { Remove-Item -Recurse -Force $seed }
New-Item -ItemType Directory -Force -Path $seed | Out-Null
$userData = @'
#cloud-config
hostname: supercloud-collector
manage_etc_hosts: true
timezone: Asia/Bangkok
package_update: true
packages: [ca-certificates, curl, openssh-client, iputils-ping, sshpass]
runcmd:
  - |
      set -eu
      export DEBIAN_FRONTEND=noninteractive
      if ! command -v node >/dev/null 2>&1; then
        curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
        apt-get install -y nodejs
      fi
      install -d -m 755 /opt/bastion /etc/bastion
      PACK=https://raw.githubusercontent.com/TechmarkCo/supercloud-collector/main
      curl -fsSL "$PACK/bastion-collector.mjs" -o /opt/bastion/bastion-collector.mjs
      chmod 755 /opt/bastion/bastion-collector.mjs
      printf '%s\n' '{"siteId":"REPLACE_SITE","hostname":"supercloud-collector","hubUrl":"https://supercloud.techmarkcompany.com/collector/v1","token":"REPLACE_TOKEN","inventoryPath":"/etc/bastion/inventory.yaml","pollSeconds":20,"autoUpgrade":true}' > /etc/bastion/collector.config.json
      chmod 600 /etc/bastion/collector.config.json
      printf '%s\n' 'site: REPLACE_SITE' 'collector:' '  hostname: supercloud-collector' > /etc/bastion/inventory.yaml
      chmod 600 /etc/bastion/inventory.yaml
      cat > /usr/local/sbin/supercloud-apply-cidata.sh << 'EOF'
#!/bin/sh
set -eu
mkdir -p /mnt/cidata
mount -L CIDATA /mnt/cidata 2>/dev/null || mount /dev/sdb1 /mnt/cidata 2>/dev/null || true
if [ -f /mnt/cidata/supercloud.env ]; then
  . /mnt/cidata/supercloud.env
  if [ -n "${SUPERCLOUD_SITE:-}" ] && [ -n "${SUPERCLOUD_TOKEN:-}" ]; then
    umask 077
    cat > /etc/bastion/collector.config.json << JS
{"siteId":"$SUPERCLOUD_SITE","hostname":"COLLECTOR-$SUPERCLOUD_SITE","hubUrl":"${SUPERCLOUD_HUB:-https://supercloud.techmarkcompany.com/collector/v1}","token":"$SUPERCLOUD_TOKEN","inventoryPath":"/etc/bastion/inventory.yaml","pollSeconds":20,"autoUpgrade":true}
JS
    systemctl restart bastion-collector || true
  fi
fi
EOF
      chmod 755 /usr/local/sbin/supercloud-apply-cidata.sh
      cat > /etc/systemd/system/supercloud-apply-cidata.service << 'EOF'
[Unit]
Description=Apply SuperCloud CIDATA
After=network-online.target
Before=bastion-collector.service
[Service]
Type=oneshot
ExecStart=/usr/local/sbin/supercloud-apply-cidata.sh
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target
EOF
      cat > /etc/systemd/system/bastion-collector.service << 'EOF'
[Unit]
Description=SuperCloud site collector
After=network-online.target supercloud-apply-cidata.service
Wants=network-online.target
[Service]
Type=simple
WorkingDirectory=/opt/bastion
ExecStart=/usr/bin/node /opt/bastion/bastion-collector.mjs --config /etc/bastion/collector.config.json
Restart=always
RestartSec=10
[Install]
WantedBy=multi-user.target
EOF
      systemctl daemon-reload
      systemctl enable supercloud-apply-cidata.service bastion-collector.service
      truncate -s 0 /etc/machine-id || true
      shutdown -h now
'
Set-Content (Join-Path $seed "user-data") $userData -Encoding ascii
Set-Content (Join-Path $seed "meta-data") "instance-id: supercloud-collector-bake`nlocal-hostname: supercloud-collector`n" -Encoding ascii
Set-Content (Join-Path $seed "network-config") "version: 2`nethernets:`n  id0:`n    match: {name: `"en*`"}`n    dhcp4: true`n  id1:`n    match: {name: `"eth*`"}`n    dhcp4: true`n" -Encoding ascii

$seedVhd = Join-Path $WorkRoot "cidata-bake.vhdx"
if (Test-Path $seedVhd) { Dismount-VHD $seedVhd -ErrorAction SilentlyContinue; Remove-Item -Force $seedVhd }
New-VHD -Path $seedVhd -SizeBytes 64MB -Dynamic | Out-Null
$disk = Mount-VHD -Path $seedVhd -Passthru | Get-Disk
if ($disk.PartitionStyle -eq "RAW") { Initialize-Disk -Number $disk.Number -PartitionStyle MBR -PassThru | Out-Null }
$part = Get-Partition -DiskNumber $disk.Number | Where-Object { $_.Type -ne "Reserved" -and $_.Size -gt 1MB } | Select-Object -First 1
if (-not $part) { $part = New-Partition -DiskNumber $disk.Number -UseMaximumSize -AssignDriveLetter -IsActive }
elseif (-not $part.DriveLetter) { Add-PartitionAccessPath -DiskNumber $disk.Number -PartitionNumber $part.PartitionNumber -AssignDriveLetter | Out-Null; $part = Get-Partition -DiskNumber $disk.Number -PartitionNumber $part.PartitionNumber }
Format-Volume -Partition $part -FileSystem FAT32 -NewFileSystemLabel "CIDATA" -Confirm:$false | Out-Null
$letter = (Get-Partition -DiskNumber $disk.Number -PartitionNumber $part.PartitionNumber).DriveLetter
Copy-Item (Join-Path $seed "*") "${letter}:\" -Force
Dismount-VHD $seedVhd

Write-Step "Bake VM"
$old = Get-VM -Name $BakeVmName -ErrorAction SilentlyContinue
if ($old) {
  if ($old.State -ne "Off") { Stop-VM $BakeVmName -TurnOff -Force }
  Remove-VM $BakeVmName -Force
}
$switch = Get-VMSwitch | Where-Object { $_.SwitchType -eq "External" } | Select-Object -First 1
if (-not $switch) { $switch = Get-VMSwitch | Select-Object -First 1 }
if (-not $switch) { throw "No Hyper-V switch. Create an External switch first." }
New-VM -Name $BakeVmName -MemoryStartupBytes $MemoryBytes -Generation 1 -VHDPath $template -SwitchName $switch.Name | Out-Null
Set-VM -Name $BakeVmName -ProcessorCount 2 -AutomaticStartAction Nothing -AutomaticStopAction ShutDown
Add-VMHardDiskDrive -VMName $BakeVmName -Path $seedVhd
Start-VM $BakeVmName
Write-Host "Waiting up to $WaitMinutes minutes for bake VM to power off."
$deadline = (Get-Date).AddMinutes($WaitMinutes)
do {
  Start-Sleep -Seconds 15
  $state = (Get-VM $BakeVmName).State
  Write-Host ("  {0} {1}" -f (Get-Date -Format HH:mm:ss), $state)
} while ($state -ne "Off" -and (Get-Date) -lt $deadline)
if ((Get-VM $BakeVmName).State -ne "Off") {
  throw "Bake VM did not power off. VMConnect $BakeVmName and read the console."
}
Remove-VM $BakeVmName -Force
try { Optimize-VHD -Path $template -Mode Full } catch { Write-Host "Optimize-VHD skipped" }
if ($PublishPath) {
  New-Item -ItemType Directory -Force -Path (Split-Path $PublishPath) | Out-Null
  Copy-Item $template $PublishPath -Force
}
Write-Host "BAKE DONE" -ForegroundColor Green
Write-Host "Template: $template"

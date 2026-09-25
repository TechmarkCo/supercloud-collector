# SuperCloud collector — Windows Hyper-V host install and setup
#
# This host is a site collector. It must NOT receive the cloud console
# (no src/, no web app, no full SuperCloud clone). Download only the
# collector slice from the master, or sparse-checkout collector/ +
# public/collector/.
#
#   [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
#   Invoke-WebRequest -UseBasicParsing https://supercloud.techmarkcompany.com/collector/Install-SuperCloudHyperVHost.ps1 -OutFile $env:TEMP\Install-SuperCloudHyperVHost.ps1
#   powershell -NoProfile -ExecutionPolicy Bypass -File $env:TEMP\Install-SuperCloudHyperVHost.ps1 -Site bkk -Token "<reveal>"
#
# Master: https://supercloud.techmarkcompany.com
# Token:  https://supercloud.techmarkcompany.com/collectors  -> Reveal token
#
# Do not put device passwords in the console URL. Inventory stays on the box.

[CmdletBinding()]
param(
  [string]$Site = $(if ($env:SUPERCLOUD_SITE) { $env:SUPERCLOUD_SITE } else { "bkk" }),
  [string]$Token = $(if ($env:SUPERCLOUD_TOKEN) { $env:SUPERCLOUD_TOKEN } else { $env:BASTION_TOKEN }),
  [string]$Master = $(if ($env:SUPERCLOUD_MASTER) { $env:SUPERCLOUD_MASTER } else { "https://supercloud.techmarkcompany.com" }),
  [string]$VmName = "SuperCloud-Collector",
  [string]$SwitchName = "SuperCloud-External",
  [string]$NetAdapterName = "",
  [int64]$MemoryBytes = 1GB,
  [int]$ProcessorCount = 1,
  [string]$WorkRoot = "$env:ProgramData\SuperCloud\hyperv",
  [string]$AppliancePath = "",
  [string]$VhdPath = "",
  [string]$IsoPath = "",
  [switch]$DownloadCloudImage,
  [switch]$NativeHost,
  [switch]$HostOnly,
  [switch]$SkipStart,
  [switch]$MountVhdOnly,
  [switch]$GitSparse,
  [string]$GitUrl = "https://github.com/TechmarkCo/supercloud-collector.git",
  [string]$PackBase = "https://raw.githubusercontent.com/TechmarkCo/supercloud-collector/main"
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
# Windows PowerShell 5.1 still defaults to TLS 1.0. Force 1.2 so Invoke-WebRequest
# works against supercloud.techmarkcompany.com without curl.exe.
try {
  [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
} catch {}

function Assert-Admin {
  $id = [Security.Principal.WindowsIdentity]::GetCurrent()
  $p = New-Object Security.Principal.WindowsPrincipal($id)
  if (-not $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw "Run this script in an elevated PowerShell (Run as administrator)."
  }
}

function Write-Step([string]$Message) {
  Write-Host ""
  Write-Host "==> $Message" -ForegroundColor Cyan
}

function Get-RemoteFile {
  param(
    [Parameter(Mandatory)][string]$Uri,
    [Parameter(Mandatory)][string]$OutFile
  )
  $dir = Split-Path -Parent $OutFile
  if ($dir -and -not (Test-Path $dir)) {
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
  }
  Write-Host "GET $Uri"
  Invoke-WebRequest -Uri $Uri -OutFile $OutFile -UseBasicParsing
  if (-not (Test-Path $OutFile) -or (Get-Item $OutFile).Length -lt 1) {
    throw "Download failed or empty: $Uri"
  }
  return (Get-Item $OutFile).FullName
}

function Get-RemoteText {
  param([Parameter(Mandatory)][string]$Uri)
  Write-Host "GET $Uri"
  $r = Invoke-WebRequest -Uri $Uri -UseBasicParsing
  return [string]$r.Content
}

function Test-ConsoleTree([string]$Root) {
  if (-not $Root -or -not (Test-Path $Root)) { return $false }
  foreach ($rel in @("src\routes\collectors.tsx", "src\lib\soc", "app", "server.ts", "package.json")) {
    if (Test-Path (Join-Path $Root $rel)) { return $true }
  }
  return $false
}

function Copy-CollectorSlice {
  param([Parameter(Mandatory)][string]$Root)
  $out = Join-Path $WorkRoot "collector-only"
  if (Test-Path $out) { Remove-Item -Recurse -Force $out }
  New-Item -ItemType Directory -Force -Path $out | Out-Null
  $copied = $false
  foreach ($rel in @("collector", "public\collector")) {
    $src = Join-Path $Root $rel
    if (Test-Path $src) {
      $dest = Join-Path $out $rel
      New-Item -ItemType Directory -Force -Path (Split-Path $dest) | Out-Null
      Copy-Item $src $dest -Recurse -Force
      $copied = $true
    }
  }
  if (Test-Path (Join-Path $Root "collector\appliance")) {
    $appOut = Join-Path $out "collector\appliance"
    if (-not (Test-Path $appOut)) {
      New-Item -ItemType Directory -Force -Path (Join-Path $out "collector") | Out-Null
      Copy-Item (Join-Path $Root "collector\appliance") $appOut -Recurse -Force
      $copied = $true
    }
  }
  if (Test-ConsoleTree $Root) {
    Write-Host "Cloud console files under $Root were not copied. This host only keeps collector/ and public/collector/."
  }
  if (-not $copied) {
    throw "No collector/ or public/collector/ slice under $Root"
  }
  return $out
}

function Get-CollectorSparseClone {
  Write-Step "Sparse-clone collector slice only (not the cloud console)"
  if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    throw "git is not installed. Download the collector pack from $Master/collector/appliance-pack.tar.gz instead."
  }
  $dest = Join-Path $WorkRoot "collector-src"
  if (Test-Path $dest) { Remove-Item -Recurse -Force $dest }
  & git clone --filter=blob:none --sparse --depth 1 $GitUrl $dest
  if ($LASTEXITCODE -ne 0) { throw "git clone failed for collector slice" }
  Push-Location $dest
  try {
    & git sparse-checkout set collector public/collector
    if ($LASTEXITCODE -ne 0) { throw "git sparse-checkout failed" }
  } finally { Pop-Location }
  if (Test-ConsoleTree $dest) {
    Write-Host "Removing console tree that sparse-checkout should not have fetched."
    foreach ($drop in @("src", "app", "scripts", "node_modules")) {
      $p = Join-Path $dest $drop
      if (Test-Path $p) { Remove-Item -Recurse -Force $p }
    }
  }
  return (Copy-CollectorSlice $dest)
}

function Get-CollectorOnlyPack {
  Write-Step "Download collector files only (no console)"
  $pack = Join-Path $WorkRoot "collector-only"
  if (Test-Path $pack) { Remove-Item -Recurse -Force $pack }
  New-Item -ItemType Directory -Force -Path $pack | Out-Null

  $bases = @(
    $PackBase.TrimEnd("/"),
    "$Master/collector",
    "https://raw.githubusercontent.com/TechmarkCo/supercloud-collector/main"
  ) | Select-Object -Unique

  $archive = Join-Path $WorkRoot "appliance-pack.tar.gz"
  foreach ($base in $bases) {
    foreach ($name in @("appliance-pack.tar.gz", "pack.tar.gz")) {
      try {
        Get-RemoteFile -Uri "$base/$name" -OutFile $archive | Out-Null
        $extract = Join-Path $WorkRoot "pack-extract"
        if (Test-Path $extract) { Remove-Item -Recurse -Force $extract }
        New-Item -ItemType Directory -Force -Path $extract | Out-Null
        Push-Location $extract
        try { & tar -xf $archive } finally { Pop-Location }
        if (Test-ConsoleTree $extract) { return (Copy-CollectorSlice $extract) }
        if ((Test-Path (Join-Path $extract "collector")) -or (Test-Path (Join-Path $extract "public\collector"))) {
          return $extract
        }
        return $extract
      } catch {
        Write-Host "No pack at $base/$name"
      }
    }
  }

  $relMap = @(
    @{ Rel = "public\collector\install.sh"; Names = @("install.sh", "public/collector/install.sh") },
    @{ Rel = "public\collector\install.ps1"; Names = @("install.ps1", "public/collector/install.ps1") },
    @{ Rel = "public\collector\bastion-collector.mjs"; Names = @("bastion-collector.mjs") },
    @{ Rel = "public\collector\start-collector.sh"; Names = @("start-collector.sh") },
    @{ Rel = "public\collector\start-collector.ps1"; Names = @("start-collector.ps1") },
    @{ Rel = "public\collector\collector.config.example.json"; Names = @("collector.config.example.json") },
    @{ Rel = "collector\appliance\cloud-init.yaml"; Names = @("cloud-init.yaml") },
    @{ Rel = "collector\appliance\network-config.yaml"; Names = @("network-config.yaml") },
    @{ Rel = "collector\appliance\firstboot.sh"; Names = @("firstboot.sh") }
  )
  $ok = 0
  foreach ($item in $relMap) {
    $got = $false
    foreach ($base in $bases) {
      if ($got) { break }
      foreach ($name in $item.Names) {
        try {
          Get-RemoteFile -Uri "$base/$name" -OutFile (Join-Path $pack $item.Rel) | Out-Null
          $ok++
          $got = $true
          break
        } catch { }
      }
    }
    if (-not $got) { Write-Host "Skip $($item.Rel)" }
  }
  if ($ok -lt 1) {
    throw "Could not download collector files. Tried $([string]::Join(', ', $bases)). Do not clone the SuperCloud console repo."
  }
  return $pack
}

function Get-ScriptRoot {
  if ($PSScriptRoot) { return $PSScriptRoot }
  return Split-Path -Parent $MyInvocation.MyCommand.Path
}

function Test-HyperVPresent {
  # Server Hyper-V hosts already have Get-VM. Client SKUs use Microsoft-Hyper-V-All.
  if (Get-Command Get-VM -ErrorAction SilentlyContinue) { return $true }
  if (Get-Command Get-WindowsFeature -ErrorAction SilentlyContinue) {
    try {
      $wf = Get-WindowsFeature -Name Hyper-V -ErrorAction Stop
      if ($wf -and $wf.Installed) { return $true }
    } catch { }
  }
  foreach ($name in @("Microsoft-Hyper-V", "Microsoft-Hyper-V-All")) {
    try {
      $f = Get-WindowsOptionalFeature -Online -FeatureName $name -ErrorAction Stop
      if ($f.State -eq "Enabled") { return $true }
    } catch { }
  }
  return $false
}

function Enable-HyperVRole {
  Write-Step "Enable Hyper-V role"
  if (Test-HyperVPresent) {
    Write-Host "Hyper-V is already enabled."
    return $false
  }
  $restart = $false
  $os = $null
  try { $os = Get-CimInstance Win32_OperatingSystem } catch { }
  $isServer = $os -and ($os.ProductType -ne 1)
  Write-Host $("OS={0} ProductType={1} (1=client, 2/3=server)" -f $os.Caption, $os.ProductType)

  if ($isServer -and (Get-Command Install-WindowsFeature -ErrorAction SilentlyContinue)) {
    Write-Host "Windows Server: Install-WindowsFeature Hyper-V"
    $r = Install-WindowsFeature -Name Hyper-V -IncludeManagementTools -Restart:$false
    if ($r.RestartNeeded) { $restart = $true }
  } else {
    $enabled = $false
    foreach ($name in @("Microsoft-Hyper-V", "Microsoft-Hyper-V-All")) {
      try {
        Write-Host "Trying optional feature $name"
        $r = Enable-WindowsOptionalFeature -Online -FeatureName $name -All -NoRestart
        $enabled = $true
        if ($r.RestartNeeded) { $restart = $true }
        break
      } catch {
        Write-Host "$name not available ($($_.Exception.Message))"
      }
    }
    if (-not $enabled) {
      if (Get-Command Install-WindowsFeature -ErrorAction SilentlyContinue) {
        $r = Install-WindowsFeature -Name Hyper-V -IncludeManagementTools -Restart:$false
        if ($r.RestartNeeded) { $restart = $true }
      } else {
        throw "Could not enable Hyper-V. On Server use: Install-WindowsFeature Hyper-V -IncludeManagementTools"
      }
    }
  }
  if ($restart) {
    Write-Host "Hyper-V is installed but a reboot is required."
    Write-Host "Reboot this host, then run this script again with the same arguments."
    $flag = Join-Path $WorkRoot "reboot-pending.txt"
    New-Item -ItemType Directory -Force -Path $WorkRoot | Out-Null
    @(
      "Site=$Site",
      "SwitchName=$SwitchName",
      "VmName=$VmName",
      "AppliancePath=$AppliancePath",
      "VhdPath=$VhdPath"
    ) | Set-Content $flag
    exit 3010
  }
  return $false
}

function Get-SiteNic {
  if ($NetAdapterName) {
    $n = Get-NetAdapter -Name $NetAdapterName -ErrorAction Stop
    return $n
  }
  $up = Get-NetAdapter | Where-Object {
    $_.Status -eq "Up" -and $_.HardwareInterface -eq $true -and $_.Virtual -ne $true
  } | Sort-Object -Property LinkSpeed -Descending
  if (-not $up) {
    $up = Get-NetAdapter | Where-Object { $_.Status -eq "Up" -and $_.Name -notmatch "vEthernet|Default Switch|Loopback" }
  }
  if (-not $up) { throw "No connected physical NIC found. Pass -NetAdapterName explicitly." }
  if ($up.Count -gt 1) {
    Write-Host "Multiple NICs are up. Using '$($up[0].Name)'. Pass -NetAdapterName to override."
    foreach ($n in $up) { Write-Host ("  {0}  {1}  {2}" -f $n.Name, $n.MacAddress, $n.LinkSpeed) }
  }
  return $up[0]
}

function Ensure-ExternalSwitch {
  Write-Step "External virtual switch (site LAN / DHCP)"
  $existing = Get-VMSwitch -Name $SwitchName -ErrorAction SilentlyContinue
  if ($existing) {
    Write-Host "Switch '$SwitchName' already exists ($($existing.SwitchType))."
    if ($existing.SwitchType -ne "External") {
      throw "Switch '$SwitchName' is $($existing.SwitchType). The collector NIC must be External (bridged to the LAN)."
    }
    return $existing
  }
  $legacy = Get-VMSwitch -Name "External" -ErrorAction SilentlyContinue
  if ($legacy -and $legacy.SwitchType -eq "External") {
    Write-Host "Reusing existing switch 'External'."
    $script:SwitchName = "External"
    return $legacy
  }
  $nic = Get-SiteNic
  Write-Host "Binding '$SwitchName' to NIC '$($nic.Name)' ($($nic.MacAddress)). AllowManagementOS=ON so this host keeps its address."
  New-VMSwitch -Name $SwitchName -NetAdapterName $nic.Name -AllowManagementOS $true | Out-Null
  return Get-VMSwitch -Name $SwitchName
}

function Expand-Appliance {
  param([string]$Path)
  if (-not $Path) { return $null }
  if (-not (Test-Path $Path)) { throw "Appliance path not found: $Path" }
  $item = Get-Item $Path
  $dest = Join-Path $WorkRoot "pack"
  New-Item -ItemType Directory -Force -Path $dest | Out-Null
  $ext = $item.Extension.ToLowerInvariant()
  if ($item.PSIsContainer) {
    Write-Host "Using unpacked pack at $($item.FullName)"
    return $item.FullName
  }
  if ($ext -in ".vhdx", ".vhd", ".iso") { return $item.FullName }
  Write-Step "Extract appliance archive"
  $out = Join-Path $WorkRoot ("extract-" + $item.BaseName)
  if (Test-Path $out) { Remove-Item -Recurse -Force $out }
  New-Item -ItemType Directory -Force -Path $out | Out-Null
  if ($item.Name -match "\.tar\.gz$" -or $ext -eq ".tgz" -or $ext -eq ".ova" -or $item.Name -match "\.tar$") {
    $tar = Get-Command tar -ErrorAction SilentlyContinue
    if (-not $tar) { throw "tar is required to unpack $($item.Name) (included in Windows 10 1803+ / Server 2019+)." }
    Push-Location $out
    try { & tar -xf $item.FullName } finally { Pop-Location }
    return $out
  }
  if ($ext -eq ".zip") {
    Expand-Archive -Path $item.FullName -DestinationPath $out -Force
    return $out
  }
  throw "Unsupported appliance file: $($item.FullName)"
}

function Find-DiskImage([string]$Root) {
  if (-not $Root -or -not (Test-Path $Root)) { return $null }
  $hit = Get-ChildItem -Path $Root -Recurse -File -ErrorAction SilentlyContinue |
    Where-Object { $_.Extension -match "^\.(vhdx|vhd)$" } |
    Select-Object -First 1
  if ($hit) { return $hit.FullName }
  return $null
}

function Find-IsoImage([string]$Root) {
  if (-not $Root -or -not (Test-Path $Root)) { return $null }
  $hit = Get-ChildItem -Path $Root -Recurse -File -ErrorAction SilentlyContinue |
    Where-Object { $_.Extension -eq ".iso" -and $_.Name -notmatch "cidata|seed" } |
    Select-Object -First 1
  if ($hit) { return $hit.FullName }
  return $null
}

function Find-PackRoot([string]$Root) {
  if (-not $Root -or -not (Test-Path $Root)) { return $null }
  if (Test-Path (Join-Path $Root "collector\appliance\cloud-init.yaml")) { return $Root }
  $hit = Get-ChildItem -Path $Root -Recurse -Filter "cloud-init.yaml" -ErrorAction SilentlyContinue |
    Where-Object { $_.DirectoryName -match "appliance" } |
    Select-Object -First 1
  if ($hit) { return (Resolve-Path (Join-Path $hit.DirectoryName "..\..")).Path }
  return $Root
}

function New-CidataIso {
  param(
    [Parameter(Mandatory)][string]$SeedDir,
    [Parameter(Mandatory)][string]$IsoPath
  )
  $IsoPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($IsoPath)
  $SeedDir = (Resolve-Path $SeedDir).Path
  if (Test-Path $IsoPath) { Remove-Item -Force $IsoPath }

  $oscdimg = @(
    "$env:ProgramFiles(x86)\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\amd64\Oscdimg\oscdimg.exe",
    "$env:ProgramFiles\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\amd64\Oscdimg\oscdimg.exe"
  ) | Where-Object { Test-Path $_ } | Select-Object -First 1
  if ($oscdimg) {
    & $oscdimg -j1 -o -m -lCIDATA $SeedDir $IsoPath | Out-Null
    if (Test-Path $IsoPath) { return $IsoPath }
  }

  Add-Type -TypeDefinition @"
using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;
public static class ScIsoWriter {
  public static void Write(object comStream, string dest) {
    IStream input = (IStream)comStream;
    using (FileStream output = File.Open(dest, FileMode.Create, FileAccess.Write)) {
      byte[] buffer = new byte[1048576];
      IntPtr pcbRead = Marshal.AllocHGlobal(sizeof(int));
      try {
        while (true) {
          input.Read(buffer, buffer.Length, pcbRead);
          int n = Marshal.ReadInt32(pcbRead);
          if (n <= 0) break;
          output.Write(buffer, 0, n);
        }
      } finally { Marshal.FreeHGlobal(pcbRead); }
    }
  }
}
"@ -ErrorAction SilentlyContinue

  $fsi = New-Object -ComObject IMAPI2FS.MsftFileSystemImage
  $fsi.VolumeName = "CIDATA"
  $fsi.FileSystemsToCreate = 3
  $fsi.FreeMediaBlocks = 0
  $null = $fsi.Root.AddTree($SeedDir, $false)
  $result = $fsi.CreateResultImage()
  [ScIsoWriter]::Write($result.ImageStream, $IsoPath)
  if (-not (Test-Path $IsoPath)) { throw "Failed to build CIDATA ISO at $IsoPath" }
  return $IsoPath
}

function New-CollectorSeedIso {
  param(
    [string]$PackRoot,
    [string]$SiteId,
    [string]$HubToken
  )
  $seed = Join-Path $WorkRoot "seed"
  if (Test-Path $seed) { Remove-Item -Recurse -Force $seed }
  New-Item -ItemType Directory -Force -Path $seed | Out-Null

  # Fetch the Linux installer with PowerShell on this host. The guest then runs
  # the copy from the CIDATA ISO and never needs curl.
  $guestInstall = Join-Path $seed "install.sh"
  $installTried = @(
    "$PackBase/install.sh",
    "$Master/collector/install.sh",
    "https://raw.githubusercontent.com/TechmarkCo/supercloud-collector/main/install.sh"
  )
  $gotInstall = $false
  foreach ($u in $installTried) {
    try {
      Get-RemoteFile -Uri $u -OutFile $guestInstall | Out-Null
      $gotInstall = $true
      break
    } catch { Write-Host "install.sh not at $u" }
  }
  if (-not $gotInstall) {
    if ($PackRoot -and (Test-Path (Join-Path $PackRoot "public\collector\install.sh"))) {
      Copy-Item (Join-Path $PackRoot "public\collector\install.sh") $guestInstall -Force
    } elseif ($PackRoot -and (Test-Path (Join-Path $PackRoot "collector\install\install-linux.sh"))) {
      Copy-Item (Join-Path $PackRoot "collector\install\install-linux.sh") $guestInstall -Force
    } else {
      Write-Host "Seed ISO will not contain install.sh. Set it after first boot."
    }
  }

  $userData = @"
#cloud-config
hostname: supercloud-collector
fqdn: supercloud-collector
manage_etc_hosts: true
timezone: Asia/Bangkok
package_update: true
packages:
  - ca-certificates
  - openssh-client
ssh_pwauth: false
write_files:
  - path: /etc/supercloud.env
    permissions: "0600"
    content: |
      SUPERCLOUD_MASTER=$Master
      SUPERCLOUD_SITE=$SiteId
      SUPERCLOUD_TOKEN=$HubToken
runcmd:
  - dhclient -v || true
  - . /etc/supercloud.env
  - mkdir -p /mnt/cidata
  - mount /dev/sr0 /mnt/cidata 2>/dev/null || mount /dev/cdrom /mnt/cidata 2>/dev/null || true
  - |
      if [ -z "`$SUPERCLOUD_TOKEN" ]; then
        echo "Token empty. Edit /etc/supercloud.env and re-run /mnt/cidata/install.sh" >&2
      elif [ -f /mnt/cidata/install.sh ]; then
        sh /mnt/cidata/install.sh --site "`$SUPERCLOUD_SITE" --token "`$SUPERCLOUD_TOKEN"
      else
        echo "install.sh missing from CIDATA ISO." >&2
      fi
final_message: "SuperCloud collector first boot finished. NIC should have a DHCP lease."
"@

  Set-Content -Path (Join-Path $seed "user-data") -Value $userData -Encoding ascii
  Set-Content -Path (Join-Path $seed "meta-data") -Value "instance-id: supercloud-collector-01`nlocal-hostname: supercloud-collector`n" -Encoding ascii
  $net = @"
network:
  version: 2
  ethernets:
    eth0:
      dhcp4: true
      dhcp-identifier: mac
    ens5:
      dhcp4: true
      dhcp-identifier: mac
    id0:
      match:
        name: "en*"
      dhcp4: true
      dhcp-identifier: mac
"@
  if ($PackRoot -and (Test-Path (Join-Path $PackRoot "collector\appliance\network-config.yaml"))) {
    $net = Get-Content -Raw (Join-Path $PackRoot "collector\appliance\network-config.yaml")
  }
  Set-Content -Path (Join-Path $seed "network-config") -Value $net -Encoding ascii
  $iso = Join-Path $WorkRoot "cidata.iso"
  return New-CidataIso -SeedDir $seed -IsoPath $iso
}

function Get-UbuntuAzureVhd {
  $imgDir = Join-Path $WorkRoot "images"
  New-Item -ItemType Directory -Force -Path $imgDir | Out-Null
  $vhd = Join-Path $imgDir "jammy-server-cloudimg-amd64-azure.vhd"
  if (Test-Path $vhd) {
    Write-Host "Reusing $vhd"
    return $vhd
  }
  $existing = Get-ChildItem $imgDir -Recurse -Include *.vhd,*.vhdx -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($existing) {
    Write-Host "Reusing $($existing.FullName)"
    return $existing.FullName
  }

  $urls = @(
    "https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-amd64-azure.vhd.tar.gz",
    "https://cloud-images.ubuntu.com/releases/jammy/release/jammy-server-cloudimg-amd64-azure.vhd.tar.gz",
    "https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64-azure.vhd.tar.gz"
  )
  Write-Step "Download Ubuntu Azure VHD for Hyper-V (~700 MB .tar.gz, not the old .zip)"
  $archive = $null
  foreach ($url in $urls) {
    $dest = Join-Path $imgDir ([IO.Path]::GetFileName($url))
    try {
      Write-Host "GET $url"
      if (Get-Command Start-BitsTransfer -ErrorAction SilentlyContinue) {
        Start-BitsTransfer -Source $url -Destination $dest -ErrorAction Stop
      } else {
        $old = $ProgressPreference
        $ProgressPreference = "Continue"
        try { Invoke-WebRequest -Uri $url -OutFile $dest -UseBasicParsing } finally { $ProgressPreference = $old }
      }
      if ((Test-Path $dest) -and (Get-Item $dest).Length -gt 1MB) {
        $archive = $dest
        break
      }
    } catch {
      Write-Host "Missed $url ($($_.Exception.Message))"
    }
  }
  if (-not $archive) {
    throw "Could not download an Ubuntu Azure VHD. Pass -VhdPath to an existing .vhd/.vhdx."
  }
  Write-Host "Unpacking $archive ..."
  if (-not (Get-Command tar -ErrorAction SilentlyContinue)) {
    throw "tar.exe is required to unpack $($archive). It ships with Windows Server 2019+."
  }
  Push-Location $imgDir
  try { & tar -xf $archive } finally { Pop-Location }
  $found = Get-ChildItem $imgDir -Recurse -Include *.vhd,*.vhdx -ErrorAction SilentlyContinue | Select-Object -First 1
  if (-not $found) { throw "Archive unpacked but no .vhd/.vhdx was inside: $archive" }
  if ($found.FullName -ne $vhd) {
    Copy-Item $found.FullName $vhd -Force
    return $vhd
  }
  return $found.FullName
}

function Copy-DifferencingDisk([string]$BaseVhd) {
  $disks = Join-Path $WorkRoot "disks"
  New-Item -ItemType Directory -Force -Path $disks | Out-Null
  $child = Join-Path $disks ("{0}.vhdx" -f $VmName)
  if (Test-Path $child) { Remove-Item -Force $child }
  $ext = [IO.Path]::GetExtension($BaseVhd).ToLowerInvariant()
  if ($ext -eq ".vhd") {
    # Azure cloud image is a fixed VHD. Clone it so the original download stays clean.
    $clone = Join-Path $disks ("{0}-base.vhd" -f $VmName)
    Write-Host "Copying base VHD to $clone (this can take a minute)..."
    Copy-Item $BaseVhd $clone -Force
    return $clone
  }
  New-VHD -Path $child -ParentPath $BaseVhd -Differencing | Out-Null
  return $child
}

function Mount-CollectorVhd {
  param([Parameter(Mandatory)][string]$Path)
  Write-Step "Mount VHD/VHDX on the Hyper-V host"
  $full = (Resolve-Path $Path).Path
  $mounted = Mount-VHD -Path $full -Passthru
  $disks = $mounted | Get-Disk
  foreach ($d in $disks) {
    Write-Host ("Disk {0}  {1} GB  PartitionStyle={2}" -f $d.Number, [math]::Round($d.Size/1GB, 1), $d.PartitionStyle)
    $d | Get-Partition | Format-Table PartitionNumber, DriveLetter, Type, Size -AutoSize
  }
  Write-Host "Linux ext4 partitions will not get a Windows drive letter. For the collector guest you want Attach-to-VM, not a host mount."
  Write-Host "Dismount later with:  Dismount-VHD -Path '$full'"
  return $mounted
}

function New-CollectorVm {
  param(
    [string]$DiskPath,
    [string]$SeedIso,
    [string]$InstallIso,
    [int]$Generation = 1
  )
  Write-Step "Create VM $VmName (Gen$Generation)"
  $old = Get-VM -Name $VmName -ErrorAction SilentlyContinue
  if ($old) {
    if ($old.State -ne "Off") { Stop-VM -Name $VmName -TurnOff -Force }
    Remove-VM -Name $VmName -Force
  }
  $vm = New-VM -Name $VmName -MemoryStartupBytes $MemoryBytes -Generation $Generation -VHDPath $DiskPath -SwitchName $SwitchName
  Set-VM -Name $VmName -ProcessorCount $ProcessorCount -AutomaticStartAction Start -AutomaticStopAction ShutDown -Notes "SuperCloud site collector. DHCP on $SwitchName. Master $Master"
  Set-VMProcessor -VMName $VmName -Count $ProcessorCount
  if ($Generation -eq 2) {
    Set-VMFirmware -VMName $VmName -EnableSecureBoot On -SecureBootTemplate MicrosoftUEFICertificateAuthority
    if ($SeedIso) { Add-VMDvdDrive -VMName $VmName -Path $SeedIso }
    if ($InstallIso) { Add-VMDvdDrive -VMName $VmName -Path $InstallIso }
  } else {
    if ($SeedIso) { Set-VMDvdDrive -VMName $VmName -Path $SeedIso }
    elseif ($InstallIso) { Set-VMDvdDrive -VMName $VmName -Path $InstallIso }
  }
  $nic = Get-VMNetworkAdapter -VMName $VmName
  Write-Host ("NIC MAC {0} on switch {1}" -f $nic.MacAddress, $SwitchName)
  return $vm
}

function Install-NativeWindowsCollector {
  Write-Step "Native Windows collector on this Hyper-V host"
  if (-not $Token) {
    throw "Native install needs -Token from $Master/collectors"
  }
  $url = "$Master/collector/install.ps1"
  Write-Host "Bootstrap $url"
  $tmp = Join-Path $WorkRoot "install-collector.ps1"
  New-Item -ItemType Directory -Force -Path $WorkRoot | Out-Null
  Get-RemoteFile -Uri $url -OutFile $tmp | Out-Null
  & $tmp -Site $Site -Token $Token -Master $Master
}

# --- main ---
Assert-Admin
New-Item -ItemType Directory -Force -Path $WorkRoot | Out-Null
Write-Host "SuperCloud Hyper-V host setup"
Write-Host "Site=$Site  VM=$VmName  WorkRoot=$WorkRoot  Master=$Master"

if ($NativeHost) {
  Enable-HyperVRole | Out-Null
  Install-NativeWindowsCollector
  Write-Host "Native collector scheduled as task BastionCollector."
  if ($HostOnly) { return }
}

Enable-HyperVRole | Out-Null
if (-not (Get-Command New-VM -ErrorAction SilentlyContinue)) {
  throw "Hyper-V PowerShell module is not available yet. Reboot and re-run."
}
Ensure-ExternalSwitch | Out-Null

if (-not $AppliancePath) {
  $here = Get-ScriptRoot
  $guess = @(
    (Join-Path $here "appliance-pack.tar.gz"),
    (Join-Path $here "supercloud-collector-appliance.tar.gz"),
    (Join-Path $here "supercloud-collector-pack"),
    (Join-Path $here "collector\appliance")
  ) | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
  if ($guess) { $AppliancePath = (Resolve-Path $guess).Path }
}

$extracted = $null
$packRoot = $null
if ($GitSparse) {
  $packRoot = Get-CollectorSparseClone
} elseif ($AppliancePath) {
  $extracted = Expand-Appliance $AppliancePath
  if ($extracted -and (Test-Path $extracted -PathType Container)) {
    if (Test-ConsoleTree $extracted) {
      $packRoot = Copy-CollectorSlice $extracted
    } else {
      $packRoot = Find-PackRoot $extracted
      if ($packRoot -and (Test-ConsoleTree $packRoot)) {
        $packRoot = Copy-CollectorSlice $packRoot
      }
    }
    if (-not $VhdPath) { $VhdPath = Find-DiskImage $packRoot }
    if (-not $IsoPath) { $IsoPath = Find-IsoImage $packRoot }
  } elseif ($extracted -and (Test-Path $extracted -PathType Leaf)) {
    $VhdPath = $extracted
  }
} else {
  $packRoot = Get-CollectorOnlyPack
}

if ($MountVhdOnly) {
  if (-not $VhdPath) { throw "-MountVhdOnly requires -VhdPath" }
  Mount-CollectorVhd -Path $VhdPath | Out-Null
  return
}

if ($HostOnly) {
  Write-Host "Host-only mode: Hyper-V and switch '$SwitchName' are ready. No VM created."
  return
}

$seedIso = $null
$generation = 1
$diskForVm = $VhdPath

if (-not $diskForVm) {
  Write-Host "No VHDX/VHD in the appliance pack (git stores the pack, not a multi-GB image)."
  $DownloadCloudImage = $true
}

if ($DownloadCloudImage -and -not $diskForVm) {
  $base = Get-UbuntuAzureVhd
  $diskForVm = Copy-DifferencingDisk $base
  $generation = 1
}

if (-not $diskForVm) {
  throw "Nothing to attach. Pass -VhdPath, or omit it to download the Ubuntu Azure VHD."
}

$diskForVm = (Resolve-Path $diskForVm).Path
if ($Token) {
  $seedIso = New-CollectorSeedIso -PackRoot $packRoot -SiteId $Site -HubToken $Token
} else {
  Write-Host "No -Token. Building a seed ISO with an empty token; firstboot will wait until you set it."
  $seedIso = New-CollectorSeedIso -PackRoot $packRoot -SiteId $Site -HubToken ""
}

New-CollectorVm -DiskPath $diskForVm -SeedIso $seedIso -InstallIso $IsoPath -Generation $generation | Out-Null

if (-not $SkipStart) {
  Write-Step "Start $VmName"
  Start-VM -Name $VmName
}

Write-Host ""
Write-Host "Done." -ForegroundColor Green
Write-Host "  VM:           $VmName"
Write-Host "  Switch:       $SwitchName  (External / site DHCP)"
Write-Host "  Disk:         $diskForVm"
Write-Host "  Seed ISO:     $seedIso"
Write-Host "  Master:       $Master"
Write-Host "  Console:      https://supercloud.techmarkcompany.com"
Write-Host ""
Write-Host "The guest NIC0 must take a DHCP lease on the site LAN."
Write-Host "Within about a minute SuperCloud → Sites should show the collector live."
Write-Host "Do not shut a switch port to prove the path."
if (-not $Token) {
  Write-Host ""
  Write-Host "Token was not passed. Reveal it at $Master/collectors"
  Write-Host "then either re-run this script with -Token, or inside the guest:"
  Write-Host "  sudo nano /etc/supercloud.env"
  Write-Host "  sudo sh /mnt/cidata/install.sh --site $Site --token YOURTOKEN"
}
Write-Host ""
Write-Host "Useful commands:"
Write-Host "  Get-VM $VmName | Format-List Name,State,CPUUsage,MemoryAssigned"
Write-Host "  Get-VMNetworkAdapter -VMName $VmName"
Write-Host "  VMConnect localhost $VmName"
Write-Host "  Stop-VM $VmName"

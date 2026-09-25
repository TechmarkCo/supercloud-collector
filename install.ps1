param(
  [string]$Site = $env:SUPERCLOUD_SITE,
  [string]$Token = $(if ($env:SUPERCLOUD_TOKEN) { $env:SUPERCLOUD_TOKEN } else { $env:BASTION_TOKEN }),
  [string]$Master = $(if ($env:SUPERCLOUD_MASTER) { $env:SUPERCLOUD_MASTER } else { "https://supercloud.techmarkcompany.com" }),
  [string]$Hub = $(if ($env:SUPERCLOUD_HUB) { $env:SUPERCLOUD_HUB } else { "" }),
  [string]$PackBase = $(if ($env:SUPERCLOUD_PACK) { $env:SUPERCLOUD_PACK } else { "https://raw.githubusercontent.com/TechmarkCo/supercloud-collector/main" })
)
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}
if (-not $Hub) { $Hub = "$Master/collector/v1" }
if (-not $Site -or -not $Token) {
  Write-Error "Need -Site and -Token from SuperCloud → Sites → Reveal token."
}
if (-not (Get-Command node -ErrorAction SilentlyContinue)) {
  Write-Error "Install Node.js LTS from https://nodejs.org then re-run."
}

function Get-CollectorFile {
  param([string]$Name, [string]$OutFile, [switch]$Optional)
  $uris = @(
    "$($PackBase.TrimEnd('/'))/$Name",
    "https://raw.githubusercontent.com/TechmarkCo/supercloud-collector/main/$Name",
    "$Master/collector/$Name"
  ) | Select-Object -Unique
  foreach ($uri in $uris) {
    Write-Host "GET $uri"
    try {
      Invoke-WebRequest -UseBasicParsing -Uri $uri -OutFile $OutFile
      if ((Test-Path $OutFile) -and (Get-Item $OutFile).Length -gt 0) { return }
    } catch {
      Write-Host "Not at $uri"
    }
  }
  if ($Optional) { return }
  throw "Could not download $Name. Console /collector/ is 404; use PackBase $PackBase"
}

$Dest = "C:\Bastion"
New-Item -ItemType Directory -Force -Path $Dest | Out-Null
Get-CollectorFile -Name "bastion-collector.mjs" -OutFile "$Dest\bastion-collector.mjs"
try { Get-CollectorFile -Name "start-collector.ps1" -OutFile "$Dest\start-collector.ps1" } catch {}
if (-not (Test-Path "$Dest\start-collector.ps1")) {
  @'
$ErrorActionPreference = "Stop"
Set-Location -Path $PSScriptRoot
if (-not (Get-Command node -ErrorAction SilentlyContinue)) { throw "Install Node.js LTS" }
node .\bastion-collector.mjs @args
'@ | Set-Content "$Dest\start-collector.ps1" -Encoding ascii
}
$config = Join-Path $Dest "collector.config.json"
if (-not (Test-Path $config)) {
  $hostName = "COLLECTOR-" + $Site.ToUpper()
  @"
{
  "siteId": "$Site",
  "hostname": "$hostName",
  "hubUrl": "$Hub",
  "token": "$Token",
  "inventoryPath": "C:\\Bastion\\inventory.yaml",
  "pollSeconds": 20,
  "autoUpgrade": true,
  "honeypot": {
    "enabled": true,
    "bind": "0.0.0.0",
    "services": [
      { "name": "SSH", "port": 2222, "banner": "SSH-2.0-OpenSSH_8.4" },
      { "name": "HTTP", "port": 8088 },
      { "name": "SMB", "port": 4450 }
    ]
  }
}
"@ | Set-Content -Path $config -Encoding ascii
}
if (-not (Test-Path "$Dest\inventory.yaml")) {
  "site: $Site`ncollector:`n  hostname: COLLECTOR-$($Site.ToUpper())`n" | Set-Content "$Dest\inventory.yaml"
}
$tr = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\Bastion\start-collector.ps1"
schtasks /Create /TN BastionCollector /SC ONSTART /RL HIGHEST /F /TR $tr | Out-Null
schtasks /Run /TN BastionCollector
Write-Host "Collector installed. Hub $Hub"

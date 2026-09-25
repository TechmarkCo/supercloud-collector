param(
  [string]$Site = $env:SUPERCLOUD_SITE,
  [string]$Token = $(if ($env:SUPERCLOUD_TOKEN) { $env:SUPERCLOUD_TOKEN } else { $env:BASTION_TOKEN }),
  [string]$Master = $(if ($env:SUPERCLOUD_MASTER) { $env:SUPERCLOUD_MASTER } else { "https://supercloud.techmarkcompany.com" }),
  [string]$Hub = $(if ($env:SUPERCLOUD_HUB) { $env:SUPERCLOUD_HUB } else { "" })
)
$ErrorActionPreference = "Stop"
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}
if (-not $Hub) { $Hub = "$Master/collector/v1" }
if (-not $Site -or -not $Token) {
  Write-Error "Need -Site and -Token from SuperCloud → Sites → Reveal token."
}
if (-not (Get-Command node -ErrorAction SilentlyContinue)) {
  Write-Error "Install Node.js LTS from https://nodejs.org then re-run."
}
$Dest = "C:\Bastion"
New-Item -ItemType Directory -Force -Path $Dest | Out-Null
Invoke-WebRequest -UseBasicParsing "$Master/collector/bastion-collector.mjs" -OutFile "$Dest\bastion-collector.mjs"
try { Invoke-WebRequest -UseBasicParsing "$Master/collector/start-collector.ps1" -OutFile "$Dest\start-collector.ps1" } catch {}
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

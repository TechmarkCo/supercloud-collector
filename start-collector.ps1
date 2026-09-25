# Run the SuperCloud collector on a Windows host at the site.
# Requires Node.js LTS. Inventory YAML and collector.config.json sit next to this script.

$ErrorActionPreference = "Stop"
Set-Location -Path $PSScriptRoot

if (-not (Get-Command node -ErrorAction SilentlyContinue)) {
  Write-Host "Install Node.js LTS from https://nodejs.org then re-run this script."
  exit 1
}

if (-not (Test-Path ".\collector.config.json")) {
  Write-Host "Missing collector.config.json — download it from SuperCloud Sites."
  exit 1
}

node .\bastion-collector.mjs @args

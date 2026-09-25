# SuperCloud site collector (no console)

Site appliance is a **pre-baked Ubuntu VHDX**. The Hyper-V host does not
install Node and does not build the image on each site.

Master: https://supercloud.techmarkcompany.com

## Once (lab / build host)

Bake Ubuntu + Node + collector into one VHDX:

```powershell
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
Invoke-WebRequest -UseBasicParsing https://raw.githubusercontent.com/TechmarkCo/supercloud-collector/main/Bake-SuperCloudCollectorVhdx.ps1 -OutFile $env:TEMP\Bake-SuperCloudCollectorVhdx.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File $env:TEMP\Bake-SuperCloudCollectorVhdx.ps1
```

Output: `C:\ProgramData\SuperCloud\images\supercloud-collector.vhdx`

Copy that file to the console as:
`https://supercloud.techmarkcompany.com/collector/supercloud-collector.vhdx`

## Every site (deploy only)

```powershell
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
Invoke-WebRequest -UseBasicParsing https://raw.githubusercontent.com/TechmarkCo/supercloud-collector/main/Deploy-SuperCloudCollectorVm.ps1 -OutFile $env:TEMP\Deploy-SuperCloudCollectorVm.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File $env:TEMP\Deploy-SuperCloudCollectorVm.ps1 -Site bkk -Token "TOKEN" -TemplatePath C:\ProgramData\SuperCloud\images\supercloud-collector.vhdx
```

If the website already hosts the VHDX, omit `-TemplatePath` and the script
downloads it. NIC is External / DHCP. Site token is written to a 64 MB CIDATA
disk; the OS image is not rebuilt.

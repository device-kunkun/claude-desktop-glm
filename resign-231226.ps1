$ErrorActionPreference = 'Continue'
$log = 'C:\Users\Admin\.zcode\workspace\default\claude-desktop-glm\resign231226.txt'
$pkg = Get-AppxPackage -Name Claude
$exe = Join-Path $pkg.InstallLocation 'app\resources\cowork-svc.exe'
$cert = Get-Item 'Cert:\LocalMachine\TrustedPublisher\88AD8106B420AF2CE0254C3D0A7AD2A2A457E006' -ErrorAction SilentlyContinue
if (-not $cert) { $cert = Get-Item 'Cert:\LocalMachine\My\88AD8106B420AF2CE0254C3D0A7AD2A2A457E006' }
takeown /f $exe | Out-Null
icacls $exe /grant '*S-1-5-32-544:F' | Out-Null
$sig = Set-AuthenticodeSignature -FilePath $exe -Certificate $cert
Add-Content $log ("resign: " + $sig.Status)
try { icacls $exe /remove:g '*S-1-5-32-544' | Out-Null } catch {}
try { icacls $exe /setowner 'NT SERVICE\TrustedInstaller' | Out-Null } catch {}
Start-Service CoworkVMService -ErrorAction SilentlyContinue
Start-Sleep -Seconds 3
Add-Content $log ("service: " + (Get-Service CoworkVMService).Status)
exit 0

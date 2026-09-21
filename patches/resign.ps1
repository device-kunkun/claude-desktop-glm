# 为两个被修改的二进制重签本地代码签名证书
# - claude.exe    : fuse 翻转后签名失效；Cowork 服务校验客户端签名的第一层需要有效签名
# - cowork-svc.exe: 打补丁后自校验失败 (0x80096010)，必须重签才能启动
# 证书：自签 CodeSigning 证书（主体伪装 Anthropic 以兼容可能的主体比对），
#       导入 LocalMachine Root + TrustedPublisher，使 WinVerifyTrust 判定为受信。
# ⚠️ 注意：Cowork 服务还有第二层"证书指纹固定"校验，本重签无法通过该层，
#          需配合 svcpatch.ps1（跳过指纹比对）使用。

$ErrorActionPreference = 'Stop'
$pkg  = Get-AppxPackage -Name Claude
$appExe = Join-Path $pkg.InstallLocation 'app\claude.exe'
$svcExe = Join-Path $pkg.InstallLocation 'app\resources\cowork-svc.exe'
$log  = Join-Path $PSScriptRoot 'resign-result.txt'
$tp   = '88AD8106B420AF2CE0254C3D0A7AD2A2A457E006'   # 本地重签证书指纹（复用）

function L($m) { Add-Content -Path $log -Value ("{0} {1}" -f (Get-Date -Format o), $m) }
Remove-Item $log -ErrorAction SilentlyContinue

# 0. 关闭应用
Get-Process claude, cowork-svc -ErrorAction SilentlyContinue |
  Where-Object { $_.Path -like '*WindowsApps*' } | Stop-Process -Force
Start-Sleep -Seconds 2

# 1. 复用或创建证书
$cert = Get-Item "Cert:\LocalMachine\My\$tp" -ErrorAction SilentlyContinue
if (-not $cert) { $cert = Get-Item "Cert:\CurrentUser\My\$tp" -ErrorAction SilentlyContinue }
if (-not $cert) {
  L '创建新的自签代码签名证书'
  $cert = New-SelfSignedCertificate -Type CodeSigningCert `
      -Subject 'CN=Anthropic, PBC, O=Anthropic, PBC, C=US' `
      -CertStoreLocation 'Cert:\CurrentUser\My' `
      -KeyUsage DigitalSignature -KeyExportPolicy Exportable `
      -FriendlyName 'ClaudeLocalResign' -NotAfter (Get-Date).AddYears(10)
} else {
  L '复用已有本地签名证书'
}

# 2. 导入 LocalMachine Root + TrustedPublisher（WinVerifyTrust 受信的关键）
$pw  = ConvertTo-SecureString -String 'claudelocal-pfx' -Force -AsPlainText
$pfx = Join-Path $env:TEMP 'claude-local-resign.pfx'
Export-PfxCertificate -Cert $cert -FilePath $pfx -Password $pw | Out-Null
Import-PfxCertificate -FilePath $pfx -CertStoreLocation 'Cert:\LocalMachine\Root' -Password $pw | Out-Null
Import-PfxCertificate -FilePath $pfx -CertStoreLocation 'Cert:\LocalMachine\TrustedPublisher' -Password $pw | Out-Null
Remove-Item $pfx -Force
$signCert = Get-Item "Cert:\LocalMachine\TrustedPublisher\$tp"

# 3. 依次重签
foreach ($exe in @($appExe, $svcExe)) {
  takeown /f $exe | Out-Null
  icacls $exe /grant '*S-1-5-32-544:F' | Out-Null
  $sig = Set-AuthenticodeSignature -FilePath $exe -Certificate $signCert
  L ("{0} -> {1}" -f (Split-Path $exe -Leaf), $sig.Status)
  if ($sig.Status -ne 'Valid') { throw "签名失败: $($exe) => $($sig.StatusMessage)" }
  try { icacls $exe /remove:g '*S-1-5-32-544' | Out-Null } catch {}
  try { icacls $exe /setowner 'NT SERVICE\TrustedInstaller' | Out-Null } catch {}
}

# 4. 重启服务
try {
  Start-Service CoworkVMService -ErrorAction SilentlyContinue
  L ('CoworkVMService: ' + (Get-Service CoworkVMService).Status)
} catch { L ('service start: ' + $_.Exception.Message) }
L 'DONE'
exit 0

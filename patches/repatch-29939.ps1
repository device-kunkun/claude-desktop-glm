# Claude Desktop 2.9939.2.0 full patch kit
# gates: discovery filter / picker filter / session resolvers x2 + fuse flip + cowork-svc jne patch + resign
$ErrorActionPreference = 'Stop'
$log = 'C:\Users\Admin\.zcode\workspace\default\claude-desktop-glm\patch-29939-result.txt'
$pkg = Get-AppxPackage -Name Claude
$res = Join-Path $pkg.InstallLocation 'app\resources'
$asar = Join-Path $res 'app.asar'
$claudeExe = Join-Path $pkg.InstallLocation 'app\claude.exe'
$svcExe = Join-Path $res 'cowork-svc.exe'
$bakDir = 'C:\Users\Admin\.zcode\workspace\default\claude-desktop-glm\switch\backup'
New-Item -ItemType Directory -Path $bakDir -Force | Out-Null

function L($m) { Add-Content -Path $log -Value ("{0} {1}" -f (Get-Date -Format o), $m) }
$enc = [System.Text.Encoding]::GetEncoding(28591)

try {
  L 'kill app + service'
  Get-Process claude, cowork-svc -ErrorAction SilentlyContinue |
    Where-Object { $_.Path -like '*WindowsApps*' } | Stop-Process -Force
  try { Stop-Service CoworkVMService -Force -ErrorAction SilentlyContinue } catch {}
  Start-Sleep -Seconds 3

  Copy-Item $asar (Join-Path $bakDir 'app.asar.official-2.9939.bak') -Force
  Copy-Item $claudeExe (Join-Path $bakDir 'claude.exe.official-2.9939.bak') -Force
  Copy-Item $svcExe (Join-Path $bakDir 'cowork-svc.exe.official-2.9939.bak') -Force
  L 'backups saved'

  takeown /f $asar | Out-Null;  icacls $asar /grant '*S-1-5-32-544:F' | Out-Null
  takeown /f $claudeExe | Out-Null; icacls $claudeExe /grant '*S-1-5-32-544:F' | Out-Null
  takeown /f $svcExe | Out-Null;  icacls $svcExe /grant '*S-1-5-32-544:F' | Out-Null

  # ---- asar 4 gates (2.9939.2.0 patterns) ----
  $text = $enc.GetString([System.IO.File]::ReadAllBytes($asar))
  $pairs = @(
    @{ orig = '!Yo(t.id)&&!n'; repl = '!1&Yo(t.id)&n' },
    @{ orig = 'Xo(e,t.id).ok'; repl = '""+Xo(e,t.id)' },
    @{ orig = 'i.ok?e:(N.warn(`[resolveSessionModel]'; repl = '!0+0?e:(N.warn(`[resolveSessionModel]' },
    @{ orig = 'a.ok?e:(N.warn(`[resolveCodeSessionModel]'; repl = '!0+0?e:(N.warn(`[resolveCodeSessionModel]' }
  )
  foreach ($p in $pairs) {
    if ($p.orig.Length -ne $p.repl.Length) { throw "length mismatch: $($p.orig)" }
    $first = $text.IndexOf($p.orig); $last = $text.LastIndexOf($p.orig)
    L ("{0} -> x{1}" -f $p.orig.Substring(0,[Math]::Min(30,$p.orig.Length)), $(if($first -eq $last){1}else{"$first/$last"}))
    if ($first -lt 0 -or $first -ne $last) { throw "occurrence check failed: $($p.orig)" }
    $text = $text.Remove($first, $p.orig.Length).Insert($first, $p.repl)
  }
  [System.IO.File]::WriteAllBytes($asar, $enc.GetBytes($text))
  $chk = $enc.GetString([System.IO.File]::ReadAllBytes($asar))
  foreach ($p in $pairs) { if (-not $chk.Contains($p.repl)) { throw "verify failed: $($p.repl)" } }
  L 'asar 4 gates OK'

  # ---- fuse flip ----
  $sent = [System.Text.Encoding]::ASCII.GetBytes('dL7pKGdnNz796PbbjQWNKmHXBZaB9tsX')
  $eb = [System.IO.File]::ReadAllBytes($claudeExe)
  $found = -1
  for ($i = 0; $i -le $eb.Length - 32; $i++) {
    if ($eb[$i] -ne $sent[0]) { continue }
    $ok = $true
    for ($j = 1; $j -lt 32; $j++) { if ($eb[$i+$j] -ne $sent[$j]) { $ok = $false; break } }
    if ($ok) { $found = $i; break }
  }
  if ($found -lt 0) { throw 'fuse sentinel not found' }
  $statesOff = $found + 34
  $before = [System.Text.Encoding]::ASCII.GetString($eb, $statesOff, 9)
  L ("fuse states: $before")
  if ($before -notlike '010011011*') { throw 'fuse layout unexpected' }
  $eb[$statesOff + 4] = [byte][char]'0'
  [System.IO.File]::WriteAllBytes($claudeExe, $eb)
  L 'fuse flipped'

  # ---- svc 6-byte patch ----
  $sb = [System.IO.File]::ReadAllBytes($svcExe)
  $off = 0x4F9F82
  $svcOrig = [byte[]](0x0F,0x85,0x60,0x02,0x00,0x00)
  $svcNew  = [byte[]](0xE9,0x61,0x02,0x00,0x00,0x90)
  for ($j = 0; $j -lt 6; $j++) { if ($sb[$off+$j] -ne $svcOrig[$j]) { throw ("svc bytes unexpected: " + [System.BitConverter]::ToString($sb,$off,6)) } }
  for ($j = 0; $j -lt 6; $j++) { $sb[$off+$j] = $svcNew[$j] }
  [System.IO.File]::WriteAllBytes($svcExe, $sb)
  L 'svc patched'

  # ---- resign both ----
  $tp = '88AD8106B420AF2CE0254C3D0A7AD2A2A457E006'
  $signCert = Get-Item "Cert:\LocalMachine\TrustedPublisher\$tp" -ErrorAction SilentlyContinue
  if (-not $signCert) { $signCert = Get-Item "Cert:\LocalMachine\My\$tp" -ErrorAction SilentlyContinue }
  if (-not $signCert) {
    L 'creating local signing cert'
    $cert = New-SelfSignedCertificate -Type CodeSigningCert -Subject 'CN=Anthropic, PBC, O=Anthropic, PBC, C=US' -CertStoreLocation 'Cert:\CurrentUser\My' -KeyUsage DigitalSignature -KeyExportPolicy Exportable -FriendlyName 'ClaudeLocalResign' -NotAfter (Get-Date).AddYears(10)
    $pw = ConvertTo-SecureString -String 'claudelocal-pfx' -Force -AsPlainText
    $pfx = Join-Path $env:TEMP 'claude-local-resign.pfx'
    Export-PfxCertificate -Cert $cert -FilePath $pfx -Password $pw | Out-Null
    Import-PfxCertificate -FilePath $pfx -CertStoreLocation 'Cert:\LocalMachine\Root' -Password $pw | Out-Null
    Import-PfxCertificate -FilePath $pfx -CertStoreLocation 'Cert:\LocalMachine\TrustedPublisher' -Password $pw | Out-Null
    Remove-Item $pfx -Force
    $signCert = Get-Item "Cert:\LocalMachine\TrustedPublisher\$tp"
  }
  foreach ($f in @($claudeExe, $svcExe)) {
    $sig = Set-AuthenticodeSignature -FilePath $f -Certificate $signCert
    L ("resign " + (Split-Path $f -Leaf) + " -> " + $sig.Status)
    if ($sig.Status -ne 'Valid') { throw ('resign failed: ' + $f) }
  }

  foreach ($f in @($asar, $claudeExe, $svcExe)) {
    try { icacls $f /remove:g '*S-1-5-32-544' | Out-Null } catch {}
    try { icacls $f /setowner 'NT SERVICE\TrustedInstaller' | Out-Null } catch {}
  }

  L 'starting service'
  Start-Service CoworkVMService -ErrorAction SilentlyContinue
  Start-Sleep -Seconds 3
  L ('service: ' + (Get-Service CoworkVMService).Status)
  L 'ALL DONE'
  exit 0
} catch {
  L ('ERROR: ' + $_.Exception.Message)
  exit 1
}

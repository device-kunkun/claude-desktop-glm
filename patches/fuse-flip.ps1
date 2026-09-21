# 翻转 claude.exe 的 Electron fuse：EnableEmbeddedAsarIntegrityValidation (ENABLED->REMOVED)
# 新版桌面端会校验 app.asar 哈希与 PE 内嵌值是否一致，打补丁后必须关掉这个校验才能启动。
# 注意：本脚本修改 PE 字节会破坏原始 Authenticode 签名，需配合 resign.ps1 重签
#（Cowork 的 cowork-svc 会校验客户端签名；如果只用聊天/Code 不用 Cowork，可以不重签）。

$ErrorActionPreference = 'Stop'
$pkg = Get-AppxPackage -Name Claude
$exe = Join-Path $pkg.InstallLocation 'app\claude.exe'
$log = Join-Path $PSScriptRoot 'fuse-flip-result.txt'
$sentinel = [System.Text.Encoding]::ASCII.GetBytes('dL7pKGdnNz796PbbjQWNKmHXBZaB9tsX')

function L($m) { Add-Content -Path $log -Value ("{0} {1}" -f (Get-Date -Format o), $m) }
Remove-Item $log -ErrorAction SilentlyContinue

Get-Process claude -ErrorAction SilentlyContinue |
  Where-Object { $_.Path -like '*WindowsApps*' } | Stop-Process -Force

takeown /f $exe | Out-Null
icacls $exe /grant '*S-1-5-32-544:F' | Out-Null

$b = [System.IO.File]::ReadAllBytes($exe)

# 定位 fuse 哨兵: dL7pKGdnNz796PbbjQWNKmHXBZaB9tsX
$found = -1
for ($i = 0; $i -le $b.Length - 32; $i++) {
  if ($b[$i] -ne $sentinel[0]) { continue }
  $ok = $true
  for ($j = 1; $j -lt 32; $j++) { if ($b[$i+$j] -ne $sentinel[$j]) { $ok = $false; break } }
  if ($ok) { $found = $i; break }
}
if ($found -lt 0) { throw 'fuse sentinel not found' }

# 布局: [sentinel 32B][version 1B][count 1B][state0..stateN]
# 状态为 ASCII 字符：'0'=REMOVED '1'=DISABLED '2'=ENABLED
# 本构建实测 '1' 为生效态（fuse 4 = AsarIntegrity）
$statesOff = $found + 34
$before = [System.Text.Encoding]::ASCII.GetString($b, $statesOff, 9)
L ("states before: $before")
if ($before -notlike '010011011*') { L '警告: fuse 布局与已知版本不同，请人工核对后再改'; }

# fuse[4] = EnableEmbeddedAsarIntegrityValidation: '1' -> '0'
$b[$statesOff + 4] = [byte][char]'0'
[System.IO.File]::WriteAllBytes($exe, $b)

$after = [System.Text.Encoding]::ASCII.GetString([System.IO.File]::ReadAllBytes($exe), $statesOff, 9)
L ("states after:  $after")

try { icacls $exe /remove:g '*S-1-5-32-544' | Out-Null } catch {}
try { icacls $exe /setowner 'NT SERVICE\TrustedInstaller' | Out-Null } catch {}
L 'DONE'
exit 0

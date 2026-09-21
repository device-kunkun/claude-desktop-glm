# Requires: PowerShell 5.1+ (管理员运行；脚本内已自动触发 UAC 提权说明见 README)
# 作用：对 Claude Desktop (MSIX) 的 app.asar 应用四处等长补丁，
#       打开第三方网关模型的全部闸门（发现过滤 / picker 过滤 / 会话模型解析 x2）
# 适用版本：2.2553.1.0（其他版本模式可能不同，脚本会自检并拒绝盲改）

$ErrorActionPreference = 'Stop'
$pkg = Get-AppxPackage -Name Claude
if (-not $pkg) { Write-Error '未找到 Claude MSIX 包'; exit 1 }
$asar = Join-Path $pkg.InstallLocation 'app\resources\app.asar'
$log  = Join-Path $PSScriptRoot 'repatch-result.txt'

# 四处等长补丁（字节数完全一致，不破坏 asar 偏移）
$pairs = @(
  # 1. 网关 /v1/models 解析器：家族过滤失效（glm-* 等 id 不再被丢弃）
  @{ orig = '!Go(t.id)&&!n';                                repl = '!1&Go(t.id)&n' },
  # 2. resolvedModels 最终过滤：picker 不再按"必须是 Anthropic 模型路由"剔除
  @{ orig = 'Ko(e,t.id).ok';                                repl = '""+Ko(e,t.id)' },
  # 3a. 聊天会话模型解析：选了什么就用什么，不再静默回退默认模型
  @{ orig = 'i.ok?e:(N.warn(`[resolveSessionModel]';        repl = '!0+0?e:(N.warn(`[resolveSessionModel]' },
  # 3b. Code 会话模型解析：同上
  @{ orig = 'a.ok?e:(N.warn(`[resolveCodeSessionModel]';    repl = '!0+0?e:(N.warn(`[resolveCodeSessionModel]' }
)

function L($m) { Add-Content -Path $log -Value ("{0} {1}" -f (Get-Date -Format o), $m) }
Remove-Item $log -ErrorAction SilentlyContinue

if (-not $pkg.SignatureKind -or $pkg.SignatureKind.ToString() -eq 'None') { }
L ("target asar: $asar")

# 关闭正在运行的 Claude（MSIX 路径），文件被占用无法写入
Get-Process claude -ErrorAction SilentlyContinue |
  Where-Object { $_.Path -like '*WindowsApps*' } | Stop-Process -Force
Start-Sleep -Seconds 3

takeown /f $asar | Out-Null
icacls $asar /grant '*S-1-5-32-544:F' | Out-Null

# latin-1 编码：字节 <-> 字符一一对应，整文件往返不失真
$enc  = [System.Text.Encoding]::GetEncoding(28591)
$text = $enc.GetString([System.IO.File]::ReadAllBytes($asar))

foreach ($p in $pairs) {
  if ($p.orig.Length -ne $p.repl.Length) { throw "补丁长度不等长: $($p.orig)" }
  $first = $text.IndexOf($p.orig); $last = $text.LastIndexOf($p.orig)
  L ("{0} -> 出现 {1} 次" -f $p.orig.Substring(0,[Math]::Min(28,$p.orig.Length)), $(if($first -eq $last){1}else{'多/0'}))
  if ($first -lt 0 -or $first -ne $last) { throw "模式应唯一出现一次，实际 first=$first last=$last —— 版本不匹配，拒绝修改" }
  $text = $text.Remove($first, $p.orig.Length).Insert($first, $p.repl)
}

[System.IO.File]::WriteAllBytes($asar, $enc.GetBytes($text))
$check = $enc.GetString([System.IO.File]::ReadAllBytes($asar))
foreach ($p in $pairs) {
  if (-not $check.Contains($p.repl)) { throw "回读验证失败: $($p.repl)" }
}
L 'verify: 4 处补丁全部生效'

try { icacls $asar /remove:g '*S-1-5-32-544' | Out-Null } catch {}
try { icacls $asar /setowner 'NT SERVICE\TrustedInstaller' | Out-Null } catch {}
L 'DONE'
exit 0

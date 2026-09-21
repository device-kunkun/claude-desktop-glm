# 双模式一键切换：GLM 补丁模式 / 官方原版模式
# 用法（管理员）：
#   .\switch-mode.ps1 -Mode glm      # 启用 GLM 补丁版 asar
#   .\switch-mode.ps1 -Mode official # 恢复官方原版 asar（Cowork + Anthropic 模型）
#
# 前提：BackupDir 下有两份 asar：
#   app.asar.glm.bak      <- 打好四闸补丁的 asar
#   app.asar.official.bak <- 官方原版 asar
# （各自如何得到见 README）

param(
  [Parameter(Mandatory = $true)]
  [ValidateSet('glm', 'official')]
  [string]$Mode,

  [string]$BackupDir = (Join-Path $PSScriptRoot 'backup')
)
$ErrorActionPreference = 'Stop'

$pkg  = Get-AppxPackage -Name Claude
$asar = Join-Path $pkg.InstallLocation 'app\resources\app.asar'

$src = switch ($Mode) {
  'glm'      { Join-Path $BackupDir 'app.asar.glm.bak' }
  'official' { Join-Path $BackupDir 'app.asar.official.bak' }
}
if (-not (Test-Path $src)) { throw "找不到 $src，请先按 README 生成两份 asar" }

Write-Host '关闭 Claude...'
Get-Process claude -ErrorAction SilentlyContinue |
  Where-Object { $_.Path -like '*WindowsApps*' } | Stop-Process -Force
Start-Sleep -Seconds 3

takeown /f $asar | Out-Null
icacls $asar /grant '*S-1-5-32-544:F' | Out-Null
Copy-Item $src $asar -Force
try { icacls $asar /remove:g '*S-1-5-32-544' | Out-Null } catch {}
try { icacls $asar /setowner 'NT SERVICE\TrustedInstaller' | Out-Null } catch {}

Write-Host "已切换到 [$Mode] 模式，启动 Claude..."
Start-Process ("shell:AppsFolder\" + $pkg.PackageFamilyName + "!Claude")

# Patch cowork-svc.exe：证书指纹比对分支恒走成功路径（6 字节等长补丁）
# 原理：服务校验客户端时
#   call runtime.memequal   ; 客户端指纹 vs 期望指纹
#   test al, al
#   jne  <success>          ; 相等 -> 审计事件 + return nil
#   ...                     ; 不等 -> 构造 "signature verification failed" 错误
# 将 jne(rel32) 改为 jmp(rel32)+nop，恒走成功分支。
#
# ⚠️ 偏移 0x4F9F82 与指令字节均为 2.2553.1.0 专属，其他版本必须重新定位：
#    1. 搜索字符串 "client certificate does not match service"
#    2. 计算 .rdata VA，扫描 .text 中指向它的 LEA (48/4C 8D /r, mod=00 rm=101)
#    3. 反汇编 LEA 前约 0x160 字节，找到 jne <success> 的 memequal 比对
#
# 补丁后服务自校验签名会失效，必须再跑 resign.ps1 对其重签，否则服务无法启动。

$ErrorActionPreference = 'Stop'
$pkg = Get-AppxPackage -Name Claude
$exe = Join-Path $pkg.InstallLocation 'app\resources\cowork-svc.exe'
$log = Join-Path $PSScriptRoot 'svcpatch-result.txt'
$bak = Join-Path $env:TEMP 'cowork-svc.exe.pristine.bak'
$off = 0x4F9F82

function L($m) { Add-Content -Path $log -Value ("{0} {1}" -f (Get-Date -Format o), $m) }
Remove-Item $log -ErrorAction SilentlyContinue

Get-Process cowork-svc -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
try { Stop-Service CoworkVMService -Force -ErrorAction SilentlyContinue } catch {}
Start-Sleep -Seconds 2

Copy-Item $exe $bak -Force
L 'pristine backup saved'

takeown /f $exe | Out-Null
icacls $exe /grant '*S-1-5-32-544:F' | Out-Null

$b = [System.IO.File]::ReadAllBytes($exe)
$orig = [byte[]](0x0F,0x85,0x60,0x02,0x00,0x00)   # jne  -> success
$new  = [byte[]](0xE9,0x61,0x02,0x00,0x00,0x90)   # jmp  -> success + nop
for ($j = 0; $j -lt 6; $j++) {
  if ($b[$off+$j] -ne $orig[$j]) {
    throw ("现场字节不匹配 (得到 $($b[$off..($off+5)] 的十六进制)) —— 版本不兼容，拒绝修改")
  }
}
for ($j = 0; $j -lt 6; $j++) { $b[$off+$j] = $new[$j] }
[System.IO.File]::WriteAllBytes($exe, $b)

if ([System.IO.File]::ReadAllBytes($exe)[$off] -ne 0xE9) { throw 'verify failed' }
L 'patched & verified'

try { icacls $exe /remove:g '*S-1-5-32-544' | Out-Null } catch {}
try { icacls $exe /setowner 'NT SERVICE\TrustedInstaller' | Out-Null } catch {}
L 'DONE (下一步必须运行 resign.ps1 重签本文件)'
exit 0

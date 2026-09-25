# 安装 Win32-OpenSSH 并搭建 宿主机<->Cowork沙箱 SSH 桥
$ErrorActionPreference = 'Continue'
$log = 'C:\Users\Admin\.zcode\workspace\default\claude-desktop-glm\ssh-bridge-result.txt'
$zip = 'C:\Users\Admin\Downloads\OpenSSH-Win64.zip'
$dest = 'C:\Program Files\OpenSSH-Win64'
$bridgeDir = 'D:\AgriGate-MMM\.host-bridge'
function L($m) { Add-Content -Path $log -Value ("{0} {1}" -f (Get-Date -Format o), $m) }
Remove-Item $log -ErrorAction SilentlyContinue
try {
  L 'extracting to Program Files\OpenSSH'
  Expand-Archive -Path $zip -DestinationPath 'C:\Program Files' -Force
  L 'install-sshd (registers sshd + ssh-agent services)'
  & (Join-Path $dest 'install-sshd.ps1') 2>&1 | Out-Null

  if (-not (Get-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -ErrorAction SilentlyContinue)) {
    New-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -DisplayName 'OpenSSH Server (sshd)' `
      -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22 | Out-Null
    L 'firewall rule created'
  }

  Set-Service sshd -StartupType Automatic
  Start-Service sshd
  L ('sshd: ' + (Get-Service sshd).Status)

  L 'generating bridge keypair'
  New-Item -ItemType Directory -Path $bridgeDir -Force | Out-Null
  if (Test-Path "$bridgeDir\id_ed25519") { Remove-Item "$bridgeDir\id_ed25519","$bridgeDir\id_ed25519.pub" -Force }
  & ssh-keygen -t ed25519 -f "$bridgeDir\id_ed25519" -N '""' -C 'cowork-vm-bridge' 2>&1 | Out-Null
  $pub = (Get-Content "$bridgeDir\id_ed25519.pub" -Raw).Trim()

  $ak = 'C:\ProgramData\ssh\administrators_authorized_keys'
  Add-Content -Path $ak -Value $pub
  icacls $ak /inheritance:r /grant 'SYSTEM:F' /grant 'BUILTIN\Administrators:F' | Out-Null
  L 'authorized_keys installed (Admin)'

  $ips = (Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
    Where-Object { $_.IPAddress -notlike '169.254*' -and $_.IPAddress -ne '127.0.0.1' } |
    Select-Object -ExpandProperty IPAddress) -join ', '
  L ("host IPv4: $ips")

  @"
# Host CLI Bridge（宿主机命令桥）
宿主机 SSH 已就绪（仅密钥认证）。在沙箱内执行：

  mkdir -p ~/.ssh && cp /mnt/AgriGate-MMM/.host-bridge/id_ed25519 ~/.ssh/bridge_key && chmod 600 ~/.ssh/bridge_key
  ssh -i ~/.ssh/bridge_key -o StrictHostKeyChecking=no Admin@192.168.127.1 "whoami"

成功会返回 nt authority\system 之类的宿主机账号名。
若 192.168.127.1 超时，按顺序尝试宿主机 IP: $ips
之后即可同步调用宿主机任何 CLI，例如：
  ssh -i ~/.ssh/bridge_key Admin@192.168.127.1 "claude --version"
"@ | Out-File -FilePath "$bridgeDir\README-bridge.md" -Encoding utf8
  L 'bridge README written'
  L 'DONE'
  exit 0
} catch {
  L ('ERROR: ' + $_.Exception.Message)
  exit 1
}

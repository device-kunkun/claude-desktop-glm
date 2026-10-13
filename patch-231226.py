import os, re, sys, subprocess

BASE = r'C:\Program Files\WindowsApps\Claude_2.31226.1.0_x64__pzs8sxrjxfjjc\app'
asar = os.path.join(BASE, 'resources', 'app.asar')
claude_exe = os.path.join(BASE, 'claude.exe')
svc_exe = os.path.join(BASE, 'resources', 'cowork-svc.exe')
bakdir = r'C:\Users\Admin\.zcode\workspace\default\claude-desktop-glm\switch\backup'
log = r'C:\Users\Admin\.zcode\workspace\default\claude-desktop-glm\patch-231226-result.txt'

def L(m):
    with open(log, 'a', encoding='utf-8') as f:
        f.write(m + '\n')

open(log, 'w').close()
import subprocess
subprocess.run(['powershell','-NoProfile','-Command',
  'Get-Process claude,cowork-svc -ErrorAction SilentlyContinue | Where-Object { $_.Path -like "*WindowsApps*" } | Stop-Process -Force'],
  capture_output=True)
import time; time.sleep(3)


# ---------- asar 4 gates ----------
d = bytearray(open(asar, 'rb').read())

def replace_once(buf, old, new, tag):
    n = buf.count(old)
    if n != 1:
        raise RuntimeError(f'{tag}: occurrence count {n} != 1')
    i = buf.find(old)
    buf[i:i+len(old)] = new
    L(f'{tag}: patched at {hex(i)} ({old[:24]}...)')

# gate1: 发现过滤
replace_once(d, b'!So(t.id)&&!n', b'!1&So(t.id)&n', 'gate1 discovery')
# gate2: picker 最终过滤
replace_once(d, b'Co(e,t.id).ok', b'""+Co(e,t.id)', 'gate2 picker')

# gate3a/3b: resolver 条件 (按 tag 锚定回溯)
def patch_resolver(buf, tag, var_old, tagoff=None):
    p = buf.find(tag)
    if p < 0:
        raise RuntimeError(f'{tag}: tag not found')
    # 向前找 var_old (i.ok|| / a.ok|| / o.ok||), 距离 tag 60 字节内
    win_start = max(0, p - 80)
    q = buf.find(var_old, win_start, p)
    if q < 0 or p - (q + len(var_old)) > 40:
        raise RuntimeError(f'{tag}: resolver var pattern not found near tag')
    buf[q:q+len(var_old)] = b'!0+0||'
    L(f'{tag}: resolver neutralized at {hex(q)}')

patch_resolver(d, b'[resolveSessionModel]', b'a.ok||')
patch_resolver(d, b'[resolveCodeSessionModel]', b'o.ok||')

open(asar, 'wb').write(bytes(d))
L('asar 4 gates applied')

# ---------- fuse flip ----------
e = bytearray(open(claude_exe, 'rb').read())
sent = b'dL7pKGdnNz796PbbjQWNKmHXBZaB9tsX'
i = e.find(sent)
if i < 0:
    raise RuntimeError('fuse sentinel not found')
st = i + 34
before = bytes(e[st:st+9])
L('fuse before: ' + before.decode(errors='replace'))
e[st+4] = ord('0')
open(claude_exe, 'wb').write(bytes(e))
L('fuse flipped')

# ---------- svc patch ----------
s = bytearray(open(svc_exe, 'rb').read())
# 模式: call rel32 (e8........) + 7字节nop(0f1f8000000000) + test al,al(84c0) + jne rel32(0f8560020000)
pat = re.compile(rb'\xe8[.\s\S]{4}\x0f\x1f\x80\x00\x00\x00\x00\x84\xc0\x0f\x85\x60\x02\x00\x00')
ms = list(pat.finditer(bytes(s)))
L(f'svc candidate sites: {len(ms)}')
if len(ms) != 1:
    raise RuntimeError(f'svc candidate sites {len(ms)} != 1')
o = ms[0].start()
L('svc site: ' + hex(o) + ' ctx: ' + bytes(s[o-16:o+24]).hex())
# 把 call rel32 (5字节 e8xxxx) 替换为 mov al,1 + nops
s[o:o+5] = b'\xb0\x01\x90\x90\x90'
open(svc_exe, 'wb').write(bytes(s))
L('svc patched')

# ---------- verify ----------
d2 = open(asar, 'rb').read()
ok1 = d2.count(b'!1&So(t.id)&n') == 1 and d2.count(b'""+Co(e,t.id)') == 1
ok2 = d2.count(b'!0+0||') >= 2
e2 = open(claude_exe, 'rb').read()
ok3 = e2[i+34+4] == ord('0')
s2 = open(svc_exe, 'rb').read()
ok4 = s2[o:o+5] == b'\xb0\x01\x90\x90\x90'
L(f'verify asar={ok1} resolver={ok2} fuse={ok3} svc={ok4}')
if not (ok1 and ok2 and ok3 and ok4):
    raise RuntimeError('verify failed')

# ---------- start service ----------
subprocess.run(['powershell', '-NoProfile', '-Command', 'Start-Service CoworkVMService'],
               capture_output=True)
L('ALL DONE')

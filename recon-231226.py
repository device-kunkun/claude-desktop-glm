import re, os
base = r'C:\Program Files\WindowsApps\Claude_2.31226.1.0_x64__pzs8sxrjxfjjc\app'
d = open(os.path.join(base, 'resources', 'app.asar'), 'rb').read().decode('utf-8', errors='replace')
BT = chr(96)

print('=== A. 发现过滤(anthropic_family_tier 上下文) ===')
for m in re.finditer(r'anthropic_family_tier', d):
    s = m.start()
    seg = d[max(0, s-350):s+150]
    if 'flatMap' in seg or 'return!' in seg:
        print('@', s, ':', seg.replace('\n', ' ')[-420:])
        print()

print('=== B. picker 过滤 (X(e,t.id).ok) ===')
for m in re.finditer(r'(\w+)\(e,t\.id\)\.ok', d):
    j = m.start()
    print(m.group(0), '@', j, ':', d[max(0, j-130):j+40].replace('\n', ' ')[-160:])

print()
print('=== C. resolver 原始字节 ===')
db = open(os.path.join(base, 'resources', 'app.asar'), 'rb').read()
for tag in [b'[resolveSessionModel]', b'[resolveCodeSessionModel]']:
    i = db.find(tag)
    if i < 0:
        print(tag, 'NOT FOUND')
        continue
    raw = db[max(0, i-130):i+40]
    print(tag.decode(), '@', i)
    print(repr(raw))
    print()

print('=== D. svc 二进制候选点 ===')
s = open(os.path.join(base, 'resources', 'cowork-svc.exe'), 'rb').read()
print('svc size:', len(s))
pat = bytes.fromhex('84c00f8560020000')  # test al,al ; jne rel32
occ = []
i = s.find(pat)
while i != -1:
    occ.append(i)
    i = s.find(pat, i + 1)
print('test+jne 模式出现:', len(occ), '处 @', [hex(x) for x in occ[:10]])
for o in occ[:6]:
    ctx = s[o-60:o+14]
    print(hex(o), ':', ctx.hex())
print()
print('svc 字符串: does not match service x', s.count(b'does not match service'),
      '| file is not signed x', s.count(b'file is not signed'))

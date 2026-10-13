import re
p = r'C:\Program Files\WindowsApps\Claude_2.19675.1.0_x64__pzs8sxrjxfjjc\app\resources\app.asar'
d = open(p, 'rb').read().decode('utf-8', errors='replace')
BT = chr(96)

# Gate 1: 网关解析器(带 family filter 的 flatMap)
for m in re.finditer(r'anthropic_family_tier', d):
    s = m.start()
    seg = d[max(0, s-350):s+200]
    if 'flatMap' in seg or 'filter' in seg:
        print('=== gate1 parser ctx @', s, '===')
        print(seg.replace('\n', ' '))
        print()

# Gate 2: picker 最终过滤 (Xx(e,t.id).ok 形态)
for m in re.finditer(r'(\w+)\(e,t\.id\)\.ok', d):
    print('gate2 call:', m.group(0), '@', m.start())
    j = m.start()
    print('  ctx:', d[max(0, j-120):j+60].replace('\n', ' ')[-170:])

# Gate 3: resolver 模式核验
for pat in ['i.ok?e:(N.warn(' + BT + '[resolveSessionModel]',
            'a.ok?e:(N.warn(' + BT + '[resolveCodeSessionModel]',
            'if(i.ok)return e;',
            'return a.ok?e:']:
    print(f'pattern {pat[:50]!r} -> {d.count(pat)}')

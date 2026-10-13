import re

new_svc = open(r'C:\Program Files\WindowsApps\Claude_2.19675.1.0_x64__pzs8sxrjxfjjc\app\resources\cowork-svc.exe', 'rb').read()
old_pristine = open(r'C:\Users\Admin\.zcode\workspace\default\claude-desktop-glm\switch\backup\cowork-svc.exe.official-2.9939.bak', 'rb').read()

OLD_OFF = 0x4F9F82
pat = bytes.fromhex('0f8560020000')

# 旧版(2.9939 pristine)补丁点邻域
old_ctx = old_pristine[OLD_OFF-64:OLD_OFF+64]
print('old site bytes:', old_pristine[OLD_OFF:OLD_OFF+6].hex())
print('old ctx head:', old_ctx[:32].hex())

# 在新版中搜索相同 jne 模式的所有出现
occ = []
i = new_svc.find(pat)
while i != -1:
    occ.append(i)
    i = new_svc.find(pat, i + 1)
print(f'new svc 中 jne(0f8560020000) 出现: {len(occ)} 处')

# 用旧邻域的左右各 24 字节(不含 jne 本身)在新版中找最佳匹配位置
left = old_pristine[OLD_OFF-24:OLD_OFF]
right = old_pristine[OLD_OFF+6:OLD_OFF+6+24]
best = None
for o in occ:
    l = new_svc[o-24:o]
    r = new_svc[o+6:o+6+24]
    score = sum(1 for a, b in zip(l, left) if a == b) + sum(1 for a, b in zip(r, right) if a == b)
    if best is None or score > best[1]:
        best = (o, score)
if best:
    print(f'best candidate: offset {hex(best[0])} score {best[1]}/48')
    print('ctx:', new_svc[best[0]-32:best[0]+38].hex())
# 也验证旧版同偏移邻域对比
print()
print('new svc strings check: "does not match service" x', new_svc.count(b'does not match service'),
      '| "file is not signed" x', new_svc.count(b'file is not signed'))

#!/usr/bin/env python3
"""本地化完整性门禁。三项检查,任一失败退出码非零:

1. 覆盖:代码里每个 String(localized:) key 与 L() 用到的 rawValue,
   en.lproj 里必须有对应条目(缺了英文界面会漏中文)。
2. 中英格式符一致:en 值的 %@/%d/%.1f 集合必须与中文 key 相同
   (错位在运行时输出乱码,编译器不查)。
3. 参数个数:每个 String(format: String(localized:)) 调用的实参个数
   必须等于 key 里的格式符个数。

用法:python3 Tools/check-l10n.py   (在仓库根目录跑)
"""
import re, glob, sys

FAIL = 0
def fail(msg):
    global FAIL
    FAIL += 1
    print(f"✗ {msg}")

spec = re.compile(r'%(?:%|@|[-+ 0#]*\d*(?:\.\d+)?[dDfFsSxX])')
def specs(s):
    return sorted(m.group(0) for m in spec.finditer(s) if m.group(0) != '%%')

src_files = glob.glob('Sources/MacPulse/*.swift') + glob.glob('Sources/MacPulseCore/*.swift')
loc = re.compile(r'String\(localized:\s*"((?:[^"\\]|\\.)*)"')
raw = re.compile(r'^\s*case\s+\w+\s*=\s*"([^"]*[一-鿿][^"]*)"', re.M)
code_keys = set()
for f in src_files:
    s = open(f).read()
    code_keys.update(m.group(1) for m in loc.finditer(s))
    code_keys.update(m.group(1) for m in raw.finditer(s))

table = open('Resources/en.lproj/Localizable.strings').read()
pairs = dict(re.findall(r'^"((?:[^"\\]|\\.)*)"\s*=\s*"((?:[^"\\]|\\.)*)";', table, re.M))

# 1. 覆盖
for k in sorted(code_keys - set(pairs)):
    fail(f"en 缺条目: {k[:60]}")

# 2. 中英格式符一致(只查会被 format 的:key 含格式符才有风险)
for k, v in pairs.items():
    if specs(k) and specs(k) != specs(v):
        fail(f"格式符不一致: {k[:50]} | zh{specs(k)} en{specs(v)}")

# 3. 参数个数
call = re.compile(r'String\(\s*format:\s*String\(localized:\s*"((?:[^"\\]|\\.)*)"\s*\)\s*,')
for f in src_files:
    s = open(f).read()
    for m in call.finditer(s):
        key = m.group(1)
        i = s.index('(', m.start()); depth = 1; j = i + 1; instr = False; esc = False
        while j < len(s) and depth:
            c = s[j]
            if instr:
                if esc: esc = False
                elif c == '\\': esc = True
                elif c == '"': instr = False
            else:
                if c == '"': instr = True
                elif c == '(': depth += 1
                elif c == ')': depth -= 1
            j += 1
        body = s[i + 1:j - 1]
        d = 0; instr = False; esc = False; commas = 0
        for c in body:
            if instr:
                if esc: esc = False
                elif c == '\\': esc = True
                elif c == '"': instr = False
                continue
            if c == '"': instr = True
            elif c in '([{': d += 1
            elif c in ')]}': d -= 1
            elif c == ',' and d == 0: commas += 1
        need = len(specs(key))
        if need != commas:
            fail(f"{f.split('/')[-1]}: key 需 {need} 参、实给 {commas}: {key[:50]}")

if FAIL:
    print(f"\n{FAIL} 处问题")
    sys.exit(1)
print(f"✓ 覆盖 {len(code_keys)} key / 表 {len(pairs)} 条 / 格式符与参数个数全部一致")

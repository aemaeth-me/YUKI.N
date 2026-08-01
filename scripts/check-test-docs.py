#!/usr/bin/env python3
"""文档即测试门禁：检查 test/**/*.hs 中每个 testCase/testProperty 注册的契约。

规则（对应测试体系约定）：
1. 禁止匿名 body：每个 testCase/testProperty 必须引用本模块的具名顶层声明；
2. 被引用的声明必须紧邻其前有 `-- |` 文档块；
3. 文档块必须包含行为规格（非空说明行）、`背景：` 与 `变更记录：`，
   且变更记录至少含一条 `- YYYY-MM-DD:` 带日期条目；
4. testGroup/辅助函数不受第 2/3 条约束；
5. Golden 的特殊分派（`replayOf scenario` / `deterministicOf scenario`）按
   分派函数的所有 `"case" -> target` 分支目标递归校验，消除匿名注册；
6. 注册必须写成单行 `testCase "标题" body` / `testProperty "标题" prop` 形式；
   把 testCase/testProperty 与标题或 body 拆到多行属于违规（防止静默漏检）；
   注释、字符串字面量与 import 行中的同名符号不视为注册。

用法：python3 scripts/check-test-docs.py [--root PATH]
退出码：0 全部通过；1 存在违规（每项违规输出 file:line: 说明）。
"""

import argparse
import os
import re
import sys

DATE_ENTRY = re.compile(r"-\s*\d{4}-\d{2}-\d{2}\s*:")
SIG = re.compile(r"^([A-Za-z_][A-Za-z0-9_']*)\s*::")
SIG_LIST = re.compile(r"^([A-Za-z_][A-Za-z0-9_']*(?:\s*,\s*[A-Za-z_][A-Za-z0-9_']*)+)\s*::")
DEF = re.compile(r"^([A-Za-z_][A-Za-z0-9_']*)\s*=")
TOPLEVEL = re.compile(r"^[A-Za-z_][A-Za-z0-9_']*\s*(::|=)")
CASE_BRANCH = re.compile(r'^\s*"([^"]*)"\s*->\s*([A-Za-z_][A-Za-z0-9_\']*)')
REG = re.compile(r'(testCase|testProperty)\s+"((?:[^"\\]|\\.)*)"\s*(\S*)')
WORD = re.compile(r"\b(testCase|testProperty)\b")
# 剥掉字符串字面量与行注释后剩余"代码文本"
STRIP_LITERALS = re.compile(r'"(?:[^"\\]|\\.)*"|--.*$')

# Golden 的按场景分派函数：其 case 分支目标视为注册的测试实现。
DISPATCHERS = {"replayOf", "deterministicOf"}


class Violation(Exception):
    def __init__(self, path, line, message):
        super().__init__(f"{path}:{line}: {message}")
        self.path = path
        self.line = line
        self.message = message


def find_top_bindings(lines):
    """返回 {name: 0-based 定义行}，只收集列 0 的顶层声明；签名行优先。"""
    bindings = {}
    for idx, line in enumerate(lines):
        if not line or line[0].isspace():
            continue
        m = SIG_LIST.match(line)
        if m:
            for name in m.group(1).split(","):
                bindings.setdefault(name.strip(), idx)
            continue
        m = SIG.match(line)
        if m:
            bindings.setdefault(m.group(1), idx)
            continue
        m = DEF.match(line)
        if m:
            bindings.setdefault(m.group(1), idx)
    return bindings


def doc_block(lines, binding_idx):
    """收集紧邻 binding_idx 声明之前的 `-- |` 文档块；无合法块返回 None。"""
    run = []
    i = binding_idx - 1
    while i >= 0 and lines[i].strip().startswith("--"):
        run.append(i)
        i -= 1
    if not run:
        return None
    starts = [j for j in run if re.match(r"^--\s*\|", lines[j])]
    if not starts:
        return None
    head = starts[-1]
    block = list(range(head, binding_idx))
    if any(not lines[j].strip() for j in block):
        return None
    return block


def block_text(lines, block):
    return "\n".join(re.sub(r"^--\s*\|?\s?", "", lines[j]) for j in block)


def check_doc(lines, block, path, name):
    text = block_text(lines, block)
    if "背景：" not in text:
        raise Violation(path, block[0] + 1, f"`{name}` 的 -- | 文档块缺少 `背景：`")
    if "变更记录：" not in text:
        raise Violation(path, block[0] + 1, f"`{name}` 的 -- | 文档块缺少 `变更记录：`")
    if not DATE_ENTRY.search(text):
        raise Violation(path, block[0] + 1, f"`{name}` 的变更记录缺少 `- YYYY-MM-DD:` 日期条目")
    spec = text.split("背景：", 1)[0]
    if not any(line.strip() for line in spec.splitlines()):
        raise Violation(path, block[0] + 1, f"`{name}` 的 -- | 文档块缺少行为规格说明")


def dispatch_targets(lines, name, bindings):
    """从分派函数定义中提取 `"case" -> target` 的 target 名字（去重保序）。"""
    start = bindings.get(name)
    if start is None:
        return []
    targets = []
    for idx in range(start + 1, len(lines)):
        line = lines[idx]
        if TOPLEVEL.match(line) and not line.startswith(" "):
            break
        m = CASE_BRANCH.match(line)
        if m and m.group(2) not in targets:
            targets.append(m.group(2))
    return targets


def registration_name(body):
    """从注册 body 提取引用的顶层名；返回 None 表示匿名。"""
    body = body.strip()
    if not body:
        return None
    if body.startswith("("):
        body = body[1:]
    if body[:1] in ("\\", "$", "["):
        return None
    m = re.match(r"([A-Za-z_][A-Za-z0-9_']*)", body)
    if not m:
        return None
    return m.group(1)


def code_without_literals(line):
    """剥掉字符串字面量与行注释，返回剩余文本（用于判断标识符是否真的出现在代码中）。"""
    return STRIP_LITERALS.sub("", line)


def check_binding(path, lines, bindings, name, violations, registered):
    line_no = bindings.get(name)
    if line_no is None:
        if registered:
            violations.append(Violation(path, 0, f"注册引用了未定义/非顶层声明 `{name}`"))
        return
    block = doc_block(lines, line_no)
    if block is None:
        if registered:
            violations.append(Violation(path, line_no + 1, f"`{name}` 紧邻声明前缺少 `-- |` 文档块"))
        return
    try:
        check_doc(lines, block, path, name)
    except Violation as exc:
        violations.append(exc)


def check_file(path):
    """检查单个 .hs 文件，返回违规列表（Violation）。"""
    with open(path, encoding="utf-8") as handle:
        lines = handle.read().splitlines()
    bindings = find_top_bindings(lines)
    violations = []
    for idx, line in enumerate(lines):
        if line.startswith("import "):
            continue
        code = code_without_literals(line)
        pos = 0
        found_registration = False
        while True:
            m = REG.search(line, pos)
            if not m:
                break
            found_registration = True
            pos = m.end()
            kind, title, body = m.group(1), m.group(2), m.group(3)
            if not body.strip():
                violations.append(
                    Violation(
                        path,
                        idx + 1,
                        f"拆行注册：`{kind} \"{title}\"` 的 body 未与注册写在同一行",
                    )
                )
                continue
            name = registration_name(body)
            if name is None:
                violations.append(
                    Violation(path, idx + 1, f"匿名 {kind} `{title}`：body 必须引用具名顶层声明")
                )
                continue
            if name in DISPATCHERS:
                for target in dispatch_targets(lines, name, bindings):
                    check_binding(path, lines, bindings, target, violations, registered=True)
                continue
            check_binding(path, lines, bindings, name, violations, registered=True)
        # 代码中出现了 testCase/testProperty 标识符但本行没有合法单行注册形式：
        # 这是拆行注册（testCase 与标题/body 分行），判违规以防静默漏检。
        if not found_registration:
            hit = WORD.search(code)
            if hit is not None:
                violations.append(
                    Violation(
                        path,
                        idx + 1,
                        f"拆行注册：`{hit.group(1)}` 未在同一行完成 `\"标题\" body` 形式；"
                        "注册必须单行书写以免漏检",
                    )
                )
    return violations


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", default=".", help="仓库根目录")
    args = parser.parse_args()
    test_dir = os.path.join(os.path.abspath(args.root), "test")
    violations = []
    checked = 0
    for dirpath, _dirnames, filenames in os.walk(test_dir):
        for filename in sorted(filenames):
            if not filename.endswith(".hs"):
                continue
            checked += 1
            violations.extend(check_file(os.path.join(dirpath, filename)))
    if violations:
        for exc in sorted(violations, key=lambda v: (v.path, v.line)):
            print(str(exc), file=sys.stderr)
        print(f"FAIL: {len(violations)} 项文档门禁违规（检查 {checked} 个文件）", file=sys.stderr)
        return 1
    print(f"OK: 全部 {checked} 个测试文件通过文档门禁")
    return 0


if __name__ == "__main__":
    sys.exit(main())

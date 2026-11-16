#!/usr/bin/env python3
"""Classify the binary's imports by thunk difficulty using SDK declarations (clang JSON AST).

usage: sigscan.py AST.json NAMES.txt OUT.json
"""
import collections, json, re, sys

ast = json.load(open(sys.argv[1]))
want = set(open(sys.argv[2]).read().split())
decl = {}
def walk(n):
    for x in n.get("inner", ()):
        k, nm = x.get("kind"), x.get("name")
        if nm in want and k in ("FunctionDecl", "VarDecl") and nm not in decl:
            decl[nm] = (k, x["type"]["qualType"], x.get("variadic", False))
        if k == "LinkageSpecDecl":
            walk(x)
walk(ast)
FLOAT = re.compile(r"\b(float|double|GLfloat|GLdouble|GLclampf|CGFloat|Float32|Float64|AudioUnitParameterValue)\b")
STRUCT_VAL = re.compile(r"\b(CGRect|CGPoint|CGSize|NSRect|NSPoint|NSSize|NSRange|CFRange|CGDirectDisplayID\s*\*?)\b")
cls = collections.defaultdict(list)
for n in sorted(want):
    if n not in decl:
        cls["no SDK declaration"].append(n); continue
    k, t, var = decl[n]
    if k == "VarDecl": cls["data symbol"].append(n); continue
    ret, args = t.split("(", 1)
    if var or "..." in args: cls["variadic"].append(n)
    elif re.search(r"\(\s*\*", args) or "Callback" in args or "Proc" in args or "IMP" in args: cls["takes callback"].append(n)
    elif re.search(r"\b(CGRect|CGPoint|CGSize|NSRect|NSPoint|NSSize|NSRange|CFRange)\b(?!\s*\*)", t): cls["struct by value"].append(n)
    elif FLOAT.search(t): cls["float/double args"].append(n)
    else: cls["integer/pointer only (auto)"].append(n)
for k, v in sorted(cls.items(), key=lambda x: -len(x[1])):
    print("%-30s %4d  %s" % (k, len(v), " ".join(v[:12])))
json.dump({"decl": decl, "classes": cls}, open(sys.argv[3], "w"), indent=1)

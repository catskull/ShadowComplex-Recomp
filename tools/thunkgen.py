#!/usr/bin/env python3
"""Generate host thunks for imported functions from SDK declarations (clang JSON AST).

A thunk reads System V x86_64 arguments from the guest CPU (integer class from rdi..r9,
float/double from xmm0..7, overflow from the guest stack), calls the native function through
a pointer typed with fixed-width kinds (so clang applies Apple arm64 argument extension),
stores the result in rax or xmm0 and pops the guest return address.

Imports whose thunk is hand-written in runtime/ are skipped; signatures that cannot be
expressed this way (struct by value, variadic, callbacks, long double) are reported.

usage: thunkgen.py AST.json IMPORTS.txt RUNTIME_DIR OUT.m
"""
import glob
import json
import os
import re
import sys

sys.path.insert(0, os.path.dirname(__file__))
from recomp import cname

INT_KINDS = {
    "_Bool": "uint8_t", "bool": "uint8_t", "char": "int8_t", "signed char": "int8_t", "unsigned char": "uint8_t",
    "short": "int16_t", "unsigned short": "uint16_t", "int": "int32_t", "unsigned int": "uint32_t",
    "long": "int64_t", "unsigned long": "uint64_t", "long long": "int64_t", "unsigned long long": "uint64_t",
    "wchar_t": "int32_t", "__darwin_wchar_t": "int32_t",
}
QUALS = re.compile(r"\b(const|volatile|restrict|_Nullable|_Nonnull|_Null_unspecified|__unsafe_unretained|__strong|struct|__kindof)\b")


class Manual(Exception):
    pass


class Types:
    def __init__(self, ast):
        self.typedefs, self.enums, self.records, self.funcs = {}, {}, set(), {}
        self.walk(ast)

    def walk(self, n):
        for x in n.get("inner", ()):
            k, nm = x.get("kind"), x.get("name")
            if k == "TypedefDecl" and nm:
                t = x["type"]
                self.typedefs.setdefault(nm, t.get("desugaredQualType", t["qualType"]))
            elif k == "EnumDecl" and nm:
                u = x.get("fixedUnderlyingType")
                self.enums.setdefault(nm, (u.get("desugaredQualType", u["qualType"]) if u else "unsigned int"))
            elif k in ("RecordDecl", "CXXRecordDecl") and nm:
                self.records.add(nm)
            elif k == "FunctionDecl" and nm and nm not in self.funcs:
                self.funcs[nm] = x
            elif k == "LinkageSpecDecl":
                self.walk(x)

    def kind(self, t, depth=0):
        """'P' pointer, 'F' float, 'D' double, or a C integer type name; raises Manual."""
        if depth > 20: raise Manual("typedef loop " + t)
        if "^" in t: return "P"                      # block pointer
        if "(*" in t.replace(" ", ""):
            raise Manual("callback")
        if "*" in t or "[" in t: return "P"
        s = re.sub(r"\s+", " ", QUALS.sub("", t)).strip()
        if s in ("float",): return "F"
        if s in ("double",): return "D"
        if s == "long double": raise Manual("long double")
        if s == "void": return "V"
        if s in INT_KINDS: return INT_KINDS[s]
        if s.startswith("enum "):
            return self.kind(self.enums.get(s[5:], "unsigned int"), depth + 1)
        if s.startswith("union ") or s in self.records:
            raise Manual("struct by value")
        if s in self.typedefs:
            if self.typedefs[s].strip() == s:       # typedef struct {...} Name
                raise Manual("struct by value")
            return self.kind(self.typedefs[s], depth + 1)
        if s.startswith(("int", "uint")) and s.endswith("_t"):
            return s
        raise Manual("unknown type " + s)


def split_return(ftype):
    """'R (A, B)' -> 'R' (handles nested parens in the argument list)."""
    assert ftype.endswith(")")
    depth = 0
    for k in range(len(ftype) - 1, -1, -1):
        ch = ftype[k]
        if ch == ")": depth += 1
        elif ch == "(":
            depth -= 1
            if depth == 0:
                return ftype[:k].strip()
    raise Manual("bad function type")


def thunk(types, name, host):
    fd = types.funcs.get(host)
    if fd is None: raise Manual("no SDK declaration")
    if fd.get("variadic"): raise Manual("variadic")
    ftype = re.sub(r"\s*__attribute__\(\(.*\)\)\s*$", "", fd["type"]["qualType"])
    ret = types.kind(split_return(ftype))
    params = [p["type"].get("desugaredQualType", p["type"]["qualType"])
              for p in fd.get("inner", ()) if p.get("kind") == "ParmVarDecl"]
    kinds = [types.kind(p) for p in params]
    ni = nf = ns = 0
    ctypes, args = [], []
    for k in kinds:
        if k in ("F", "D"):
            ct = "float" if k == "F" else "double"
            if nf < 8:
                args.append("C.xmm[%d].%s[0]" % (nf, "f" if k == "F" else "d")); nf += 1
            else:
                args.append("rd%s(C.rsp + %d)" % ("f" if k == "F" else "d", 8 + 8 * ns)); ns += 1
        else:
            ct = "uint64_t" if k == "P" else k
            if ni < 6:
                args.append("(%s)C.%s" % (ct, ["rdi", "rsi", "rdx", "rcx", "r8", "r9"][ni])); ni += 1
            else:
                args.append("(%s)rd64(C.rsp + %d)" % (ct, 8 + 8 * ns)); ns += 1
        ctypes.append(ct)
    rt = {"V": "void", "F": "float", "D": "double", "P": "uint64_t"}.get(ret, ret)
    target = "(void *)%s" % host
    if name.startswith("_gl"):                  # the Metal renderer replaces every GL entry point
        target = "(rt_metal ? (void *)mgl_%s : (void *)%s)" % (host, host)
    call = "((%s (*)(%s))%s)(%s)" % (rt, ", ".join(ctypes) or "void", target, ", ".join(args))
    if ret == "V": body = "%s;" % call
    elif ret == "F": body = "C.xmm[0].f[0] = %s;" % call
    elif ret == "D": body = "C.xmm[0].d[0] = %s;" % call
    elif ret == "P": body = "C.rax = %s;" % call
    else: body = "C.rax = (uint64_t)(%s)%s;" % ("int64_t" if ret.startswith("int") else "uint64_t", call)
    count = ""
    if name.startswith(("_gl", "_CGL")):
        iargs = [a for a, k in zip(args, kinds) if k not in ("F", "D")]
        fargs = [a for a, k in zip(args, kinds) if k in ("F", "D")]
        count = 'GLCOUNT("%s"); ' % name[1:]
        count += 'if (rt_glargs_on) { uint64_t a_[] = {%s}; double f_[] = {%s}; rt_glargs("%s", a_, %d, f_, %d); } ' % (
            ", ".join("(uint64_t)(%s)" % a for a in iargs) or "0", ", ".join("(double)(%s)" % a for a in fargs) or "0",
            name[1:], len(iargs), len(fargs))
    return "void I_%s(CPU *c) { %s%s C.rsp += 8; }" % (cname(name), count, body)


def main():
    ast, names, rtdir, out = sys.argv[1:5]
    types = Types(json.load(open(ast)))
    hand = set()
    for f in glob.glob(os.path.join(rtdir, "*.[cm]")):
        hand |= set(re.findall(r"\bvoid (I_\w+)\(CPU \*c\)", open(f).read()))
        # INT_THUNK(x) style helpers in runtime/imports.c
        hand |= {"I__" + m for m in re.findall(r"\b(?:INT|F1|F2)_THUNK\((\w+)\)", open(f).read())}
    lines, manual = [], {}
    for name in open(names).read().split():
        if "I_" + cname(name) in hand: continue
        host = name[1:].split("$")[0]          # _fstat$INODE64 -> fstat (arm64 has only the 64-bit inode ABI)
        try:
            if name.startswith("_gl"): lines.append("void mgl_%s(void);" % host)
            lines.append(thunk(types, name, host))
        except Manual as ex:
            manual[name] = str(ex)
    with open(out, "w") as f:
        f.write("// generated by tools/thunkgen.py - do not edit\n#include \"sdk.h\"\n#include \"rt.h\"\n\n")
        f.write("\n".join(lines) + "\n")
    print("generated %d thunks; %d hand-written; %d need manual work" % (sum(1 for l in lines if l.startswith("void I_")), len(hand), len(manual)))
    by = {}
    for n, why in manual.items(): by.setdefault(why, []).append(n)
    for why, ns in sorted(by.items(), key=lambda x: -len(x[1])):
        print("  %-22s %3d  %s" % (why, len(ns), " ".join(ns)))


if __name__ == "__main__":
    main()

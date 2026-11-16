#!/usr/bin/env python3
"""Survey the x86_64 binary: recursive-descent disassembly of every function,
instruction histogram, control-flow oddities, import usage. Writes JSON + prints a summary.

usage: survey.py BINARY OUT.json
"""
import collections
import json
import multiprocessing as mp
import os
import sys

sys.path.insert(0, os.path.dirname(__file__))
from macho import Image
import capstone as cs
from capstone import x86 as X

IMG = None
MD = None


def init(path):
    global IMG, MD
    IMG = Image(path)
    MD = cs.Cs(cs.CS_ARCH_X86, cs.CS_MODE_64)
    MD.detail = True


def ends_block(m):
    return m in ("ret", "jmp", "ud2", "hlt") or m.startswith("ret")


def survey_func(addr):
    end = IMG.func_end(addr)
    code = IMG.read(addr, end - addr)
    seen, work = {}, [addr]
    r = collections.Counter()
    mn = collections.Counter()
    imports = collections.Counter()
    while work:
        a = work.pop()
        while a not in seen and addr <= a < end:
            ins = next(MD.disasm(code[a - addr:a - addr + 16], a, 1), None)
            seen[a] = ins
            if ins is None:
                r["undecodable"] += 1
                break
            m = ins.mnemonic
            mn[m] += 1
            ops = ins.operands
            if ins.group(cs.CS_GRP_JUMP) or m == "call":
                if ops and ops[0].type == X.X86_OP_IMM:
                    t = ops[0].imm
                    if m == "call":
                        if t in IMG.stubs: imports[IMG.stubs[t] or "?"] += 1; r["call_import"] += 1
                        elif t in IMG.func_names: r["call_direct"] += 1
                        elif t == ins.address + ins.size: r["call_next_pic"] += 1
                        else: r["call_mid_func"] += 1
                    elif addr <= t < end:
                        work.append(t)
                    elif t in IMG.stubs:
                        imports[IMG.stubs[t] or "?"] += 1; r["tail_import"] += 1
                    elif t in IMG.func_names:
                        r["tail_direct"] += 1
                    else:
                        r["jump_outside_mid"] += 1
                elif ops and ops[0].type == X.X86_OP_MEM and ops[0].mem.base == X.X86_REG_RIP:
                    slot = ins.address + ins.size + ops[0].mem.disp
                    nm = IMG.ptrs.get(slot)
                    r[("call" if m == "call" else "jmp") + "_got"] += 1
                    if nm: imports[nm] += 1
                else:
                    r["call_indirect" if m == "call" else "jmp_indirect"] += 1
            if any(o.type == X.X86_OP_MEM and o.mem.segment not in (0,) for o in ops):
                r["segment_override"] += 1
            if ends_block(m):
                break
            a = ins.address + ins.size
    covered = sum(i.size for i in seen.values() if i)
    return addr, end - addr, covered, dict(mn), dict(r), dict(imports)


def main():
    path, out = sys.argv[1], sys.argv[2]
    init(path)
    funcs = IMG.func_addrs
    tot_mn, tot_r, tot_imp = collections.Counter(), collections.Counter(), collections.Counter()
    fn_using = collections.Counter()
    nbytes = ncov = 0
    perfunc = {}
    with mp.Pool(os.cpu_count(), initializer=init, initargs=(path,)) as pool:
        for addr, size, cov, mn, r, imp in pool.imap_unordered(survey_func, funcs, chunksize=64):
            nbytes += size; ncov += cov
            tot_mn.update(mn); tot_r.update(r); tot_imp.update(imp)
            for m in mn: fn_using[m] += 1
            perfunc[addr] = {"size": size, "cov": cov, "mn": mn, "r": r}
    json.dump({"mnemonics": tot_mn, "funcs_using": fn_using, "flow": tot_r, "imports": tot_imp,
               "nfuncs": len(funcs), "bytes": nbytes, "covered": ncov,
               "perfunc": {hex(k): v for k, v in perfunc.items()}}, open(out, "w"))
    print("functions %d  text bytes %d  reached %.1f%%" % (len(funcs), nbytes, 100.0 * ncov / nbytes))
    print("instructions %d  distinct mnemonics %d" % (sum(tot_mn.values()), len(tot_mn)))
    print("flow:", dict(tot_r))
    print("imports referenced: %d" % len(tot_imp))


if __name__ == "__main__":
    main()

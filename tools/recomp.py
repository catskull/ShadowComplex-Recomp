#!/usr/bin/env python3
"""Static recompiler: x86_64 Mach-O functions -> C operating on the guest CPU state.

Adapted from JPTG-Recomp's i386 recompiler (https://github.com/NightSightProductions/JPTG-Recomp),
Copyright (c) 2026 NightSight Productions, MIT License (licenses/JPTG-Recomp-LICENSE.txt).

The guest image is loaded at a fixed host base and rebased, so guest pointers are host
pointers. Guest addresses known at translation time are emitted as G(addr), which applies
the constant slide.

usage: recomp.py BINARY OUTDIR [LO HI]      (hex addresses; default = every function)
"""
import collections
import multiprocessing as mp
import os
import re
import sys

sys.path.insert(0, os.path.dirname(__file__))
from macho import Image
import capstone as cs
from capstone import x86 as X

R64 = ["rax", "rcx", "rdx", "rbx", "rsp", "rbp", "rsi", "rdi",
       "r8", "r9", "r10", "r11", "r12", "r13", "r14", "r15"]
R32 = ["eax", "ecx", "edx", "ebx", "esp", "ebp", "esi", "edi"] + ["r%dd" % k for k in range(8, 16)]
R16 = ["ax", "cx", "dx", "bx", "sp", "bp", "si", "di"] + ["r%dw" % k for k in range(8, 16)]
R8L = ["al", "cl", "dl", "bl", "spl", "bpl", "sil", "dil"] + ["r%db" % k for k in range(8, 16)]
R8H = {"ah": "rax", "ch": "rcx", "dh": "rdx", "bh": "rbx"}
REG = {}
for k, n in enumerate(R64):
    REG[R64[k]] = (n, 8); REG[R32[k]] = (n, 4); REG[R16[k]] = (n, 2); REG[R8L[k]] = (n, 1)

UT = {1: "uint8_t", 2: "uint16_t", 4: "uint32_t", 8: "uint64_t"}
ST = {1: "int8_t", 2: "int16_t", 4: "int32_t", 8: "int64_t"}
MASK = {1: "0xFFull", 2: "0xFFFFull", 4: "0xFFFFFFFFull", 8: "0xFFFFFFFFFFFFFFFFull"}

CC = {"e": "zf", "ne": "!zf", "b": "cf", "ae": "!cf", "be": "(cf|zf)", "a": "(!cf&&!zf)",
      "l": "(sf!=of)", "ge": "(sf==of)", "le": "(zf||sf!=of)", "g": "(!zf&&sf==of)",
      "s": "sf", "ns": "!sf", "p": "pf", "np": "!pf", "o": "of", "no": "!of"}
CC_ALIAS = {"z": "e", "nz": "ne", "c": "b", "nae": "b", "nb": "ae", "nc": "ae", "na": "be",
            "nbe": "a", "nge": "l", "nl": "ge", "ng": "le", "nle": "g", "pe": "p", "po": "np"}
CMP_PRED = {"eq": "a == b", "lt": "a < b", "le": "a <= b", "unord": "a != a || b != b",
            "neq": "!(a == b)", "nlt": "!(a < b)", "nle": "!(a <= b)", "ord": "a == a && b == b"}

# guest functions that call a host hook on entry (runtime/debug.c), keyed by symbol name
HOOKS = {
    "__ZN12NxFoundation13FoundationSDK9errorImplE11NxErrorCodePKciPbS3_P13__va_list_tag": "H_physx_error",
    "__ZN12ULocalPlayer13CalcSceneViewEP16FSceneViewFamilyR7FVectorR8FRotatorP9FViewportP18FViewElementDrawer": "H_calc_scene_view",
}

# runtime-provided replacements for imports that cannot be thin native thunks
SPECIAL_IMPORTS = {"_setjmp", "_longjmp", "__Unwind_Resume"}

# keep guest registers in C locals within each function (see cache_regs); RECOMP_NO_CACHE=1 disables
CACHE_REGS = not os.environ.get("RECOMP_NO_CACHE")


def cname(s):
    return re.sub(r"[^A-Za-z0-9_]", "_", s)


def ends_block(i):
    m = i.mnemonic
    return m in ("ret", "jmp", "ud2", "hlt") or m.startswith("ret")


# ---------- register caching ----------
# Generated code addresses guest registers as C.<reg> (fields of *c). Guest memory is reached
# through integer-derived pointers, which clang must assume may point into *c, so every guest store
# (and every ordered load) forces registers back to memory. cache_regs() moves the registers a
# function uses into locals whose address is never taken, writes back the ones it assigns before
# anything that can observe *c (calls, runtime helpers, returns) and reloads them afterwards.
_CREF = re.compile(r"(?<![\w.])C\.(r[a-z0-9]+|xmm\[(\d+)\])")
_CALL = (r"\b(?:F_[0-9a-f]+|I_\w+|H_\w+|call_ind|missing_func|bad_insn|bad_jump)\(c(?:,[^;]*)?\);")
_SYNC = re.compile(r"(%s)(\s*return;)?|\breturn;" % _CALL)
_SETJMP = re.compile(r"\{ RtJmp \*j_ = rt_jmp_slot\(c, (\w+)\); rt_jmp_save\(c, j_\); "
                     r"if \(_setjmp\(j_->host\)\) rt_jmp_restore\(c, j_\); else (\w+) = 0; \}")
_WRITE = re.compile(r"\b(R_\w+|X_\d+)(?:\.[a-z]+\[[^\]]*\])?\s*(?:[-+*/%&|^]|<<|>>)?=(?!=)|&(R_\w+|X_\d+)\b")

def cache_regs(lines):
    """lines: the function body (between the TRACE_FN line and the closing brace)."""
    body = "\n".join(lines)
    regs = set()
    def ren(m):
        if m.group(2) is not None:
            regs.add("X_" + m.group(2)); return "X_" + m.group(2)
        regs.add("R_" + m.group(1)); return "R_" + m.group(1)
    body = _CREF.sub(ren, body)
    body = body.replace("PUSH(", "LPUSH(").replace("POP()", "LPOP()")
    if "LPUSH(" in body or "LPOP()" in body: regs.add("R_rsp")
    if not regs: return lines
    written = {m.group(1) or m.group(2) for m in _WRITE.finditer(body)}
    if "LPUSH(" in body or "LPOP()" in body: written.add("R_rsp")
    written &= regs
    def field(r): return "C.xmm[%s]" % r[2:] if r.startswith("X_") else "C." + r[2:]
    order = sorted(regs, key=lambda r: (r[0], int(r[2:]) if r[0] == "X" else r))
    out_ = " ".join("%s = %s;" % (field(r), r) for r in order if r in written)
    in_ = " ".join("%s = %s;" % (r, field(r)) for r in order)
    body = _SETJMP.sub(lambda m: "{ SYNC_OUT RtJmp *j_ = rt_jmp_slot(c, %s); rt_jmp_save(c, j_); "
                       "if (_setjmp(j_->host)) { rt_jmp_restore(c, j_); SYNC_IN } else %s = 0; }" % (m.group(1), m.group(2)), body)
    def sync(m):
        if m.group(1) is None: return "{ SYNC_OUT return; }"
        if m.group(2): return "{ SYNC_OUT %s return; }" % m.group(1)
        return "{ SYNC_OUT %s SYNC_IN }" % m.group(1)
    body = _SYNC.sub(sync, body)
    if re.search(r"\bc\b(?!->)", body.replace("(c)", "").replace("(c,", "")):
        raise Unsupported("unrecognised use of c")
    decl = []
    gpr = [r for r in order if r.startswith("R_")]
    xmm = [r for r in order if r.startswith("X_")]
    if gpr: decl.append("    uint64_t %s;" % ", ".join("%s = %s" % (r, field(r)) for r in gpr))
    if xmm: decl.append("    XMM %s;" % ", ".join("%s = %s" % (r, field(r)) for r in xmm))
    decl.append("#define SYNC_OUT %s" % out_)
    decl.append("#define SYNC_IN %s" % in_)
    return decl + body.split("\n") + ["#undef SYNC_OUT", "#undef SYNC_IN"]


class Unsupported(Exception):
    pass


class FuncGen:
    def __init__(self, tr, addr):
        self.tr, self.img, self.addr = tr, tr.img, addr
        self.end = self.img.func_end(addr)
        self.code = self.img.read(addr, self.end - addr)
        self.tables = {}
        self.table_bases = set()
        self.ins = self.descend()
        self.addrs = {i.address for i in self.ins}
        self.labels = set()
        self.out = []

    # ---------- operands ----------
    def rn(self, r):
        return self.cur.reg_name(r)

    def mem_addr(self, op):
        m = op.mem
        if m.segment not in (0, X.X86_REG_CS, X.X86_REG_DS, X.X86_REG_ES, X.X86_REG_SS):
            raise Unsupported("segment " + self.rn(m.segment))
        if m.base == X.X86_REG_RIP:
            return "G(0x%xull)" % ((self.cur.address + self.cur.size + m.disp) & MASK_64)
        parts = []
        if m.base:
            parts.append(self.reg64(m.base))
        if m.index:
            parts.append("%s*%du" % (self.reg64(m.index), m.scale) if m.scale != 1 else self.reg64(m.index))
        if m.disp or not parts:
            parts.append("0x%xull" % (m.disp & MASK_64))
        return "(uint64_t)(%s)" % " + ".join(parts)

    def sfx(self, op):
        """'s' for thread-private stack accesses (plain loads/stores); '' for ordered (TSO) accesses"""
        m = op.mem
        return "s" if m.base in (X.X86_REG_RSP, X.X86_REG_RBP) and not m.index else ""

    def reg64(self, r):
        n = self.rn(r)
        if n not in REG or REG[n][1] not in (8, 4):
            raise Unsupported("addr reg " + n)
        b, sz = REG[n]
        return "C.%s" % b if sz == 8 else "(uint32_t)C.%s" % b

    def isx(self, op):
        return op.type == X.X86_OP_REG and self.rn(op.reg).startswith("xmm")

    def rd(self, op, size=None):
        size = size or op.size
        if op.type == X.X86_OP_REG:
            n = self.rn(op.reg)
            if n in R8H:
                return "(uint8_t)(C.%s >> 8)" % R8H[n]
            if n not in REG:
                raise Unsupported("reg " + n)
            b, sz = REG[n]
            return "C.%s" % b if sz == 8 else "(%s)C.%s" % (UT[sz], b)
        if op.type == X.X86_OP_IMM:
            return "(%s)0x%xull" % (UT[size], op.imm & ((1 << (8 * size)) - 1))
        if op.type == X.X86_OP_MEM:
            return "rd%d%s(%s)" % (8 * size, self.sfx(op), self.mem_addr(op))
        raise Unsupported("op")

    def wr(self, op, v):
        if op.type == X.X86_OP_REG:
            n = self.rn(op.reg)
            if n in R8H:
                return "C.{0} = (C.{0} & ~0xFF00ull) | ((uint64_t)(uint8_t)({1}) << 8);".format(R8H[n], v)
            if n not in REG:
                raise Unsupported("wreg " + n)
            b, sz = REG[n]
            if sz == 8: return "C.%s = (uint64_t)(%s);" % (b, v)
            if sz == 4: return "C.%s = (uint32_t)(%s);" % (b, v)   # 32-bit writes zero-extend
            return "C.{0} = (C.{0} & ~{1}) | ({2})({3});".format(b, MASK[sz], UT[sz], v)
        if op.type == X.X86_OP_MEM:
            return "wr%d%s(%s, (%s)(%s));" % (8 * op.size, self.sfx(op), self.mem_addr(op), UT[op.size], v)
        raise Unsupported("wop")

    def xmm(self, op):
        n = self.rn(op.reg)
        if not n.startswith("xmm"): raise Unsupported("xmm " + n)
        return "C.xmm[%s]" % n[3:]

    def src_x(self, op):
        return self.xmm(op) if op.type == X.X86_OP_REG else "rdx%s(%s)" % (self.sfx(op), self.mem_addr(op))

    def src_f(self, op):
        return "%s.f[0]" % self.xmm(op) if op.type == X.X86_OP_REG else "rdf%s(%s)" % (self.sfx(op), self.mem_addr(op))

    def src_d(self, op):
        return "%s.d[0]" % self.xmm(op) if op.type == X.X86_OP_REG else "rdd%s(%s)" % (self.sfx(op), self.mem_addr(op))

    def e(self, s):
        self.out.append("    " + s)

    @staticmethod
    def szf(r, size):
        return "zf = ((%s) & %s) == 0; sf = ((%s) >> %d) & 1; pf = PARITY(r);" % (r, MASK[size], r, 8 * size - 1)

    # ---------- control flow discovery ----------
    def decode(self, a):
        if not (self.addr <= a < self.end): return None
        return next(self.tr.md.disasm(self.code[a - self.addr:a - self.addr + 16], a, 1), None)

    def chain(self, seen, jmp, n=16):
        """the straight-line predecessors of jmp (nearest first), ignoring overlapping decodes"""
        by_end = {}
        for x in seen.values():
            if x: by_end.setdefault(x.address + x.size, []).append(x)
        out, cur = [], jmp.address
        for _ in range(n):
            cands = [x for x in by_end.get(cur, ()) if not ends_block(x)]
            if len(cands) != 1: break
            out.append(cands[0])
            cur = cands[0].address
        return out

    def find_table(self, jmp, seen):
        """clang PIC switch: [lea Rb,[rip+T]] ... movsxd Rt,[Rb+Ri*4]; add Rt,Rb; jmp Rt
        Returns (table address, entry limit or None) or None."""
        reg = jmp.operands[0].reg
        ch = self.chain(seen, jmp)
        # skip instructions between the add and the jmp that do not write the jump register
        jr = self.cur_md_regname(reg)
        while ch and not (ch[0].operands and ch[0].operands[0].type == X.X86_OP_REG
                          and REG.get(ch[0].reg_name(ch[0].operands[0].reg), ("?",))[0] == jr):
            if ch[0].group(cs.CS_GRP_CALL) or ch[0].group(cs.CS_GRP_JUMP): return None
            ch = ch[1:]
        if not ch or ch[0].mnemonic != "add" or len(ch[0].operands) != 2: return None
        o = ch[0].operands
        if o[0].type != X.X86_OP_REG or o[0].reg != reg or o[1].type != X.X86_OP_REG: return None
        tb, idx, load = o[1].reg, None, None
        for k, q in enumerate(ch[1:], 1):
            qo = q.operands
            if q.mnemonic == "movsxd" and qo[0].reg == reg and qo[1].type == X.X86_OP_MEM \
                    and qo[1].mem.base == tb and qo[1].mem.scale == 4:
                idx = qo[1].mem.index
                rest = ch[k + 1:]
                break
        if idx is None: return None
        # table base: in the chain (possibly copied through registers), else a unique lea in the function
        base, r = None, tb
        for q in rest:
            qo = q.operands
            if len(qo) == 2 and qo[0].type == X.X86_OP_REG and qo[0].reg == r:
                if q.mnemonic == "lea" and qo[1].mem.base == X.X86_REG_RIP:
                    base = q.address + q.size + qo[1].mem.disp; break
                if q.mnemonic == "mov" and qo[1].type == X.X86_OP_REG:
                    r = qo[1].reg; continue
                break
        # bound: cmp idx, N (any width, following register copies of idx) or cmp [M], N where idx came from [M]
        names = {self.cur_md_regname(idx)}
        loaded_from = limit = None
        def dst_of(q):
            qo = q.operands
            return REG.get(q.reg_name(qo[0].reg), ("?",))[0] if qo and qo[0].type == X.X86_OP_REG else None
        for q in rest:                          # aliases first: the copy precedes the cmp in program order
            qo = q.operands
            if q.mnemonic in ("mov", "movzx", "movsxd") and len(qo) == 2 and dst_of(q) in names:
                if qo[1].type == X.X86_OP_MEM: loaded_from = q.op_str.split(",", 1)[1].strip().split("ptr ")[-1]
                elif qo[1].type == X.X86_OP_REG: names.add(REG.get(q.reg_name(qo[1].reg), ("?",))[0])
        for q in rest:
            qo = q.operands
            dst = dst_of(q)
            if q.mnemonic == "cmp" and len(qo) == 2 and qo[1].type == X.X86_OP_IMM:
                if (qo[0].type == X.X86_OP_REG and dst in names) or (qo[0].type == X.X86_OP_MEM and loaded_from and
                        q.op_str.split(",")[0].split("ptr ")[-1].strip() == loaded_from):
                    limit = qo[1].imm + 1
                    break
        if base is None:
            # the base register is set elsewhere: take the definitions that reach the jump
            base = self.reaching_lea(seen, jmp, r)
            if base is None: return (None, limit)
        return base, limit

    def reaching_lea(self, seen, jmp, reg):
        """RIP-relative lea value of `reg` reaching `jmp` along every CFG path, or None"""
        name = self.cur_md_regname(reg)
        preds = {}
        for x in seen.values():
            if not x: continue
            nxt = x.address + x.size
            if not ends_block(x): preds.setdefault(nxt, []).append(x)
            if x.group(cs.CS_GRP_JUMP) and x.operands and x.operands[0].type == X.X86_OP_IMM:
                preds.setdefault(x.operands[0].imm, []).append(x)
            for t in self.tables.get(x.address, ()):
                preds.setdefault(t, []).append(x)
        vals, todo, done = set(), [jmp.address], set()
        while todo:
            a = todo.pop()
            for p in preds.get(a, ()):
                if p.address in done: continue
                done.add(p.address)
                po = p.operands
                if po and po[0].type == X.X86_OP_REG and REG.get(p.reg_name(po[0].reg), ("?",))[0] == name \
                        and p.mnemonic not in ("cmp", "test"):
                    if p.mnemonic == "lea" and po[1].mem.base == X.X86_REG_RIP:
                        vals.add(p.address + p.size + po[1].mem.disp)
                        continue
                    return None                      # defined some other way
                if p.group(cs.CS_GRP_CALL) and name in ("rax", "rcx", "rdx", "rsi", "rdi", "r8", "r9", "r10", "r11"):
                    return None                      # clobbered by a call
                todo.append(p.address)
            if len(done) > 20000: return None
        return vals.pop() if len(vals) == 1 else None

    def vararg_save(self, jmp, seen):
        """GCC-style varargs prologue: lea R,[rip+E]; sub R, al*4; jmp R into a run of 4-byte movaps saves.
        Records the 9 possible targets (al = 0..8 vector registers) as a jump table."""
        jr = self.cur_md_regname(jmp.operands[0].reg)
        ch = self.chain(seen, jmp, 6)
        writes = [q for q in ch if q.operands and q.operands[0].type == X.X86_OP_REG
                  and REG.get(q.reg_name(q.operands[0].reg), ("?",))[0] == jr]
        if len(writes) < 2 or writes[0].mnemonic != "sub" or writes[1].mnemonic != "lea" \
                or writes[1].operands[1].mem.base != X.X86_REG_RIP:
            return False
        e = writes[1].address + writes[1].size + writes[1].operands[1].mem.disp
        self.tables[jmp.address] = [e - 4 * k for k in range(9) if self.addr <= e - 4 * k < self.end]
        return True

    def table_shaped(self, jmp):
        """jmp reg whose register was last written by `add reg, reg` (a PIC switch dispatch)"""
        seen = {x.address: x for x in self.ins}
        jr = self.cur_md_regname(jmp.operands[0].reg)
        for q in self.chain(seen, jmp):
            qo = q.operands
            if qo and qo[0].type == X.X86_OP_REG and REG.get(q.reg_name(qo[0].reg), ("?",))[0] == jr:
                return q.mnemonic == "add" and len(qo) == 2 and qo[1].type == X.X86_OP_REG
            if q.group(cs.CS_GRP_CALL) or q.group(cs.CS_GRP_JUMP): return False
        return False

    def cur_md_regname(self, r):
        return REG.get(self.tr.md.reg_name(r), ("?",))[0]

    def walk(self, seen, work, pending):
        while work:
            a = work.pop()
            while a not in seen:
                i = self.decode(a)
                seen[a] = i
                if i is None: break
                if i.group(cs.CS_GRP_JUMP) and i.operands and i.operands[0].type == X.X86_OP_IMM:
                    t = i.operands[0].imm
                    if self.addr <= t < self.end: work.append(t)
                if i.mnemonic == "jmp" and i.operands[0].type == X.X86_OP_REG and self.vararg_save(i, seen):
                    work.extend(self.tables[i.address])
                elif i.mnemonic == "jmp" and i.operands[0].type == X.X86_OP_REG:
                    ft = self.find_table(i, seen)
                    if ft and ft[0] is None:
                        self.retry[i.address] = i                # base defined in code not decoded yet
                    elif ft:
                        base, limit = ft
                        if limit is None:
                            pending[i.address] = base          # read once trusted code is known
                        else:
                            tbl = [base + self.img.i32(base + 4 * k) for k in range(min(limit, 4096))]
                            tbl = [t for t in tbl if self.addr <= t < self.end]
                            self.tables[i.address] = tbl
                            work.extend(tbl)
                if ends_block(i): break
                a = i.address + i.size

    def descend(self):
        seen, pending = {}, {}
        self.retry = {}
        self.walk(seen, [self.addr], pending)
        while pending or self.retry:
            for ja, i in list(self.retry.items()):
                del self.retry[ja]
                ft = self.find_table(i, seen)
                if ft and ft[0] is not None:
                    base, limit = ft
                    if limit is None:
                        pending[ja] = base
                    else:
                        tbl = [base + self.img.i32(base + 4 * k) for k in range(min(limit, 4096))]
                        self.tables[ja] = [t for t in tbl if self.addr <= t < self.end]
                        self.walk(seen, list(self.tables[ja]), pending)
            if not pending:
                break
            # unbounded tables end where they run into decoded code or another table
            covered = set()
            for x in seen.values():
                if x: covered.update(range(x.address, x.address + x.size))
            starts = {x.address for x in seen.values() if x}
            bases = set(pending.values()) | {b for b in self.table_bases}
            work = []
            for ja, base in list(pending.items()):
                tbl = []
                for k in range(1024):
                    ea = base + 4 * k
                    if ea in covered or (k and ea in bases) or ea + 4 > self.end: break
                    t = base + self.img.i32(ea)
                    if not (self.addr <= t < self.end) or (t in covered and t not in starts): break
                    tbl.append(t)
                self.tables[ja] = tbl
                self.table_bases.add(base)
                work.extend(tbl)
            pending = {}
            # the re-walk may find further tables; their pending entries get the same treatment
            self.walk(seen, work, pending)
            pending = {a: b for a, b in pending.items() if a not in self.tables}
        self.bad_decode = [a for a, x in seen.items() if x is None and self.addr <= a < self.end]
        return sorted((x for x in seen.values() if x), key=lambda x: x.address)

    # ---------- function ----------
    def gen(self):
        for i in self.ins:
            if i.group(cs.CS_GRP_JUMP) and i.operands and i.operands[0].type == X.X86_OP_IMM:
                if i.operands[0].imm in self.addrs: self.labels.add(i.operands[0].imm)
            self.labels.update(t for t in self.tables.get(i.address, ()) if t in self.addrs)
        for k, i in enumerate(self.ins):
            nx = self.ins[k + 1].address if k + 1 < len(self.ins) else None
            if not ends_block(i) and nx != i.address + i.size and (i.address + i.size) in self.addrs:
                self.labels.add(i.address + i.size)
        f = self.out
        # restrict: guest memory never overlaps the CPU state, so guest registers can live in host registers across stores
        f.append("void F_%x(CPU *restrict c) { /* %s */" % (self.addr, self.img.func_names[self.addr]))
        f.append("    uint64_t cf = 0, zf = 0, sf = 0, of = 0, pf = 0; (void)cf; (void)zf; (void)sf; (void)of; (void)pf;")
        f.append("    TRACE_FN(0x%x);" % self.addr)
        hook = HOOKS.get(self.img.func_names[self.addr])
        if hook:                      # host diagnostics hook, runs with the guest's entry registers
            f.append("    %s(c);" % hook)
        last = None
        for i in self.ins:
            if last is not None and not ends_block(last) and i.address != last.address + last.size:
                ft = last.address + last.size
                self.e("goto L_%x;" % ft if ft in self.addrs else self.tail(ft))
            self.cur = i
            if i.address in self.labels:
                f.append("L_%x:;" % i.address)
            try:
                self.insn(i)
            except Unsupported as ex:
                self.e("bad_insn(c, 0x%x); /* %s %s : %s */" % (i.address, i.mnemonic, i.op_str, ex))
                key = i.mnemonic if str(ex) == i.mnemonic else "%s (%s)" % (i.mnemonic, ex)
                self.tr.unsupported[key] += 1
            last = i
        if last is not None and not ends_block(last):
            self.e(self.tail(last.address + last.size))
        self.tr.unsupported["<undecodable>"] += len(self.bad_decode)
        if CACHE_REGS:
            k = next(n for n, ln in enumerate(f) if ln.startswith("    TRACE_FN("))
            head, body = f[:k + 1], f[k + 1:]
            try:
                f = head + cache_regs(body)
            except Unsupported as ex:
                self.tr.unsupported["<no register caching: %s>" % ex] += 1
        f.append("}")
        return "\n".join(f)

    def callee(self, t):
        """C call expression for a direct transfer to guest address t, or None."""
        if t in self.img.func_names:
            return "F_%x(c)" % t
        if t in self.img.stubs:
            return self.tr.import_call(self.img.stubs[t])
        return None

    def tail(self, t):
        ce = self.callee(t)
        if ce is None:
            return "missing_func(c, G(0x%xull)); return;" % t
        return "%s; return;" % ce

    # ---------- instructions ----------
    def insn(self, i):
        m, ops = i.mnemonic, i.operands
        nxt = i.address + i.size
        e = self.e
        if m.startswith("nop") or m in ("cld", "wait", "lfence", "mfence", "sfence", "pause", "emms"):
            return
        if m in ("mov", "movabs"):
            e(self.wr(ops[0], self.rd(ops[1], ops[0].size))); return
        if m == "movzx":
            e(self.wr(ops[0], "(uint64_t)" + self.rd(ops[1]))); return
        if m in ("movsx", "movsxd"):
            e(self.wr(ops[0], "(uint64_t)(int64_t)(%s)%s" % (ST[ops[1].size], self.rd(ops[1])))); return
        if m == "lea":
            e(self.wr(ops[0], self.mem_addr(ops[1]))); return
        if m == "push":
            e("PUSH(%s);" % ("(uint64_t)(int64_t)(int32_t)0x%xu" % (ops[0].imm & 0xFFFFFFFF)
                             if ops[0].type == X.X86_OP_IMM else self.rd(ops[0], 8))); return
        if m == "pop":
            e("{ uint64_t v = POP(); %s }" % self.wr(ops[0], "v")); return
        if m == "leave":
            e("C.rsp = C.rbp; C.rbp = POP();"); return
        if m == "ret":
            e("C.rsp += %d; return;" % (8 + (ops[0].imm if ops else 0))); return
        if m in ("ud2", "hlt"):
            e("bad_insn(c, 0x%x); return;" % i.address); return
        if m == "cdqe":
            e("C.rax = (uint64_t)(int64_t)(int32_t)C.rax;"); return
        if m == "cwde":
            e("C.rax = (uint32_t)(int32_t)(int16_t)C.rax;"); return
        if m == "cdq":
            e("C.rdx = (int32_t)C.rax < 0 ? 0xFFFFFFFFull : 0;"); return
        if m == "cqo":
            e("C.rdx = (int64_t)C.rax < 0 ? ~0ull : 0;"); return
        if m in ("add", "sub", "cmp", "and", "or", "xor", "test", "adc", "sbb"):
            return self.alu(m, ops)
        if m in ("inc", "dec", "neg", "not"):
            return self.unary(m, ops[0])
        if m in ("shl", "sal", "shr", "sar", "rol", "ror"):
            return self.shift(m, ops)
        if m in ("imul", "mul", "div", "idiv"):
            return self.muldiv(m, ops)
        if m == "call":
            return self.call(i, ops[0], nxt)
        if m == "jmp":
            return self.jmp(i, ops[0])
        if m in ("jrcxz", "jecxz"):
            t = ops[0].imm
            reg = "C.rcx" if m == "jrcxz" else "(uint32_t)C.rcx"
            e("if (!%s) %s" % (reg, "goto L_%x;" % t if t in self.addrs else "{ %s }" % self.tail(t)))
            return
        if m.startswith("j"):
            t = ops[0].imm
            e("if (%s) %s" % (self.cc(m[1:]), "goto L_%x;" % t if t in self.addrs else "{ %s }" % self.tail(t)))
            return
        if m.startswith("set"):
            e(self.wr(ops[0], "(%s) ? 1 : 0" % self.cc(m[3:]))); return
        if m.startswith("cmov"):
            # a 32-bit cmov zero-extends the destination even when the condition is false
            d = ops[0]
            keep = self.wr(d, self.rd(d)) if d.size == 4 else ""
            e("if (%s) %s%s" % (self.cc(m[4:]), self.wr(d, self.rd(ops[1])), (" else " + keep) if keep else ""))
            return
        if m in ("fld", "fstp") and ops[0].type == X.X86_OP_MEM and ops[0].size == 10:
            # only use in the game: copying an 80-bit long double through the x87 stack
            if m == "fld": e("C.x87top = (C.x87top - 1) & 7; memcpy(C.x87raw[C.x87top], (void *)%s, 10);" % self.mem_addr(ops[0]))
            else: e("memcpy((void *)%s, C.x87raw[C.x87top], 10); C.x87top = (C.x87top + 1) & 7;" % self.mem_addr(ops[0]))
            return
        if self.strop(m, ops) or self.extra(m, ops) or self.sse(m, ops):
            return
        raise Unsupported(m)

    def cc(self, c):
        c = CC_ALIAS.get(c, c)
        if c not in CC: raise Unsupported("cc " + c)
        return CC[c]

    def jmp(self, i, op):
        e = self.e
        if op.type == X.X86_OP_IMM:
            t = op.imm
            e("goto L_%x;" % t if t in self.addrs else self.tail(t)); return
        if op.type == X.X86_OP_MEM and op.mem.base == X.X86_REG_RIP:
            slot = i.address + i.size + op.mem.disp
            name = self.img.ptrs.get(slot)
            if name:
                e("%s; return;" % self.tr.import_call(name)); return
        tbl = self.tables.get(i.address)
        v = self.rd(op, 8)
        if tbl:
            cases = " ".join("case 0x%xull: goto L_%x;" % (t, t) for t in sorted(set(tbl)) if t in self.addrs)
            e("switch (%s - GSLIDE) { %s default: bad_jump(c, %s, 0x%x); return; }" % (v, cases, v, i.address))
        else:
            if op.type == X.X86_OP_REG and self.table_shaped(i):
                self.tr.unsupported["<unresolved jump table>"] += 1
            e("{ uint64_t t = %s; call_ind(c, t); return; }" % v)

    def call(self, i, op, nxt):
        e = self.e
        if op.type == X.X86_OP_IMM:
            t = op.imm
            if t in self.img.stubs and self.img.stubs[t] == "_setjmp":
                # host setjmp must run in this function's own frame
                e("{ RtJmp *j_ = rt_jmp_slot(c, C.rdi); rt_jmp_save(c, j_); if (_setjmp(j_->host)) rt_jmp_restore(c, j_); else C.rax = 0; }")
                return
            ce = self.callee(t)
            e("PUSH(G(0x%xull)); %s;" % (nxt, ce or "missing_func(c, G(0x%xull))" % t))
            return
        if op.type == X.X86_OP_MEM and op.mem.base == X.X86_REG_RIP:
            name = self.img.ptrs.get(i.address + i.size + op.mem.disp)
            if name:
                e("PUSH(G(0x%xull)); %s;" % (nxt, self.tr.import_call(name))); return
        e("{ uint64_t t = %s; PUSH(G(0x%xull)); call_ind(c, t); }" % (self.rd(op, 8), nxt))

    def alu(self, m, ops):
        d, s = ops
        n = d.size
        sign = 8 * n - 1
        if m in ("xor", "sub") and d.type == X.X86_OP_REG and s.type == X.X86_OP_REG and d.reg == s.reg:
            self.e(self.wr(d, "0") + " zf = 1; sf = 0; cf = 0; of = 0; pf = 1;"); return
        st = ["uint64_t a = %s, b = (uint64_t)(int64_t)(%s)%s, r;" % (self.rd(d), ST[n], self.rd(s, n))
              if s.type == X.X86_OP_IMM else "uint64_t a = %s, b = %s, r;" % (self.rd(d), self.rd(s, n))]
        Mk = MASK[n]
        if m in ("add", "adc"):
            if n == 8:
                st.append("r = a + b%s; cf = %s;" % (" + cf" if m == "adc" else "",
                          "r < a" if m == "add" else "(r < a) || (cf && r == a)"))
            else:
                st.append("r = (a + (b & %s)%s) & %s; cf = ((a & %s) + (b & %s)%s) > %s;"
                          % (Mk, " + cf" if m == "adc" else "", Mk, Mk, Mk, " + cf" if m == "adc" else "", Mk))
            st.append("of = (((a ^ r) & (b ^ r)) >> %d) & 1;" % sign)
        elif m in ("sub", "cmp", "sbb"):
            bb = "b & %s" % Mk if n != 8 else "b"
            if m == "sbb":
                st.append("r = (a - (%s) - cf) & %s; cf = (a & %s) < (%s) || (cf && (a & %s) == (%s));"
                          % (bb, Mk, Mk, bb, Mk, bb))
            else:
                st.append("r = (a - (%s)) & %s; cf = (a & %s) < (%s);" % (bb, Mk, Mk, bb))
            st.append("of = (((a ^ b) & (a ^ r)) >> %d) & 1;" % sign)
        else:
            op = {"and": "&", "test": "&", "or": "|", "xor": "^"}[m]
            st.append("r = (a %s b) & %s; cf = 0; of = 0;" % (op, Mk))
        st.append(self.szf("r", n))
        if m not in ("cmp", "test"):
            st.append(self.wr(d, "r"))
        self.e("{ " + " ".join(st) + " }")

    def unary(self, m, d):
        n = d.size; sign = 8 * n - 1; Mk = MASK[n]
        a = self.rd(d)
        if m == "not":
            self.e(self.wr(d, "~%s" % a)); return
        if m == "inc":
            body = "r = (a + 1) & %s; of = r == (1ull << %d);" % (Mk, sign)
        elif m == "dec":
            body = "r = (a - 1) & %s; of = a == (1ull << %d);" % (Mk, sign)
        else:
            body = "r = (0ull - a) & %s; cf = a != 0; of = a == (1ull << %d);" % (Mk, sign)
        self.e("{ uint64_t a = %s, r; %s %s %s }" % (a, body, self.szf("r", n), self.wr(d, "r")))

    def shift(self, m, ops):
        d = ops[0]; n = d.size; bits = 8 * n; Mk = MASK[n]
        cm = 63 if n == 8 else 31
        if len(ops) == 1: cnt = "1u"
        elif ops[1].type == X.X86_OP_IMM: cnt = "%du" % (ops[1].imm & cm)
        else: cnt = "((uint32_t)C.rcx & %du)" % cm
        a = self.rd(d)
        if m in ("shl", "sal"):
            body = "r = (a << cc) & %s; cf = (a >> (%d - cc)) & 1; of = ((r >> %d) & 1) ^ cf;" % (Mk, bits, bits - 1)
        elif m == "shr":
            body = "r = a >> cc; cf = (a >> (cc - 1)) & 1; of = (a >> %d) & 1;" % (bits - 1)
        elif m == "sar":
            body = "r = (uint64_t)(((int64_t)(%s)a) >> cc) & %s; cf = (((int64_t)(%s)a) >> (cc - 1)) & 1; of = 0;" % (ST[n], Mk, ST[n])
        else:
            k = "(cc %% %d)" % bits
            if m == "rol":
                body = "uint32_t k = %s; r = k ? ((a << k) | (a >> (%d - k))) & %s : a; cf = r & 1; of = ((r >> %d) ^ r) & 1;" % (k, bits, Mk, bits - 1)
            else:
                body = "uint32_t k = %s; r = k ? ((a >> k) | (a << (%d - k))) & %s : a; cf = (r >> %d) & 1; of = ((r >> %d) ^ (r >> %d)) & 1;" % (k, bits, Mk, bits - 1, bits - 1, bits - 2)
            self.e("{ uint32_t cc = %s; if (cc) { uint64_t a = %s, r; %s %s } }" % (cnt, a, body, self.wr(d, "r")))
            return
        self.e("{ uint32_t cc = %s; if (cc) { uint64_t a = %s, r; %s %s %s } }" % (cnt, a, body, self.szf("r", n), self.wr(d, "r")))

    def muldiv(self, m, ops):
        e = self.e
        if m == "imul" and len(ops) >= 2:
            d = ops[0]; n = d.size
            a = self.rd(ops[1]) if len(ops) == 3 else self.rd(d)
            b = self.rd(ops[2], n) if len(ops) == 3 else self.rd(ops[1], n)
            wide, nar = {8: ("__int128", "int64_t"), 4: ("int64_t", "int32_t"), 2: ("int32_t", "int16_t")}[n]
            e("{ %s p = (%s)(%s)%s * (%s)(%s)%s; uint64_t r = (uint64_t)(%s)p; "
              "cf = of = p != (%s)(%s)r; %s %s }" % (wide, wide, nar, a, wide, nar, b, nar, wide, nar,
                                                    self.szf("r", n), self.wr(d, "r")))
            return
        s = ops[0]; n = s.size
        v = self.rd(s)
        if n == 8:
            if m == "mul":
                e("{ unsigned __int128 p = (unsigned __int128)C.rax * %s; C.rax = (uint64_t)p; C.rdx = (uint64_t)(p >> 64); cf = of = C.rdx != 0; }" % v)
            elif m == "imul":
                e("{ __int128 p = (__int128)(int64_t)C.rax * (int64_t)%s; C.rax = (uint64_t)p; C.rdx = (uint64_t)((unsigned __int128)p >> 64); cf = of = p != (int64_t)C.rax; }" % v)
            elif m == "div":
                e("{ unsigned __int128 nn = ((unsigned __int128)C.rdx << 64) | C.rax; uint64_t dd = %s; C.rax = (uint64_t)(nn / dd); C.rdx = (uint64_t)(nn %% dd); }" % v)
            else:
                e("{ __int128 nn = (__int128)(((unsigned __int128)C.rdx << 64) | C.rax); int64_t dd = (int64_t)%s; C.rax = (uint64_t)(int64_t)(nn / dd); C.rdx = (uint64_t)(int64_t)(nn %% dd); }" % v)
        elif n == 4:
            if m == "mul":
                e("{ uint64_t p = (uint64_t)(uint32_t)C.rax * %s; C.rax = (uint32_t)p; C.rdx = (uint32_t)(p >> 32); cf = of = C.rdx != 0; }" % v)
            elif m == "imul":
                e("{ int64_t p = (int64_t)(int32_t)C.rax * (int32_t)%s; C.rax = (uint32_t)p; C.rdx = (uint32_t)((uint64_t)p >> 32); cf = of = p != (int32_t)C.rax; }" % v)
            elif m == "div":
                e("{ uint64_t nn = ((uint64_t)(uint32_t)C.rdx << 32) | (uint32_t)C.rax; uint32_t dd = %s; C.rax = (uint32_t)(nn / dd); C.rdx = (uint32_t)(nn %% dd); }" % v)
            else:
                e("{ int64_t nn = (int64_t)(((uint64_t)(uint32_t)C.rdx << 32) | (uint32_t)C.rax); int32_t dd = (int32_t)%s; C.rax = (uint32_t)(int32_t)(nn / dd); C.rdx = (uint32_t)(int32_t)(nn %% dd); }" % v)
        elif n == 2:
            if m in ("mul", "imul"):
                t = "uint32_t)(uint16_t" if m == "mul" else "int32_t)(int16_t"
                e("{ uint32_t p = (uint32_t)((%s)C.rax * (%s)%s); C.rax = (C.rax & ~0xFFFFull) | (uint16_t)p; C.rdx = (C.rdx & ~0xFFFFull) | (uint16_t)(p >> 16); cf = of = (p >> 16) != 0; }" % (t, t, v))
            elif m == "div":
                e("{ uint32_t nn = ((uint32_t)(uint16_t)C.rdx << 16) | (uint16_t)C.rax; uint16_t dd = %s; C.rax = (C.rax & ~0xFFFFull) | (uint16_t)(nn / dd); C.rdx = (C.rdx & ~0xFFFFull) | (uint16_t)(nn %% dd); }" % v)
            else:
                e("{ int32_t nn = (int32_t)(((uint32_t)(uint16_t)C.rdx << 16) | (uint16_t)C.rax); int16_t dd = (int16_t)%s; C.rax = (C.rax & ~0xFFFFull) | (uint16_t)(nn / dd); C.rdx = (C.rdx & ~0xFFFFull) | (uint16_t)(nn %% dd); }" % v)
        else:
            if m == "mul":
                e("{ uint16_t p = (uint16_t)((uint8_t)C.rax * (uint8_t)%s); C.rax = (C.rax & ~0xFFFFull) | p; cf = of = (p >> 8) != 0; }" % v)
            elif m == "imul":
                e("{ int16_t p = (int16_t)((int8_t)C.rax * (int8_t)%s); C.rax = (C.rax & ~0xFFFFull) | (uint16_t)p; cf = of = p != (int8_t)p; }" % v)
            elif m == "div":
                e("{ uint16_t nn = (uint16_t)C.rax; uint8_t dd = %s; C.rax = (C.rax & ~0xFFFFull) | (uint16_t)((nn %% dd) << 8 | (uint8_t)(nn / dd)); }" % v)
            else:
                e("{ int16_t nn = (int16_t)C.rax; int8_t dd = (int8_t)%s; C.rax = (C.rax & ~0xFFFFull) | (uint16_t)(((uint8_t)(nn %% dd)) << 8 | (uint8_t)(nn / dd)); }" % v)

    # ---------- strings ----------
    def strop(self, m, ops):
        mm = re.match(r"(rep |repe |repne )?(movs|stos|lods|scas|cmps)([bwdq])$", m)
        if not mm or any(self.isx(o) for o in ops):
            return False   # SSE movsd/cmpsd share the mnemonic
        rep, op, w = mm.group(1), mm.group(2), {"b": 1, "w": 2, "d": 4, "q": 8}[mm.group(3)]
        if op not in ("movs", "stos"):
            raise Unsupported(m)
        b = 8 * w
        if not rep:
            self.e("wr%d(C.rdi, rd%d(C.rsi)); C.rsi += %d; C.rdi += %d;" % (b, b, w, w) if op == "movs"
                   else "wr%d(C.rdi, (%s)C.rax); C.rdi += %d;" % (b, UT[w], w))
        elif op == "movs":
            self.e("if (C.rcx) { memmove((void *)C.rdi, (void *)C.rsi, %du * C.rcx); C.rsi += %d * C.rcx; C.rdi += %d * C.rcx; C.rcx = 0; }" % (w, w, w))
        else:
            self.e("while (C.rcx) { wr%d(C.rdi, (%s)C.rax); C.rdi += %d; C.rcx--; }" % (b, UT[w], w))
        return True

    # ---------- misc integer / atomic ----------
    def extra(self, m, ops):
        e = self.e
        if m == "bswap":
            d = ops[0]
            e(self.wr(d, "__builtin_bswap%d(%s)" % (8 * d.size, self.rd(d)))); return True
        if m in ("shld", "shrd"):
            d, s_, k = ops
            n = 8 * d.size
            if n not in (32, 64): raise Unsupported(m + "16")
            cm = n - 1
            cnt = "%du" % (k.imm & cm) if k.type == X.X86_OP_IMM else "((uint32_t)C.rcx & %du)" % cm
            if m == "shld": body = "r = ((a << cc) | (b >> (%d - cc))) & %s; cf = (a >> (%d - cc)) & 1;" % (n, MASK[n // 8], n)
            else: body = "r = ((a >> cc) | (b << (%d - cc))) & %s; cf = (a >> (cc - 1)) & 1;" % (n, MASK[n // 8])
            e("{ uint32_t cc = %s; if (cc) { uint64_t a = %s, b = %s, r; %s %s %s } }" % (cnt, self.rd(d), self.rd(s_), body, self.szf("r", n // 8), self.wr(d, "r")))
            return True
        if m == "bt":
            d, b = ops
            if d.type == X.X86_OP_MEM and b.type == X.X86_OP_REG:
                e("{ int64_t bi = (int64_t)(%s)%s; cf = (rd8(%s + (uint64_t)(bi >> 3)) >> (bi & 7)) & 1; }" % (ST[b.size], self.rd(b), self.mem_addr(d)))
            else:
                e("cf = (%s >> (%s & %d)) & 1;" % (self.rd(d), self.rd(b, d.size), 8 * d.size - 1))
            return True
        if m in ("bsr", "bsf"):
            d, s_ = ops
            f = ("%d - __builtin_clzll(v)" % 63) if m == "bsr" else "__builtin_ctzll(v)"
            e("{ uint64_t v = %s; zf = v == 0; if (v) %s }" % (self.rd(s_), self.wr(d, f)))
            return True
        if m == "xchg":
            a, b = ops
            e("{ uint64_t t = %s; %s %s }" % (self.rd(a), self.wr(a, self.rd(b)), self.wr(b, "t")))
            return True
        if m in ("clc", "stc", "cmc"):
            e({"clc": "cf = 0;", "stc": "cf = 1;", "cmc": "cf ^= 1;"}[m]); return True
        if m in ("sti", "cli"):
            e("bad_insn(c, 0x%x); return;" % self.cur.address); return True   # privileged; only in dead bytes
        if m == "rdtsc":
            e("{ uint64_t t = rt_rdtsc(); C.rax = (uint32_t)t; C.rdx = (uint32_t)(t >> 32); }"); return True
        if m == "cpuid":
            e("rt_cpuid(c);"); return True
        if m.startswith("lock "):
            op = m[5:]
            d = ops[0]
            if d.type != X.X86_OP_MEM or d.size not in (4, 8): raise Unsupported(m)
            n = d.size; t = UT[n]
            p = "(%s *)(%s)" % (t, self.mem_addr(d))
            if op == "cmpxchg":
                e("{ %s exp = (%s)C.rax; zf = __atomic_compare_exchange_n(%s, &exp, (%s)%s, 0, __ATOMIC_SEQ_CST, __ATOMIC_SEQ_CST); if (!zf) C.rax = exp; }"
                  % (t, t, p, t, self.rd(ops[1])))
            elif op == "xadd":
                e("{ %s b = %s; %s a = __atomic_fetch_add(%s, b, __ATOMIC_SEQ_CST); uint64_t r = (%s)(a + b); %s %s }" % (t, self.rd(ops[1]), t, p, t, self.szf("r", n), self.wr(ops[1], "a")))
            elif op in ("inc", "dec", "add", "sub", "or", "and", "xor"):
                b = "1" if op in ("inc", "dec") else self.rd(ops[1], n)
                fn = {"inc": "add", "dec": "sub"}.get(op, op)
                e("{ uint64_t r = __atomic_%s_fetch(%s, (%s)%s, __ATOMIC_SEQ_CST); %s }" % (fn, p, t, b, self.szf("r", n)))
            else:
                raise Unsupported(m)
            return True
        return False

    # ---------- SSE ----------
    def sse(self, m, ops):
        e = self.e
        d = ops[0] if ops else None
        s = ops[1] if len(ops) > 1 else None
        X_ = self.xmm
        if m in ("ldmxcsr", "stmxcsr"):
            e("C.mxcsr = rd32(%s);" % self.mem_addr(d) if m == "ldmxcsr" else "wr32(%s, C.mxcsr);" % self.mem_addr(d))
            return True
        if m in ("movss", "movsd"):
            fl, w = ("f", "wrf") if m == "movss" else ("d", "wrd")
            if d.type == X.X86_OP_MEM: e("%s%s(%s, %s.%s[0]);" % (w, self.sfx(d), self.mem_addr(d), X_(s), fl))
            elif s.type == X.X86_OP_MEM: e("{ XMM x = {0}; x.%s[0] = %s; %s = x; }" % (fl, self.src_f(s) if fl == "f" else self.src_d(s), X_(d)))
            else: e("%s.%s[0] = %s.%s[0];" % (X_(d), fl, X_(s), fl))
            return True
        if m in ("movaps", "movups", "movdqa", "movdqu", "movapd", "movupd"):
            if d.type == X.X86_OP_MEM: e("wrx%s(%s, %s);" % (self.sfx(d), self.mem_addr(d), X_(s)))
            else: e("%s = %s;" % (X_(d), self.src_x(s)))
            return True
        if m == "movd" or (m == "movq" and not (self.isx(d) and (self.isx(s) or s.type == X.X86_OP_MEM)) and not (d.type == X.X86_OP_MEM)):
            n = 4 if m == "movd" else 8
            if self.isx(d): e("{ XMM x = {0}; x.q[0] = %s; %s = x; }" % (self.rd(s, n), X_(d)))
            else: e(self.wr(d, "%s.%s[0]" % (X_(s), "u" if n == 4 else "q")))
            return True
        if m == "movq":
            if self.isx(d): e("{ XMM x = {0}; x.q[0] = %s; %s = x; }" % ("%s.q[0]" % X_(s) if self.isx(s) else "rd64(%s)" % self.mem_addr(s), X_(d)))
            else: e("wr64(%s, %s.q[0]);" % (self.mem_addr(d), X_(s)))
            return True
        if m in ("movhpd", "movhps", "movlpd", "movlps"):
            k = 1 if m[3] == "h" else 0
            if d.type == X.X86_OP_MEM: e("wr64(%s, %s.q[%d]);" % (self.mem_addr(d), X_(s), k))
            else: e("%s.q[%d] = rd64(%s);" % (X_(d), k, self.mem_addr(s)))
            return True
        if m == "movlhps": e("%s.q[1] = %s.q[0];" % (X_(d), X_(s))); return True
        if m == "movhlps": e("%s.q[0] = %s.q[1];" % (X_(d), X_(s))); return True
        if m == "movmskps":
            e(self.wr(d, "xmm_movmskps(%s)" % X_(s))); return True
        if m in ("pextrw",):
            e(self.wr(d, "%s.w[%d]" % (X_(s), ops[2].imm & 7))); return True
        if m in ("pinsrw",):
            e("%s.w[%d] = (uint16_t)%s;" % (X_(d), ops[2].imm & 7, self.rd(s, 2) if s.type == X.X86_OP_MEM else "(uint16_t)" + self.rd(s))); return True
        mc = re.match(r"cmp(eq|lt|le|unord|neq|nlt|nle|ord)(ss|sd|ps|pd)$", m)
        if mc:
            pred, ty = mc.groups()
            cond = CMP_PRED[pred]
            if ty == "ss": e("{ float a = %s.f[0], b = %s; %s.u[0] = (%s) ? ~0u : 0; }" % (X_(d), self.src_f(s), X_(d), cond))
            elif ty == "sd": e("{ double a = %s.d[0], b = %s; %s.q[0] = (%s) ? ~0ull : 0; }" % (X_(d), self.src_d(s), X_(d), cond))
            elif ty == "ps": e("{ XMM sv = %s; for (int k = 0; k < 4; k++) { float a = %s.f[k], b = sv.f[k]; %s.u[k] = (%s) ? ~0u : 0; } }" % (self.src_x(s), X_(d), X_(d), cond))
            else: e("{ XMM sv = %s; for (int k = 0; k < 2; k++) { double a = %s.d[k], b = sv.d[k]; %s.q[k] = (%s) ? ~0ull : 0; } }" % (self.src_x(s), X_(d), X_(d), cond))
            return True
        ar = {"add": "+", "sub": "-", "mul": "*", "div": "/"}
        mm = re.match(r"(add|sub|mul|div)(ss|sd|ps|pd)$", m)
        if mm:
            o, ty = ar[mm.group(1)], mm.group(2)
            if ty == "ss": e("%s.f[0] = %s.f[0] %s %s;" % (X_(d), X_(d), o, self.src_f(s)))
            elif ty == "sd": e("%s.d[0] = %s.d[0] %s %s;" % (X_(d), X_(d), o, self.src_d(s)))
            else:
                fl, nn = ("f", 4) if ty == "ps" else ("d", 2)
                e("{ XMM sv = %s; for (int k = 0; k < %d; k++) %s.%s[k] %s= sv.%s[k]; }" % (self.src_x(s), nn, X_(d), fl, o, fl))
            return True
        mm = re.match(r"(min|max)(ss|sd|ps|pd)$", m)
        if mm:
            o = "<" if mm.group(1) == "min" else ">"
            ty = mm.group(2)
            fl, nn, ct = {"ss": ("f", 1, "float"), "sd": ("d", 1, "double"), "ps": ("f", 4, "float"), "pd": ("d", 2, "double")}[ty]
            # x86 semantics: result is the second operand unless dst strictly wins (NaN -> src)
            if nn == 1:
                e("{ %s a = %s.%s[0], b = %s; %s.%s[0] = (a %s b) ? a : b; }"
                  % (ct, X_(d), fl, self.src_f(s) if fl == "f" else self.src_d(s), X_(d), fl, o))
            else:
                e("{ XMM sv = %s; for (int k = 0; k < %d; k++) { %s a = %s.%s[k], b = sv.%s[k]; %s.%s[k] = (a %s b) ? a : b; } }"
                  % (self.src_x(s), nn, ct, X_(d), fl, fl, X_(d), fl, o))
            return True
        if m in ("sqrtss", "sqrtsd"):
            if m == "sqrtss": e("%s.f[0] = sqrtf(%s);" % (X_(d), self.src_f(s)))
            else: e("%s.d[0] = sqrt(%s);" % (X_(d), self.src_d(s)))
            return True
        if m in ("rcpps", "rsqrtps"):
            f = "1.0f / sv.f[k]" if m == "rcpps" else "1.0f / sqrtf(sv.f[k])"
            e("{ XMM sv = %s; for (int k = 0; k < 4; k++) %s.f[k] = %s; }" % (self.src_x(s), X_(d), f)); return True
        if m in ("ucomiss", "comiss", "ucomisd", "comisd"):
            a, b = ("%s.f[0]" % X_(d), self.src_f(s)) if m.endswith("ss") else ("%s.d[0]" % X_(d), self.src_d(s))
            e("{ double a = %s, b = %s; if (a != a || b != b) { zf = pf = cf = 1; } else { zf = a == b; pf = 0; cf = a < b; } of = sf = 0; }" % (a, b))
            return True
        if m == "cvtss2sd": e("%s.d[0] = (double)%s;" % (X_(d), self.src_f(s))); return True
        if m == "cvtsd2ss": e("%s.f[0] = (float)%s;" % (X_(d), self.src_d(s))); return True
        if m in ("cvtsi2ss", "cvtsi2sd"):
            fl, ty = ("f", "float") if m.endswith("ss") else ("d", "double")
            e("%s.%s[0] = (%s)(%s)%s;" % (X_(d), fl, ty, ST[s.size], self.rd(s))); return True
        if m in ("cvttss2si", "cvttsd2si", "cvtss2si", "cvtsd2si"):
            src = self.src_f(s) if "ss" in m else self.src_d(s)
            fn = ("cvtt_i%d" if "cvtt" in m else "cvtr_i%d") % (8 * d.size)
            e(self.wr(d, "%s((double)%s)" % (fn, src))); return True
        if m == "cvttps2dq":
            e("{ XMM sv = %s; for (int k = 0; k < 4; k++) %s.u[k] = (uint32_t)cvtt_i32(sv.f[k]); }" % (self.src_x(s), X_(d))); return True
        if m == "cvtdq2ps":
            e("{ XMM sv = %s; for (int k = 0; k < 4; k++) %s.f[k] = (float)sv.i[k]; }" % (self.src_x(s), X_(d))); return True
        if m == "cvtps2pd":
            e("{ XMM sv = %s; %s.d[0] = sv.f[0]; %s.d[1] = sv.f[1]; }" % (self.src_x(s) if self.isx(s) else "xmm_lo64(rd64(%s))" % self.mem_addr(s), X_(d), X_(d))); return True
        if m == "cvtpd2ps":
            e("{ XMM sv = %s; %s.f[0] = (float)sv.d[0]; %s.f[1] = (float)sv.d[1]; %s.q[1] = 0; }" % (self.src_x(s), X_(d), X_(d), X_(d))); return True
        bit = {"xorps": "^", "xorpd": "^", "pxor": "^", "andps": "&", "andpd": "&", "pand": "&",
               "orps": "|", "orpd": "|", "por": "|", "andnps": "&", "andnpd": "&", "pandn": "&"}
        if m in bit:
            if not self.isx(d): raise Unsupported("mmx " + m)
            if m in ("xorps", "xorpd", "pxor") and self.isx(s) and s.reg == d.reg:
                e("memset(&%s, 0, 16);" % X_(d)); return True
            pre = "~" if m in ("andnps", "andnpd", "pandn") else ""
            e("{ XMM sv = %s; for (int k = 0; k < 2; k++) %s.q[k] = (%s%s.q[k]) %s sv.q[k]; }" % (self.src_x(s), X_(d), pre, X_(d), bit[m]))
            return True
        # shuffles, unpacks, horizontal ops: implemented as inline helpers in rt.h
        if m in ("shufps", "shufpd", "pshufd"):
            e("%s = xmm_%s(%s, %s, %d);" % (X_(d), m, X_(d), self.src_x(s), ops[2].imm)); return True
        if m in ("unpcklps", "unpckhps", "unpcklpd", "unpckhpd", "punpckldq", "punpcklqdq", "punpckhqdq",
                 "punpcklwd", "punpcklbw", "movshdup", "movsldup", "movddup", "haddps", "haddpd", "addsubps",
                 "pshufb", "phaddd", "pmuludq", "packssdw", "packuswb", "pcmpeqd", "pcmpgtd",
                 "paddd", "paddq", "paddw", "psubd", "psubq"):
            if not self.isx(d): raise Unsupported("mmx " + m)
            src = self.src_x(s) if self.isx(s) or m not in ("movddup",) else "xmm_lo64(rd64(%s))" % self.mem_addr(s)
            e("%s = xmm_%s(%s, %s);" % (X_(d), m, X_(d), src)); return True
        if m in ("pslld", "psrld", "psrad", "psllq", "psrlq", "pslldq", "psrldq"):
            if not self.isx(d): raise Unsupported("mmx " + m)
            cnt = "%d" % s.imm if s.type == X.X86_OP_IMM else "(int)%s.q[0]" % self.src_x(s)
            e("%s = xmm_%s(%s, %s);" % (X_(d), m, X_(d), cnt)); return True
        return False


MASK_64 = (1 << 64) - 1


class Translator:
    def __init__(self, img):
        self.img = img
        self.md = cs.Cs(cs.CS_ARCH_X86, cs.CS_MODE_64)
        self.md.detail = True
        self.unsupported = collections.Counter()
        self.imports = set()
        self.local = {n: a for a, n in img.func_names.items()}

    def import_call(self, name):
        if name is None:
            return "missing_import(c)"
        if name in self.local:     # weak C++ definitions bound back into the image
            return "F_%x(c)" % self.local[name]
        self.imports.add(name)
        return "I_%s(c)" % cname(name)


_T = None


def _init(path):
    global _T
    _T = Translator(Image(path))


def _work(chunk):
    _T.unsupported, _T.imports = collections.Counter(), set()
    bodies = [FuncGen(_T, a).gen() for a in chunk]
    return bodies, _T.unsupported, _T.imports


def main():
    path, outdir = sys.argv[1], sys.argv[2]
    img = Image(path)
    lo, hi = (int(sys.argv[3], 16), int(sys.argv[4], 16)) if len(sys.argv) > 4 else (0, 1 << 64)
    funcs = [a for a in img.func_addrs if lo <= a < hi]
    os.makedirs(outdir, exist_ok=True)
    for fn in os.listdir(outdir):
        if fn.startswith("code_") and fn.endswith(".c"): os.remove(os.path.join(outdir, fn))
    per_file = 250
    chunks = [funcs[k:k + per_file] for k in range(0, len(funcs), per_file)]
    unsup, imports = collections.Counter(), set()
    hdr = '#include "rt.h"\n#include "funcs.h"\n'
    with mp.Pool(os.cpu_count(), initializer=_init, initargs=(path,)) as pool:
        for k, (bodies, u, imps) in enumerate(pool.imap(_work, chunks)):
            with open(os.path.join(outdir, "code_%03d.c" % k), "w") as f:
                f.write(hdr + "\n\n".join(bodies) + "\n")
            unsup.update(u); imports |= imps
    with open(os.path.join(outdir, "funcs.h"), "w") as f:
        f.write("#pragma once\n")
        f.write("".join("void %s(CPU *c);\n" % h for h in sorted(set(HOOKS.values()))))
        f.write("".join("void F_%x(CPU *c);\n" % a for a in img.func_addrs))
        f.write("".join("void I_%s(CPU *c);\n" % cname(n) for n in sorted(imports)))
    with open(os.path.join(outdir, "tables.c"), "w") as f:
        f.write('#include "rt.h"\n#include "funcs.h"\n')
        f.write("const GFunc gfuncs[] = {\n")
        f.write("".join('  {0x%xull, F_%x},\n' % (a, a) for a in img.func_addrs))
        f.write("};\nconst int ngfuncs = %d;\n" % len(img.func_addrs))
    print("functions: %d  imports used: %d  unsupported instructions: %d" % (len(funcs), len(imports), sum(unsup.values())))
    for k, v in unsup.most_common(40):
        print("  %6d  %s" % (v, k))


if __name__ == "__main__":
    main()

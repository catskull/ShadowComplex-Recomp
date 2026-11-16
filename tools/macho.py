"""Load the original x86_64 Mach-O: segments, function symbols, import stubs and bindings.

Adapted from JPTG-Recomp's i386 recompiler (https://github.com/NightSightProductions/JPTG-Recomp),
Copyright (c) 2026 NightSight Productions, MIT License (licenses/JPTG-Recomp-LICENSE.txt).
"""
import bisect
import struct
import subprocess
import lief


class Image:
    def __init__(self, path):
        b = self.bin = lief.parse(path)
        self.raw = open(path, "rb").read()
        self.segments = [(s.name, s.virtual_address, s.virtual_size, s.file_offset, s.file_size)
                         for s in b.segments if s.virtual_size and s.name not in ("__PAGEZERO", "__LINKEDIT")]
        self.sec = {s.name: s for s in b.sections}
        self.text = self.sec["__text"]

        ind = b.dynamic_symbol_command
        raw_idx = struct.unpack_from("<%dI" % ind.nb_indirect_symbols, self.raw, ind.indirect_symbol_offset)
        syms = list(b.symbols)

        def name_of(i):
            v = raw_idx[i]
            return None if v & 0xC0000000 else syms[v].name

        # __stubs: 6-byte `jmp *slot(%rip)` entries, one per lazily bound import
        self.stubs = {}
        s = self.sec["__stubs"]
        for k in range(s.size // s.reserved2):
            self.stubs[s.virtual_address + k * s.reserved2] = name_of(s.reserved1 + k)
        # pointer slots dyld fills with an import's address (None = local symbol)
        self.ptrs = {}
        for nm in ("__got", "__nl_symbol_ptr", "__la_symbol_ptr"):
            s = self.sec.get(nm)
            if s is None:
                continue
            for k in range(s.size // 8):
                self.ptrs[s.virtual_address + 8 * k] = name_of(s.reserved1 + k)
        # every bind (incl. data pointers such as vtable slots of imported classes)
        self.binds = [(bi.address, bi.symbol.name if bi.has_symbol else None, bi.addend)
                      for bi in b.dyld_info.bindings] if b.has_dyld_info else []

        lo, hi = self.text.virtual_address, self.text.virtual_address + self.text.size
        fn = {}
        out = subprocess.run(["nm", "-n", path], capture_output=True, text=True,
                             env={"LC_ALL": "C"}).stdout
        for line in out.splitlines():
            p = line.split(" ", 2)
            if len(p) == 3 and p[1] in ("T", "t"):
                v = int(p[0], 16)
                if lo <= v < hi and v not in fn:
                    fn[v] = p[2]
        self.func_addrs = sorted(fn)
        self.func_names = fn
        self.text_lo, self.text_end = lo, hi

    def read(self, addr, n):
        for name, va, vs, fo, fs in self.segments:
            if va <= addr < va + vs:
                o = addr - va
                if o >= fs:
                    return b"\0" * n
                return self.raw[fo + o: fo + o + n]
        raise KeyError(hex(addr))

    def u64(self, addr):
        return struct.unpack("<Q", self.read(addr, 8))[0]

    def i32(self, addr):
        return struct.unpack("<i", self.read(addr, 4))[0]

    def func_end(self, addr):
        i = bisect.bisect_right(self.func_addrs, addr)
        return self.func_addrs[i] if i < len(self.func_addrs) else self.text_end

    def func_containing(self, addr):
        i = bisect.bisect_right(self.func_addrs, addr) - 1
        return self.func_addrs[i] if i >= 0 else None

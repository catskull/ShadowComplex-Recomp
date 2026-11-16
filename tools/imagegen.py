#!/usr/bin/env python3
"""Emit the loader tables for the guest image: segments, rebases, binds, static initializers,
and a weak default thunk for every imported symbol.

usage: imagegen.py BINARY OUTDIR
"""
import os
import sys

sys.path.insert(0, os.path.dirname(__file__))
from macho import Image
from recomp import cname


def main():
    path, outdir = sys.argv[1], sys.argv[2]
    img = Image(path)
    b = img.bin
    defined = {}
    for s in b.symbols:
        if s.value and s.raw_type & 0x0E == 0x0E:     # N_SECT: defined in this image
            defined.setdefault(s.name, s.value)
    rebases = sorted(r.address for r in b.relocations)
    imports, binds = [], []
    index = {}
    for addr, name, addend in img.binds:
        if name in defined:
            binds.append((addr, -1, defined[name] + addend))      # weak definition bound to self
            continue
        if name not in index:
            index[name] = len(imports)
            imports.append(name)
        binds.append((addr, index[name], addend))
    mi = img.sec["__mod_init_func"]
    inits = [img.u64(mi.virtual_address + 8 * k) for k in range(mi.size // 8)]
    with open(os.path.join(outdir, "image.c"), "w") as f:
        f.write('#include "rt.h"\n#include "image.h"\n')
        f.write("const GSeg gsegs[] = {\n")
        f.write("".join('  {"%s", 0x%xull, 0x%xull, 0x%xull, 0x%xull},\n' % s for s in img.segments))
        f.write("};\nconst int ngsegs = %d;\n" % len(img.segments))
        f.write("const uint32_t grebases[] = {\n")
        for k in range(0, len(rebases), 12):
            f.write("  " + ", ".join("0x%x" % (a - 0x100000000) for a in rebases[k:k + 12]) + ",\n")
        f.write("};\nconst int ngrebases = %d;\n" % len(rebases))
        f.write("const GBind gbinds[] = {\n")
        f.write("".join("  {0x%xull, %d, %d},\n" % (a, k, ad) for a, k, ad in binds if k >= 0))
        f.write("};\nconst int ngbinds = %d;\n" % sum(1 for x in binds if x[1] >= 0))
        f.write("const GSelfBind gselfbinds[] = {\n")
        f.write("".join("  {0x%xull, 0x%xull},\n" % (a, v) for a, k, v in binds if k < 0))
        f.write("};\nconst int ngselfbinds = %d;\n" % sum(1 for x in binds if x[1] < 0))
        for n in imports:
            f.write('__attribute__((weak)) void I_%s(CPU *c) { unimpl_import(c, "%s"); }\n' % (cname(n), n))
        f.write("const GImport gimports[] = {\n")
        f.write("".join('  {"%s", I_%s},\n' % (n, cname(n)) for n in imports))
        f.write("};\nconst int ngimports = %d;\n" % len(imports))
        f.write("const uint64_t gmodinit[] = {%s};\nconst int ngmodinit = %d;\n"
                % (", ".join("0x%xull" % v for v in inits), len(inits)))
        f.write("const GSect gsects[] = {\n")
        f.write("".join('  {"%s", "%s", 0x%xull, 0x%xull},\n' % (x.segment_name, x.name, x.virtual_address, x.size)
                        for x in b.sections))
        f.write("};\nconst int ngsects = %d;\n" % len(b.sections))
        f.write("const uint64_t gentry = 0x%xull;\n" % (0x100000000 + b.main_command.entrypoint))
    with open(os.path.join(outdir, "imports.txt"), "w") as f:
        f.write("\n".join(imports) + "\n")
    print("segments %d  rebases %d  binds %d (self %d)  imports %d  initializers %d"
          % (len(img.segments), len(rebases), len(binds), sum(1 for x in binds if x[1] < 0), len(imports), len(inits)))


if __name__ == "__main__":
    main()

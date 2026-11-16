#!/usr/bin/env python3
"""Prototype of the shader path for the Metal renderer: the game's GLSL 1.20 (as produced by UE3's
D3D-bytecode translator) -> GLSL 4.50 -> SPIR-V (glslangValidator) -> MSL (spirv-cross).

The runtime will do the same at glLinkProgram time; this script exists to test the rewrite rules
against a corpus of shaders.

usage: glsl2msl.py OUTDIR SHADER|DIR...   (*.vert / *.frag; prints a summary of failures)
"""
import collections
import multiprocessing
import os
import re
import subprocess
import sys

MAX_TC = 8          # gl_TexCoord[0..7] -> varying locations 0..7
LOC_COLOR = 8       # gl_FrontColor / gl_Color
LOC_COLOR2 = 9      # gl_FrontSecondaryColor / gl_SecondaryColor


def upgrade(src, stage):
    """GLSL 1.20 compatibility profile -> GLSL 4.50 core, keeping names the runtime binds by."""
    lines = []
    for ln in src.split("\n"):
        s = ln.strip()
        if s.startswith("#version") or s.startswith("#extension"):
            continue
        lines.append(ln)
    body = "\n".join(lines)
    body = body.replace("/*ndabl*/uniform", "uniform").replace("bindable uniform", "uniform")

    # non-constant global initialisers (vec4 X = _X;) are not allowed in 4.50: assign in main()
    inits = []
    def glob_init(m):
        inits.append("%s = %s;" % (m.group(2), m.group(3)))
        return "%s %s;" % (m.group(1), m.group(2))
    body = re.sub(r"^(vec4|vec3|vec2|float|ivec4|int)\s+(\w+)\s*=\s*(_\w+)\s*;", glob_init, body, flags=re.M)

    decl = []
    if stage == "vert":
        body = re.sub(r"^attribute\s+", "in ", body, flags=re.M)
        used_tc = sorted({int(n) for n in re.findall(r"gl_TexCoord\[(\d+)\]", body)})
        body = re.sub(r"gl_TexCoord\[(\d+)\]", r"SC_TexCoord\1", body)
        for n in used_tc: decl.append("layout(location=%d) out vec4 SC_TexCoord%d;" % (n, n))
        if "gl_FrontColor" in body:
            decl.append("layout(location=%d) out vec4 SC_Color;" % LOC_COLOR)
            body = body.replace("gl_FrontColor", "SC_Color")
        if "gl_FrontSecondaryColor" in body:
            decl.append("layout(location=%d) out vec4 SC_Color2;" % LOC_COLOR2)
            body = body.replace("gl_FrontSecondaryColor", "SC_Color2")
        body = re.sub(r"\bgl_Back(Secondary)?Color\b", "SC_Unused", body)
        if "SC_Unused" in body: decl.append("vec4 SC_Unused;")
    else:
        used_tc = sorted({int(n) for n in re.findall(r"gl_TexCoord\[(\d+)\]", body)})
        body = re.sub(r"gl_TexCoord\[(\d+)\]", r"SC_TexCoord\1", body)
        for n in used_tc: decl.append("layout(location=%d) in vec4 SC_TexCoord%d;" % (n, n))
        if re.search(r"\bgl_Color\b", body):
            decl.append("layout(location=%d) in vec4 SC_Color;" % LOC_COLOR)
            body = re.sub(r"\bgl_Color\b", "SC_Color", body)
        if "gl_SecondaryColor" in body:
            decl.append("layout(location=%d) in vec4 SC_Color2;" % LOC_COLOR2)
            body = body.replace("gl_SecondaryColor", "SC_Color2")
        used_fd = sorted({int(n) for n in re.findall(r"gl_FragData\[(\d+)\]", body)})
        body = re.sub(r"gl_FragData\[(\d+)\]", r"SC_FragData\1", body)
        if "gl_FragColor" in body:
            body = body.replace("gl_FragColor", "SC_FragData0")
            used_fd = sorted(set(used_fd) | {0})
        for n in used_fd: decl.append("layout(location=%d) out vec4 SC_FragData%d;" % (n, n))
    # sampling functions
    for old, new in (("texture2DProjLod", "textureProjLod"), ("texture2DProj", "textureProj"),
                     ("texture2DLod", "textureLod"), ("texture2D", "texture"),
                     ("textureCubeLod", "textureLod"), ("textureCube", "texture"),
                     ("shadow2DProj", "textureProj"), ("shadow2D", "texture"),
                     ("texture3DLod", "textureLod"), ("texture3D", "texture")):
        body = re.sub(r"\b%s\s*\(" % old, new + "(", body)
    if inits:
        body = re.sub(r"void\s+main\s*\(\s*\)\s*\{", lambda m: m.group(0) + "\n" + "\n".join(inits), body, count=1)
    return "#version 450\n" + "\n".join(decl) + "\n" + body


def convert(path, outdir):
    stage = "vert" if path.endswith(".vert") else "frag"
    base = os.path.join(outdir, os.path.basename(path))
    src = open(path).read()
    glsl = upgrade(src, stage)
    open(base + ".450", "w").write(glsl)
    r = subprocess.run(["glslangValidator", "-V", "-R", "--amb", "--aml", "-S", stage, "-o", base + ".spv",
                        base + ".450"], capture_output=True, text=True)
    if r.returncode:
        err = [l for l in r.stdout.split("\n") if "ERROR" in l]
        return "glslang", err[0] if err else r.stdout.strip()[:200]
    args = ["spirv-cross", base + ".spv", "--msl", "--msl-version", "20100", "--output", base + ".metal"]
    if stage == "vert": args += ["--flip-vert-y"]
    r = subprocess.run(args, capture_output=True, text=True)
    if r.returncode:
        return "spirv-cross", r.stderr.strip()[:200]
    r = subprocess.run(["xcrun", "metal", "-c", base + ".metal", "-o", base + ".air"], capture_output=True, text=True)
    if r.returncode:
        err = [l for l in r.stderr.split("\n") if "error" in l]
        return "metal", err[0] if err else r.stderr.strip()[:200]
    return None


def main():
    outdir = sys.argv[1]
    os.makedirs(outdir, exist_ok=True)
    fails = collections.Counter()
    examples = {}
    paths = []
    for a in sys.argv[2:]:                      # files, or directories of *.vert / *.frag
        if os.path.isdir(a): paths += sorted(os.path.join(a, f) for f in os.listdir(a) if f.endswith((".vert", ".frag")))
        else: paths.append(a)
    n = len(paths)
    with multiprocessing.Pool() as pool:
        results = pool.starmap(convert, [(p, outdir) for p in paths])
    for p, res in zip(paths, results):
        if res:
            key = (res[0], re.sub(r"\d+", "N", res[1])[:120])
            fails[key] += 1
            examples.setdefault(key, p)
    print("%d shaders, %d converted to Metal" % (n, n - sum(fails.values())))
    for (stage, msg), k in fails.most_common():
        print("  %4d  %s: %s   e.g. %s" % (k, stage, msg, os.path.basename(examples[(stage, msg)])))


if __name__ == "__main__":
    main()

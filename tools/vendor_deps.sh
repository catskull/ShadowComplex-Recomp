#!/bin/sh
# Copies the Metal renderer's shader-conversion libraries (glslang, SPIRV-Tools, SPIRV-Cross) from Homebrew
# into deps/, so builds don't need Homebrew: headers, static SPIRV-Cross, and glslang's dylibs renamed to
# @rpath/... (the app bundle carries them in Contents/Frameworks). Run on the machine that packages the
# launcher:  brew install glslang spirv-cross && tools/vendor_deps.sh
set -e
BREW=${BREW:-/opt/homebrew}
cd "$(dirname "$0")/.."
rm -rf deps
mkdir -p deps/include deps/lib deps/licenses
cp -RL "$BREW/include/glslang" "$BREW/include/spirv_cross" deps/include/

for f in libglslang.16 libglslang-default-resource-limits.16; do cp -L "$BREW/opt/glslang/lib/$f.dylib" deps/lib/; done
for f in libSPIRV-Tools-opt libSPIRV-Tools; do cp -L "$BREW/opt/spirv-tools/lib/$f.dylib" deps/lib/; done
chmod u+w deps/lib/*.dylib
for d in deps/lib/*.dylib; do
    n=$(basename "$d")
    install_name_tool -id "@rpath/$n" "$d" 2>/dev/null
    for dep in $(otool -L "$d" | awk 'NR > 1 {print $1}' | grep -E "glslang|SPIRV"); do
        install_name_tool -change "$dep" "@rpath/$(basename "$dep")" "$d" 2>/dev/null
    done
    codesign -f -s - "$d" 2>/dev/null
done
ln -s libglslang.16.dylib deps/lib/libglslang.dylib
ln -s libglslang-default-resource-limits.16.dylib deps/lib/libglslang-default-resource-limits.dylib

for f in c msl hlsl cpp reflect glsl core; do cp -L "$BREW/opt/spirv-cross/lib/libspirv-cross-$f.a" deps/lib/; done

for p in glslang spirv-tools spirv-cross; do
    l=$(find "$BREW/opt/$p/" -maxdepth 1 -iname "LICENSE*" ! -name "*.cfg" | head -1)
    [ -n "$l" ] && cp "$l" "deps/licenses/$p-$(basename "$l")"
done
echo "deps/: $(ls deps/lib | wc -l | tr -d ' ') libraries"

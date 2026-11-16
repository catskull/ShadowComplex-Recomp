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

# each library is copied under its install name (e.g. libglslang.16.dylib), whatever version Homebrew has
for f in glslang/lib/libglslang glslang/lib/libglslang-default-resource-limits spirv-tools/lib/libSPIRV-Tools-opt \
         spirv-tools/lib/libSPIRV-Tools; do
    src="$BREW/opt/$f.dylib"
    real=$(basename "$(otool -D "$src" | tail -1)")
    cp -L "$src" "deps/lib/$real"
    [ "$real" = "$(basename "$src")" ] || ln -s "$real" "deps/lib/$(basename "$src")"
done
chmod u+w deps/lib/*.dylib
for d in $(find deps/lib -name "*.dylib" -type f); do
    n=$(basename "$d")
    install_name_tool -id "@rpath/$n" "$d" 2>/dev/null
    for dep in $(otool -L "$d" | awk 'NR > 1 {print $1}' | grep -E "glslang|SPIRV"); do
        install_name_tool -change "$dep" "@rpath/$(basename "$dep")" "$d" 2>/dev/null
    done
    codesign -f -s - "$d" 2>/dev/null
done

for f in c msl hlsl cpp reflect glsl core; do cp -L "$BREW/opt/spirv-cross/lib/libspirv-cross-$f.a" deps/lib/; done

for p in glslang spirv-tools spirv-cross; do
    l=$(find "$BREW/opt/$p/" -maxdepth 1 -iname "LICENSE*" ! -name "*.cfg" | head -1)
    [ -n "$l" ] && cp "$l" "deps/licenses/$p-$(basename "$l")"
done
echo "deps/: $(ls deps/lib | wc -l | tr -d ' ') libraries"

# Shadow Complex Remastered static recompilation (feasibility spike)
GAME_APP ?= $(HOME)/Library/Application Support/Steam/steamapps/common/Shadow Complex Remastered/Shadow Complex Remastered.app/Contents
GAME = $(GAME_APP)/MacOS/ShadowComplexRemastered
PY   ?= .venv/bin/python -I
CC   := clang
CFLAGS := -O2 -w -fno-strict-aliasing -mcpu=apple-m1 -Iruntime -Igen
OBJ  := build/obj
JOBS ?= $(shell sysctl -n hw.ncpu)
MAKEFLAGS += -j$(JOBS)        # the generated code is ~230 files; build them in parallel by default

GEN_SRC = $(wildcard gen/code_*.c) gen/tables.c gen/image.c
RT_SRC  = runtime/rt.c runtime/imports.c runtime/abi.c runtime/varargs.c runtime/objc.m runtime/shims.m \
          runtime/steam.c runtime/vorbis.c runtime/mainq.m runtime/debug.c runtime/gltrace.m runtime/glcount.c \
          runtime/mgl.m runtime/mgl_shader.cpp
FRAMEWORKS = -framework Cocoa -framework OpenGL -framework AudioToolbox -framework AudioUnit -framework CoreAudio \
             -framework IOKit -framework ForceFeedback -framework Security -framework CoreServices -framework GameKit \
             -framework CFNetwork -framework Metal -framework QuartzCore -framework MetalFX
# Metal renderer shader conversion: glslang (dylibs, carried in the app's Frameworks) and SPIRV-Cross (static),
# from deps/ (tools/vendor_deps.sh copies them from Homebrew: brew install glslang spirv-cross)
DEPS ?= deps
SHADER_LIBS = -L$(DEPS)/lib -lglslang -lglslang-default-resource-limits -lspirv-cross-c -lspirv-cross-msl \
              -lspirv-cross-hlsl -lspirv-cross-cpp -lspirv-cross-reflect -lspirv-cross-glsl -lspirv-cross-core \
              -Wl,-rpath,@executable_path/../Frameworks
LIBS = $(FRAMEWORKS) $(SHADER_LIBS) -lz -lc++ -lffi

.PHONY: all gen survey spike app run clean
all: app

APP = build/Shadow Complex Remastered.app
EXE = build/ShadowComplexRemastered

orig.bin:
	cp "$(GAME)" $@
	@shasum -a 256 -c tools/orig.sha256

survey: orig.bin
	@mkdir -p out
	$(PY) tools/survey.py orig.bin out/survey.json

gen: orig.bin out/sig/ast.json
	$(PY) tools/recomp.py orig.bin gen
	$(PY) tools/imagegen.py orig.bin gen
	$(PY) tools/thunkgen.py out/sig/ast.json gen/imports.txt runtime gen/thunks.m

# SDK declarations for thunk generation
out/sig/ast.json: runtime/sdk.h
	@mkdir -p out/sig
	clang -x objective-c -fsyntax-only -Wno-everything -Xclang -ast-dump=json runtime/sdk.h > $@

$(OBJ)/thunks.o: gen/thunks.m runtime/rt.h runtime/sdk.h
	@mkdir -p $(OBJ)
	$(CC) $(CFLAGS) -fno-objc-arc -c $< -o $@

$(OBJ)/%.o: gen/%.c runtime/rt.h
	@mkdir -p $(OBJ)
	@echo "compiling $<"
	@$(CC) $(CFLAGS) -c $< -o $@

$(OBJ)/rt_%.o: runtime/%.c runtime/rt.h runtime/image.h runtime/abi.h
	@mkdir -p $(OBJ)
	$(CC) $(CFLAGS) -c $< -o $@

$(OBJ)/rt_%.o: runtime/%.m runtime/rt.h runtime/image.h runtime/abi.h
	@mkdir -p $(OBJ)
	$(CC) $(CFLAGS) -fno-objc-arc -c $< -o $@

$(OBJ)/rt_%.o: runtime/%.cpp runtime/mgl_shader.h
	@mkdir -p $(OBJ)
	clang++ -std=c++17 -O2 -w -I$(DEPS)/include -Iruntime -c $< -o $@

$(OBJ)/rt_mgl.o: runtime/mgl.m runtime/rt.h runtime/mgl_shader.h

RT_OBJ = $(patsubst runtime/%,$(OBJ)/rt_%,$(RT_SRC:.c=.o))
RT_OBJ := $(RT_OBJ:.m=.o)
RT_OBJ := $(RT_OBJ:.cpp=.o) $(OBJ)/thunks.o

build/spike: $(patsubst gen/%.c,$(OBJ)/%.o,$(GEN_SRC)) $(RT_OBJ) tests/spike.c
	$(CC) $(CFLAGS) tests/spike.c $(filter %.o,$^) $(LIBS) -o $@

$(EXE): $(patsubst gen/%.c,$(OBJ)/%.o,$(GEN_SRC)) $(RT_OBJ) $(OBJ)/main.o
	$(CC) $(CFLAGS) $(filter %.o,$^) $(LIBS) -o $@

$(OBJ)/main.o: runtime/main.m runtime/rt.h runtime/abi.h runtime/image.h
	@mkdir -p $(OBJ)
	$(CC) $(CFLAGS) -fno-objc-arc -c $< -o $@

# native bundle: our executable + the game's Info.plist and nib; game data is symlinked
app: $(EXE)
	rm -rf "$(APP)"
	mkdir -p "$(APP)/Contents/MacOS" "$(APP)/Contents/Resources" "$(APP)/Contents/Frameworks"
	cp "$(EXE)" "$(APP)/Contents/MacOS/ShadowComplexRemastered"
	cp $(DEPS)/lib/*.16.dylib $(DEPS)/lib/libSPIRV-Tools*.dylib "$(APP)/Contents/Frameworks/"
	cp "$(GAME_APP)/MacOS/steam_appid.txt" "$(APP)/Contents/MacOS/"
	cp "$(GAME_APP)/Info.plist" "$(APP)/Contents/Info.plist"
	plutil -replace LSMinimumSystemVersion -string 11.0 "$(APP)/Contents/Info.plist"
	plutil -replace NSHighResolutionCapable -bool YES "$(APP)/Contents/Info.plist"   # Metal: native drawable; GL keeps a 1x surface
	plutil -replace SCRGameBinary -string "$(GAME)" "$(APP)/Contents/Info.plist"   # the copy of the game this was built from
	for f in "$(GAME_APP)/Resources/"*; do ln -s "$$f" "$(APP)/Contents/Resources/"; done

run: app
	cd "$(APP)/Contents/MacOS" && RT_VERBOSE=1 ./ShadowComplexRemastered

spike: build/spike orig.bin
	build/spike orig.bin

clean:
	rm -rf build

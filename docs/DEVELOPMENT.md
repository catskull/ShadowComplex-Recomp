# Development notes

Technical notes from building the recompilation: how the translator and runtime work, what was measured, and
why things are the way they are. For using it, see the [README](../README.md).

Build by hand (needs `brew install glslang spirv-cross`, then `tools/vendor_deps.sh` once, and a Python venv
in `.venv` with `tools/requirements.txt`):

```sh
make gen     # translate the game binary (from your Steam install) to C and emit loader tables
make app     # compile and assemble build/Shadow Complex Remastered.app
```

Always use `RT_TEST_PROFILE=1` for test runs: it switches to a separate Steam ID and save folder, so tests
never overwrite real saves.

## Layout

| Path | What |
|---|---|
| `tools/macho.py` | Loads the x86_64 Mach-O: segments, function symbols, stubs, GOT, dyld binds |
| `tools/survey.py` | Whole-binary disassembly survey (instruction mix, control flow, imports) |
| `tools/recomp.py` | The translator: every guest function becomes one C function over a guest `CPU` |
| `tools/imagegen.py` | Loader tables: segments, rebases, binds, static initializers, import list |
| `tools/sigscan.py` | Classifies imports by thunk difficulty from SDK declarations |
| `runtime/rt.h` | Guest CPU, memory access, SSE helpers used by generated code |
| `runtime/rt.c` | Loader (fixed-base map + rebase + bind), indirect-call dispatch, failure paths |
| `runtime/imports.c` | Host thunks for imported functions (System V x86_64 -> native arm64 calls) |
| `tests/spike.c` | Runs translated game code natively and checks it against host references |

```sh
make gen     # translate (about 8 s) and emit loader tables
make spike   # compile everything for arm64 (about 35 s on M3 Max) and run the checks
```

## Spike results (2026-11-14, macOS 27.2.1, M3 Max)

**Binary.** `ShadowComplexRemastered` is x86_64 only (the bundled Steam and Vorbis dylibs also carry i386 slices,
which may be why the store page says 32-bit). It is PIE with symbols: 58,130 functions, 17.9 MB of code,
3.86 M instructions, 455 external imports.

**Translation.** All 58,130 functions are translated, 211 distinct mnemonics, and every generated file compiles for
arm64. About 140 instructions are flagged unsupported, and all of them are decode artifacts reached only through
over-read jump tables (`in`, `out`, `retf`, `enter` mid-instruction). Real code coverage is effectively 100%.
The binary helps a lot: almost no x87 (2 instructions), no AVX, no thread-local `gs:` access, and **no
`__cxa_throw` anywhere**, so exception landing pads are cleanup-only and need no unwinder.

**Memory model.** macOS 27 does not let a process map `0x100000000`, so the guest image is mapped at
`0x300000000000` and rebased (293 K rebases). Guest pointers are then host pointers: no pointer translation,
and imports call native libraries directly. `G(addr)` is a compile-time constant slide.

**Correctness and speed (all PASS):**

| Check | Result |
|---|---|
| PhysX `NxFoundation::crc32`, 64 MB | bit-exact; 137 ms translated vs 153 ms for the same loop compiled natively |
| LZO1X compress then decompress, 16 MB | bit-exact round trip; 1.5 GB/s compress, 1.7 GB/s decompress |
| `FMatrix::Inverse` (SSE) | max error 1.1e-07 |
| All 638 static initializers | 638/638 complete, 989 destructors registered |

**Imports (455):**

| Class | Count | Work |
|---|---|---|
| Integer/pointer signatures | 297 | auto-generate thunks from SDK headers |
| ObjC classes, C++ ABI and libc internals | 68 | data binds, or small hand shims |
| Float/double arguments | 35 | auto-generate (xmm -> v regs) |
| Steam API | 22 | offline stub with guest-visible interface vtables (as JPTG does) |
| Data symbols | 15 | direct bind (already works) |
| Variadic (`printf`, `swprintf`, `swscanf`, `open`, `fcntl`, ...) | 9 | hand-written: x86_64 va_list differs from arm64 |
| Callbacks (`pthread_create`, `qsort`, IOHID, AudioConverter, ...) | 6 | guest-function wrappers |
| Struct by value (`CGEventGetLocation`, ...) | 3 | hand-written |
| libvorbis `ov_*` (bundled dylib is x86-only) | 7 | arm64 libvorbis or stb_vorbis, plus callback bridging |

OpenGL (95 functions, including legacy `glBegin`) is present natively on macOS 27 and every function resolves.

## Bring-up (2026-11-14)

The native build launches from `build/Shadow Complex Remastered.app`. It loads the game binary from the Steam
install, runs the engine (game thread, rendering thread, package loading, shaders) and renders the 3D main menu at
full resolution.

```sh
make gen && make app && make run    # run prints guest backtraces on crashes; tools/symbolize.py names them
```

What made it work, beyond the translator:

| Piece | File |
|---|---|
| SDK-driven thunk generator (267 imports) | `tools/thunkgen.py` |
| System V <-> arm64 marshalling with struct classification, libffi calls and closures | `runtime/abi.c` |
| Objective-C bridge: guest classes registered with closures as IMPs; msgSend/_stret/Super2 | `runtime/objc.m` |
| Variadics via format-driven repacking into an arm64 va_list | `runtime/varargs.c` |
| Callbacks, threads (one guest CPU per thread), struct-by-value, alerts | `runtime/shims.m` |
| Main-thread queue for AppKit calls from the render thread, drained at waits and sends | `runtime/mainq.m` |
| Offline Steam (SDK 1.34 vtables, local achievements) and Vorbis on stb_vorbis | `runtime/steam.c`, `runtime/vorbis.c` |
| x86 TSO memory ordering: shared loads/stores are LDAPR/STLR, stack accesses plain | `runtime/rt.h` |

Translator: every PIC jump table in the binary now resolves (deferred bounds, reaching-definition table bases);
the only untranslated bytes left are 14 undecodable ones in dead code.

## Debugging

- `RT_TEST_PROFILE=1 ./ShadowComplexRemastered EmpireXBLA_P` boots straight into the streaming world map. That starts
  a **new game, which overwrites the save** of the active Steam ID. Always use `RT_TEST_PROFILE=1` for test runs: it
  switches to a separate test Steam ID and save folder.
- Hooks: functions listed in `HOOKS` (`tools/recomp.py`) call a host function on entry (`runtime/debug.c`).
  PhysX errors are printed as `physx: error <code> at <file>:<line>: <message>`.
- Crash reports name the host PC; with `restrict`, the guest register dump can be stale. To find the exact guest
  instruction, recompile that `gen/code_*.c` with `-g` and look up the offset with `llvm-dwarfdump --lookup`.
- Fixed 2026-11-14: crash in `FRBPhysScene::FindPhysMaterialIndex` (null `NxMaterial`) while streaming levels. The
  main-thread `pthread_cond_wait` shim returned spuriously, and PhysX's sync does not re-check its predicate, so the
  game modified the scene mid-simulation.

- Fixed 2026-11-14: physics deadlock (main thread in `NpScene::fetchResults` waiting forever, PhysX workers idle).
  The main thread waits in 2 ms slices to service AppKit work. A broadcast racing a slice's timeout was lost, and
  `NxSync::wait` waits once without re-checking its flag. Signals now bump a per-condition-variable counter, which
  the sliced wait checks (`runtime/mainq.m`).

- Fixed 2026-11-14: black horizontal streaks on floors under the flashlight, worst on metal. Not shadows: UE3 draws
  each dynamic light as another pass over the scene with an exact depth test against the base pass. D3D gives
  bit-identical positions for identical vertex maths; GLSL only does for `invariant` outputs, and Apple's compiler
  rounds the passes differently, so light passes skipped pixels. `runtime/gltrace.m` now inserts
  `invariant gl_Position;` into every vertex shader (`RT_NO_INVARIANT=1` disables). It also rewrites
  `inversesqrt(x)` as `inversesqrt(abs(x))` to match D3D9 `rsq` (`RT_NO_SHADERFIX=1` disables).
  And `( 1.0 / <constant>.c )` becomes a reciprocal that is huge but finite for 0, since D3D9 gives 0 for
  0 * inf and Apple GPUs give NaN: materials that disable an effect with zero parameters (the water's
  refraction strength and fade distance) otherwise produce NaN offsets, a black band along the water.
  Capture tooling used to find it: `RT_SHADOWDUMP=1`, then `touch ~/sc-dump` while playing, saves the shadow maps,
  every blit-resolved buffer and a per-draw crop of one frame to `~/sc-shadow` (`RT_DUMPRECT`, `RT_DUMPPROG=<id>`
  save more); `RT_FULL_SCENE=1` allocates RGBA16F targets as RGBA32F (did not matter).

## Metal renderer

Why: with the CPU work done, the GPU is the limit (80-95% busy). Apple's GL-on-Metal turns each frame into
about 75 Metal render passes. Each pass loads and stores full-resolution attachments (about 0.27 ms each on an
M3 Max), whatever it draws. The engine makes 40-44 resolve blits, 140 framebuffer binds and 23 occlusion queries
per frame. A renderer that records a frame and then decides load and store actions can avoid most of that traffic.

Approach: implement the ~85 GL entry points the game imports directly on Metal in the runtime (the thunks already
own every GL call). Apple's GL stays available as a fallback.

1. Shaders - done as a prototype (`tools/glsl2msl.py`): GLSL 1.20 is rewritten textually to 4.50 (gl_TexCoord[n],
   gl_FrontColor and gl_FragData[n] become explicit varyings and outputs; attribute/varying and texture2D* are
   updated; non-constant global initialisers move into main). glslang `-V -R` builds SPIR-V with loose uniforms
   packed into one default block, and spirv-cross `--msl --flip-vert-y` emits MSL. All 10,024 shaders the game
   compiles convert, and all compile with `xcrun metal`. In the runtime this runs at glLinkProgram, using the
   attribute locations from glBindAttribLocation, and results are cached on disk. Needs `brew install glslang
   spirv-cross`.
2. Core - working (`runtime/mgl.m`, `runtime/mgl_shader.cpp`; enable with `RT_METAL=1`): menu and gameplay render
   correctly. Programs convert and compile in the background at glLinkProgram; Metal's shader cache makes later
   launches fast. Occlusion queries commit their command buffer early, as a GL flush would; the engine waits on last
   frame's results (`UpdatePrimitiveOcclusion`), and one command buffer per frame serialised CPU and GPU. First
   level, display sync off: 113-120 fps (the engine's cap) at 36-69% GPU busy, against GL's ~118 fps at 77-84%.
   Debugging: `RT_METAL_SNAP=<frame,...>` with `RT_METAL_SNAP_DIR` saves presented frames as raw BGRA.
   `RT_METAL_CHECK=1` logs indexed draws that read past their vertex data or range end, or have non-finite or huge
   positions (with the attributes and vertex shader). It found the stretched fractured-wall chunks: the game binds a
   shared 4-byte default vertex colour with stride 0 (D3D's one-value-for-all-vertices idiom); Metal read past it.
   Live capture: `touch ~/sc-dump` saves the next frame to `~/sc-capture` (draws.txt with each draw's shaders,
   state and constants, the drawn GLSL sources, sampled float/screen-size textures and the final frame as raw files
   headed "W H pixelformat"). `~/sc-skip` lists GLSL source hashes (capture file names) whose draws are skipped,
   re-read every second, to bisect an artifact from another terminal while the game keeps focus.
   `RT_METAL_SHADERDUMP=<dir>` saves every GLSL source the game sends.
   Texture-unit LOD bias (glTexEnvf GL_TEXTURE_LOD_BIAS, used by many scene materials with values -1..5) is
   emulated: fragment shaders get `vec4 SC_LodBias[4]` at the end of their uniform block and implicit-LOD
   lookups (texture2D, textureCube, texture2DProj) pass it as the bias argument; the renderer fills it per
   draw from each sampler's unit. Converter changes bump `conv_version` in stage_job (cache keys).
   A cold shader cache needs two launches: the first learns the attribute name -> location map, the second
   batch-compiles the vertex shaders with it.
   Known gaps: depth/stencil blits are not implemented, multisampled renderbuffers are single-sampled.
3. Full coverage: queries, stencil, blits, immediate-mode draws, glReadPixels.
4. Pass analysis - measured, mostly not needed. Metal System Trace, first level, same scene: Apple GL 7.4 ms of
   GPU time per frame (80 passes), this renderer 5.5 ms (67 passes). Apple GL's ~0.27 ms fixed cost per pass
   does not exist here: most passes cost 0.01-0.2 ms, and the frame is dominated by real work (scene pass ~0.9 ms,
   ~10 full-screen flipped resolve copies at ~0.1 ms). Deferring clears into the next pass and skipping
   loads changed nothing measurable. Kept: blits that cover their whole destination do not load it. Deferred
   clears are opt-in (`RT_METAL_DEFER=1`). A larger gain would need removing the engine's flipped resolve
   copies (rendering offscreen targets in texture orientation).
   Shader/pipeline caching (the source of the in-game hitches): stages are compiled from glShaderSource in
   batches of 64 (~8 ms per shader instead of ~110 ms), saved as .metallib files under
   ~/Library/Caches/ShadowComplexRecomp/lib-v2 (built by `xcrun metal` in the background), and pipelines are
   recorded by stage hashes and prebuilt at startup (pipelines-v3.bin).

Orientation: vertices are flipped in Y (`--flip-vert-y`), so memory row 0 matches GL. GL viewport and scissor
values can then be used directly as Metal origins, front-face winding is inverted, and the final present flips
once. Clip-space depth is remapped from [-w,w] to [0,w].

## Notes by area

1. **Verified in play**: gameplay, cutscenes, audio, keyboard and mouse, saving and loading, resolution changes
   from the options menu.
2. **Not yet verified**: gamepads; mouse aiming and HUD with `RT_FILL_SCREEN=1`.
3. **Steam**: unimplemented slots are logged at runtime (`ISteamUtils` 10/11/16, `ISteamRemoteStorage` 0/15/20,
   `ISteamUserStats` 12/16, `ISteamFriends` 43, ...). RemoteStorage matters if saves go through Steam Cloud.
4. **Retina**: the app is `NSHighResolutionCapable`. Apple GL keeps a 1x surface (`setWantsBestResolutionOpenGLSurface:NO`
   at setView:). The Metal renderer presents to a native-resolution drawable: the game still renders at the
   window's size in points (2560x1440 on a 5K display) and the frame is upscaled with MetalFX spatial scaling
   (`RT_METAL_UPSCALE=bilinear` for a plain stretch). Findings: this port ignores `ScreenPercentage` upscaling
   (the scene renders into a corner of the full-size buffers), and the engine sizes its scene from the
   window/screen frames and reads the mouse in points, so rendering at more than 1x needs consistent
   coordinate scaling. Under Metal the game therefore works in units of points x render scale, and the
   scale follows its own resolution setting (so the in-game menu works): in fullscreen it is
   ResFullscreenX / screen width in points (read from `GSystemSettings`), windowed it is 1. The game renders
   at its resolution into an offscreen buffer and stretches that to the display size itself
   (`EndDrawingViewport` / `MacGetDisplaySize`); in these units that stretch is 1:1 and MetalFX upscales the
   frame to the native drawable. Converted in `send` (objc.m) and the CGDisplay*/CGEventGetLocation thunks:
   window/screen/view frames, window and view creation rects, setFrame/contentRect conversions, the mouse
   (locationInWindow, convertPoint:*, convertBaseToScreen:, mouseLocation, CGEventGetLocation, deltaX/Y).
   Messages handled by the game's own classes (UOpenGLView) are not converted, only what reaches AppKit. The
   resolution list is the display's modes plus the native one in pixels (1280x720 ... 3840x2160, 5120x2880).
   Fullscreen is native (toggleFullScreen:); every windowDidResize: becomes `FMacViewport::Resize(w, h,
   styleMask has fullscreen)`, so before entering fullscreen the window is fitted to the visible frame
   (otherwise AppKit shrinks it, the game reads that as "windowed" and toggles back and forth). First level at
   3840x2160: ~78 fps with sync off; 5120x2880 native: ~40. `RT_LOG_GEOMETRY=1` logs the converted calls,
   `RT_LOG_SEND=word,...` logs messages whose selector contains a word, and
   `RT_TEST_SETRES=<s>:<W>x<H>,...` changes the fullscreen resolution as the options menu does. The game's own
   NSAutoreleasePool init/release on the render thread first ends the renderer's per-frame pool (popping a
   game pool beneath it used to abort with "Invalid or prematurely-freed autorelease pool" on a resolution
   change).
   Screens narrower than 16:9 (16:10, 4:3, 5:4) are letterboxed by the game's camera
   (`ACamera::bConstrainAspectRatio`, 16:9). `RT_FILL_SCREEN=1` (hook on `ULocalPlayer::CalcSceneView`) clears
   that flag and sets the engine's 16:9 projection constant (also used by FastProject/FastDeProject and the
   UI) to the viewport's aspect, so the view keeps the 16:9 width and shows more above and below (Vert+).
   Checked on the title screen in a 1000x800 window; gameplay, HUD and aiming untested.
   `RT_SCREEN=<index or part of a name>` (e.g. `RT_SCREEN=SyncMaster`) runs the game on another display: the
   game's `+[NSScreen mainScreen]` and `CGMainDisplayID` return that screen and its window is centred there
   before it goes fullscreen. A non-Retina screen uses the plain 1x path.
5. **Performance**: done so far: O(1) direct-mapped indirect dispatch (`call_ind` was the top hotspot), `restrict` on
   the guest CPU pointer, `-O2`. Translated CRC32 now matches native speed. Diagnostics: `RT_FPS=1` prints presented
   frames per second, `RT_NOVSYNC=1` forces swap interval 0. `tools/profile.sh` samples the running game and
   `tools/profsum.py` summarizes busy threads and hot functions.
   - The game's own limiter caps it at 62 fps (`MaxSmoothedFrameRate` in `Mac-EmpireEngine.ini`); raised to 120.
   - The main-thread `usleep` shim slept in slices and overslept, dragging UE3's smoothed cap down. It now sleeps
     once and wakes early only for queued AppKit work. Menu: about 60 -> 85-91 fps.
   - The current limit is the render thread (92% busy): 43% translated code, about 32% Apple's OpenGL-on-Metal driver.
   - TSO ordering is required: a build without it (`-DRT_NO_TSO`, measurement only) crashes in the render thread.
   - Indirect calls to functions that are not 16-byte aligned (much of PhysX) used a binary search (`find_func`,
     14% of the physics thread). They now use a hash table.
   - Register caching (`cache_regs` in `tools/recomp.py`): guest registers live in C locals within each function and
     are written back to `*c` only around calls and returns. Before, clang reloaded them after every guest memory
     access, because a pointer made from an integer might point into `*c`. `AActor::LocalToWorld`: 841 -> ~515
     instructions. `RECOMP_NO_CACHE=1 make gen` turns it off.
   - Next levers: cut redundant flag/ordering work in hot render
     code, and reduce GL driver overhead per draw.

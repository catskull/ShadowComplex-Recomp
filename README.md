# Shadow Complex Recomp

> **Note:** this project was heavily vibe coded: most of the code was written with an AI coding assistant.
> It has been tested by hand, by playing the game on an M3 Max and an M1 Mac, and runs smoothly on both.
> Expect rough edges, and please report what you find.

Play **[Shadow Complex Remastered](https://store.steampowered.com/app/385560/Shadow_Complex_Remastered/)** natively on Apple Silicon Macs.

The Mac version of the game on Steam is an Intel-only (x86_64) app, so on Apple Silicon it needs Rosetta 2
and Apple's deprecated OpenGL. This project statically recompiles the game's own code into native arm64 code
on your Mac, and replaces its OpenGL renderer with one written for Metal. You get:

- native Apple Silicon performance, with no Rosetta required
- a Metal renderer: correct rendering, about 25% less GPU time per frame than Apple's OpenGL
- Retina support: any resolution from the game's menu, up to your display's native resolution (e.g. 5K),
  upscaled with MetalFX
- an option to fill 16:10, 4:3 and 5:4 screens instead of letterboxing
- a choice of display when you have more than one

**No game files are included.** You need your own copy of [Shadow Complex Remastered from Steam](https://store.steampowered.com/app/385560/Shadow_Complex_Remastered/). The launcher
recompiles that copy on your Mac.

## Requirements

- A Mac with Apple Silicon (M1 or later), macOS 13 Ventura or later
- [Shadow Complex Remastered](https://store.steampowered.com/app/385560/Shadow_Complex_Remastered/) installed with Steam (the current Mac version)
- Apple's Command Line Tools (free; the launcher offers to install them). Full Xcode is not needed.
- About 2 GB of free disk space for the build

## Getting started

1. Download **Shadow Complex Recomp.zip** from the Releases page, unzip it, and move
   **Shadow Complex Recomp.app** to your Applications folder.
2. Open it. It finds the game in your Steam library (or click **Choose…** to point it at
   `Shadow Complex Remastered.app`) and checks that it is the supported version.
3. Click **Build**. The launcher recompiles the game; this takes a few minutes and is only needed once (and
   again after an update).
4. Pick your settings and click **Play**.

The first launch compiles the game's shaders in the background, so expect a few brief stutters in the first
minute or so. Later launches are smooth.

## Settings

| Setting | What it does |
|---|---|
| Renderer | **Metal** (recommended) or the game's original **OpenGL** renderer |
| Display | Which screen the game runs on |
| Upscaling | How a lower render resolution is scaled to the screen: **MetalFX** (sharper) or **Bilinear** |
| Fill screens narrower than 16:9 | On 16:10, 4:3 or 5:4 screens, shows more of the scene above and below instead of black bars |
| Turn off vertical sync | Uncapped frame rate (may tear) |
| Test profile | Uses a separate save slot, leaving your real saves untouched |

Resolution, anti-aliasing, texture quality and the other game options are in the game's own **Settings** menu.
The resolution you pick there is the resolution the game renders at: choose your display's native resolution
for the sharpest image, or a lower one for higher frame rates.

## Files

| What | Where |
|---|---|
| Saves (the same as the original game's) | `~/Library/Application Support/My Games/Shadow Complex/` |
| The recompiled game and its build | `~/Library/Application Support/ShadowComplexRecomp/` |
| Logs (`game.log`, `build.log`) | `~/Library/Logs/ShadowComplexRecomp/` |
| Shader cache | `~/Library/Caches/ShadowComplexRecomp/` |

To uninstall, delete the launcher and the folders above (keep the first one if you want your saves).

## Troubleshooting

- **"This version of the game isn't supported."** The launcher only works with the exact game build it was
  made for. If Steam updated the game, a launcher update is needed.
- **The build fails.** Click **Build log** for details, and make sure the Command Line Tools are installed
  (`xcode-select --install` in Terminal).
- **The game quits or misbehaves.** Click **Game Log** and include `game.log` when you report the problem.
- **Steam features.** The recompiled game runs without the Steam client. Achievements are kept locally, and
  Steam Cloud saves are not synced.

## Building from source

You need Xcode or the Command Line Tools, plus Homebrew for the shader-conversion libraries.

```sh
brew install glslang spirv-cross
tools/vendor_deps.sh          # copy those libraries into deps/
launcher/package.sh           # builds build/launcher/Shadow Complex Recomp.app and its .zip
```

The launcher also works from a terminal: `--build` builds (or rebuilds) and `--play` launches with the saved
settings. The build it runs is `tools/launcher_build.sh`.

## How it works

The game binary is translated function by function into C (`tools/recomp.py`): about 58,000 functions and
3.9 million x86-64 instructions. The C is then compiled for arm64 and linked with a runtime that does the
following:

- loads the game's data from your Steam install
- bridges its calls into macOS: Objective-C, threads, variadic functions, callbacks
- provides an offline Steam layer and Vorbis audio
- implements the subset of OpenGL the game uses on top of Metal (`runtime/mgl.m`), converting its shaders from
  GLSL to Metal Shading Language with glslang and SPIRV-Cross

[docs/DEVELOPMENT.md](docs/DEVELOPMENT.md) has the technical details and measurements.

## Contributing

Bug reports and code are both welcome. Please use the GitHub issue tracker and pull requests.

### Reporting a problem

Open an issue and include:

- **Your Mac and macOS version** (Apple menu → About This Mac), e.g. "MacBook Pro M1, macOS 15.3"
- **The launcher version**, shown under the title in the launcher window
- **Your settings**: the launcher's settings, plus the resolution and anti-aliasing chosen in the game, and
  which display you play on if you have more than one
- **What happened and what you expected**, with steps to reproduce it if you can (where in the game, what you
  were doing)
- **A screenshot or short video** for graphical problems

**For crashes, always attach the game log.** Click **Game Log** in the launcher (or open
`~/Library/Logs/ShadowComplexRecomp/game.log`) and attach the whole file. It records the crash and the game's
internal call stack at that moment, which is usually what pins the bug down. The log is overwritten every time
you click **Play**, so save a copy before you start the game again.

**For build failures,** attach `~/Library/Logs/ShadowComplexRecomp/build.log` (also shown under **Build log**
in the launcher).

Please don't attach the game's files or your save files.

### Contributing code

1. Read [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md) for how the recompiler and runtime fit together, and how
   to build by hand.
2. Test with your own copy of the game. Run test builds with `RT_TEST_PROFILE=1` (or the launcher's **Test
   profile** setting): it uses a separate save slot, so a test run can't overwrite your real save.
3. Keep game-derived files out of commits. `.gitignore` already excludes them (`orig.bin`, `gen/`, `out/`,
   `build/`).
4. In the pull request, say what you changed, why, and how you tested it: which Mac, which part of the game,
   and before/after screenshots or frame rates for rendering or performance changes.

Crash backtraces in `game.log` list guest addresses. To name the functions, run
`tools/symbolize.py orig.bin < game.log` (after `make orig.bin`).

AI-assisted contributions are fine, as long as you've tested the change by playing the game.

## License

MIT, see [LICENSE](LICENSE). Parts of the recompiler (`tools/recomp.py`, `tools/macho.py`) are adapted from
JPTG-Recomp and keep its MIT notice (`licenses/JPTG-Recomp-LICENSE.txt`); bundled third-party libraries keep
their own licences. The license covers this project's code only, not Shadow Complex Remastered or any of its
assets.

## Legal

This is an unofficial fan project. It is not affiliated with or endorsed by Chair Entertainment, Epic Games,
Microsoft or Valve. Shadow Complex is a trademark of its owners. This repository and the launcher contain no
game code or assets; you must own the game.

## Credits

- [JPTG-Recomp](https://github.com/NightSightProductions/JPTG-Recomp) by NightSight Productions (MIT): the
  recompiler (`tools/recomp.py`, `tools/macho.py`) began as an adaptation of its i386 recompiler, extended
  to x86-64, and the overall approach follows it. Its licence is in `licenses/JPTG-Recomp-LICENSE.txt`
- [stb_vorbis](https://github.com/nothings/stb) (public domain / MIT)
- [glslang](https://github.com/KhronosGroup/glslang), [SPIRV-Tools](https://github.com/KhronosGroup/SPIRV-Tools)
  and [SPIRV-Cross](https://github.com/KhronosGroup/SPIRV-Cross); their licences ship inside the launcher
  (`deps/licenses`, created by `tools/vendor_deps.sh`)
- [LIEF](https://github.com/lief-project/LIEF) and [Capstone](https://github.com/capstone-engine/capstone),
  used by the recompiler

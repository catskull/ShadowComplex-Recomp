#!/bin/sh
# Full build from the user's own copy of the game, as run by the launcher (or by hand):
#   tools/launcher_build.sh "<.../Shadow Complex Remastered.app/Contents>"
# Prints "STEP <name>" before each phase and "PROGRESS <done> <total>" while compiling; ends with "DONE".
# Needs Apple's Command Line Tools (clang, python3); Python packages go in ./venv.
set -e
cd "$(dirname "$0")/.."
GAME_APP=${1:?usage: launcher_build.sh <game .app/Contents>}

echo "STEP Checking tools"
if ! xcrun -f clang >/dev/null 2>&1; then echo "ERROR Apple's Command Line Tools are not installed (xcode-select --install)"; exit 1; fi
PYTHON=$(xcrun -f python3 2>/dev/null || command -v python3)

echo "STEP Setting up Python"
if [ ! -x venv/bin/python ]; then "$PYTHON" -m venv venv; fi
venv/bin/python -m pip install --disable-pip-version-check -q -r tools/requirements.txt

echo "STEP Checking the game"
rm -f orig.bin
if ! make -s orig.bin GAME_APP="$GAME_APP" >/dev/null 2>&1; then
    echo "ERROR This copy of the game is not the supported version (tools/orig.sha256)"; exit 1
fi

echo "STEP Recompiling the game"
make -s gen GAME_APP="$GAME_APP" PY="venv/bin/python -I"

echo "STEP Compiling"
total=$(ls gen/code_*.c | wc -l | tr -d ' ')
make app GAME_APP="$GAME_APP" PY="venv/bin/python -I" 2>&1 | awk -v total="$total" '
    /^compiling gen\/code_/ { n++; print "PROGRESS " n " " total; fflush(); next }
    /error:/ { print "ERROR " $0; fflush(); next }
    { print; fflush() }'
[ -x "build/Shadow Complex Remastered.app/Contents/MacOS/ShadowComplexRemastered" ] || { echo "ERROR build failed"; exit 1; }
echo "DONE"

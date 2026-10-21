#!/bin/bash
set -euo pipefail
TASK_DIR=$(cd "$(dirname "$0")" && pwd)
TASK_NDK=${ANDROID_NDK_HOME:-/home/dsultanr/f515/toolchains/android-ndk-r27d}
TASK_CC="$TASK_NDK/toolchains/llvm/prebuilt/linux-x86_64/bin/aarch64-linux-android30-clang"
bash "$TASK_DIR/build.sh"
python3 - "$TASK_DIR" <<'PY'
import pathlib, sys, zipfile
p = pathlib.Path(sys.argv[1]) / 'build'
with zipfile.ZipFile(p / 'cell-collector.jar') as jar:
    dex = jar.read('classes.dex')
(p / 'cells-dex.h').write_text('static const unsigned char cells_dex[] = {' + ','.join(map(str, dex)) + '};\n')
PY
TASK_FLAGS=(-O2 -g -Wall -Wextra -Werror -fstack-protector-strong -D_FORTIFY_SOURCE=2)
"$TASK_CC" "${TASK_FLAGS[@]}" -fPIE -pie "$TASK_DIR/injector.c" -ldl -o "$TASK_DIR/build/native-inject"
"$TASK_CC" "${TASK_FLAGS[@]}" -fPIC -shared -fvisibility=hidden "$TASK_DIR/native-bridge.c" \
    -ldl -llog -o "$TASK_DIR/build/libwwan_cells.so"
sha256sum "$TASK_DIR/build/native-inject" "$TASK_DIR/build/libwwan_cells.so"

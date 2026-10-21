#!/bin/bash
set -euo pipefail
TASK_DIR=$(cd "$(dirname "$0")" && pwd)
TASK_MODULES=${FRIDA_NODE_MODULES:?Set FRIDA_NODE_MODULES to installed frida-compile and frida-java-bridge modules}
mkdir -p "$TASK_DIR/build"
TASK_OUT=$(mktemp -d "$TASK_DIR/build/agent.XXXXXX")
ln -s "$TASK_MODULES" "$TASK_OUT/node_modules"
cp "$TASK_DIR/telephony-probe.src.js" "$TASK_OUT/main.js"
"${NODE:-node}" "$TASK_MODULES/frida-compile/dist/cli.js" "$TASK_OUT/main.js" \
    -o "$TASK_DIR/build/telephony-probe.js"
sha256sum "$TASK_DIR/build/telephony-probe.js"

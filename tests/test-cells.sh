#!/bin/bash
set -euo pipefail
TASK_ROOT=$(cd "$(dirname "$0")/.." && pwd)
TASK_JAVA=${JAVA_HOME:-/usr/lib/jvm/java-11-openjdk-amd64}
mkdir -p "$TASK_ROOT/cells/build"
TASK_OUT=$(mktemp -d "$TASK_ROOT/cells/build/test.XXXXXX")
"$TASK_JAVA/bin/javac" -encoding UTF-8 -d "$TASK_OUT" \
    "$TASK_ROOT/cells/CellObservation.java" "$TASK_ROOT/cells/CellSnapshot.java" \
    "$TASK_ROOT/cells/HuaweiCellParser.java" "$TASK_ROOT/tests/CellSourceTest.java"
"$TASK_JAVA/bin/java" -cp "$TASK_OUT" CellSourceTest

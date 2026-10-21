#!/bin/bash
set -euo pipefail
TASK_DIR=$(cd "$(dirname "$0")" && pwd)
TASK_JAVA=${JAVA_HOME:-/usr/lib/jvm/java-11-openjdk-amd64}
TASK_SDK=${ANDROID_SDK:-/home/dsultanr/android-sdk}
TASK_BT=${ANDROID_BUILD_TOOLS:-$TASK_SDK/android-14}
TASK_PLATFORM=${ANDROID_JAR:-$TASK_SDK/android-11/android.jar}
mkdir -p "$TASK_DIR/build"
TASK_BUILD=$(mktemp -d "$TASK_DIR/build/run.XXXXXX")
mkdir -p "$TASK_BUILD/classes" "$TASK_BUILD/dex"
"$TASK_JAVA/bin/javac" -source 8 -target 8 -encoding UTF-8 \
    -bootclasspath "$TASK_PLATFORM" -d "$TASK_BUILD/classes" "$TASK_DIR"/*.java
JAVA_HOME="$TASK_JAVA" "$TASK_BT/d8" --min-api 30 --lib "$TASK_PLATFORM" \
    --output "$TASK_BUILD/dex" "$TASK_BUILD/classes"/*.class
(cd "$TASK_BUILD/dex" && zip -q -X "$TASK_DIR/build/cell-collector.jar" classes.dex)
sha256sum "$TASK_DIR/build/cell-collector.jar"

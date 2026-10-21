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
"$TASK_BT/aapt2" link --manifest "$TASK_DIR/AndroidManifest.xml" -I "$TASK_PLATFORM" \
    --min-sdk-version 30 --target-sdk-version 30 -o "$TASK_BUILD/base.apk"
"$TASK_JAVA/bin/javac" -source 8 -target 8 -encoding UTF-8 -bootclasspath "$TASK_PLATFORM" \
    -d "$TASK_BUILD/classes" "$TASK_DIR/CellProbeService.java"
find "$TASK_BUILD/classes" -name '*.class' > "$TASK_BUILD/classes.list"
JAVA_HOME="$TASK_JAVA" "$TASK_BT/d8" --min-api 30 --lib "$TASK_PLATFORM" \
    --output "$TASK_BUILD/dex" @"$TASK_BUILD/classes.list"
(cd "$TASK_BUILD/dex" && zip -q -X "$TASK_BUILD/base.apk" classes.dex)
"$TASK_BT/zipalign" -p 4 "$TASK_BUILD/base.apk" "$TASK_BUILD/aligned.apk"
if [ ! -f "$TASK_DIR/build/probe.jks" ]; then
    "$TASK_JAVA/bin/keytool" -genkeypair -keystore "$TASK_DIR/build/probe.jks" -alias probe \
        -storepass celltest -keypass celltest -keyalg RSA -keysize 2048 -validity 365 \
        -dname 'CN=Temporary CellInfo test' >/dev/null 2>&1
fi
JAVA_HOME="$TASK_JAVA" "$TASK_BT/apksigner" sign --ks "$TASK_DIR/build/probe.jks" \
    --ks-pass pass:celltest --key-pass pass:celltest --out "$TASK_DIR/build/cell-probe.apk" \
    "$TASK_BUILD/aligned.apk"
sha256sum "$TASK_DIR/build/cell-probe.apk"

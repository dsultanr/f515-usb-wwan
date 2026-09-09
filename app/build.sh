#!/bin/bash
# Собирает F515UsbWwanApp.apk без gradle: aapt2 -> javac -> d8 -> zipalign -> apksigner.
#
# Полезная нагрузка (скрипты, модули ядра, huawei-modeswitch) живёт в репозитории
# один раз - в scripts/, modules/prebuilt/ и tools/ - и копируется в app/assets/ прямо
# здесь, перед линковкой. Держать вторую копию в assets/ под гитом смысла нет: она
# разъезжается с оригиналом ровно в тот момент, когда про неё забываешь.
set -euo pipefail

SDK=${ANDROID_SDK:-/home/dsultanr/android-sdk}
BT=${BUILD_TOOLS:-$SDK/android-14}
PLATFORM=${ANDROID_JAR:-$SDK/android-11/android.jar}
PROJ=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$PROJ/.." && pwd)
OUT=$PROJ/build
APK=$PROJ/F515UsbWwanApp.apk

mkdir -p "$OUT/classes" "$OUT/dex" "$OUT/res-compiled" "$PROJ/assets"

echo "== assets (scripts + modules + tools)"
for f in "$ROOT"/scripts/wwan-up.sh "$ROOT"/scripts/wwan-boot.sh \
         "$ROOT"/scripts/dial.sh "$ROOT"/scripts/at.sh "$ROOT"/scripts/format-sdcard.sh \
         "$ROOT"/scripts/tbox-icon.sh \
         "$ROOT"/scripts/sms.sh \
         "$ROOT"/tbox/prebuilt/tboxwire.jar \
         "$ROOT"/tools/huawei-modeswitch \
         "$ROOT"/modules/prebuilt/usbserialmerged2.ko "$ROOT"/modules/prebuilt/ppp_async.ko \
         "$ROOT"/modules/prebuilt/cdc-wdm.ko "$ROOT"/modules/prebuilt/cdc_ncm.ko \
         "$ROOT"/modules/prebuilt/huawei_cdc_ncm.ko \
         "$ROOT"/modules/prebuilt/f515_rndis.ko; do
    case "$f" in
    # Чекаут под Windows (core.autocrlf=true) отдаёт скрипты с CRLF, а
    # /system/bin/sh на голове давится на \r - нормализуем при копировании.
    # На Linux-чекауте убирать нечего, поведение то же.
    *.sh) sed 's/\r$//' "$f" > "$PROJ/assets/$(basename "$f")" ;;
    *)    cp -f "$f" "$PROJ/assets/" ;;
    esac
    echo "   $(basename "$f")"
done
# adbkey/adbkey.pub лежат в assets/ постоянно - это не копия, а оригинал.
test -f "$PROJ/assets/adbkey" || { echo "нет assets/adbkey - приложению нечем логиниться в adbd"; exit 1; }

echo "== aapt2 compile (res)"
"$BT/aapt2" compile --dir "$PROJ/res" -o "$OUT/res-compiled"

echo "== aapt2 link (manifest + assets + res)"
"$BT/aapt2" link \
    --manifest "$PROJ/AndroidManifest.xml" \
    -I "$PLATFORM" \
    -A "$PROJ/assets" \
    -R "$OUT"/res-compiled/*.flat \
    --min-sdk-version 26 --target-sdk-version 29 \
    -o "$OUT/base.apk"

echo "== javac"
find "$PROJ/src" -name '*.java' > "$OUT/sources.txt"
javac -source 8 -target 8 -nowarn \
    -bootclasspath "$PLATFORM" \
    -d "$OUT/classes" @"$OUT/sources.txt" 2>&1 | grep -v 'bootstrap class path' || true

echo "== d8"
"$BT/d8" --min-api 26 --output "$OUT/dex" \
    $(find "$OUT/classes" -name '*.class')

echo "== package"
cp "$OUT/base.apk" "$OUT/unsigned.apk"
(cd "$OUT/dex" && zip -q -X "$OUT/unsigned.apk" classes.dex)

echo "== zipalign + sign"
if [ ! -f "$PROJ/keystore.jks" ]; then
    keytool -genkeypair -keystore "$PROJ/keystore.jks" -alias f515usbwwan \
        -storepass f515usbwwan -keypass f515usbwwan -keyalg RSA -keysize 2048 \
        -validity 10000 -dname "CN=F515UsbWwanApp, O=f515, C=RU" >/dev/null 2>&1
    echo "   (created keystore.jks)"
fi
"$BT/zipalign" -f -p 4 "$OUT/unsigned.apk" "$OUT/aligned.apk"
"$BT/apksigner" sign --ks "$PROJ/keystore.jks" --ks-pass pass:f515usbwwan \
    --key-pass pass:f515usbwwan --v1-signing-enabled true --v2-signing-enabled true \
    --out "$APK" "$OUT/aligned.apk"

echo "== done"
ls -la "$APK"
"$BT/apksigner" verify --print-certs "$APK" | head -3

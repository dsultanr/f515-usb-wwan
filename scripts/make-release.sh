#!/bin/bash
# scripts/make-release.sh - Локальная сборка и публикация релиза.
# Основной канал раздачи — РФ-хостинг (tm.dsr.su/f515), GitHub-релиз остаётся как
# резерв и для счётчика скачиваний. Приложение проверяет обновления сначала на РФ,
# на GitHub падает только если РФ недоступен (UpdateManager.java).
set -euo pipefail

PROJ=$(cd "$(dirname "$0")/.." && pwd)
MANIFEST="$PROJ/app/AndroidManifest.xml"
APK="$PROJ/app/F515UsbWwanApp.apk"

# РФ-хостинг обновлений (совпадает с PRIMARY_LATEST_URL в UpdateManager.java).
RF_SSH="${RF_SSH:-cloudru-tm}"           # ssh-алиас хоста tm.dsr.su
RF_DIR="${RF_DIR:-/home/dsultanr/f515-dist}"  # каталог, смонтированный в nginx как /srv/f515
RF_BASE_URL="${RF_BASE_URL:-https://tm.dsr.su/f515}"

# Заметки релиза: если есть RELEASE_NOTES.md — идут в тег, в GitHub-релиз и в
# тело latest.json. Иначе — авто-заметки GitHub и краткая подпись тега.
NOTES_FILE="${NOTES_FILE:-$PROJ/RELEASE_NOTES.md}"

# Читаем/обновляем версию
if [ $# -ge 1 ]; then
    NEW_VER="${1#v}"
    echo "==> Установка версии $NEW_VER в AndroidManifest.xml..."
    sed -i "s/android:versionName=\"[^\"]*\"/android:versionName=\"$NEW_VER\"/" "$MANIFEST"
    CURR_CODE=$(grep -o 'android:versionCode="[^"]*"' "$MANIFEST" | cut -d'"' -f2)
    NEW_CODE=$((CURR_CODE + 1))
    sed -i "s/android:versionCode=\"[^\"]*\"/android:versionCode=\"$NEW_CODE\"/" "$MANIFEST"
fi

VERSION=$(grep -o 'android:versionName="[^"]*"' "$MANIFEST" | cut -d'"' -f2)
TAG="v$VERSION"

echo "==> Локальная сборка и подпись APK ($TAG)..."
"$PROJ/app/build.sh"

echo "==> Фиксация изменений в Git..."
cd "$PROJ"
git add -A
if ! git diff --cached --quiet; then
    git commit -m "release: $TAG"
fi

if git rev-parse "$TAG" >/dev/null 2>&1; then
    echo "WARN: Тег $TAG уже существует локально. Перезаписываю..."
    git tag -d "$TAG"
    git push origin ":refs/tags/$TAG" 2>/dev/null || true
fi

echo "==> Создание тега $TAG..."
if [ -f "$NOTES_FILE" ]; then
    git tag -a "$TAG" -F "$NOTES_FILE"
else
    git tag -a "$TAG" -m "Release $TAG"
fi

echo "==> Отправка коммитов в GitHub..."
git push origin main
git push origin "$TAG"

echo "==> Публикация релиза через GitHub CLI (резерв + счётчик скачиваний)..."
if gh release view "$TAG" >/dev/null 2>&1; then
    gh release upload "$TAG" "$APK" --clobber
else
    if [ -f "$NOTES_FILE" ]; then
        gh release create "$TAG" "$APK" --title "$TAG" --notes-file "$NOTES_FILE"
    else
        gh release create "$TAG" "$APK" --title "$TAG" --generate-notes
    fi
fi

echo "==> Публикация на РФ-хостинг ($RF_BASE_URL)..."
APK_SIZE=$(stat -c%s "$APK")
if [ -f "$NOTES_FILE" ]; then NOTES=$(cat "$NOTES_FILE"); else NOTES=$(git tag -l --format='%(contents:subject)' "$TAG"); fi
# latest.json — формат, который читает UpdateManager.fetchRf()
LATEST_JSON=$(cat <<JSON
{
  "tag_name": "$TAG",
  "version": "$VERSION",
  "name": "$TAG",
  "body": $(printf '%s' "${NOTES:-$TAG}" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))'),
  "apk_url": "$RF_BASE_URL/F515UsbWwanApp.apk",
  "size": $APK_SIZE
}
JSON
)
# Заливаем сначала APK, потом latest.json — чтобы клиент никогда не увидел новую
# версию в json раньше, чем сам файл окажется на месте.
ssh "$RF_SSH" "mkdir -p '$RF_DIR'"
scp "$APK" "$RF_SSH:$RF_DIR/F515UsbWwanApp.apk"
printf '%s\n' "$LATEST_JSON" | ssh "$RF_SSH" "cat > '$RF_DIR/latest.json'"

echo "==> Релиз $TAG опубликован:"
echo "    РФ-хостинг: $RF_BASE_URL/latest.json  (основной)"
echo "    GitHub:     https://github.com/dsultanr/f515-usb-wwan/releases/tag/$TAG  (резерв)"

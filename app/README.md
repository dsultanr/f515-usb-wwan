# F515 USB WWAN — приложение

Кнопки над `scripts/wwan-up.sh` и `scripts/wwan-boot.sh`: **Проверка** (`--check`) /
**Включить** (`--system` — полный подъём модема и раздача интернета приложениям Android
одной кнопкой) / **Выключить** (`--down`) / **Автозапуск** (включить подъём после ребута,
посмотреть состояние сторожа, снять блокировку безопасного режима) / **Интернетометр**
(открыть `https://internet.yandex.ru` через системный `ACTION_VIEW` — визуально проверить,
что интернет действительно есть) / **Форматировать SD**.

При открытии приложение проверяет наличие обновлений. Команды кнопок разворачивают
полезную нагрузку и запускают LBS, если функция включена (по умолчанию включена).
Включённый пользователем автозапуск на `BOOT_COMPLETED` поднимает модем и LBS после
перезагрузки ([docs/autostart.md](../docs/autostart.md)).

Пакет `su.dsr.f515usbwwan` — отдельный от прежних `su.dsr.f515wwan` (Huawei) и
`su.dsr.f515hilinkwwan` (ZTE), они друг другу не мешают. Если стоят старые — их можно
удалить, этот заменяет оба.

## Как это работает

adbd на этой прошивке уже слушает `127.0.0.1:5555` и работает от root без дополнительного
`su`. `AdbClient.java` — минимальный ADB-клиент (CNXN → AUTH RSA/SHA1 → OPEN `shell:`),
коннектится на loopback и сразу получает root-шелл.

При выполнении команд приложение заливает скрипты, модули ядра, `huawei-modeswitch` и
компоненты LBS в `/data/local/tmp/wwan/`, сверяя SHA-256 и атомарно заменяя изменённые
файлы. На время обновления LBS приостанавливается. Дальше вызывается нужный скрипт. Вся логика
подъёма/проверок — в самом скрипте, приложение её не дублирует.

Автозапуск устроен так же: `BootReceiver` → `BootService` (foreground, иначе Android 10 не
даст фоновому приложению поднять сервис) → ожидание adbd с нарастающей паузой → запуск
`wwan-boot.sh` отцепленным процессом (`setsid`), чтобы он пережил закрытие adb-сессии.

### Ключ adb

**`assets/adbkey`/`adbkey.pub` в этом репозитории — одноразовая заглушка**, сгенерированная
для публикации. adbd на этой прошивке принимает любой ключ (`/data/misc/adb/adb_keys`
пуст), так что заглушка работает и на реальном устройстве — но если ставишь на голову,
которая ключи всё-таки проверяет, сгенерируй свой:

```bash
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -pkeyopt rsa_keygen_pubexp:65537 -out assets/adbkey
python3 mkadbpub.py assets/adbkey "you@host" > assets/adbkey.pub
```

**Никогда не коммить сюда свой реальный `~/.android/adbkey`** — это приватный ключ.

## Файлы

| Путь | Что |
|---|---|
| `assets/adbkey`, `assets/adbkey.pub` | ключ хоста для self-adb (см. выше) |
| `assets/*.sh`, `assets/*.ko`, `assets/huawei-modeswitch` | копии из `scripts/`, `modules/prebuilt/`, `tools/` — их кладёт сюда `build.sh` перед сборкой, под гитом их нет |
| `src/.../AdbClient.java` | минимальный ADB-клиент |
| `src/.../Keeper.java` | заливка файлов, запуск скриптов, ожидание adbd на загрузке |
| `src/.../Autostart.java` | признак «автозапуск разрешён» (device-protected prefs) |
| `src/.../BootReceiver.java`, `BootService.java` | автозапуск после ребута |
| `src/.../MainActivity.java` | экран с кнопками и диалогами |

## Сборка

```bash
./build.sh                              # -> F515UsbWwanApp.apk
ANDROID_SDK=~/android-sdk ./build.sh    # если SDK лежит не по умолчанию
```

`assets → aapt2 → javac → d8 → zipalign → apksigner`, без gradle. Нужен Android SDK
(`aapt2`/`d8`/`zipalign`/`apksigner`, платформа `android-11`+) и JDK. `keystore.jks`
создаётся автоматически при первой сборке.

Раскладка SDK, которую ждёт скрипт, — ровно та, что получается распаковкой официальных
zip'ов Google, без `sdkmanager`:

```bash
mkdir -p ~/android-sdk && cd ~/android-sdk
curl -O https://dl.google.com/android/repository/build-tools_r34-linux.zip  # -> android-14/
curl -O https://dl.google.com/android/repository/platform-30_r03.zip        # -> android-11/
unzip -q build-tools_r34-linux.zip && unzip -q platform-30_r03.zip
```

Ключ подписи в репозиторий не кладётся, поэтому у собранного своими руками APK подпись
будет **другая**, чем у выложенного в репозитории: обновиться «поверх» установленного
приложения такой APK не даст — сначала удалить старое.

R.java при такой сборке не генерируется (`aapt2 link` вызывается без `--java`), поэтому
из кода нельзя сослаться на собственный ресурс — иконка уведомления берётся из
`android.R.drawable.*`. Верстка экрана тоже целиком кодом, без layout-XML.

## Установка

На этой прошивке `pm install`/`adb install` отключены политикой производственной сборки
(`ro.build.type=user`). APK нужно ставить так же, как остальные приложения этого стенда:
через USB-флешку и штатный установщик Toolbox на голове (не просто копирование файла —
установка идёт через приложение Toolbox) либо инъекцией в EngMode. Само по себе
приложение решение об установке не принимает — собранный `F515UsbWwanApp.apk` просто
лежит рядом.

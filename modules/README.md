# Модули ядра: usbserialmerged2, ppp_async, NCM-тройка

Ядро головы (`5.4.86-qgki-...`) не собрано с `CONFIG_USB_SERIAL` и `CONFIG_PPP_ASYNC` —
без них Huawei-модем не отдаёт AT/PPP-порты и PPP-дозвон невозможен. Там же выключены
`CONFIG_USB_NET_CDC_NCM`, `CONFIG_USB_NET_HUAWEI_CDC_NCM` и `CONFIG_USB_WDM` — без них не
работает вторая половина Huawei-модемов, у которых канал данных не AT/PPP-порт, а NCM.
Готовые `.ko` лежат в [`prebuilt/`](prebuilt/) и собраны под ядро головы
`5.4.86-qgki-g310fb9b27fcd-dirty`. Перед загрузкой `wwan-up.sh` проверяет совместимость —
но не строкой `vermagic`, а так же, как это делает само ядро: см.
[«Другая сборка того же ядра»](#другая-сборка-того-же-ядра). Пересобирать нужно, только
если разошёлся ABI.

| Модуль | Зачем | Ветка |
|---|---|---|
| `usbserialmerged2.ko` | `usb-serial` + `option`: даёт `/dev/ttyUSB*` | PPP |
| `ppp_async.ko` | line discipline `ppp` для дозвона | PPP |
| `cdc-wdm.ko` | служебный WDM-канал NCM-функции | NCM |
| `cdc_ncm.ko` | собственно NCM поверх встроенного `usbnet` | NCM |
| `huawei_cdc_ncm.ko` | NCM Huawei, спрятанный за vendor-классом `ff/02/16` | NCM |
| `f515_rndis.ko` | автономный RNDIS поверх `usbnet` (MTS 81332FT, ZTE MF90) | RNDIS / HiLink |

NCM-тройке повезло: каркас `usbnet` в ядре головы **встроен** (`CONFIG_USB_USBNET=y`,
`CONFIG_MII=y`, 41 экспортируемый символ `usbnet_*`), поэтому драйверы собираются как
внешние модули без единой правки исходников — берутся из дерева ядра как есть.

## Другая сборка того же ядра

На головах разных прошивок `uname -r` отличается OEM-хвостом: `5.4.86-qgki-gc8e10aca1899-dirty`
вместо нашего `5.4.86-qgki-g310fb9b27fcd-dirty`. Само по себе это не повод пересобирать
модули, и `wwan-up.sh` из-за одной этой строки больше не отказывает.

Причина — в том, как ядро сравнивает `vermagic` (`same_magic()`, `kernel/module.c`):

```c
if (has_crcs) {                    /* модуль несёт секцию __versions */
	amagic += strcspn(amagic, " ");   /* release ПРОПУСКАЕТСЯ */
	bmagic += strcspn(bmagic, " ");
}
return strcmp(amagic, bmagic) == 0;
```

При `CONFIG_MODVERSIONS=y` (а он у головы включён) строкой сверяется только хвост флагов
(`SMP preempt mod_unload modversions aarch64`), а настоящей проверкой ABI служит CRC
символа `module_layout` из `__versions` — он кодирует раскладку `struct module`, включая
лишнее поле от `CONFIG_CFI_CLANG`. Поэтому `wwan-up.sh` при несовпадении release сверяет
с любым штатным `/vendor/lib/modules/*.ko` этой головы:

| что сверяется | почему |
|---|---|
| CRC `module_layout` | раскладка `struct module` — то же, что проверит и ядро при `insmod` |
| хвост флагов `vermagic` | ровно эту строку ядро и сравнивает |
| наличие `__cfi_check` | ядро с CFI не-CFI модуль не примет |

Совпало — грузим (с предупреждением в лог), не совпало — отказ с указанием, что именно
разошлось. Отдельный смертный случай — модуль вообще без `module_layout` в `__versions`:
тогда раскладку не проверит никто, `insmod` пройдёт молча и порвёт память ядра.

Проверено на живой голове: модуль с меткой `-gc8e10aca1899-dirty` грузится ядром
`-g310fb9b27fcd-dirty`, `module_init()` отрабатывает (`usbcore: registered new interface
driver f515_rndis`), `rmmod` проходит штатно.

Полный отчёт по модулям на любой голове (ничего не грузит и не меняет):

```bash
sh wwan-up.sh --modcheck
```

Он печатает ядро головы, эталонный штатный модуль, `vermagic`/`module_layout`/`__cfi_check`
каждого нашего `.ko` и вердикт по каждому — это то, что имеет смысл присылать, когда на
чужой голове `insmod` отказал.

Тестовая сборка тех же модулей с меткой `-gc8e10aca1899-dirty` лежит в
[`prebuilt-gc8e10aca1899/`](prebuilt-gc8e10aca1899/) — на случай, если где-то по дороге
(старый `wwan-up.sh`, чужой скрипт, `modprobe`) строка release всё-таки проверяется целиком.

## Важно: тулчейн должен совпадать с ядром

Ядро головы собрано **clang + ThinLTO + CFI** (Control Flow Integrity). Модуль, собранный
обычным gcc-тулчейном, при загрузке либо не выполнит `module_init()` вовсе (тихо, без
ошибки — `insmod` вернёт успех), либо уронит ядро в панику на CFI-проверке. Собирать нужно
строго тем же тулчейном, что и ядро — `build-cfi.sh` делает это автоматически.

## Пересборка

```bash
# Debian: clang-11 + lld-11
sudo apt install clang-11 lld-11 aarch64-linux-gnu-gcc

# 1. Снять реальный конфиг с головы (там правда о CFI/LTO)
adb shell zcat /proc/config.gz > running.config   # или /proc/config, смотря что есть

# 2. Положить исходники ядра этой же версии в SRC (см. build-cfi.sh)
# 3. Собрать
./build-cfi.sh src/usbserial
./build-cfi.sh src/ppp
./build-cfi.sh src/ncm
```

Исходники ядра головы — CodeLinaro `msm-5.4`, тег `LA.AU.1.3.2.r2-03600-sa8155_gvmq.0`
(это ровно 5.4.86 и ровно та платформа: SA8155, Android-гость под гипервизором):

```bash
git clone --depth 1 -b LA.AU.1.3.2.r2-03600-sa8155_gvmq.0 \
    https://git.codelinaro.org/clo/la/kernel/msm-5.4.git
printf -- '-g310fb9b27fcd-dirty' > msm-5.4/.scmversion   # хвост uname -r головы
```

`.scmversion` обязателен: в конфиге головы `CONFIG_LOCALVERSION="-qgki"` и
`CONFIG_LOCALVERSION_AUTO=y`, то есть хвост `-g310fb9b27fcd-dirty` дописывает
`scripts/setlocalversion`. Коммит OEM-овский, в CLO его нет (сборка к тому же помечена
`dirty`), поэтому строку просто фиксируем файлом — иначе `vermagic` не сойдётся и
`wwan-up.sh` откажется грузить модуль.

`build-cfi.sh` при первом запуске конфигурирует дерево ядра под этот тулчейн
(`running.config` + `olddefconfig`), после чего собирает указанный внешний модуль и
сверяет результат с ожидаемой раскладкой `struct module` (`.init`/`.exit`/`__cfi_check`).

## Module.symvers — проверка совпадения с ядром "из коробки"

`oem.symvers` восстановлен из штатных `/vendor/lib/modules/*.ko` этой прошивки
(`extract-symvers.py`) и содержит CRC символа `module_layout` — по нему ядро само
проверяет, что раскладка `struct module` совпадает, и откажет понятной ошибкой
(`disagrees about version of symbol module_layout`) вместо тихой порчи памяти, если
тулчейн вдруг разъедется с ядром. `build-cfi.sh` подставляет его автоматически.

```bash
python3 extract-symvers.py oem.symvers /vendor/lib/modules/*.ko   # только если нужно обновить
```

## Файлы

- `src/usbserial/` — копии `usb-serial.c`, `bus.c`, `generic.c`, `option.c`, `usb_wwan.c`
  из `drivers/usb/serial/` апстримного дерева этого ядра, собираются в один
  `usbserialmerged2.ko`.
- `src/ppp/ppp_async.c` — копия `drivers/net/ppp/ppp_async.c`, даёt line discipline `ppp`.
- `src/ncm/` — копии `drivers/usb/class/cdc-wdm.c`, `drivers/net/usb/cdc_ncm.c` и
  `drivers/net/usb/huawei_cdc_ncm.c` **без единой правки**: таблица
  `huawei_cdc_ncm_devs` уже содержит нужную четвёрку `(12d1, ff, 02, 16)`. В отличие от
  usbserial в один `.ko` не сливаются — межмодульные символы modpost разрешает сам,
  раз все три собираются одним проходом.
- `src/rndis/` — автономный `f515_rndis.c` с встроенным CDC-биндингом (не зависящим от
  монолитного `cdc_ether`, в котором отключен RNDIS) для поддержки RNDIS-роутеров
  (MTS 81332FT, ZTE MF90 и др.).
- `prebuilt/*.ko` — готовые модули для `5.4.86-qgki-g310fb9b27fcd-dirty`.
- `build-cfi.sh`, `extract-symvers.py`, `oem.symvers` — инструменты пересборки.

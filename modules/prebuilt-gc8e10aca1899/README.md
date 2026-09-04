# Тестовая сборка под `5.4.86-qgki-gc8e10aca1899-dirty`

Те же модули, что в [`../prebuilt/`](../prebuilt/), собранные тем же тулчейном из тех же
исходников — отличается только метка сборки в `vermagic`: `-gc8e10aca1899-dirty` вместо
`-g310fb9b27fcd-dirty`. ABI идентичен: `module_layout` `07f95fc1`, флаги
`SMP preempt mod_unload modversions aarch64`, `__cfi_check` на месте.

Сделано так: в дереве ядра `.scmversion` временно переставлен на хвост чужой головы,
`make include/generated/utsrelease.h`, дальше обычный `build-cfi.sh`. Побайтная сверка с
`../prebuilt/ppp_async.ko` показывает ровно два отличия — 12 символов хеша в `vermagic` и
`srcversion`; всё остальное совпадает.

Нужны они **только** если release всё-таки проверяется целиком (старый `wwan-up.sh` до
патча, чужой скрипт, `modprobe` с его `--force-vermagic`). Начиная с этой версии
`wwan-up.sh` сверяет ABI, а не строку, — и обычные `prebuilt/` грузятся на голове любой
сборки того же ядра, см. [`../README.md`](../README.md#другая-сборка-того-же-ядра).

Установка вручную:

```bash
adb push *.ko /data/local/tmp/
adb shell 'cd /data/local/tmp && sh wwan-up.sh --modcheck'   # сначала отчёт
adb shell 'cd /data/local/tmp && sh wwan-up.sh'
```

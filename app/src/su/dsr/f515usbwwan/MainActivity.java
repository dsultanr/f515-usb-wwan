package su.dsr.f515usbwwan;

import android.app.Activity;
import android.app.AlertDialog;
import android.content.DialogInterface;
import android.content.Intent;
import android.graphics.Color;
import android.net.Uri;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.util.TypedValue;
import android.view.Gravity;
import android.view.Menu;
import android.view.MenuItem;
import android.view.View;
import android.widget.Button;
import android.widget.HorizontalScrollView;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;

import java.util.ArrayList;
import java.util.List;

/**
 * Всю работу делают скрипты на голове (wwan-up.sh - стадиями, с проверкой предусловий;
 * wwan-boot.sh - автозапуск и watchdog) - этот экран только раскладывает их и запускает
 * с разными аргументами. Само по себе ничего не стартует: либо кнопка, либо явно
 * включённый автозапуск.
 */
public class MainActivity extends Activity {

    private static final String SPEEDTEST_URL = "https://internet.yandex.ru";

    private TextView log;
    private LinearLayout buttonsRow;
    private UpdateManager.ReleaseInfo latestRelease;
    private final Handler ui = new Handler(Looper.getMainLooper());
    private boolean busy = false;

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        setTitle("F515 USB WWAN v" + versionName());

        LinearLayout root = new LinearLayout(this);
        root.setOrientation(LinearLayout.VERTICAL);
        root.setPadding(24, 24, 24, 24);
        root.setBackgroundColor(Color.BLACK);

        buttonsRow = new LinearLayout(this);
        buttonsRow.setOrientation(LinearLayout.HORIZONTAL);
        addRunButton("Проверка", "--check");
        addEnableButton();
        addRunButton("Выключить", "--down");
        addAutostartButton();
        addSmsButton();
        addIconButton();
        addWhitelistButton();
        addDnsButton();
        addVpnButton();
        addUrlButton("Интернетометр", SPEEDTEST_URL);
        addFormatButton();
        HorizontalScrollView buttonsScroll = new HorizontalScrollView(this);
        buttonsScroll.addView(buttonsRow);
        root.addView(buttonsScroll);

        log = new TextView(this);
        log.setTextSize(TypedValue.COMPLEX_UNIT_SP, 13);
        log.setTextColor(Color.WHITE);
        log.setTextIsSelectable(true);
        log.setGravity(Gravity.TOP);
        ScrollView sv = new ScrollView(this);
        sv.addView(log);
        root.addView(sv);

        setContentView(root);

        append("ready. adbd target " + Keeper.ADB_HOST + ":" + Keeper.ADB_PORT);
        append("тип модема определяется сам: HiLink (CDC-Ethernet) или AT/PPP (Huawei).");
        append("");
        append("Проверка      - только диагностика, ничего не меняет");
        append("Включить      - поднять модем и раздать интернет приложениям Android");
        append("Выключить     - остановить pppd");
        append("Автозапуск    - подъём после перезагрузки головы + слежение за связью");
        append("VPN           - совместимость с VPN-клиентами (VpnService)");
        append("Белые списки  - доступны ли серверы телеметрии Evolute (по одной строке на сервер)");
        append("Интернетометр - открыть " + SPEEDTEST_URL + " (проверка интернета глазами)");
        append("автозапуск сейчас: " + (Autostart.isEnabled(this) ? "ВКЛЮЧЕН" : "выключен"));

        checkServerVersionAsync();
    }

    // ------------------------------------------------------------------ кнопки --

    private void addEnableButton() {
        buttonsRow.addView(button("Включить", new View.OnClickListener() {
            @Override
            public void onClick(View v) {
                runInBackground("> Включить ...", new Job() {
                    @Override
                    public void run(Keeper.Progress p) {
                        Keeper.run(MainActivity.this, "--system", p);
                        if (Autostart.isEnabled(MainActivity.this)) {
                            String st = Keeper.runBoot(MainActivity.this, "--status", null);
                            if (!st.contains("watchdog=1")) {
                                p.onLine("\n> автозапуск включен — запускаю сторожа (wwan-boot.sh)...");
                                Keeper.startAutostart(MainActivity.this, true, p);
                            }
                        }
                    }
                });
            }
        }));
    }

    /**
     * Проверка белых списков телеметрии: по очереди стучится в серверы Evolute из
     * vega-mitm и показывает по строке на сервер, доступен он или нет. Работает
     * внутри приложения (Java-сокеты), маршрут — тот же, что у Android-приложений,
     * поэтому проверять лучше при поднятом модеме.
     */
    private void addWhitelistButton() {
        buttonsRow.addView(button("Белые списки", new View.OnClickListener() {
            @Override
            public void onClick(View v) {
                runInBackground("> Проверка белых списков телеметрии ...", new Job() {
                    @Override
                    public void run(Keeper.Progress p) {
                        WhitelistChecker.checkAll(p);
                    }
                });
            }
        }));
    }

    private void addRunButton(String text, final String args) {
        buttonsRow.addView(button(text, new View.OnClickListener() {
            @Override
            public void onClick(View v) {
                runInBackground("> " + text + " ...", new Job() {
                    @Override
                    public void run(Keeper.Progress p) {
                        Keeper.run(MainActivity.this, args, p);
                    }
                });
            }
        }));
    }

    /**
     * Автозапуск - единственное, что после нажатия продолжает жить само по себе, поэтому
     * он не «кнопка-переключатель», а диалог: сначала показываем реальное состояние с
     * головы (включая безопасный режим, если wwan-boot.sh его включил), и только потом
     * человек решает.
     */
    private void addAutostartButton() {
        buttonsRow.addView(button("Автозапуск", new View.OnClickListener() {
            @Override
            public void onClick(View v) {
                if (busy) return;
                setBusy(true);
                append("");
                append("> Автозапуск: читаю состояние...");
                background(new Runnable() {
                    @Override
                    public void run() {
                        final String out = Keeper.runBoot(MainActivity.this, "--status", null);
                        ui.post(new Runnable() {
                            @Override
                            public void run() {
                                setBusy(false);
                                showAutostartDialog(out);
                            }
                        });
                    }
                });
            }
        }));
    }

    private void showAutostartDialog(String status) {
        final boolean enabled = Autostart.isEnabled(this);
        final boolean blocked = value(status, "disabled").equals("1");
        String reason = value(status, "disabled_reason");
        String attempts = value(status, "attempts");
        String maxAttempts = value(status, "max_attempts");
        String lastOk = value(status, "last_ok");
        String iface = value(status, "wan_iface");
        String addr = value(status, "wan_addr");
        boolean watchdog = status.contains("watchdog=1");

        StringBuilder msg = new StringBuilder();
        msg.append("Автозапуск приложения: ").append(enabled ? "включен" : "выключен").append('\n');
        msg.append("Watchdog на голове: ").append(watchdog ? "работает" : "не запущен").append('\n');
        if (!iface.isEmpty()) {
            msg.append("Интерфейс: ").append(iface).append(' ')
                    .append(addr.isEmpty() ? "(без адреса)" : addr).append('\n');
        }
        if (!lastOk.isEmpty()) msg.append("Последний удачный подъём: ").append(lastOk).append('\n');
        msg.append("Незавершённых заходов: ").append(attempts).append(" из ").append(maxAttempts).append('\n');
        if (blocked) {
            msg.append("\nБЕЗОПАСНЫЙ РЕЖИМ: автозапуск заблокирован на голове.\n")
                    .append(reason).append('\n')
                    .append("\nПока блокировка стоит, после перезагрузки ничего не поднимается — ")
                    .append("это защита от цикла перезагрузок. Снимать её стоит, только если понятно, ")
                    .append("из-за чего голова падала.");
        }

        AlertDialog.Builder b = new AlertDialog.Builder(this)
                .setTitle("Автозапуск после перезагрузки")
                .setMessage(msg.toString());

        if (enabled) {
            b.setNegativeButton("Выключить", new DialogInterface.OnClickListener() {
                @Override
                public void onClick(DialogInterface d, int which) {
                    Autostart.setEnabled(MainActivity.this, false);
                    append("автозапуск выключен (после перезагрузки ничего не поднимется)");
                    stopWatchdog();
                }
            });
        } else {
            b.setPositiveButton("Включить", new DialogInterface.OnClickListener() {
                @Override
                public void onClick(DialogInterface d, int which) {
                    Autostart.setEnabled(MainActivity.this, true);
                    append("автозапуск включен: после перезагрузки модем поднимется сам");
                    append("(защита от бутлупа — см. docs/autostart.md)");
                }
            });
        }
        if (blocked) {
            b.setNeutralButton("Снять блокировку", new DialogInterface.OnClickListener() {
                @Override
                public void onClick(DialogInterface d, int which) {
                    runInBackground("> снимаю блокировку автозапуска...", new Job() {
                        @Override
                        public void run(Keeper.Progress p) {
                            Keeper.runBoot(MainActivity.this, "--reset", p);
                        }
                    });
                }
            });
        } else {
            b.setNeutralButton("Запустить сейчас", new DialogInterface.OnClickListener() {
                @Override
                public void onClick(DialogInterface d, int which) {
                    runInBackground("> запускаю wwan-boot.sh (подъём + watchdog)...", new Job() {
                        @Override
                        public void run(Keeper.Progress p) {
                            Keeper.startAutostart(MainActivity.this, true, p);
                        }
                    });
                }
            });
        }
        b.show();
    }

    private void addSmsButton() {
        buttonsRow.addView(button("СМС", new View.OnClickListener() {
            @Override
            public void onClick(View v) {
                loadSmsAndShow();
            }
        }));
    }

    private void loadSmsAndShow() {
        if (busy) return;
        setBusy(true);
        append("");
        append("> Чтение SMS из памяти модема...");
        background(new Runnable() {
            @Override
            public void run() {
                final List<SmsHelper.SmsMessage> list = SmsHelper.readAll(MainActivity.this, new Keeper.Progress() {
                    @Override
                    public void onLine(String line) {
                        // Не спамим сырым выводом в общий лог экрана
                    }
                });
                ui.post(new Runnable() {
                    @Override
                    public void run() {
                        setBusy(false);
                        append("> Найдено SMS: " + list.size());
                        showSmsDialog(list);
                    }
                });
            }
        });
    }

    private void showSmsDialog(final List<SmsHelper.SmsMessage> messages) {
        AlertDialog.Builder b = new AlertDialog.Builder(this);
        b.setTitle("Входящие SMS (" + messages.size() + ")");

        if (messages.isEmpty()) {
            b.setMessage("Сообщений нет (память SIM/модема пуста) или модем не ответил.");
        } else {
            StringBuilder sb = new StringBuilder();
            for (int i = 0; i < messages.size(); i++) {
                SmsHelper.SmsMessage m = messages.get(i);
                sb.append("От: ").append(m.sender);
                if (!m.timestamp.isEmpty()) {
                    sb.append(" | ").append(m.timestamp);
                }
                sb.append("\n");
                sb.append(m.text).append("\n");
                if (i < messages.size() - 1) {
                    sb.append("----------------------------------------\n\n");
                }
            }
            b.setMessage(sb.toString());
        }

        b.setNegativeButton("Закрыть", null);
        b.setNeutralButton("Обновить", new DialogInterface.OnClickListener() {
            @Override
            public void onClick(DialogInterface dialog, int which) {
                loadSmsAndShow();
            }
        });

        if (!messages.isEmpty()) {
            b.setPositiveButton("Удалить все", new DialogInterface.OnClickListener() {
                @Override
                public void onClick(DialogInterface dialog, int which) {
                    confirmDeleteAllSms();
                }
            });
        }

        AlertDialog d = b.create();
        d.show();

        TextView messageView = (TextView) d.findViewById(android.R.id.message);
        if (messageView != null) {
            messageView.setTextSize(TypedValue.COMPLEX_UNIT_SP, 15);
            messageView.setTextIsSelectable(true);
        }
    }

    private void confirmDeleteAllSms() {
        new AlertDialog.Builder(this)
                .setTitle("Удалить все SMS?")
                .setMessage("Все сообщения будут безвозвратно удалены из памяти SIM-карты и модема.")
                .setPositiveButton("Удалить", new DialogInterface.OnClickListener() {
                    @Override
                    public void onClick(DialogInterface dialog, int which) {
                        runInBackground("> Удаляю все SMS...", new Job() {
                            @Override
                            public void run(Keeper.Progress p) {
                                SmsHelper.deleteAll(MainActivity.this, p);
                                p.onLine("\n> Все SMS удалены");
                            }
                        });
                    }
                })
                .setNegativeButton("Отмена", null)
                .show();
    }

    /**
     * Иконка сотовой сети в статус-баре. Как и автозапуск, это не разовое действие, а
     * состояние, которое живёт само по себе, поэтому сначала спрашиваем голову, что там
     * сейчас, и только потом показываем выбор.
     */
    private void addIconButton() {
        buttonsRow.addView(button("Иконка сети", new View.OnClickListener() {
            @Override
            public void onClick(View v) {
                if (busy) return;
                setBusy(true);
                append("");
                append("> Иконка сети: читаю состояние...");
                background(new Runnable() {
                    @Override
                    public void run() {
                        final String out = Keeper.runIcon(MainActivity.this, "status", null);
                        ui.post(new Runnable() {
                            @Override
                            public void run() {
                                setBusy(false);
                                showIconDialog(out);
                            }
                        });
                    }
                });
            }
        }));
    }

    private void showIconDialog(String status) {
        final boolean running = value(status, "running").equals("1");
        // Два режима (см. tbox-icon.sh): native — штатная панель рисует иконку сама
        // (config tbox=1); bridge — опция TBOX выключена, штатно панель иконку не создаёт, но её
        // рисует твик iSpaceToolbox «Статус сети» из файла-моста, который мы пишем. В ОБОИХ
        // режимах иконку можно включить — раньше на bridge «Включить» блокировали, исправлено.
        String mode = value(status, "mode");
        if (mode.isEmpty()) mode = value(status, "capable").equals("0") ? "bridge" : "native";
        final boolean bridge = mode.equals("bridge");

        StringBuilder msg = new StringBuilder();
        msg.append("Штатная иконка мобильной сети показывает сигнал USB-модема ")
                .append("вместо крестика: голове отдаётся то, что в машине отдавал бы блок TBOX.\n\n");
        if (bridge) {
            msg.append("Опция TBOX в машине выключена (").append(value(status, "capable_why"))
                    .append("), штатная панель иконку не создаёт. Её рисует твик iSpaceToolbox ")
                    .append("«Статус сети» из файла-моста — включите этот твик в тулбоксе, ")
                    .append("иначе иконки не будет.\n\n");
        } else {
            msg.append("Штатная панель рисует иконку сама (config tbox=1).\n\n");
        }
        msg.append("Сейчас: ").append(running ? "работает" : "не запущена").append('\n');
        // Не `enabled`: в bridge сама она после ребута не поднимется, пока её хоть раз не
        // включили здесь кнопкой (иначе поллер зря занимал бы AT-порт модема). Ответ на этот
        // вопрос целиком считает скрипт — поле autostart; enabled оставлен для старых версий.
        String autostart = value(status, "autostart");
        if (autostart.isEmpty()) autostart = value(status, "enabled");
        msg.append("После подъёма модема: ").append(autostart.equals("1")
                ? "включается сама"
                : bridge && !value(status, "enabled").equals("0")
                        ? "не включается (включите один раз кнопкой ниже)"
                        : "не включается (выключено вручную)").append('\n');
        msg.append("\nНа сам интернет это никак не влияет — только на картинку в статус-баре.");

        AlertDialog.Builder b = new AlertDialog.Builder(this)
                .setTitle("Иконка сотовой сети")
                .setMessage(msg.toString());

        if (running) {
            b.setNegativeButton("Выключить", new DialogInterface.OnClickListener() {
                @Override
                public void onClick(DialogInterface d, int which) {
                    runInBackground("> выключаю иконку...", new Job() {
                        @Override
                        public void run(Keeper.Progress p) {
                            Keeper.runIcon(MainActivity.this, "stop", p);
                        }
                    });
                }
            });
        } else {
            b.setPositiveButton("Включить", new DialogInterface.OnClickListener() {
                @Override
                public void onClick(DialogInterface d, int which) {
                    runInBackground("> включаю иконку...", new Job() {
                        @Override
                        public void run(Keeper.Progress p) {
                            Keeper.runIcon(MainActivity.this, "start", p);
                        }
                    });
                }
            });
        }
        b.setNeutralButton("Что видит модем", new DialogInterface.OnClickListener() {
            @Override
            public void onClick(DialogInterface d, int which) {
                runInBackground("> опрашиваю модем...", new Job() {
                    @Override
                    public void run(Keeper.Progress p) {
                        Keeper.runIcon(MainActivity.this, "signal", p);
                    }
                });
            }
        });
        b.show();
    }

    // Адреса для кнопок-пресетов: набирать цифры на голове неудобно, а промах по цифре
    // здесь стоит дорого — приложения останутся без резолвинга до следующей правки.
    private static final String[][] DNS_PRESETS = {
            {"Яндекс", "77.88.8.8"},
            {"Google", "8.8.8.8"},
            {"Cloudflare", "1.1.1.1"},
            {"AdGuard", "94.140.14.14"},
    };

    private void addDnsButton() {
        buttonsRow.addView(button("DNS", new View.OnClickListener() {
            @Override
            public void onClick(View v) {
                if (busy) return;
                setBusy(true);
                append("");
                append("> DNS: читаю настройку...");
                background(new Runnable() {
                    @Override
                    public void run() {
                        final String out = Keeper.run(MainActivity.this, "--dns", null);
                        ui.post(new Runnable() {
                            @Override
                            public void run() {
                                setBusy(false);
                                showDnsDialog(out);
                            }
                        });
                    }
                });
            }
        }));
    }

    private void addVpnButton() {
        buttonsRow.addView(button("VPN", new View.OnClickListener() {
            @Override
            public void onClick(View v) {
                if (busy) return;
                setBusy(true);
                append("");
                append("> VPN: читаю состояние...");
                background(new Runnable() {
                    @Override
                    public void run() {
                        final String out = Keeper.run(MainActivity.this, "--vpn-status", null);
                        ui.post(new Runnable() {
                            @Override
                            public void run() {
                                setBusy(false);
                                showVpnDialog(out);
                            }
                        });
                    }
                });
            }
        }));
    }

    @Override
    public boolean onCreateOptionsMenu(Menu menu) {
        MenuItem item = menu.add(0, 1001, 0, "Обновить");
        item.setShowAsAction(MenuItem.SHOW_AS_ACTION_ALWAYS);
        return true;
    }

    @Override
    public boolean onOptionsItemSelected(MenuItem item) {
        if (item.getItemId() == 1001) {
            onUpdateClicked();
            return true;
        }
        return super.onOptionsItemSelected(item);
    }

    private void checkServerVersionAsync() {
        setTitle("F515 USB WWAN v" + versionName() + " [проверка...]");
        UpdateManager.check(this, new UpdateManager.CheckCallback() {
            @Override
            public void onResult(final boolean hasUpdate, final UpdateManager.ReleaseInfo release, final String currentVersion, final String message) {
                ui.post(new Runnable() {
                    @Override
                    public void run() {
                        latestRelease = release;
                        if (hasUpdate) {
                            setTitle("F515 USB WWAN v" + currentVersion + " (доступна " + release.tagName + "!)");
                        } else {
                            setTitle("F515 USB WWAN v" + currentVersion + " (актуально)");
                        }
                    }
                });
            }

            @Override
            public void onError(final String error) {
                ui.post(new Runnable() {
                    @Override
                    public void run() {
                        setTitle("F515 USB WWAN v" + versionName());
                    }
                });
            }
        });
    }

    private void onUpdateClicked() {
        if (busy) return;
        if (latestRelease != null && UpdateManager.isVersionNewer(latestRelease.versionName, versionName())) {
            showUpdateDialog(latestRelease, versionName());
            return;
        }
        setBusy(true);
        append("");
        append("> Проверка обновлений на GitHub...");
        UpdateManager.check(this, new UpdateManager.CheckCallback() {
            @Override
            public void onResult(final boolean hasUpdate, final UpdateManager.ReleaseInfo release, final String currentVersion, final String message) {
                ui.post(new Runnable() {
                    @Override
                    public void run() {
                        setBusy(false);
                        latestRelease = release;
                        append(message);
                        if (hasUpdate) {
                            setTitle("F515 USB WWAN v" + currentVersion + " (доступна " + release.tagName + "!)");
                            showUpdateDialog(release, currentVersion);
                        } else {
                            setTitle("F515 USB WWAN v" + currentVersion + " (актуально)");
                        }
                    }
                });
            }

            @Override
            public void onError(final String error) {
                ui.post(new Runnable() {
                    @Override
                    public void run() {
                        setBusy(false);
                        append("ERROR: " + error);
                    }
                });
            }
        });
    }

    private void showUpdateDialog(final UpdateManager.ReleaseInfo release, String currentVer) {
        AlertDialog.Builder b = new AlertDialog.Builder(this);
        b.setTitle("Доступно обновление: " + release.tagName);

        StringBuilder sb = new StringBuilder();
        sb.append("Текущая версия: v").append(currentVer).append("\n");
        sb.append("Новая версия: ").append(release.tagName).append("\n\n");
        if (release.body != null && !release.body.trim().isEmpty()) {
            sb.append("Что нового:\n").append(release.body.trim()).append("\n\n");
        }
        sb.append("После скачивания система спросит подтверждение установки — нажмите «Установить».\n");
        sb.append("Приложение при этом закроется; дождитесь конца установки и откройте его снова.\n\n");
        sb.append("Установить обновление сейчас?");
        b.setMessage(sb.toString());

        b.setPositiveButton("Установить", new DialogInterface.OnClickListener() {
            @Override
            public void onClick(DialogInterface dialog, int which) {
                setBusy(true);
                append("");
                append("> Запуск процесса обновления...");
                UpdateManager.downloadAndInstall(MainActivity.this, release, new Keeper.Progress() {
                    @Override
                    public void onLine(final String line) {
                        ui.post(new Runnable() {
                            @Override
                            public void run() {
                                append(line);
                            }
                        });
                    }
                });
            }
        });
        b.setNegativeButton("Позже", new DialogInterface.OnClickListener() {
            @Override
            public void onClick(DialogInterface dialog, int which) {
                dialog.dismiss();
            }
        });
        b.show();
    }

    /**
     * Куда уходят DNS-запросы приложений. Меняется ровно одна вещь — цель DNAT'а на DNS
     * фантомной TBOX-сети; почему другого места на этой прошивке нет, написано в
     * wwan-up.sh (функция dns_nat) и docs/app-network.md.
     */
    private void showDnsDialog(String status) {
        String setting = value(status, "dns");
        String active = value(status, "dns_active");
        String auto = value(status, "dns_auto");
        if (setting.isEmpty()) setting = "auto";

        LinearLayout box = new LinearLayout(this);
        box.setOrientation(LinearLayout.VERTICAL);
        box.setPadding(dp(20), dp(8), dp(20), 0);

        TextView msg = new TextView(this);
        StringBuilder t = new StringBuilder();
        t.append("Куда уходят DNS-запросы приложений, пока интернет идёт через модем. ")
                .append("На Wi-Fi приложения берут DNS роутера — эта настройка их не касается.\n\n");
        t.append("Сейчас: ").append(active.isEmpty() ? "штатный DNS сети" : active);
        if (setting.equals("auto")) {
            t.append("\nНастройка: авто");
            if (!auto.isEmpty()) t.append(" (оператор даёт ").append(auto).append(')');
        } else {
            t.append("\nНастройка: ").append(setting).append(" (задан вручную)");
        }
        t.append("\n\nПустое поле = вернуться к DNS оператора.");
        msg.setText(t.toString());
        box.addView(msg);

        final android.widget.EditText input = new android.widget.EditText(this);
        // Именно текстовое поле, а не NUMBER: на цифровой клавиатуре головы точки может
        // не оказаться вовсе, а адрес без точек не введёшь.
        input.setInputType(android.text.InputType.TYPE_CLASS_TEXT);
        input.setSingleLine(true);
        input.setHint("например 1.1.1.1");
        if (!setting.equals("auto")) input.setText(setting);
        box.addView(input);

        LinearLayout presets = new LinearLayout(this);
        presets.setOrientation(LinearLayout.HORIZONTAL);
        for (String[] p : DNS_PRESETS) {
            final String addr = p[1];
            Button b = button(p[0], new View.OnClickListener() {
                @Override
                public void onClick(View v) {
                    input.setText(addr);
                    input.setSelection(addr.length());
                }
            });
            presets.addView(b);
        }
        HorizontalScrollView presetsScroll = new HorizontalScrollView(this);
        presetsScroll.addView(presets);
        box.addView(presetsScroll);

        new AlertDialog.Builder(this)
                .setTitle("DNS для приложений")
                .setView(box)
                .setPositiveButton("Применить", new DialogInterface.OnClickListener() {
                    @Override
                    public void onClick(DialogInterface d, int which) {
                        String v = input.getText().toString().trim();
                        applyDns(v.isEmpty() ? "auto" : v);
                    }
                })
                .setNeutralButton("DNS оператора", new DialogInterface.OnClickListener() {
                    @Override
                    public void onClick(DialogInterface d, int which) {
                        applyDns("auto");
                    }
                })
                .setNegativeButton("Отмена", null)
                .show();
    }

    /**
     * Похож ли адрес на адрес — решает скрипт (одна проверка на всех, в том числе для
     * правки wwan.conf руками), его отказ виден в логе на экране. Здесь только защита
     * командной строки: строка уходит в `sh wwan-up.sh --dns=<...>` через adb-шелл, и
     * точка с запятой в поле ввода стала бы отдельной командой с правами root.
     */
    private void applyDns(final String value) {
        if (!value.matches("auto|[0-9.]{1,15}")) {
            append("> DNS: '" + value + "' — в адресе только цифры и точки");
            return;
        }
        runInBackground("> DNS: " + value + "...", new Job() {
            @Override
            public void run(Keeper.Progress p) {
                Keeper.run(MainActivity.this, "--dns=" + value, p);
            }
        });
    }

    /**
     * Совместимость с VPN-клиентами на VpnService (HAPP, WireGuard, v2rayNG и др.).
     * Сдвигает вендорский default в таблице main ниже правил netd.
     */
    private void showVpnDialog(String status) {
        final boolean modeOn = value(status, "vpn_mode").equals("1");
        final boolean moved = value(status, "vpn_moved").equals("1");
        String tun = value(status, "vpn_tun");

        StringBuilder msg = new StringBuilder();
        msg.append("Совместимость с VPN-клиентами на VpnService (HAPP, WireGuard, v2rayNG и др.).\n\n")
                .append("Штатное вендорское правило маршрутизации перехватывает трафик до правил Android netd, ")
                .append("из-за чего приложения идут мимо VPN-туннеля. Этот режим сдвигает default в main ниже правил netd.\n\n");

        msg.append("Настройка: ").append(modeOn ? "ВКЛЮЧЕНО" : "выключено").append('\n');
        msg.append("Правила в ядре: ").append(moved ? "перенесены (совместимы с VPN)" : "штатные вендорские").append('\n');
        if (!tun.isEmpty()) {
            msg.append("Активный туннель: ").append(tun).append('\n');
        }
        msg.append("\nНастройка сохраняется и применяется при каждом подъёме модема.");

        AlertDialog.Builder b = new AlertDialog.Builder(this)
                .setTitle("Совместимость с VPN")
                .setMessage(msg.toString());

        if (modeOn || moved) {
            b.setNegativeButton("Выключить", new DialogInterface.OnClickListener() {
                @Override
                public void onClick(DialogInterface d, int which) {
                    applyVpn(false);
                }
            });
        } else {
            b.setPositiveButton("Включить", new DialogInterface.OnClickListener() {
                @Override
                public void onClick(DialogInterface d, int which) {
                    applyVpn(true);
                }
            });
        }
        b.setNeutralButton("Отмена", null);
        b.show();
    }

    private void applyVpn(final boolean enable) {
        final String arg = enable ? "--vpn=on" : "--vpn=off";
        runInBackground("> VPN: " + (enable ? "включаю" : "выключаю") + "...", new Job() {
            @Override
            public void run(Keeper.Progress p) {
                Keeper.run(MainActivity.this, arg, p);
            }
        });
    }

    private void stopWatchdog() {
        runInBackground("> останавливаю watchdog...", new Job() {
            @Override
            public void run(Keeper.Progress p) {
                Keeper.runBoot(MainActivity.this, "--stop", p);
            }
        });
    }

    /** "key=value" из вывода wwan-boot.sh --status. */
    private String value(String text, String key) {
        for (String l : text.split("\n")) {
            String s = l.trim();
            if (s.startsWith(key + "=")) return s.substring(key.length() + 1).trim();
        }
        return "";
    }

    /**
     * Форматирование - деструктивная операция, поэтому в отличие от остальных кнопок
     * ничего не запускает сразу: сначала опрашивает format-sdcard.sh --list (безопасно,
     * ничего не меняет), затем пользователь явно выбирает устройство и подтверждает.
     * Никакого автовыбора "самой вероятной" карты - список показывает vendor/model/размер,
     * решает человек.
     */
    private void addFormatButton() {
        buttonsRow.addView(button("Форматировать SD", new View.OnClickListener() {
            @Override
            public void onClick(View v) {
                if (busy) return;
                setBusy(true);
                append("");
                append("> Форматировать SD: ищу карты...");
                background(new Runnable() {
                    @Override
                    public void run() {
                        final String out = Keeper.runFormat(MainActivity.this, "--list", null);
                        final List<String[]> devices = parseDevices(out);
                        ui.post(new Runnable() {
                            @Override
                            public void run() {
                                if (devices.isEmpty()) {
                                    append("устройства не найдены (или ошибка):");
                                    append(out);
                                    setBusy(false);
                                } else {
                                    showDeviceChooser(devices);
                                }
                            }
                        });
                    }
                });
            }
        }));
    }

    /** Строки вида "sdb|HUAWEI|TF CARD Storage|14.5G|exfat|" из format-sdcard.sh --list. */
    private List<String[]> parseDevices(String out) {
        List<String[]> result = new ArrayList<>();
        for (String line : out.split("\n")) {
            String[] p = line.split("\\|", -1);
            if (p.length >= 6 && p[0].matches("sd[a-z]")) {
                result.add(p);
            }
        }
        return result;
    }

    /**
     * Один диалог: радио-список карт + кнопка "Форматировать" - выбор и запуск разделены,
     * тап по строке списка сам по себе ничего не запускает. После нажатия "Форматировать"
     * идёт ещё один диалог-подтверждение (см. confirmFormat) - это уже финальный шаг.
     */
    private void showDeviceChooser(final List<String[]> devices) {
        final String[] labels = new String[devices.size()];
        for (int i = 0; i < devices.size(); i++) {
            String[] d = devices.get(i);
            String vendor = d[1].trim();
            String model = d[2].trim();
            String size = d[3].trim();
            String fstype = d[4].trim();
            labels[i] = d[0] + " - " + vendor + " " + model + ", " + size +
                    (fstype.isEmpty() ? "" : ", сейчас " + fstype);
        }
        final int[] selected = {0};
        new AlertDialog.Builder(this)
                .setTitle("Какую карту форматировать?")
                .setSingleChoiceItems(labels, 0, new DialogInterface.OnClickListener() {
                    @Override
                    public void onClick(DialogInterface dialog, int which) {
                        selected[0] = which;
                    }
                })
                .setPositiveButton("Форматировать", new DialogInterface.OnClickListener() {
                    @Override
                    public void onClick(DialogInterface dialog, int which) {
                        confirmFormat(devices.get(selected[0]));
                    }
                })
                .setNegativeButton("Отмена", new DialogInterface.OnClickListener() {
                    @Override
                    public void onClick(DialogInterface dialog, int which) {
                        append("отменено.");
                        setBusy(false);
                    }
                })
                .setOnCancelListener(new DialogInterface.OnCancelListener() {
                    @Override
                    public void onCancel(DialogInterface dialog) {
                        append("отменено.");
                        setBusy(false);
                    }
                })
                .show();
    }

    private void confirmFormat(final String[] dev) {
        final String name = dev[0];
        String vendor = dev[1].trim();
        String model = dev[2].trim();
        String size = dev[3].trim();
        new AlertDialog.Builder(this)
                .setTitle("Стереть " + name + "?")
                .setMessage(vendor + " " + model + ", " + size +
                        "\n\nВСЕ данные на этой карте будут уничтожены безвозвратно.")
                .setPositiveButton("Стереть", new DialogInterface.OnClickListener() {
                    @Override
                    public void onClick(DialogInterface dialog, int which) {
                        setBusy(false);
                        runInBackground("> форматирую " + name + "...", new Job() {
                            @Override
                            public void run(Keeper.Progress p) {
                                Keeper.runFormat(MainActivity.this, "--format=" + name, p);
                            }
                        });
                    }
                })
                .setNegativeButton("Отмена", new DialogInterface.OnClickListener() {
                    @Override
                    public void onClick(DialogInterface dialog, int which) {
                        append("отменено.");
                        setBusy(false);
                    }
                })
                .setOnCancelListener(new DialogInterface.OnCancelListener() {
                    @Override
                    public void onCancel(DialogInterface dialog) {
                        append("отменено.");
                        setBusy(false);
                    }
                })
                .show();
    }

    /**
     * Открывает URL системным обработчиком ACTION_VIEW - на этой прошивке уже есть
     * готовый webview-просмотрщик, поднимать второй смысла нет.
     */
    private void addUrlButton(String text, final String url) {
        buttonsRow.addView(button(text, new View.OnClickListener() {
            @Override
            public void onClick(View v) {
                try {
                    startActivity(new Intent(Intent.ACTION_VIEW, Uri.parse(url)));
                } catch (Exception e) {
                    append("не удалось открыть " + url + ": " + e);
                }
            }
        }));
    }

    // ------------------------------------------------------------------ каркас --

    private interface Job {
        void run(Keeper.Progress progress);
    }

    private void runInBackground(final String header, final Job job) {
        if (busy) return;
        setBusy(true);
        append("");
        append(header);
        background(new Runnable() {
            @Override
            public void run() {
                job.run(new Keeper.Progress() {
                    @Override
                    public void onLine(String line) {
                        post(line);
                    }
                });
                ui.post(new Runnable() {
                    @Override
                    public void run() {
                        setBusy(false);
                    }
                });
            }
        });
    }

    private void setBusy(boolean b) {
        busy = b;
        for (int i = 0; i < buttonsRow.getChildCount(); i++) {
            buttonsRow.getChildAt(i).setEnabled(!b);
        }
    }

    private String versionName() {
        try {
            return getPackageManager().getPackageInfo(getPackageName(), 0).versionName;
        } catch (Exception e) {
            return "?";
        }
    }

    private Button button(String text, View.OnClickListener l) {
        Button b = new Button(this);
        b.setText(text);
        b.setOnClickListener(l);
        LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.WRAP_CONTENT, LinearLayout.LayoutParams.WRAP_CONTENT);
        lp.setMargins(0, 0, dp(12), 0);
        b.setLayoutParams(lp);
        return b;
    }

    private int dp(int v) {
        return (int) TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_DIP, v, getResources().getDisplayMetrics());
    }

    private void background(Runnable r) {
        new Thread(r, "wwan-work").start();
    }

    private void post(final String text) {
        ui.post(new Runnable() {
            @Override
            public void run() {
                append(text);
            }
        });
    }

    private void append(String text) {
        log.append(text + "\n");
    }
}

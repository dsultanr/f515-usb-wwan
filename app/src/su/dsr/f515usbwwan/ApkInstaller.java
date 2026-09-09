package su.dsr.f515usbwwan;

import android.app.PendingIntent;
import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;
import android.content.pm.PackageInstaller;
import android.util.Log;

import java.io.File;
import java.io.FileInputStream;
import java.io.InputStream;
import java.io.OutputStream;

/**
 * Установка обновления через штатный PackageInstaller Session API — тем же путём, каким
 * ставят APK обычные файловые менеджеры.
 *
 * Почему не по-старому. Раньше обновление шло через adbd: APK копировался в
 * /data/local/tmp/wwan/ и там его ставил install-update.sh — инжектом чужого
 * engmode-install.js в com.seres.engineeringmode, с запасным pm install. Оба пути мертвы:
 * pm install вендор режет всегда (CarInstallerManagerImpl.canAdbInstall() читает
 * /vendor/etc/data/install_config.json с adbEnabled=false и печатает
 * "Error: adb install be disabled"), а инжектор был не наш — он принадлежит iSpace Toolbox
 * и уехал с его очередным обновлением. Session API идёт по ДРУГОМУ гейту —
 * canInstall(installerPackageName), на уровне Binder, — и adb-запрет его не касается вовсе.
 *
 * Гейт installerPackageName сверяет с whiteApps (engineeringmode / launcher / appmarket);
 * нашего пакета там нет, поэтому установка проходит, только пока активен твик Toolbox
 * «разрешить любые установщики» (Frida-патч CarInstallerManagerImpl в system_server,
 * ставит installEnabled=true). Если твик не включён, PMS ответит STATUS_FAILURE_BLOCKED —
 * это ровно то, о чём говорит текст ошибки ниже, и лечится включением твика, а не кодом.
 */
public final class ApkInstaller {

    private static final String TAG = "WWAN_ApkInstaller";
    private static final String ACTION_RESULT = "su.dsr.f515usbwwan.INSTALL_RESULT";

    /** PendingIntent.FLAG_MUTABLE — API 31, а собираемся мы против API 30. */
    private static final int FLAG_MUTABLE = 0x02000000;

    private static boolean receiverRegistered;
    /** Куда писать ход установки: результат приходит асинхронно, уже после install(). */
    private static volatile Keeper.Progress sink;

    private ApkInstaller() {
    }

    /**
     * Ставит APK из локального файла. Данные уходят в сессию синхронно, а вот результат
     * (и запрос подтверждения) прилетает броадкастом позже — его ловит приёмник ниже.
     *
     * При самообновлении наш процесс будет убит в момент установки, поэтому «Успешная
     * установка» до лога может и не дойти: приложение к тому времени уже перезапускается.
     */
    public static void install(Context context, File apk, Keeper.Progress progress) {
        Context ctx = context.getApplicationContext();
        sink = progress;
        ensureInstallPermission(ctx, progress);
        registerResultReceiver(ctx);

        PackageInstaller installer = ctx.getPackageManager().getPackageInstaller();
        PackageInstaller.Session session = null;
        int sessionId = -1;
        try {
            PackageInstaller.SessionParams params =
                    new PackageInstaller.SessionParams(PackageInstaller.SessionParams.MODE_FULL_INSTALL);
            params.setAppPackageName(ctx.getPackageName());
            sessionId = installer.createSession(params);
            session = installer.openSession(sessionId);

            progress.onLine("> Сессия установки " + sessionId + ", запись APK ("
                    + (apk.length() / 1024) + " KB)...");

            InputStream in = new FileInputStream(apk);
            OutputStream out = session.openWrite("base.apk", 0, apk.length());
            try {
                byte[] buf = new byte[65536];
                int read;
                while ((read = in.read(buf)) != -1) {
                    out.write(buf, 0, read);
                }
                session.fsync(out);
            } finally {
                out.close();
                in.close();
            }

            Intent intent = new Intent(ACTION_RESULT).setPackage(ctx.getPackageName());
            PendingIntent pending = PendingIntent.getBroadcast(ctx, sessionId, intent,
                    PendingIntent.FLAG_UPDATE_CURRENT | FLAG_MUTABLE);
            session.commit(pending.getIntentSender());
            session = null;
            progress.onLine("> Установка передана системе, подтвердите её на экране ГУ.");
        } catch (Exception e) {
            Log.e(TAG, "install failed", e);
            progress.onLine("ERROR: установка не начата: " + e);
            if (session != null) {
                // Незакоммиченная сессия иначе висит до перезагрузки и ест лимит сессий.
                try {
                    session.abandon();
                } catch (Exception ignored) {
                }
            }
        } finally {
            if (session != null) session.close();
        }
    }

    /**
     * REQUEST_INSTALL_PACKAGES объявлен в манифесте, но на Android 11 это ещё и appop,
     * который пользователь подтверждает в Настройках — а на этой прошивке экрана
     * «Установка неизвестных приложений» просто нет. Поэтому, если разрешения нет,
     * выдаём его себе сами через root-adb: cmd appops стоковый, вендор патчил только
     * install-команды PackageManagerShellCommand.
     *
     * Best-effort: если adbd недоступен, установка всё равно пробуется — вдруг appop уже
     * стоит с прошлого раза (он живёт в /data/system/appops.xml и переживает перезагрузку).
     */
    private static void ensureInstallPermission(Context ctx, Keeper.Progress progress) {
        try {
            if (ctx.getPackageManager().canRequestPackageInstalls()) return;
        } catch (Exception e) {
            Log.w(TAG, "canRequestPackageInstalls failed", e);
        }
        progress.onLine("> Нет разрешения на установку, выдаю appops REQUEST_INSTALL_PACKAGES...");
        Keeper.exec(ctx, null, "cmd appops set " + ctx.getPackageName()
                + " REQUEST_INSTALL_PACKAGES allow </dev/null 2>&1; echo appops=$?", progress);
    }

    private static synchronized void registerResultReceiver(final Context ctx) {
        if (receiverRegistered) return;
        ctx.registerReceiver(new BroadcastReceiver() {
            @Override
            public void onReceive(Context c, Intent intent) {
                onInstallResult(ctx, intent);
            }
        }, new IntentFilter(ACTION_RESULT));
        receiverRegistered = true;
    }

    private static void onInstallResult(Context ctx, Intent intent) {
        int status = intent.getIntExtra(PackageInstaller.EXTRA_STATUS,
                PackageInstaller.STATUS_FAILURE);
        String message = intent.getStringExtra(PackageInstaller.EXTRA_STATUS_MESSAGE);

        if (status == PackageInstaller.STATUS_PENDING_USER_ACTION) {
            // Штатный диалог «Установить?» — его показывает ts-package-installer.
            Intent confirm = intent.getParcelableExtra(Intent.EXTRA_INTENT);
            if (confirm == null) {
                say("ERROR: система просит подтверждения, но не дала диалога");
                return;
            }
            confirm.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
            try {
                ctx.startActivity(confirm);
                say("> Подтвердите установку на экране ГУ.");
            } catch (Exception e) {
                Log.e(TAG, "confirm dialog failed", e);
                say("ERROR: не удалось показать диалог установки: " + e);
            }
            return;
        }

        if (status == PackageInstaller.STATUS_SUCCESS) {
            say("OK: обновление установлено.");
            return;
        }

        say("ERROR: установка не прошла (" + statusName(status) + ")"
                + (message == null || message.isEmpty() ? "" : ": " + message));
        if (status == PackageInstaller.STATUS_FAILURE_BLOCKED) {
            say("   Похоже, гейт установщиков Seres снова включён — проверь твик Toolbox"
                    + " «разрешить любые установщики».");
        }
    }

    private static String statusName(int status) {
        switch (status) {
            case PackageInstaller.STATUS_FAILURE_ABORTED:    return "отменено";
            case PackageInstaller.STATUS_FAILURE_BLOCKED:    return "заблокировано политикой";
            case PackageInstaller.STATUS_FAILURE_CONFLICT:   return "конфликт с установленным пакетом";
            case PackageInstaller.STATUS_FAILURE_INCOMPATIBLE: return "несовместимо с устройством";
            case PackageInstaller.STATUS_FAILURE_INVALID:    return "APK повреждён или не подписан";
            case PackageInstaller.STATUS_FAILURE_STORAGE:    return "нет места";
            default:                                         return "код " + status;
        }
    }

    private static void say(String line) {
        Keeper.Progress p = sink;
        Log.i(TAG, line);
        if (p != null) p.onLine(line);
    }
}

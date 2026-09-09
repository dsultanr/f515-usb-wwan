package su.dsr.f515usbwwan;

import android.content.Context;

import java.io.ByteArrayOutputStream;
import java.io.InputStream;

/**
 * Everything that needs root goes through here: connect to the local adbd (already root
 * on this build), deploy the wwan/ files and run one of the scripts. The scripts
 * themselves are idempotent and self-checking (wwan-up.sh checks every stage's
 * precondition, wwan-boot.sh guards against boot loops), so this class stays deliberately
 * thin - it does not duplicate any of that logic, it just makes sure the files are on the
 * device before running them.
 */
public class Keeper {

    static final String DIR = "/data/local/tmp/wwan";
    static final String UP = DIR + "/wwan-up.sh";
    static final String BOOT = DIR + "/wwan-boot.sh";
    static final String FORMAT = DIR + "/format-sdcard.sh";
    static final String ICON = DIR + "/tbox-icon.sh";
    static final String SMS = DIR + "/sms.sh";
    static final String ADB_HOST = "127.0.0.1";
    static final int ADB_PORT = 5555;

    /** 180s: worst case inside wwan-up.sh is modeswitch reconnect (20s) + network
     *  registration (30s) + dial timeout (60s) + margin. */
    private static final int RUN_TIMEOUT_MS = 180000;

    /**
     * Как часто дёргать adbd, пока он не поднялся после перезагрузки.
     *
     * Была лесенка 5→10→…→30 с, и она регулярно проедала полминуты на пустом месте: adbd
     * поднимался, скажем, на 35-й секунде, а следующая попытка приходилась на 45-ю. Попытка
     * стоит одного connect() на localhost, так что секундный опрос ничего не стоит, зато
     * автозапуск начинается ровно тогда, когда становится возможен.
     */
    private static final int ADB_POLL_MS = 1000;

    /** name in assets/, path on device, executable bit */
    private static final Object[][] FILES = {
            {"wwan-up.sh", "wwan-up.sh", Boolean.TRUE},
            {"wwan-boot.sh", "wwan-boot.sh", Boolean.TRUE},
            {"dial.sh", "dial.sh", Boolean.TRUE},
            {"at.sh", "at.sh", Boolean.TRUE},
            {"format-sdcard.sh", "format-sdcard.sh", Boolean.TRUE},
            {"tbox-icon.sh", "tbox-icon.sh", Boolean.TRUE},
            {"sms.sh", "sms.sh", Boolean.TRUE},
            {"tboxwire.jar", "tboxwire.jar", Boolean.FALSE},
            {"huawei-modeswitch", "huawei-modeswitch", Boolean.TRUE},
            {"usbserialmerged2.ko", "usbserialmerged2.ko", Boolean.FALSE},
            {"ppp_async.ko", "ppp_async.ko", Boolean.FALSE},
            // NCM-ветка: Huawei с HiLink-прошивкой (E8278 и родня) отдаёт данные
            // сетевым интерфейсом, а не AT/PPP-портом; этих трёх драйверов в ядре
            // головы нет — см. стадию "NCM-интерфейс Huawei" в wwan-up.sh.
            {"cdc-wdm.ko", "cdc-wdm.ko", Boolean.FALSE},
            {"cdc_ncm.ko", "cdc_ncm.ko", Boolean.FALSE},
            {"huawei_cdc_ncm.ko", "huawei_cdc_ncm.ko", Boolean.FALSE},
            {"f515_rndis.ko", "f515_rndis.ko", Boolean.FALSE},
    };

    private static final Object LOCK = new Object();

    public interface Progress {
        void onLine(String line);
    }

    /** Deploys wwan/ and runs wwan-up.sh with the given arguments (e.g. "--check"). */
    public static String run(Context ctx, String args, Progress progress) {
        return exec(ctx, UP, args, progress);
    }

    /** wwan-boot.sh with the given arguments ("--status", "--reset", "--disable", "--stop"). */
    public static String runBoot(Context ctx, String args, Progress progress) {
        return exec(ctx, BOOT, args, progress);
    }

    /** tbox-icon.sh with the given arguments ("status", "start", "stop", "signal"). */
    public static String runIcon(Context ctx, String args, Progress progress) {
        return exec(ctx, ICON, args, progress);
    }

    /** format-sdcard.sh with the given arguments ("--list" or "--format=sdX"). */
    public static String runFormat(Context ctx, String args, Progress progress) {
        return exec(ctx, FORMAT, args, progress);
    }

    /** sms.sh with the given arguments ("list", "delete <id>", "delete_all"). */
    public static String runSms(Context ctx, String args, Progress progress) {
        return exec(ctx, SMS, args, progress);
    }

    /**
     * Команда запуска wwan-boot.sh, отцепленного от текущей adb-сессии.
     *
     * setsid + закрытое stdio - только половина дела. Вторая половина: shell-сервис adbd
     * сносит всю группу процессов, как только команда напечатала последнюю строку и канал
     * закрылся, и фоновая копия успевает только родиться. 2026-08-12 на стенде это
     * выглядело так: приложение рапортует "started", а в boot.log и boot-stdout.log не
     * появляется ни строки - скрипт не выполнил вообще ничего, и после ребута сеть не
     * поднималась. Поэтому команда не завершается сразу, а ждёт, пока в pidfile окажется
     * ЖИВОЙ pid именно wwan-boot.sh (сам pidfile переживает перезагрузку, поэтому мало
     * проверить, что файл непустой - сверяем cmdline). Ожидание держит канал открытым
     * ровно столько, сколько потомку нужно, чтобы уйти в свою сессию, и заодно превращает
     * "started" из обещания в факт: в ответе виден pid.
     *
     * В boot-stdout.log уходит только stderr, а stdout - в /dev/null. Раньше туда шло всё,
     * и каждая строка сторожа ложилась на флеш дважды: сначала log() пишет её в boot.log,
     * потом та же строка приходит сюда через stdout. Смысл этого файла всегда был в другом -
     * поймать то, что до boot.log не доходит вовсе (ошибки шелла, падение до открытия лога),
     * а это как раз stderr.
     */
    private static String launchCmd(boolean now) {
        String pid = DIR + "/state/watchdog.pid";
        return "mkdir -p " + DIR + "/state; setsid sh " + BOOT + (now ? " --now" : "")
                + " </dev/null >/dev/null 2>>" + DIR + "/state/boot-stdout.log &"
                + " w=; i=0; while [ $i -lt 15 ]; do p=$(cat " + pid + " 2>/dev/null);"
                + " if [ -n \"$p\" ] && grep -qs wwan-boot /proc/$p/cmdline; then w=$p; break; fi;"
                + " sleep 1; i=$((i+1)); done;"
                + " echo \"started, watchdog pid=${w:-НЕ ЗАПУСТИЛСЯ}\"";
    }

    /**
     * Starts wwan-boot.sh detached from this adb session; see {@link #launchCmd} for why the
     * command waits instead of returning the moment the job is backgrounded.
     */
    public static String startAutostart(Context ctx, boolean now, Progress progress) {
        return exec(ctx, null, launchCmd(now), progress);
    }

    /**
     * The autostart path (BootService): same as startAutostart, but waits for adbd to
     * come up first - right after a reboot it usually is not listening yet.
     *
     * Ошибку НЕ глотает, а пробрасывает: вызывающий по ней решает, считать ли заход
     * состоявшимся. Раньше неудача возвращалась обычной строкой, неотличимой от успеха,
     * и второй броадкаст (BOOT_COMPLETED следом за LOCKED_BOOT_COMPLETED) отшивался как
     * лишний — хотя именно он и был запасным шансом.
     */
    public static String bootAutostart(Context ctx, long budgetMs, Progress progress)
            throws Exception {
        synchronized (LOCK) {
            StringBuilder sb = new StringBuilder();
            AdbClient adb = null;
            try {
                adb = connectWaiting(ctx, budgetMs, progress);
                String uid = adb.shell("id -u").trim();
                line(progress, sb, "adb connected, uid=" + uid);
                if (!uid.startsWith("0")) {
                    line(progress, sb, "WARNING: adbd is not root, this will fail");
                }
                adb.shell("mkdir -p " + DIR + "/state");
                // Признак «идут проверки автозапуска» — под него иконка мигает крестиком и
                // полной шкалой. Ставится до раскладки файлов: она сама по себе не мгновенна,
                // а сразу за ней wwan-boot.sh ждёт ещё 45 секунд, пока догрузится система.
                adb.shell("echo 1 > " + DIR + "/state/appboot");
                deployMissing(ctx, adb, progress, sb);
                // Иконку поднимаем здесь, а не внутри wwan-up.sh: та стадия начнётся минуту
                // спустя, а показывать «автозапуск работает» надо уже сейчас. Молча и без
                // права что-либо уронить — к подъёму модема иконка отношения не имеет.
                adb.shell("sh " + ICON + " auto >/dev/null 2>&1");
                // Признак здесь НЕ снимаем: сразу за запуском wwan-boot.sh ждёт 45 секунд,
                // пока догрузится система, и всё это время показывать всё ещё нечего.
                // Снимет его wwan-up.sh, когда действительно начнёт подъём, — там же
                // начинается вторая анимация, так что наложиться они не могут.
                String out = adb.shell(launchCmd(false));
                line(progress, sb, "запуск wwan-boot.sh: " + out.trim());
            } catch (Exception e) {
                line(progress, sb, "автозапуск не состоялся: " + e);
                throw e;
            } finally {
                if (adb != null) adb.close();
            }
            return sb.toString();
        }
    }

    /**
     * Deploys the payload, then runs either a script (script != null, args appended) or a
     * raw shell command (script == null, the command is in args).
     */
    static String exec(Context ctx, String script, String args, Progress progress) {
        synchronized (LOCK) {
            StringBuilder sb = new StringBuilder();
            AdbClient adb = null;
            try {
                adb = connect(ctx, RUN_TIMEOUT_MS);
                String uid = adb.shell("id -u").trim();
                line(progress, sb, "adb connected, uid=" + uid);
                if (!uid.startsWith("0")) {
                    line(progress, sb, "WARNING: adbd is not root, this will fail");
                }

                adb.shell("mkdir -p " + DIR);
                deployMissing(ctx, adb, progress, sb);

                String cmd = script == null ? args : "sh " + script + " " + args + " 2>&1";
                line(progress, sb, "--- " + cmd + " ---");
                String out = adb.shell(cmd);
                for (String l : out.split("\n")) line(progress, sb, l);
            } catch (Exception e) {
                line(progress, sb, "failed: " + e);
            } finally {
                if (adb != null) adb.close();
            }
            return sb.toString();
        }
    }

    static AdbClient connect(Context ctx, int timeoutMs) throws Exception {
        return new AdbClient(ADB_HOST, ADB_PORT, asset(ctx, "adbkey"), asset(ctx, "adbkey.pub"), timeoutMs);
    }

    /**
     * Same, but for the boot path: right after BOOT_COMPLETED adbd may not be listening on
     * 5555 yet (or may not have loaded adb_keys), so a single attempt is not enough.
     * Waits with a growing delay instead of hammering, and gives up rather than looping
     * forever - if adb never shows up, nothing here can work anyway and the user still has
     * the buttons.
     *
     * Отсчёт идёт по elapsedRealtime, а НЕ по currentTimeMillis. Голова стартует с часами
     * 1970 года и подтягивает реальное время через несколько секунд после загрузки —
     * ровно тогда, когда мы тут и крутимся. По стенным часам дедлайн в этот момент
     * уезжает на 56 лет в прошлое, цикл выходит после первой же попытки, и автозапуск
     * молча не состаивается (наблюдалось 2026-08-12: «попытка 1» в 03:00:14 по старым
     * часам, следом сразу «не состоялся» в 13:29:48 по новым).
     */
    static AdbClient connectWaiting(Context ctx, long budgetMs, Progress progress) throws Exception {
        Exception last = null;
        long deadline = android.os.SystemClock.elapsedRealtime() + budgetMs;
        for (int i = 1; ; i++) {
            try {
                AdbClient adb = connect(ctx, RUN_TIMEOUT_MS);
                if (progress != null) progress.onLine("adbd доступен с попытки " + i);
                return adb;
            } catch (Exception e) {
                last = e;
                // Раз в 10 попыток, а не каждый раз: попытки теперь секундные, и полный
                // список забивал бы логи одинаковыми ECONNREFUSED.
                if (progress != null && i % 10 == 1) {
                    progress.onLine("adbd пока недоступен (попытка " + i + "): " + e);
                }
                if (android.os.SystemClock.elapsedRealtime() >= deadline) break;
                Thread.sleep(ADB_POLL_MS);
            }
        }
        throw last != null ? last : new java.io.IOException("adbd недоступен");
    }

    /**
     * Pushes only files that are missing or the wrong size (idempotent: pressing any
     * button again after the first run does not re-transfer ~800 KB every time).
     * Uses base64 chunks over the shell channel rather than the sync protocol, since the
     * shell() helper already exists and is proven to work - large payloads are just split
     * into pieces small enough that no single adb message approaches AdbClient's MAXDATA.
     */
    static void deployMissing(Context ctx, AdbClient adb, Progress progress, StringBuilder sb)
            throws Exception {
        for (Object[] f : FILES) {
            String assetName = (String) f[0];
            String remote = DIR + "/" + f[1];
            boolean exec = (Boolean) f[2];

            byte[] data = asset(ctx, assetName);
            String remoteSize = adb.shell("stat -c%s " + remote + " 2>/dev/null || echo 0").trim();
            if (String.valueOf(data.length).equals(remoteSize)) {
                line(progress, sb, "  " + assetName + ": уже на месте (" + data.length + " Б)");
                continue;
            }

            line(progress, sb, "  " + assetName + ": заливаю (" + data.length + " Б)...");
            pushFile(adb, data, remote);

            String newSize = adb.shell("stat -c%s " + remote + " 2>/dev/null || echo -1").trim();
            if (!String.valueOf(data.length).equals(newSize)) {
                throw new java.io.IOException(assetName + ": после заливки размер " + newSize
                        + ", ожидался " + data.length);
            }
            if (exec) adb.shell("chmod 755 " + remote);
            line(progress, sb, "  " + assetName + ": ok");
        }
    }

    private static void pushFile(AdbClient adb, byte[] data, String remote) throws Exception {
        String b64 = android.util.Base64.encodeToString(data, android.util.Base64.NO_WRAP);
        String tmp = remote + ".b64";
        adb.shell("rm -f " + tmp);
        // ~48000 base64 chars/chunk keeps each adb shell command comfortably under any
        // adbd service-string limit while still needing only ~20 round trips per MB.
        int chunk = 48000;
        for (int i = 0; i < b64.length(); i += chunk) {
            String part = b64.substring(i, Math.min(b64.length(), i + chunk));
            adb.shell("echo '" + part + "' >> " + tmp);
        }
        String out = adb.shell("base64 -d " + tmp + " > " + remote + " && rm -f " + tmp + " && echo ok").trim();
        if (!out.contains("ok")) {
            throw new java.io.IOException("base64 -d не сработал: " + out);
        }
    }

    private static byte[] asset(Context ctx, String name) throws Exception {
        InputStream is = ctx.getAssets().open(name);
        try {
            ByteArrayOutputStream bos = new ByteArrayOutputStream();
            byte[] buf = new byte[16384];
            int n;
            while ((n = is.read(buf)) > 0) bos.write(buf, 0, n);
            return bos.toByteArray();
        } finally {
            is.close();
        }
    }

    private static void line(Progress progress, StringBuilder sb, String text) {
        sb.append(text).append('\n');
        if (progress != null) progress.onLine(text);
    }
}

package su.dsr.f515usbwwan;

import android.content.Context;
import android.content.pm.PackageInfo;
import android.content.pm.PackageManager;
import android.util.Log;

import org.json.JSONArray;
import org.json.JSONObject;

import java.io.BufferedInputStream;
import java.io.BufferedReader;
import java.io.File;
import java.io.FileOutputStream;
import java.io.InputStream;
import java.io.InputStreamReader;
import java.io.OutputStream;
import java.net.HttpURLConnection;
import java.net.URL;

/**
 * Проверка наличия новых релизов на GitHub и фоновая загрузка / тихая установка APK.
 */
public class UpdateManager {

    private static final String TAG = "WWAN_UpdateManager";

    // Основной источник обновлений — РФ-хостинг. GitHub из машины через российских
    // операторов периодически недоступен (api.github.com не отвечает), поэтому проверка
    // и загрузка больше не зависят от него: сначала свой сервер, GitHub — только резерв.
    public static final String PRIMARY_LATEST_URL = "https://tm.dsr.su/f515/latest.json";

    public static final String GITHUB_REPO = "dsultanr/f515-usb-wwan";
    public static final String LATEST_RELEASE_URL = "https://api.github.com/repos/" + GITHUB_REPO + "/releases/latest";

    private static final int CONNECT_TIMEOUT_MS = 10000;
    private static final int READ_TIMEOUT_MS = 15000;

    public static class ReleaseInfo {
        public final String tagName;
        public final String versionName;
        public final String title;
        public final String body;
        public final String downloadUrl;
        public final long sizeBytes;

        public ReleaseInfo(String tagName, String versionName, String title, String body, String downloadUrl, long sizeBytes) {
            this.tagName = tagName;
            this.versionName = versionName;
            this.title = title;
            this.body = body;
            this.downloadUrl = downloadUrl;
            this.sizeBytes = sizeBytes;
        }
    }

    public interface CheckCallback {
        void onResult(boolean hasUpdate, ReleaseInfo release, String currentVersion, String message);
        void onError(String error);
    }

    /**
     * Получение текущей версии установленного приложения.
     */
    public static String getInstalledVersion(Context ctx) {
        try {
            PackageInfo pi = ctx.getPackageManager().getPackageInfo(ctx.getPackageName(), 0);
            return pi.versionName;
        } catch (PackageManager.NameNotFoundException e) {
            return "0.0";
        }
    }

    /**
     * Проверка наличия свежего релиза. Сначала РФ-хостинг (основной источник), затем,
     * если он недоступен, GitHub как резерв — из машины через российских операторов
     * api.github.com периодически не отвечает, поэтому обновления не должны от него зависеть.
     */
    public static void check(final Context ctx, final CheckCallback callback) {
        new Thread(new Runnable() {
            @Override
            public void run() {
                String currentVer = getInstalledVersion(ctx);
                ReleaseInfo release = null;
                String source = null;

                // 1) Основной источник — РФ-хостинг (latest.json).
                try {
                    release = fetchRf(PRIMARY_LATEST_URL);
                    source = "РФ-хостинг";
                } catch (Exception e) {
                    Log.w(TAG, "primary (RF) update source failed: " + e.getMessage());
                }

                // 2) Резерв — GitHub.
                if (release == null) {
                    try {
                        release = fetchGithub(LATEST_RELEASE_URL);
                        source = "GitHub (резерв)";
                    } catch (Exception e) {
                        Log.e(TAG, "github fallback failed", e);
                        callback.onError("Не удалось проверить обновления: РФ-хостинг и GitHub недоступны ("
                                + e.getMessage() + ")");
                        return;
                    }
                }

                boolean isNewer = isVersionNewer(release.versionName, currentVer);
                if (isNewer) {
                    callback.onResult(true, release, currentVer,
                            "Найдена новая версия: " + release.versionName + " (источник: " + source + ")");
                } else {
                    callback.onResult(false, release, currentVer,
                            "У вас актуальная версия (" + currentVer + "), источник: " + source);
                }
            }
        }).start();
    }

    /** Разбор latest.json с РФ-хостинга. Формат наш, простой и плоский. */
    private static ReleaseInfo fetchRf(String urlStr) throws Exception {
        String bodyStr = httpGet(urlStr, "application/json");
        JSONObject json = new JSONObject(bodyStr);
        String tagName = json.optString("tag_name", "");
        String version = json.optString("version",
                tagName.startsWith("v") || tagName.startsWith("V") ? tagName.substring(1) : tagName);
        String title = json.optString("name", tagName);
        String body = json.optString("body", "");
        String apkUrl = json.optString("apk_url", null);
        long apkSize = json.optLong("size", 0);
        if (apkUrl == null || apkUrl.isEmpty()) {
            throw new Exception("в latest.json нет apk_url");
        }
        return new ReleaseInfo(tagName, version, title, body, apkUrl, apkSize);
    }

    /** Разбор ответа GitHub releases/latest (резервный источник). */
    private static ReleaseInfo fetchGithub(String urlStr) throws Exception {
        String bodyStr = httpGet(urlStr, "application/vnd.github.v3+json");
        JSONObject json = new JSONObject(bodyStr);
        String tagName = json.optString("tag_name", "");
        String title = json.optString("name", tagName);
        String body = json.optString("body", "");
        String releaseVer = tagName.startsWith("v") || tagName.startsWith("V") ? tagName.substring(1) : tagName;

        String apkUrl = null;
        long apkSize = 0;
        JSONArray assets = json.optJSONArray("assets");
        if (assets != null) {
            for (int i = 0; i < assets.length(); i++) {
                JSONObject asset = assets.getJSONObject(i);
                String name = asset.optString("name", "");
                if (name.endsWith(".apk")) {
                    apkUrl = asset.optString("browser_download_url", null);
                    apkSize = asset.optLong("size", 0);
                    if (name.equalsIgnoreCase("F515UsbWwanApp.apk")) {
                        break;
                    }
                }
            }
        }
        if (apkUrl == null) {
            throw new Exception("в релизе " + tagName + " нет APK-файла");
        }
        return new ReleaseInfo(tagName, releaseVer, title, body, apkUrl, apkSize);
    }

    /** GET с таймаутами и проверкой HTTP 200. Возвращает тело ответа. */
    private static String httpGet(String urlStr, String accept) throws Exception {
        HttpURLConnection conn = null;
        try {
            URL url = new URL(urlStr);
            conn = (HttpURLConnection) url.openConnection();
            conn.setConnectTimeout(CONNECT_TIMEOUT_MS);
            conn.setReadTimeout(READ_TIMEOUT_MS);
            conn.setRequestProperty("User-Agent", "F515-USB-WWAN-App");
            conn.setRequestProperty("Accept", accept);

            int code = conn.getResponseCode();
            if (code != 200) {
                throw new Exception("HTTP " + code + " от " + url.getHost());
            }
            BufferedReader br = new BufferedReader(new InputStreamReader(conn.getInputStream()));
            StringBuilder sb = new StringBuilder();
            String line;
            while ((line = br.readLine()) != null) {
                sb.append(line).append("\n");
            }
            br.close();
            return sb.toString();
        } finally {
            if (conn != null) conn.disconnect();
        }
    }

    /**
     * Сравнение семантических версий (например "3.7" и "3.8", "3.6.2" и "3.6").
     */
    public static boolean isVersionNewer(String remoteVer, String localVer) {
        if (remoteVer == null || localVer == null) return false;
        String[] rParts = remoteVer.trim().split("[.-]");
        String[] lParts = localVer.trim().split("[.-]");
        int len = Math.max(rParts.length, lParts.length);
        for (int i = 0; i < len; i++) {
            int r = i < rParts.length ? parseVerPart(rParts[i]) : 0;
            int l = i < lParts.length ? parseVerPart(lParts[i]) : 0;
            if (r > l) return true;
            if (r < l) return false;
        }
        return false;
    }

    private static int parseVerPart(String s) {
        try {
            return Integer.parseInt(s.replaceAll("[^0-9]", ""));
        } catch (Exception e) {
            return 0;
        }
    }

    /**
     * Загрузка APK по прямой ссылке (с поддержкой 302-редиректов GitHub -> S3)
     * и установка через PackageInstaller Session API.
     */
    public static void downloadAndInstall(final Context ctx, final ReleaseInfo release, final Keeper.Progress progress) {
        new Thread(new Runnable() {
            @Override
            public void run() {
                File tempFile = null;
                HttpURLConnection conn = null;
                try {
                    progress.onLine("> Скачивание обновления " + release.tagName + "...");
                    URL url = new URL(release.downloadUrl);
                    conn = (HttpURLConnection) url.openConnection();
                    conn.setInstanceFollowRedirects(true);
                    conn.setConnectTimeout(15000);
                    conn.setReadTimeout(30000);
                    conn.setRequestProperty("User-Agent", "F515-USB-WWAN-App");

                    int status = conn.getResponseCode();
                    if (status == HttpURLConnection.HTTP_MOVED_TEMP || status == HttpURLConnection.HTTP_MOVED_PERM || status == 307 || status == 308) {
                        String newUrl = conn.getHeaderField("Location");
                        conn.disconnect();
                        url = new URL(newUrl);
                        conn = (HttpURLConnection) url.openConnection();
                        conn.setConnectTimeout(15000);
                        conn.setReadTimeout(30000);
                        conn.setRequestProperty("User-Agent", "F515-USB-WWAN-App");
                    }

                    long totalBytes = conn.getContentLengthLong();
                    if (totalBytes <= 0) totalBytes = release.sizeBytes;

                    tempFile = new File(ctx.getCacheDir(), "update.apk");
                    InputStream in = new BufferedInputStream(conn.getInputStream());
                    OutputStream out = new FileOutputStream(tempFile);
                    byte[] buf = new byte[8192];
                    long downloaded = 0;
                    int lastPercent = -1;
                    int read;

                    while ((read = in.read(buf)) != -1) {
                        out.write(buf, 0, read);
                        downloaded += read;
                        if (totalBytes > 0) {
                            int pct = (int) ((downloaded * 100) / totalBytes);
                            if (pct != lastPercent && pct % 10 == 0) {
                                lastPercent = pct;
                                progress.onLine(String.format("   загрузка: %d%% (%.1f / %.1f MB)", pct, downloaded / 1048576.0, totalBytes / 1048576.0));
                            }
                        }
                    }
                    out.flush();
                    out.close();
                    in.close();

                    progress.onLine("> Загрузка завершена (" + (downloaded / 1024) + " KB). Подготовка к установке...");

                    // Ставим прямо из своего кэша через PackageInstaller — ни adbd, ни
                    // /data/local/tmp в этом пути больше не участвуют (см. ApkInstaller).
                    ApkInstaller.install(ctx, tempFile, progress);

                } catch (Exception e) {
                    Log.e(TAG, "downloadAndInstall failed", e);
                    progress.onLine("ERROR: ошибка скачивания/установки: " + e.getMessage());
                } finally {
                    if (conn != null) conn.disconnect();
                    if (tempFile != null && tempFile.exists()) tempFile.delete();
                }
            }
        }).start();
    }
}

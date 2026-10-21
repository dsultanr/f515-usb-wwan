package su.dsr.f515.cell_probe;

import android.app.*;
import android.content.*;
import android.os.*;
import android.telephony.*;
import org.json.*;
import java.io.*;
import java.util.List;

/** An ordinary app UID, public Android telephony APIs only; no mock location. */
public final class CellProbeService extends Service {
    final Handler handler = new Handler();
    boolean started;
    String phase;
    void write(String s) {
        try (FileWriter f = new FileWriter(new File(getFilesDir(), phase + ".txt"), true)) {
            f.write(SystemClock.elapsedRealtime() + " " + s + "\n");
        } catch (IOException e) { throw new IllegalStateException(e); }
    }
    void cells(String method, List<CellInfo> cells) {
        write(method + " count=" + (cells == null ? "null" : cells.size()));
        if (cells != null) for (CellInfo cell : cells) {
            write("CELL " + cell + " ageMs=" + (SystemClock.elapsedRealtime() - cell.getTimestampMillis()));
        }
    }
    @Override public int onStartCommand(Intent intent, int flags, int id) {
        if (started) return START_NOT_STICKY;
        phase = intent == null ? null : intent.getStringExtra("phase");
        if (phase == null || !phase.matches("[a-z-]{1,30}")) { stopSelf(); return START_NOT_STICKY; }
        started = true;
        NotificationManager nm = getSystemService(NotificationManager.class);
        nm.createNotificationChannel(new NotificationChannel("probe", "CellInfo test", 2));
        startForeground(1, new Notification.Builder(this, "probe")
                .setSmallIcon(android.R.drawable.stat_notify_sync)
                .setContentTitle("Проверка данных сотового модема").build());
        write("uid=" + android.os.Process.myUid() + " telephonyFeature="
                + getPackageManager().hasSystemFeature("android.hardware.telephony"));
        TelephonyManager tm = getSystemService(TelephonyManager.class);
        try { write("phoneCount=" + tm.getPhoneCount() + " simState=" + tm.getSimState()); }
        catch (Exception e) { write("STATE_ERROR " + e); }
        try { cells("getAllCellInfo", tm.getAllCellInfo()); }
        catch (Exception e) { write("GET_ERROR " + e); }
        try {
            tm.requestCellInfoUpdate(getMainExecutor(), new TelephonyManager.CellInfoCallback() {
                @Override public void onCellInfo(List<CellInfo> list) { cells("requestCellInfoUpdate", list); }
                @Override public void onError(int code, Throwable t) { write("CALLBACK_ERROR code=" + code + " " + t); }
            });
            write("request-sent");
        } catch (Exception e) { write("REQUEST_ERROR " + e); }
        handler.postDelayed(new Runnable() { public void run() { write("DONE"); stopSelf(); } }, 20000);
        return START_NOT_STICKY;
    }
    @Override public IBinder onBind(Intent intent) { return null; }
    @Override public void onDestroy() { handler.removeCallbacksAndMessages(null); super.onDestroy(); }
}

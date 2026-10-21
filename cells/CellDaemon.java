import android.os.SystemClock;
import java.io.*;
import java.nio.channels.*;
import java.util.*;
import org.json.*;

/** Opt-in coordinator: Toolbox -> phone Binder ACK -> client -> observed request. */
public final class CellDaemon {
    static File dir;
    static String library;
    static volatile String sourceStatus = "starting", source = "usb-wwan-none";
    static volatile boolean running = true;
    static final Map<Integer,Long> attempts = new HashMap<>();
    static boolean enabled() { return "on".equals(CellFiles.optional(new File(dir, "state/cells").getPath()))
            && !new File(CellFiles.ROOT + "maintenance").exists(); }
    static int pid(String name) {
        try {
            String text = CellCommands.run(1500, 1024, "pidof", name).trim();
            if (!text.matches("[1-9][0-9]*")) return 0;
            int pid = Integer.parseInt(text);
            String cmd = CellFiles.read("/proc/" + pid + "/cmdline").split("\u0000", 2)[0];
            return name.equals(cmd) ? pid : 0;
        } catch (Exception e) { return 0; }
    }
    static void attach(int pid) throws Exception {
        if (!new File("/proc/" + pid + "/exe").getCanonicalPath().endsWith("app_process64"))
            throw new IOException("process-abi-unsupported");
        long now = SystemClock.elapsedRealtime();
        if (now - attempts.getOrDefault(pid, -30000L) < 30000) return;
        attempts.put(pid, now);
        if (attempts.size() > 32) attempts.keySet().removeIf(p -> !new File("/proc/" + p).exists());
        CellCommands.run(8000, 8192, new File(dir, "cell-native-inject").getPath(),
                Integer.toString(pid), library, "wwan_cells_start", "0");
    }
    static JSONObject entry(JSONArray list, int pid) {
        if (list != null) for (int i = 0; i < list.length(); i++) {
            JSONObject row = list.optJSONObject(i);
            if (row != null && row.optInt("pid") == pid) return row;
        }
        return null;
    }
    static boolean fresh(JSONObject row, long maxAge) {
        long age = row == null ? -1 : SystemClock.elapsedRealtime() - row.optLong("at", -1);
        return age >= 0 && age < maxAge;
    }
    static void collect() {
        while (running && enabled()) {
            CellCollector.Sample s = CellCollector.scan(dir);
            if (!running || !enabled()) break;
            sourceStatus = s.status; source = s.source;
            try {
                // Busy is not a new measurement. Keep the old sample only until its ORIGINAL TTL.
                if (!s.status.equals("at-busy") && !s.status.equals("wwan-busy"))
                    CellCollector.publish(s, CellFiles.ROOT + "private/cell.json");
            } catch (Exception e) { sourceStatus = "snapshot-failed"; }
            long wait = s.status.equals("at-busy") || s.status.equals("wwan-busy") ? 3000
                    : Math.max(2000, 30000 - (SystemClock.elapsedRealtime() - s.elapsed));
            try { Thread.sleep(wait); } catch (InterruptedException e) { break; }
        }
    }
    static void status(String phase, JSONObject bridge) throws Exception {
        JSONObject out = new JSONObject().put("phase", phase).put("pid", android.os.Process.myPid())
                .put("source", source).put("sourceStatus", sourceStatus)
                .put("elapsedRealtimeMs", SystemClock.elapsedRealtime()).put("bootId", CellFiles.boot());
        if (bridge != null) out.put("bridge", bridge);
        CellFiles.write(CellFiles.ROOT + "status.json", out.toString() + "\n", 0, 0600);
    }
    public static void main(String[] args) throws Exception {
        if (args.length != 2 || android.os.Process.myUid() != 0) throw new SecurityException("root: WWAN_DIR LIBRARY");
        dir = new File(args[0]).getCanonicalFile(); library = new File(args[1]).getCanonicalPath();
        try (RandomAccessFile file = new RandomAccessFile(CellFiles.ROOT + "daemon.lock", "rw");
             FileChannel channel = file.getChannel(); FileLock lock = channel.tryLock()) {
            if (lock == null || !enabled()) return;
            CellFiles.write(CellFiles.ROOT + "pid", Integer.toString(android.os.Process.myPid()), 0, 0600);
            Thread collector = new Thread(CellDaemon::collect, "wwan-cell-source"); collector.setDaemon(true); collector.start();
            Runtime.getRuntime().addShutdownHook(new Thread(() -> {
                running = false; new File(CellFiles.ROOT + "lease").delete();
            }));
            try {
                while (enabled()) {
                    JSONObject state = null; String phase;
                    try {
                    CellToolboxReadiness.Result toolbox = CellToolboxReadiness.check();
                    if (!toolbox.ready) {
                        new File(CellFiles.ROOT + "lease").delete(); phase = toolbox.detail;
                    } else {
                        CellFiles.write(CellFiles.ROOT + "lease", CellFiles.boot() + " " + SystemClock.elapsedRealtime() + " " + CellBuild.ID, 0, 0644);
                        int phone = pid("com.android.phone"), navi = pid(CellRuntimeBridge.NAVI);
                        try { state = CellProtocol.call(0, "", "", 0); } catch (Exception ignored) { }
                        if (phone == 0) phase = "waiting-phone";
                        else if (state == null || state.optInt("phonePid") != phone) {
                            phase = "waiting-phone-ack"; attach(phone);
                        } else if (navi == 0) phase = "waiting-navigator";
                        else {
                            JSONObject client = entry(state.optJSONArray("clients"), navi);
                            if (!fresh(client, 5000) || "preparing".equals(client.optString("phase"))) {
                                phase = "waiting-client-ack"; attach(navi);
                            } else if (fresh(entry(state.optJSONArray("requests"), navi), 180000)) phase = "subscribed";
                            else phase = "waiting-navigator-request";
                        }
                    }
                    } catch (Exception e) { phase = "retry-" + CellCollector.status(e); }
                    status(phase, state);
                    Thread.sleep(1000);
                }
            } finally {
                running = false; new File(CellFiles.ROOT + "lease").delete(); collector.interrupt();
                // Clear the sample even if a scan is in flight. Receiver also checks lease at request time.
                CellCollector.Sample empty = new CellCollector.Sample(); empty.status = "disabled";
                CellCollector.publish(empty, CellFiles.ROOT + "private/cell.json"); status("disabled", null);
            }
        }
    }
}

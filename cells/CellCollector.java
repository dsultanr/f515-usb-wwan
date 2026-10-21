import android.os.SystemClock;
import android.util.AtomicFile;
import java.io.*;
import java.nio.charset.StandardCharsets;

/** Explicit, bounded prototype. Run only while other AT users are quiescent. No boot hook. */
public final class CellCollector {
    static String read(String path) throws IOException {
        try (BufferedReader r = new BufferedReader(new FileReader(path))) { return r.readLine(); }
    }

    public static void main(String[] args) throws Exception {
        if (args.length != 3) throw new IllegalArgumentException("WWAN_DIR TTY OUTPUT_JSON");
        if (android.os.Process.myUid() != 0) throw new SecurityException("root required");
        File dir = new File(args[0]).getCanonicalFile();
        if (!args[1].matches("/dev/ttyUSB[0-9]+")) throw new IllegalArgumentException("control-tty");
        if (!args[1].equals(read(new File(dir, "state/at-tty").getPath())))
            throw new IllegalStateException("not-selected-control-port");
        String busy = read(new File(dir, "state/busy").getPath());
        if (busy != null && !busy.equals("0 -")) throw new IllegalStateException("wwan-busy");
        String iconPid = read(new File(dir, "state/tbox.pid").getPath());
        if (iconPid != null && iconPid.matches("[1-9][0-9]*")
                && new File("/proc/" + iconPid).exists())
            throw new IllegalStateException("quiesce-at-poller-first");
        // This command must never guess the PPP data port, stop processes, or change AT modes.
        String boot = read("/proc/sys/kernel/random/boot_id");
        long measured = SystemClock.elapsedRealtime(), wall = System.currentTimeMillis();
        CellObservation cell = null;
        String status = "ready";
        StringBuilder transcript = new StringBuilder();
        String[] cmd = new String[3 + HuaweiCellParser.COMMANDS.length];
        cmd[0] = "sh"; cmd[1] = new File(dir, "at.sh").getPath(); cmd[2] = args[1];
        System.arraycopy(HuaweiCellParser.COMMANDS, 0, cmd, 3, HuaweiCellParser.COMMANDS.length);
        Process process = null;
        try {
            if (!new File(args[1]).exists()) throw new IllegalArgumentException("modem-missing");
            process = new ProcessBuilder(cmd).redirectErrorStream(true).start();
            try (BufferedReader r = new BufferedReader(new InputStreamReader(process.getInputStream(),
                    StandardCharsets.UTF_8))) {
                String line;
                while ((line = r.readLine()) != null) {
                    transcript.append(line).append('\n');
                    if (transcript.length() > 65536) throw new IllegalArgumentException("response-too-large");
                }
            }
            if (process.waitFor() != 0) throw new IllegalArgumentException("transport-failed");
            cell = HuaweiCellParser.parse(transcript.toString());
            if (!CellSnapshot.usable(boot, read("/proc/sys/kernel/random/boot_id"), measured,
                    SystemClock.elapsedRealtime())) throw new IllegalArgumentException("scan-expired");
            if (!new File(args[1]).exists()) throw new IllegalArgumentException("modem-missing");
        } catch (IllegalArgumentException e) {
            status = e.getMessage().matches("[a-z-]+") ? e.getMessage() : "invalid-sample";
            cell = null;
        } finally {
            if (process != null) process.destroy();
        }
        AtomicFile output = new AtomicFile(new File(args[2]));
        FileOutputStream stream = output.startWrite();
        try {
            android.system.Os.fchown(stream.getFD(), 0, 1001); // radio UID/GID on Android
            android.system.Os.fchmod(stream.getFD(), 0640);
            stream.write(CellSnapshot.json(cell, boot, measured, wall, status)
                    .getBytes(StandardCharsets.UTF_8));
            output.finishWrite(stream);
        } catch (Exception e) { output.failWrite(stream); throw e; }
        // Raw cell identities remain in the requested local snapshot, not regular logs.
        System.out.println("status=" + status + " cells=" + (cell == null ? 0 : 1)
                + " ageMs=" + (SystemClock.elapsedRealtime() - measured));
        if (cell == null) System.exit(2);
    }
}

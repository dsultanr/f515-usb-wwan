import android.os.SystemClock;
import android.util.AtomicFile;
import java.io.*;
import java.nio.charset.StandardCharsets;

final class CellFiles {
    static final String ROOT = "/dev/wwan-cells/";
    static String read(String path) throws IOException {
        try (InputStream in = new FileInputStream(path); ByteArrayOutputStream out = new ByteArrayOutputStream()) {
            byte[] buf = new byte[2048]; int n;
            while ((n = in.read(buf)) != -1) {
                if (out.size() + n > 65536) throw new IOException("file-too-large");
                out.write(buf, 0, n);
            }
            return new String(out.toByteArray(), StandardCharsets.UTF_8).trim();
        }
    }
    static String optional(String path) { try { return read(path); } catch (Exception e) { return ""; } }
    static String boot() throws IOException { return read("/proc/sys/kernel/random/boot_id"); }
    static void write(String path, String text, int group, int mode) throws Exception {
        AtomicFile out = new AtomicFile(new File(path)); FileOutputStream stream = out.startWrite();
        try {
            android.system.Os.fchown(stream.getFD(), 0, group);
            android.system.Os.fchmod(stream.getFD(), mode);
            stream.write(text.getBytes(StandardCharsets.UTF_8));
            out.finishWrite(stream);
        } catch (Exception e) { out.failWrite(stream); throw e; }
    }
    static boolean revoked() {
        if (new File(ROOT + "maintenance").exists() || new File(ROOT + "disabled").exists()) return true;
        String[] s = optional(ROOT + "lease").split(" ");
        return s.length == 3 && !CellBuild.ID.equals(s[2]);
    }
    static boolean leased() {
        try {
            String[] s = read(ROOT + "lease").split(" ");
            long age = SystemClock.elapsedRealtime() - Long.parseLong(s[1]);
            return s.length == 3 && CellBuild.ID.equals(s[2]) && boot().equals(s[0]) && age >= 0 && age < 15000;
        } catch (Exception e) { return false; }
    }
}

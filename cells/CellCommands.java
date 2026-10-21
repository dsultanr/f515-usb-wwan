import java.io.*;
import java.nio.charset.StandardCharsets;
import java.util.*;
import java.util.concurrent.*;

/** Bounded subprocess output and lifetime. Arguments never pass through shell interpolation. */
final class CellCommands {
    static String run(long timeoutMs, int limit, String... args) throws Exception {
        Process p = new ProcessBuilder(args).redirectErrorStream(true).start();
        ScheduledExecutorService timer = Executors.newSingleThreadScheduledExecutor();
        ScheduledFuture<?> deadline = timer.schedule(() -> p.destroyForcibly(), timeoutMs, TimeUnit.MILLISECONDS);
        try (InputStream in = p.getInputStream(); ByteArrayOutputStream out = new ByteArrayOutputStream()) {
            byte[] buf = new byte[2048]; int n;
            while ((n = in.read(buf)) != -1) {
                if (out.size() + n > limit) throw new IOException("response-too-large");
                out.write(buf, 0, n);
            }
            String text = new String(out.toByteArray(), StandardCharsets.UTF_8);
            int rc = p.waitFor();
            if (rc == 75 && text.contains("WWAN_AT_BUSY")) throw new IOException("at-busy");
            if (rc != 0) throw new IOException("transport-failed");
            return text;
        } finally { deadline.cancel(false); timer.shutdownNow(); p.destroyForcibly(); }
    }
}

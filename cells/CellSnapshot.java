/** Expiry uses Android elapsedRealtime (includes suspend), never adjustable wall time. */
public final class CellSnapshot {
    public static final long TTL_MS = 60000;
    public static boolean usable(String sampleBoot, String currentBoot, long measuredMs, long nowMs) {
        return sampleBoot != null && sampleBoot.equals(currentBoot) && measuredMs >= 0
                && nowMs >= measuredMs && nowMs - measuredMs < TTL_MS;
    }

    public static String json(CellObservation cell, String boot, long elapsed, long wall,
                              String status) {
        return json(cell, boot, elapsed, wall, status, "usb-wwan-huawei-at");
    }
    public static String json(CellObservation cell, String boot, long elapsed, long wall,
                              String status, String source) {
        if (boot == null || !boot.matches("[a-fA-F0-9-]{36}"))
            throw new IllegalArgumentException("boot-id");
        if (!status.matches("[a-z-]+")) throw new IllegalArgumentException("status");
        if (!source.matches("usb-wwan-[a-z-]+")) throw new IllegalArgumentException("source");
        return "{\"schema\":1,\"source\":\"" + source + "\",\"bootId\":\"" + boot
                + "\",\"elapsedRealtimeMs\":" + elapsed + ",\"timestampMs\":" + wall
                + ",\"maxAgeMs\":" + TTL_MS + ",\"status\":\"" + status
                + "\",\"cells\":[" + (cell == null ? "" : cell.json()) + "]}\n";
    }
}

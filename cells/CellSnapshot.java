/** Expiry uses Android elapsedRealtime (includes suspend), never adjustable wall time. */
public final class CellSnapshot {
    public static final long TTL_MS = 60000;
    public static boolean usable(String sampleBoot, String currentBoot, long measuredMs, long nowMs) {
        return sampleBoot != null && sampleBoot.equals(currentBoot) && measuredMs >= 0
                && nowMs >= measuredMs && nowMs - measuredMs < TTL_MS;
    }

    public static String json(CellObservation cell, String boot, long elapsed, long wall,
                              String status) {
        if (boot == null || !boot.matches("[a-fA-F0-9-]{36}"))
            throw new IllegalArgumentException("boot-id");
        if (!status.matches("[a-z-]+")) throw new IllegalArgumentException("status");
        return "{\"schema\":1,\"source\":\"usb-wwan-huawei-at\",\"bootId\":\"" + boot
                + "\",\"elapsedRealtimeMs\":" + elapsed + ",\"timestampMs\":" + wall
                + ",\"maxAgeMs\":" + TTL_MS + ",\"status\":\"" + status
                + "\",\"cells\":[" + (cell == null ? "" : cell.json()) + "]}\n";
    }
}

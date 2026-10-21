import android.os.SystemClock;
import java.io.*;
import java.net.*;
import java.util.*;

/** A bounded read-only scan. AT uses the same device lock as icon/SMS/bring-up. */
public final class CellCollector {
    static final class Sample {
        CellObservation cell;
        String source = "usb-wwan-none", status = "no-source";
        final long elapsed = SystemClock.elapsedRealtime(), wall = System.currentTimeMillis();
    }
    static String status(Exception e) {
        String s = e.getMessage();
        return s != null && s.matches("[a-z-]{1,60}") ? s : "source-failed";
    }
    static boolean usbInterface(String iface) throws IOException {
        if (!iface.matches("(?:wwan|usb|eth)[0-9]+")) return false;
        File dev = new File("/sys/class/net/" + iface + "/device");
        if (!dev.exists() || !dev.getCanonicalPath().contains("/usb")) return false;
        String driver = new File(dev, "driver").getCanonicalFile().getName();
        return driver.matches("huawei_cdc_ncm|cdc_ncm|cdc_ether|rndis_host|f515_rndis");
    }
    static String gateway(String iface) throws Exception {
        Set<String> gateways = new HashSet<>();
        String routes = CellCommands.run(2000, 32768, "ip", "-4", "route", "show", "table", "all", "dev", iface);
        for (String line : routes.split("\n")) {
            String[] words = line.trim().split(" +");
            if (words.length > 2 && words[0].equals("default") && words[1].equals("via")) gateways.add(words[2]);
        }
        if (gateways.size() != 1) throw new IOException("http-gateway-unavailable");
        String gw = gateways.iterator().next();
        if (!HttpCellSource.privateV4(gw)) throw new IOException("http-gateway-unavailable");
        // Require a directly attached subnet. A default route alone is insufficient.
        NetworkInterface ni = NetworkInterface.getByName(iface);
        if (ni != null) for (InterfaceAddress a : ni.getInterfaceAddresses()) {
            byte[] local = a.getAddress().getAddress(), remote = InetAddress.getByName(gw).getAddress();
            int bits = a.getNetworkPrefixLength();
            if (local.length != 4 || bits < 8 || bits > 30) continue;
            boolean same = true;
            for (int bit = 0; bit < bits; bit++)
                if (((local[bit/8] ^ remote[bit/8]) & (1 << (7-bit%8))) != 0) same = false;
            if (same && !Arrays.equals(local, remote)) return gw;
        }
        throw new IOException("http-gateway-offlink");
    }
    static Sample scan(File dir) {
        Sample s = new Sample();
        try {
            String busy = CellFiles.optional(new File(dir, "state/busy").getPath());
            if (!busy.isEmpty() && !busy.equals("0 -")) throw new IOException("wwan-busy");
            String iface = CellFiles.optional(new File(dir, "state/wan-iface").getPath());
            if (usbInterface(iface)) {
                String gw = gateway(iface);
                HttpCellSource http = new HttpCellSource(HttpCellSource.bound(iface, gw));
                try { s.cell = http.scan(); } finally { s.source = http.source; }
                if (!usbInterface(iface) || !gw.equals(gateway(iface))) throw new IOException("modem-changed");
            } else {
                s.source = "usb-wwan-huawei-at";
                String tty = CellFiles.optional(new File(dir, "state/at-tty").getPath());
                if (!tty.matches("/dev/ttyUSB[0-9]+") || !new File(tty).exists()) throw new IOException("control-port-unavailable");
                // Never guess a port, even if another ttyUSB responds to AT.
                String[] command = new String[5 + HuaweiCellParser.COMMANDS.length];
                command[0] = "env"; command[1] = "AT_LOCK_WAIT=0"; command[2] = "sh";
                command[3] = new File(dir, "at.sh").getPath(); command[4] = tty;
                System.arraycopy(HuaweiCellParser.COMMANDS, 0, command, 5, HuaweiCellParser.COMMANDS.length);
                s.cell = HuaweiCellParser.parse(CellCommands.run(28000, 65536, command));
                if (!tty.equals(CellFiles.read(new File(dir, "state/at-tty").getPath())) || !new File(tty).exists())
                    throw new IOException("modem-changed");
                busy = CellFiles.optional(new File(dir, "state/busy").getPath());
                if (!busy.isEmpty() && !busy.equals("0 -")) throw new IOException("wwan-busy");
            }
            if (SystemClock.elapsedRealtime() - s.elapsed >= CellSnapshot.TTL_MS) throw new IOException("scan-expired");
            // Android delivery currently supports LTE only. Do not report other RATs as usable.
            if (!s.cell.radio.equals("lte")) throw new IOException("radio-unsupported");
            s.status = "ready";
        } catch (Exception e) { s.cell = null; s.status = status(e); }
        return s;
    }
    static void publish(Sample s, String output) throws Exception {
        CellFiles.write(output, CellSnapshot.json(s.cell, CellFiles.boot(), s.elapsed, s.wall, s.status, s.source), 1001, 0640);
    }
    public static void main(String[] args) throws Exception {
        if (args.length != 2 || android.os.Process.myUid() != 0) throw new IllegalArgumentException("root: WWAN_DIR OUTPUT_JSON");
        Sample s = scan(new File(args[0]).getCanonicalFile()); publish(s, args[1]);
        System.out.println("status=" + s.status + " source=" + s.source + " cells=" + (s.cell == null ? 0 : 1));
        if (s.cell == null) System.exit(2);
    }
}

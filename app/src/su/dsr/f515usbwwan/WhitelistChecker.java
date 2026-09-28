package su.dsr.f515usbwwan;

import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.InetAddress;
import java.net.InetSocketAddress;
import java.net.Socket;
import java.net.UnknownHostException;
import java.nio.charset.Charset;
import java.util.zip.CRC32;

/**
 * Проверка доступности серверов телеметрии с головы. По строке на сервер: адрес и OK/FAIL.
 *
 * OK = дошли по протоколу: Vega-сервер здоровается кадром сам (read-first), Wialon отвечает
 * на логин, для своих хостов достаточно TCP-коннекта. Иначе FAIL.
 */
public final class WhitelistChecker {

    private static final Charset ASCII = Charset.forName("US-ASCII");

    private static final int CONNECT_TIMEOUT_MS = 6000;
    private static final int PROBE_TIMEOUT_MS = 4000;
    private static final int TIMED_OUT = -2;

    // Фиктивная авторизация — гарантированный отказ, живой трекер не задевает.
    private static final String FAKE_IMEI = "000000000000000";
    private static final String FAKE_PIN  = "0000";

    private static final int PROTO_WIALON = 1; // текстовый Wialon IPS
    private static final int PROTO_VEGA   = 2; // бинарный Vega
    private static final int PROTO_PLAIN  = 3; // просто TCP-коннект

    private static final int CMD_AUTORIZATION = 0x05;

    public static final class Server {
        public final String host;
        public final int port;
        public final int proto;

        Server(String host, int port, int proto) {
            this.host = host;
            this.port = port;
            this.proto = proto;
        }
    }

    /** Серверы телеметрии Evolute (vega_mitm.py) + свои хосты. */
    public static final Server[] SERVERS = new Server[] {
            new Server("caronline.evassist.ru", 21123, PROTO_WIALON),
            new Server("vega.evassist.ru",      21124, PROTO_VEGA),
            new Server("caronline.evassist.ru", 21124, PROTO_VEGA),
            new Server("telemetry.evassist.ru", 21124, PROTO_VEGA),
            new Server("tm.dsr.su",               443, PROTO_PLAIN),
            new Server("tc.dsr.su",               443, PROTO_PLAIN),
    };

    private WhitelistChecker() {}

    /** Проверяет все серверы, печатая по строке «адрес  OK/FAIL». Возвращает число OK. */
    public static int checkAll(Keeper.Progress progress) {
        int ok = 0;
        for (Server s : SERVERS) {
            boolean good = checkOne(s);
            progress.onLine(s.host + ":" + s.port + "  " + (good ? "OK" : "FAIL"));
            if (good) ok++;
        }
        return ok;
    }

    /** true = сервер доступен по протоколу (или по TCP для своих хостов). */
    private static boolean checkOne(Server s) {
        InetAddress addr;
        try {
            addr = InetAddress.getByName(s.host);
        } catch (UnknownHostException e) {
            return false;
        }

        Socket sock = new Socket();
        try {
            sock.connect(new InetSocketAddress(addr, s.port), CONNECT_TIMEOUT_MS);
        } catch (IOException e) {
            close(sock);
            return false;
        }

        try {
            if (s.proto == PROTO_PLAIN) {
                return true; // коннект есть — этого достаточно
            }
            sock.setSoTimeout(PROBE_TIMEOUT_MS);
            OutputStream out = sock.getOutputStream();
            InputStream in = sock.getInputStream();

            if (s.proto == PROTO_WIALON) {
                out.write(("#L#" + FAKE_IMEI + ";" + FAKE_PIN + "\r\n").getBytes(ASCII));
                out.flush();
                byte[] buf = new byte[128];
                int n = readWithTimeout(in, buf);
                return n > 0 && new String(buf, 0, n, ASCII).contains("#AL#");
            } else {
                // Vega: настоящий сервер здоровается кадром первым — читаем, ничего не шлём;
                // если молчит — расшевеливаем кадром авторизации и читаем ещё раз.
                byte[] buf = new byte[64];
                int n = readWithTimeout(in, buf);
                if (n == TIMED_OUT) {
                    try {
                        out.write(vegaAuthFrame(FAKE_PIN));
                        out.flush();
                        n = readWithTimeout(in, buf);
                    } catch (IOException ignore) {
                        return false;
                    }
                }
                return n > 0; // пришёл кадр/данные от настоящего сервера
            }
        } catch (IOException e) {
            return false;
        } finally {
            close(sock);
        }
    }

    private static int readWithTimeout(InputStream in, byte[] buf) throws IOException {
        try {
            return in.read(buf);
        } catch (java.net.SocketTimeoutException e) {
            return TIMED_OUT;
        }
    }

    /** Кадр авторизации Vega с неверным PIN (vega_bridge.py: build_auth_frame + build_frame). */
    private static byte[] vegaAuthFrame(String pin) {
        byte[] pinB = pin.getBytes(ASCII);
        int padLen = pinB.length <= 4 ? 5 : 17;
        byte[] payload = new byte[padLen];
        System.arraycopy(pinB, 0, payload, 0, Math.min(pinB.length, padLen));

        byte[] body = new byte[3 + payload.length];
        int flen = payload.length;
        body[0] = (byte) (flen & 0xFF);
        body[1] = (byte) ((flen >> 8) & 0xFF);
        body[2] = (byte) CMD_AUTORIZATION;
        System.arraycopy(payload, 0, body, 3, payload.length);

        CRC32 crc = new CRC32();
        crc.update(body);
        long c = crc.getValue();

        byte[] frame = new byte[body.length + 4];
        System.arraycopy(body, 0, frame, 0, body.length);
        frame[body.length]     = (byte) (c & 0xFF);
        frame[body.length + 1] = (byte) ((c >> 8) & 0xFF);
        frame[body.length + 2] = (byte) ((c >> 16) & 0xFF);
        frame[body.length + 3] = (byte) ((c >> 24) & 0xFF);
        return frame;
    }

    private static void close(Socket s) {
        try { s.close(); } catch (IOException ignore) {}
    }
}

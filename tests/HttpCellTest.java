import java.util.*;
public final class HttpCellTest {
    static int checks;
    interface Work { void run() throws Exception; }
    static void check(boolean ok, String why) { checks++; if (!ok) throw new AssertionError(why); }
    static void rejects(Work work, String why) throws Exception {
        try { work.run(); throw new AssertionError("accepted " + why); }
        catch (IllegalArgumentException | java.io.IOException expected) { checks++; }
    }
    static String plmn = "<response><Numeric>25002</Numeric></response>";
    static String status = "<response><CurrentNetworkType>19</CurrentNetworkType></response>";
    static String signal = "<response><cell_id>1193046</cell_id><tac>100</tac><rsrp>-104dBm</rsrp></response>";
    static String zte = "{\"cell_id\":\"123456\",\"lac_code\":\"100\",\"rmcc\":\"250\",\"rmnc\":\"02\",\"network_type\":\"LTE\",\"lte_rsrp\":\"-104\"}";
    public static void main(String[] args) throws Exception {
        CellObservation h = HttpCellParser.huawei(plmn, status, signal), z = HttpCellParser.zte(zte);
        check(h.cellId == 1193046 && h.area == 100 && h.dbm == -104, "Huawei decimal identity");
        check(z.cellId == 0x123456 && z.area == 0x100, "ZTE digit-only HEX");
        check(z.mnc.equals("02"), "MNC leading zero");
        check(HttpCellParser.zte(zte.replace("\"02\"", "\"002\"")).mnc.equals("002"), "MNC length");
        check(HttpCellParser.zte(zte.replace("-104", "")).dbm == null, "unknown signal");
        check(HttpCellParser.stable(h, h) == h, "stable scan");
        rejects(() -> HttpCellParser.stable(h,z), "handover");
        rejects(() -> HttpCellParser.zte(zte.replace("123456", "ffffffff")), "reserved/overflow cell");
        rejects(() -> HttpCellParser.zte(zte.replace("\"100\"", "\"ffff\"")), "unknown TAC");
        rejects(() -> HttpCellParser.zte(zte.replace("LTE", "NO SERVICE")), "not registered");
        rejects(() -> HttpCellParser.zte(zte.replace("LTE", "NR5G")), "unknown RAT with old RSRP");
        rejects(() -> HttpCellParser.zte(zte.replace("\"02\"", "\"2\"")), "ambiguous MNC length");
        rejects(() -> HttpCellParser.zte(zte.replace("-104", "-200")), "signal range");
        rejects(() -> HttpCellParser.zte(zte.replace("}", ",\"cell_id\":\"abcdef\"}")), "duplicate JSON identity");
        rejects(() -> HttpCellParser.zte(zte + "junk"), "JSON trailing junk");
        rejects(() -> HttpCellParser.huawei(plmn, status.replace("19", "21"), signal), "unknown/CDMA code not LTE");
        rejects(() -> HttpCellParser.huawei(plmn, status.replace("19", "0"), signal), "Huawei no network");
        rejects(() -> HttpCellParser.huawei(plmn, status, signal.replace("1193046", "0x123456")), "Huawei base ambiguous");
        rejects(() -> HttpCellParser.xml("<!DOCTYPE r SYSTEM 'file:///etc/passwd'><response/>"), "XML external entity");
        rejects(() -> HttpCellParser.xml("<response><Numeric>25002</Numeric><Numeric>25001</Numeric></response>"), "duplicate XML");
        rejects(() -> HttpCellParser.xml("<error><code>100003</code></error>"), "authentication required");
        rejects(() -> HttpCellParser.xml("<response><a><b>1</b></a></response>"), "nested fields");
        check(HttpCellSource.privateV4("192.168.8.1") && HttpCellSource.privateV4("172.16.0.1"), "private targets");
        check(!HttpCellSource.privateV4("8.8.8.8") && !HttpCellSource.privateV4("127.0.0.1")
                && !HttpCellSource.privateV4("192.168.008.1"), "non-modem targets rejected");
        rejects(() -> HttpCellSource.bound("wlan0", "192.168.8.1"), "WiFi forbidden");
        List<String> paths = new ArrayList<>();
        HttpCellSource src = new HttpCellSource((path, headers) -> {
            paths.add(path);
            if (path.endsWith("SesTokInfo")) return "<response><SesInfo>SessionID=test</SesInfo><TokInfo>test</TokInfo></response>";
            check("SessionID=test".equals(headers.get("Cookie")), "session passed");
            if (path.endsWith("current-plmn")) return plmn;
            if (path.endsWith("status")) return status;
            if (path.endsWith("device/signal")) return "<error><code>100002</code></error>";
            return signal;
        });
        check(src.scan().sameCell(h), "fallback Huawei endpoint, stable bracket");
        check(paths.get(paths.size()-1).endsWith("current-plmn"), "PLMN after scan");
        HttpCellSource unsupported = new HttpCellSource((p, headers) -> p.endsWith("current-plmn") ? plmn
                : p.endsWith("status") ? status : "<error><code>100002</code></error>");
        rejects(() -> unsupported.scan(), "Huawei PLMN without cell must not fabricate");
        HttpCellSource zsource = new HttpCellSource((p, headers) -> p.contains("goform") ? zte : "<html>not found</html>");
        check(zsource.scan().sameCell(z), "HTTP-only ZTE fallback");
        check(HttpCellSource.decodeResponse("ok\nWWAN_HTTP_STATUS=200").equals("ok"), "HTTP success framing");
        rejects(() -> HttpCellSource.decodeResponse("login\nWWAN_HTTP_STATUS=401"), "HTTP authentication");
        rejects(() -> HttpCellSource.decodeResponse("redirect\nWWAN_HTTP_STATUS=302"), "no redirects");
        rejects(() -> HttpCellSource.decodeResponse("missing\nWWAN_HTTP_STATUS=404"), "HTTP unsupported endpoint");
        HttpCellSource z404 = new HttpCellSource((p, headers) -> {
            if (p.contains("goform")) return zte;
            throw new java.io.IOException("http-unsupported");
        });
        check(z404.scan().sameCell(z), "ZTE after Huawei HTTP 404");
        rejects(() -> HttpCellSource.bound("usb9999", "192.168.8.1").get("/", Collections.emptyMap()), "no fallback to default interface");
        System.out.println("HTTP cells: " + checks + " checks passed");
    }
}

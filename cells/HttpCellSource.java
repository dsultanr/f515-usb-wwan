import java.util.*;

/** Interface-bound HTTP only; no default network, redirects, credentials or write requests. */
final class HttpCellSource {
    interface Get { String get(String path, Map<String,String> headers) throws Exception; }
    static final String ZTE = "/goform/goform_get_cmd_process?isTest=false&multi_data=1&cmd=cell_id,lac_code,rmcc,rmnc,network_type,lte_rsrp,rscp,rssi";
    static final String[] SIGNALS = {"/api/device/signal", "/api/net/cell-info", "/api/net/signal-para"};
    final Get http;
    String source = "usb-wwan-http";
    HttpCellSource(Get http) { this.http = http; }

    CellObservation scan() throws Exception {
        Map<String,String> headers = new HashMap<>();
        try {
            Map<String,String> session = HttpCellParser.xml(http.get("/api/webserver/SesTokInfo", headers));
            for (String key : new String[]{"SesInfo", "TokInfo"}) {
                String value = session.get(key);
                if (value != null && !value.isEmpty()) {
                    if (value.length() > 1024 || !value.matches("[\\x20-\\x7E]+")) throw new IllegalArgumentException("http-session");
                    headers.put(key.equals("SesInfo") ? "Cookie" : "__RequestVerificationToken", value);
                }
            }
        } catch (Exception e) {
            if ("http-auth-required".equals(e.getMessage())) throw e;
        }
        String plmn = "";
        Map<String,String> fields;
        try { plmn = http.get("/api/net/current-plmn", headers); fields = HttpCellParser.xml(plmn); }
        catch (Exception e) {
            if ("http-auth-required".equals(e.getMessage())) throw e;
            fields = Collections.emptyMap();
        }
        if (!fields.containsKey("Numeric")) {
            source = "usb-wwan-zte-http";
            return HttpCellParser.stable(HttpCellParser.zte(http.get(ZTE, Collections.emptyMap())),
                    HttpCellParser.zte(http.get(ZTE, Collections.emptyMap())));
        }
        source = "usb-wwan-huawei-http";
        String statusPath = "/api/monitoring/status", status;
        try {
            status = http.get(statusPath, headers);
            HttpCellParser.huaweiRadio(HttpCellParser.xml(status));
        } catch (Exception e) {
            if (!"http-unsupported".equals(e.getMessage())) throw e;
            statusPath = "/api/monitor/status"; status = http.get(statusPath, headers);
        }
        for (String path : SIGNALS) {
            String sig;
            try {
                sig = http.get(path, headers);
                if (!HttpCellParser.xml(sig).containsKey("cell_id")) continue;
            } catch (Exception e) {
                if ("http-unsupported".equals(e.getMessage())) continue;
                throw e;
            }
            CellObservation before = HttpCellParser.huawei(plmn, status, sig);
            String afterSignal = http.get(path, headers);
            String afterStatus = http.get(statusPath, headers);
            String afterPlmn = http.get("/api/net/current-plmn", headers);
            return HttpCellParser.stable(before, HttpCellParser.huawei(afterPlmn, afterStatus, afterSignal));
        }
        throw new IllegalArgumentException("http-cell-unsupported");
    }

    static Get bound(final String iface, final String gateway) {
        if (!iface.matches("(?:wwan|usb|eth)[0-9]+") || !privateV4(gateway))
            throw new IllegalArgumentException("http-target");
        return (path, headers) -> {
            List<String> cmd = new ArrayList<>(Arrays.asList("curl", "--silent", "--show-error",
                    "--noproxy", "*", "--interface", iface, "--connect-timeout", "1", "--max-time", "2",
                    "--max-filesize", "32768", "--proto", "=http", "--write-out", "\nWWAN_HTTP_STATUS=%{http_code}", "-H", "Referer: http://" + gateway + "/index.html"));
            for (Map.Entry<String,String> h : headers.entrySet()) {
                cmd.add("-H"); cmd.add(h.getKey() + ": " + h.getValue());
            }
            cmd.add("http://" + gateway + path);
            return decodeResponse(CellCommands.run(3000, HttpCellParser.LIMIT + 64, cmd.toArray(new String[0])));
        };
    }
    static String decodeResponse(String response) throws java.io.IOException {
        String marker = "\nWWAN_HTTP_STATUS=";
        int tail = response.lastIndexOf(marker);
        if (tail < 0 || tail > HttpCellParser.LIMIT) throw new java.io.IOException("http-status");
        String code = response.substring(tail + marker.length());
        if (code.equals("401") || code.equals("403")) throw new java.io.IOException("http-auth-required");
        if (code.equals("404")) throw new java.io.IOException("http-unsupported");
        if (code.startsWith("3")) throw new java.io.IOException("http-redirect");
        if (!code.equals("200")) throw new java.io.IOException("http-status");
        return response.substring(0, tail);
    }
    static boolean privateV4(String text) {
        if (text == null || !text.matches("[0-9]{1,3}(\\.[0-9]{1,3}){3}")) return false;
        String[] s = text.split("\\."); int[] n = new int[4];
        for (int i = 0; i < 4; i++) {
            n[i] = Integer.parseInt(s[i]);
            if (n[i] > 255 || !s[i].equals(Integer.toString(n[i]))) return false;
        }
        return n[3] != 0 && n[3] != 255 && (n[0] == 10 || n[0] == 192 && n[1] == 168
                || n[0] == 172 && n[1] >= 16 && n[1] <= 31);
    }
}

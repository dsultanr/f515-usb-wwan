import java.io.StringReader;
import java.util.*;
import java.util.regex.*;
import javax.xml.parsers.*;
import org.w3c.dom.*;
import org.xml.sax.*;

/** Read-only Huawei HiLink / ZTE goform schemas. No guesses from signal bars or operator names. */
public final class HttpCellParser {
    static final int LIMIT = 32768;
    static IllegalArgumentException bad(String reason) { return new IllegalArgumentException(reason); }
    public static Map<String,String> xml(String body) {
        try {
            if (body == null || body.length() > LIMIT || body.contains("<!")) throw bad("http-xml");
            DocumentBuilderFactory f = DocumentBuilderFactory.newInstance();
            f.setExpandEntityReferences(false);
            DocumentBuilder b = f.newDocumentBuilder();
            b.setEntityResolver((p, s) -> { throw new SAXException("entity"); });
            b.setErrorHandler(new org.xml.sax.helpers.DefaultHandler() {
                public void error(SAXParseException e) throws SAXException { throw e; }
                public void fatalError(SAXParseException e) throws SAXException { throw e; }
            });
            Element root = b.parse(new InputSource(new StringReader(body))).getDocumentElement();
            if (!root.getTagName().matches("response|error")) throw bad("http-xml");
            Map<String,String> out = new HashMap<>();
            for (Node n = root.getFirstChild(); n != null; n = n.getNextSibling()) {
                if (!(n instanceof Element)) continue;
                if (((Element)n).getElementsByTagName("*").getLength() != 0
                        || out.put(n.getNodeName(), n.getTextContent().trim()) != null) throw bad("http-xml");
            }
            if (root.getTagName().equals("error")) {
                String code = out.get("code");
                throw bad("100003".equals(code) || "125002".equals(code)
                        ? "http-auth-required" : "100002".equals(code) ? "http-unsupported" : "http-modem-error");
            }
            return out;
        } catch (IllegalArgumentException e) { throw e; }
        catch (Exception e) { throw bad("http-xml"); }
    }

    // Goform returns a flat object of scalar fields. Reject duplicates, nested values,
    // escapes and trailing junk instead of partially interpreting an unfamiliar schema.
    static final Pattern FIELD = Pattern.compile("\\s*\"([A-Za-z0-9_]+)\"\\s*:\\s*(?:\"([^\"\\\\\\p{Cntrl}]*)\"|(-?(?:0|[1-9][0-9]*)(?:\\.[0-9]+)?)|(null|true|false))\\s*");
    public static Map<String,String> json(String body) {
        if (body == null || body.length() > LIMIT) throw bad("http-json");
        body = body.trim();
        if (!body.startsWith("{") || !body.endsWith("}")) throw bad("http-json");
        body = body.substring(1, body.length() - 1);
        Map<String,String> out = new HashMap<>();
        int pos = 0;
        while (pos < body.length()) {
            Matcher m = FIELD.matcher(body); m.region(pos, body.length());
            if (!m.lookingAt()) throw bad("http-json");
            String value = m.group(2) != null ? m.group(2) : m.group(3) != null ? m.group(3) : "";
            if (out.put(m.group(1), value) != null) throw bad("http-json");
            pos = m.end();
            if (pos == body.length()) break;
            if (body.charAt(pos++) != ',' || pos == body.length()) throw bad("http-json");
        }
        return out;
    }
    static String required(Map<String,String> fields, String name) {
        String v = fields.get(name);
        if (v == null || v.isEmpty()) throw bad("http-incomplete-cell");
        return v;
    }
    static int number(String text, boolean hex) {
        if (!text.matches(hex ? "(?:0[xX])?[0-9a-fA-F]{1,8}" : "[0-9]{1,10}")) throw bad("http-cell-number");
        try {
            long value = Long.parseLong(hex ? text.replaceFirst("^0[xX]", "") : text, hex ? 16 : 10);
            if (value > Integer.MAX_VALUE) throw bad("http-cell-number");
            return (int)value;
        } catch (NumberFormatException e) { throw bad("http-cell-number"); }
    }
    static Integer dbm(String text) {
        if (text == null || text.trim().isEmpty() || text.equals("--") || text.equals("255") || text.equals("0")) return null;
        if (!text.matches("-[0-9]{1,3}\\s*(?:dBm)?")) throw bad("http-signal");
        return Integer.valueOf(text.replaceFirst("\\s*dBm$", ""));
    }
    static String huaweiRadio(Map<String,String> status) {
        String type = required(status, "CurrentNetworkType");
        int n = number(type, false);
        if (n == 19) return "lte"; // legacy CurrentNetworkType; do not treat CDMA codes as LTE
        if (n >= 4 && n <= 7 || n == 9 || n == 17 || n == 18) return "wcdma";
        if (n >= 1 && n <= 3) return "gsm";
        throw bad("http-radio-unsupported");
    }
    public static CellObservation huawei(String plmn, String status, String signal) {
        String radio = huaweiRadio(xml(status));
        Map<String,String> sig = xml(signal);
        String sn = radio.equals("lte") ? "rsrp" : radio.equals("wcdma") ? "rscp" : "rssi";
        return new CellObservation(radio, required(xml(plmn), "Numeric"),
                number(required(sig, radio.equals("lte") ? "tac" : "lac"), false),
                number(required(sig, "cell_id"), false), dbm(sig.get(sn)), null);
    }
    public static CellObservation zte(String body) {
        Map<String,String> f = json(body);
        String type = required(f, "network_type").toUpperCase(Locale.ROOT), radio;
        if (type.matches("LTE(?:[ +A-]*)?|FDD LTE|TDD LTE")) radio = "lte";
        else if (type.matches("WCDMA|UMTS|HSPA[+]?|HSDPA|HSUPA|HSPA[+]?[ /]HSPA[+]?|3G")) radio = "wcdma";
        else if (type.matches("GSM|GPRS|EDGE|2G")) radio = "gsm";
        else throw bad("http-radio-unsupported");
        String mcc = required(f, "rmcc"), mnc = required(f, "rmnc");
        if (!mcc.matches("[1-9][0-9]{2}") || !mnc.matches("[0-9]{2,3}")) throw bad("http-plmn");
        // ZTE cell_id AND lac_code are hex, INCLUDING digit-only values.
        return new CellObservation(radio, mcc + mnc, number(required(f, "lac_code"), true),
                number(required(f, "cell_id"), true),
                dbm(f.get(radio.equals("lte") ? "lte_rsrp" : radio.equals("wcdma") ? "rscp" : "rssi")), null);
    }
    public static CellObservation stable(CellObservation before, CellObservation after) {
        if (!before.sameCell(after)) throw bad("http-cell-changed");
        return after;
    }
}

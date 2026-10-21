import java.util.ArrayList;
import java.util.List;

/** Parse only complete AT transactions. No invented cells, PLMN guesses or CEREG truncation. */
public final class HuaweiCellParser {
    public static final String[] COMMANDS = {"AT^SYSINFOEX", "AT^CECELLID?", "AT^LOCINFO?",
            "AT^HCSQ?", "AT^LOCINFO?", "AT^CECELLID?", "AT^SYSINFOEX"};

    public static CellObservation parse(String transcript) {
        String[] responses = split(transcript);
        String radio = radio(responses[0]);
        if (!radio.equals(radio(responses[6]))) throw new IllegalArgumentException("radio-changed");
        CellObservation first = identity(radio, responses[1], responses[2]);
        CellObservation last = identity(radio, responses[5], responses[4]);
        if (!first.sameCell(last)) throw new IllegalArgumentException("cell-changed");
        String signal = field(responses[3], "^HCSQ:");
        Integer dbm = null;
        if (signal != null) {
            String[] f = signal.replace("\"", "").split(",", -1);
            if (f.length < 2 || !f[0].trim().equalsIgnoreCase(radio))
                throw new IllegalArgumentException("signal-radio-changed");
            int idx = radio.equals("gsm") ? 1 : 2;
            if (f.length <= idx) throw new IllegalArgumentException("signal-fields");
            int code = decimal(f[idx]);
            // Huawei HCSQ interval codes: 0/255 unavailable; use lower endpoint.
            int max = radio.equals("lte") ? 97 : 96;
            if (code != 0 && code != 255) {
                if (code < 1 || code > max) throw new IllegalArgumentException("signal-code");
                dbm = code - (radio.equals("lte") ? 141 : 121);
            }
        }
        return new CellObservation(radio, first.mcc + first.mnc, first.area, first.cellId,
                dbm, first.pci);
    }

    static String[] split(String transcript) {
        if (transcript == null || transcript.length() > 65536)
            throw new IllegalArgumentException("transcript-size");
        List<String> sections = new ArrayList<>();
        StringBuilder current = null;
        int n = 0;
        for (String line : transcript.replace("\r", "").split("\n")) {
            line = line.trim();
            if (line.startsWith("> ")) {
                if (n >= COMMANDS.length || !line.equals("> " + COMMANDS[n++]))
                    throw new IllegalArgumentException("command-order");
                if (current != null) sections.add(current.toString());
                current = new StringBuilder();
            } else if (current != null) current.append(line).append('\n');
        }
        if (current != null) sections.add(current.toString());
        if (sections.size() != COMMANDS.length) throw new IllegalArgumentException("incomplete-scan");
        return sections.toArray(new String[0]);
    }

    static String field(String response, String prefix) {
        if (!response.matches("(?is).*\\bOK\\s*.*")) return null;
        String value = null;
        for (String line : response.split("\n")) {
            if (!line.regionMatches(true, 0, prefix, 0, prefix.length())) continue;
            String next = line.substring(prefix.length()).trim();
            if (value != null && !value.equals(next))
                throw new IllegalArgumentException("ambiguous-response");
            value = next;
        }
        return value;
    }

    static String radio(String response) {
        String value = field(response, "^SYSINFOEX:");
        if (value == null) throw new IllegalArgumentException("no-system-info");
        String[] f = value.split(",", -1);
        if (f.length < 7 || decimal(f[0]) != 2 || decimal(f[3]) != 1)
            throw new IllegalArgumentException("not-registered");
        switch (decimal(f[5])) {
            case 6: return "lte";
            case 3: return "wcdma";
            case 1: return "gsm";
            default: throw new IllegalArgumentException("unsupported-radio");
        }
    }

    static CellObservation identity(String radio, String ce, String loc) {
        CellObservation primary = null, secondary = null;
        String value = radio.equals("lte") ? field(ce, "^CECELLID:") : null;
        if (value != null) {
            String[] f = value.split(",", -1);
            if (f.length != 4) throw new IllegalArgumentException("ce-fields");
            primary = new CellObservation(radio, f[0].trim(), decimal(f[3]), decimal(f[1]),
                    null, decimal(f[2]));
        }
        value = field(loc, "^LOCINFO:");
        if (value != null) {
            String[] f = value.split(",", -1);
            if (f.length != 4) throw new IllegalArgumentException("loc-fields");
            secondary = new CellObservation(radio, f[0].trim(), hex(f[1]), hex(f[3]), null, null);
        }
        if (primary != null && secondary != null && !primary.sameCell(secondary))
            throw new IllegalArgumentException("identity-disagreement");
        if (primary != null) return primary;
        if (secondary != null) return secondary;
        throw new IllegalArgumentException("no-cell");
    }

    static int decimal(String s) {
        s = s.trim();
        if (!s.matches("[0-9]{1,9}")) throw new IllegalArgumentException("decimal");
        return Integer.parseInt(s, 10);
    }

    static int hex(String s) {
        s = s.trim();
        if (!s.matches("0[xX][0-9a-fA-F]{1,8}")) throw new IllegalArgumentException("hex");
        long n = Long.parseLong(s.substring(2), 16);
        if (n > 268435455L) throw new IllegalArgumentException("hex-range");
        return (int)n;
    }
}

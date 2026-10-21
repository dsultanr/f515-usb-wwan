public final class CellSourceTest {
    static int checks;
    static void check(boolean ok, String why) { checks++; if (!ok) throw new AssertionError(why); }
    static String transcript(String radio, String ce, String loc, String signal) {
        int mode = radio.equals("LTE") ? 6 : radio.equals("WCDMA") ? 3 : 1;
        String sys = "^SYSINFOEX:2,3,0,1,," + mode + ",\"" + radio + "\",101,\"" + radio + "\"\nOK";
        String[] bodies = {sys, ce, loc, signal, loc, ce, sys};
        StringBuilder s = new StringBuilder();
        for (int i = 0; i < bodies.length; i++)
            s.append("> ").append(HuaweiCellParser.COMMANDS[i]).append('\n').append(bodies[i]).append('\n');
        return s.toString();
    }
    static void rejects(String text, String reason) {
        try { HuaweiCellParser.parse(text); throw new AssertionError("accepted " + reason); }
        catch (IllegalArgumentException expected) { checks++; }
    }
    public static void main(String[] args) {
        String ce = "^CECELLID: 25002,1193046,123,100\nOK";
        String loc = "^LOCINFO:25002,0x64,0xFF,0x123456\nOK";
        String lte = transcript("LTE", ce, loc, "^HCSQ:\"LTE\",47,37,111,20\nOK");
        CellObservation c = HuaweiCellParser.parse(lte);
        check(c.cellId == 1193046 && c.area == 100, "full LTE identity");
        check(c.mcc.equals("250") && c.mnc.equals("02"), "PLMN leading zero preserved");
        check(c.dbm == -104 && c.pci == 123, "RSRP and PCI");
        check(c.json().contains("\"mnc\":\"02\""), "JSON MNC");
        check(HuaweiCellParser.parse(lte.replace("\n", "\r\n")).sameCell(c), "CRLF");
        check(HuaweiCellParser.parse(lte.replace(ce, "COMMAND NOT SUPPORT")).sameCell(c), "LOCINFO fallback");
        check(HuaweiCellParser.parse(lte.replace(loc, "ERROR")).sameCell(c), "CE only");
        check(HuaweiCellParser.parse(lte.replace("47,37,111", "47,255,111")).dbm == null, "unknown signal omitted");
        check(HuaweiCellParser.parse(lte.replace("25002", "310260")).mnc.equals("260"), "three digit MNC");
        rejects(lte.replace("^SYSINFOEX:2,3", "^SYSINFOEX:0,3"), "registration lost");
        rejects(lte.replaceFirst("1193046", "1193047"), "identity discrepancy");
        rejects(lte.replaceFirst("2,3,0,1,,6", "2,3,0,1,,3"), "RAT handover");
        rejects(lte.replace("\"LTE\",47", "\"WCDMA\",47"), "signal RAT handover");
        rejects(lte.replace("25002", "25x02"), "invalid PLMN");
        rejects(lte.replace("25002", "2502"), "short PLMN");
        rejects(lte.replace("1193046", "268435455"), "reserved ECI");
        rejects(lte.replace("1193046", "4294967295"), "overflow ECI");
        rejects(lte.replace("0x123456", "123456"), "hex marker required");
        rejects(lte.replace("0x123456", "0xFFFFFFFF"), "hex overflow");
        rejects(lte.replace("123,100", "504,100"), "invalid PCI");
        rejects(lte.replace("123,100", "123,65535"), "reserved TAC");
        rejects(lte.replace("47,37,111", "47,200,111"), "invalid signal code");
        rejects(lte.substring(0, lte.lastIndexOf("> AT^SYSINFOEX")), "truncated exchange");
        rejects(lte.replace("> AT^HCSQ?", "> AT+CSQ"), "wrong command");
        rejects(lte.replace("^CECELLID: 25002,1193046,123,100", "^CECELLID: 25002,1193046,123,100\n^CECELLID: 25002,1193047,123,100"), "ambiguous URC");
        String gsm = transcript("GSM", "ERROR", "^LOCINFO:25002,0x64,0xFF,0x1234\nOK", "^HCSQ:\"GSM\",40\nOK");
        check(HuaweiCellParser.parse(gsm).dbm == -81, "GSM RSSI");
        String wcdma = transcript("WCDMA", ce, loc, "^HCSQ:\"WCDMA\",60,40,12\nOK");
        check(HuaweiCellParser.parse(wcdma).pci == null && HuaweiCellParser.parse(wcdma).dbm == -81, "WCDMA ignores old LTE");
        rejects(gsm.replace("0x1234", "0x123456"), "GSM identity width");
        check(CellSnapshot.usable("boot", "boot", 1000, 60999), "fresh boundary");
        check(!CellSnapshot.usable("boot", "boot", 1000, 61000), "expired boundary");
        check(!CellSnapshot.usable("old", "new", 1000, 2000), "reboot");
        check(!CellSnapshot.usable("boot", "boot", 1000, 999), "future monotonic time");
        check(!CellSnapshot.usable("boot", "boot", 1000, 300000), "suspend expiry");
        String json = CellSnapshot.json(c, "12345678-1234-1234-1234-123456789abc", 100, 0, "ready");
        check(json.contains("\"timestampMs\":0") && json.contains("\"maxAgeMs\":60000"), "wall clock not freshness");
        check(CellSnapshot.json(null, "12345678-1234-1234-1234-123456789abc", 100, 0, "no-cell")
                .contains("\"cells\":[]"), "failure clears cells");
        System.out.println("Cell source: " + checks + " checks passed");
    }
}

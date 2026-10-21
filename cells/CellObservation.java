import java.util.Locale;

/** One real serving cell, deliberately independent of Android and any LBS backend. */
public final class CellObservation {
    public final String radio, mcc, mnc;
    public final int area, cellId;
    public final Integer dbm, pci;

    public CellObservation(String radio, String plmn, int area, int cellId,
                           Integer dbm, Integer pci) {
        if (!radio.matches("lte|wcdma|gsm")) throw new IllegalArgumentException("radio");
        if (!plmn.matches("[1-9][0-9]{4,5}")) throw new IllegalArgumentException("plmn");
        if (area <= 0 || area >= 65534) throw new IllegalArgumentException("area");
        int max = radio.equals("gsm") ? 65534 : 268435454;
        if (cellId <= 0 || cellId > max || cellId == 65535)
            throw new IllegalArgumentException("cell-id");
        if (dbm != null && (dbm < -140 || dbm > -1)) throw new IllegalArgumentException("signal");
        if (pci != null && (!radio.equals("lte") || pci < 0 || pci > 503))
            throw new IllegalArgumentException("pci");
        this.radio = radio; this.mcc = plmn.substring(0, 3); this.mnc = plmn.substring(3);
        this.area = area; this.cellId = cellId; this.dbm = dbm; this.pci = pci;
    }

    public boolean sameCell(CellObservation other) {
        return other != null && radio.equals(other.radio) && mcc.equals(other.mcc)
                && mnc.equals(other.mnc) && area == other.area && cellId == other.cellId;
    }

    public String json() {
        return String.format(Locale.US,
                "{\"radioType\":\"%s\",\"mcc\":\"%s\",\"mnc\":\"%s\","
                + "\"area\":%d,\"cellId\":%d,\"registered\":true%s%s}",
                radio, mcc, mnc, area, cellId,
                dbm == null ? "" : ",\"dbm\":" + dbm,
                pci == null ? "" : ",\"pci\":" + pci);
    }
}

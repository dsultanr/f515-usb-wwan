public final class CellToolboxTest {
    static int checks;
    static void check(boolean ok, String why) { checks++; if (!ok) throw new AssertionError(why); }
    static String snapshot(String guard, String scale, String after, String xml) {
        return "server_before=904\nguard=" + guard + "\nscale=" + scale + "\nguard_status=on\nkilled=0\nserver_after="
                + after + "\nprefs=present\n__TBX_PREFS__\n" + xml;
    }
    static boolean ready(String s) { return CellToolboxReadiness.evaluate(s, "ru.yandex.yandexnavi").ready; }
    public static void main(String[] args) {
        String profile = "<map><set name=\"app_scale\"><string>ru.yandex.yandexnavi=80</string></set></map>";
        check(ready(snapshot("904", "904", "904", profile)), "both markers match current server");
        check(!ready(snapshot("903", "904", "904", profile)), "stale system hook marker");
        check(!ready(snapshot("904", "903", "904", profile)), "stale scale marker");
        check(!ready(snapshot("904", "904", "905", profile)), "server restarted during reads");
        check(!ready(snapshot("904", "", "904", profile)), "scale still initializing");
        check(ready(snapshot("904", "", "904", "<map/>")), "unscaled application needs no scale hook");
        check(ready(snapshot("", "", "904", "<map><boolean name=\"storage_guard_enabled\" value=\"false\"/></map>")), "disabled guard needs no marker");
        check(!ready(snapshot("904", "904", "904", "<map>")), "incomplete preferences fail closed");
        check(!ready("server_before=904"), "incomplete snapshot");
        check(!ready(snapshot("904", "904", "904", "<!DOCTYPE map><map/>")), "DTD rejected");
        System.out.println("Toolbox startup gate: " + checks + " checks passed");
    }
}

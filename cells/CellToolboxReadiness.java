import java.io.StringReader;
import java.util.HashMap;
import java.util.Map;
import javax.xml.parsers.DocumentBuilder;
import javax.xml.parsers.DocumentBuilderFactory;
import org.w3c.dom.Element;
import org.w3c.dom.Node;
import org.xml.sax.InputSource;
import org.xml.sax.SAXException;

/** Read-only readiness of Toolbox hooks. Never install hooks or manufacture their markers. */
final class CellToolboxReadiness {
    private static final String PACKAGE = "com.ispace.toolbox";
    private static final String PREFS = "/data/user/0/com.ispace.toolbox/shared_prefs/toolbox.xml";
    private static final String XML_START = "\n__TBX_PREFS__\n";
    // One bounded snapshot. The second pid prevents accepting a marker from a server that died
    // during the reads. Settings are read too: a missing marker is not evidence of a disabled hook.
    static final String PROBE =
            "printf 'server_before='; pidof system_server 2>/dev/null; "
            + "printf '\nguard='; cat /dev/tbx/storage-guard-agent-pid 2>/dev/null; "
            + "printf '\nscale='; cat /dev/tbx/app-scale-on 2>/dev/null; "
            + "printf '\nguard_status='; cat /data/local/tmp/ispace/run/storage-guard-status 2>/dev/null; "
            + "printf '\nkilled='; if [ -f /data/user/0/com.ispace.toolbox/files/frida/killed ]; then printf 1; else printf 0; fi; "
            + "printf '\nserver_after='; pidof system_server 2>/dev/null; "
            + "printf '\nprefs='; if [ -f " + PREFS + ".bak ]; then printf 'present\n__TBX_PREFS__\n'; cat " + PREFS + ".bak; "
            + "elif [ -f " + PREFS + " ]; then printf 'present\n__TBX_PREFS__\n'; cat " + PREFS + "; "
            + "else printf 'missing\n__TBX_PREFS__\n'; fi";

    static final class Result {
        final boolean ready;
        final String detail;
        Result(boolean ready, String detail) { this.ready = ready; this.detail = detail; }
    }
    private static Result ready(String why) { return new Result(true, "toolbox=" + why); }
    private static Result waitFor(String why) { return new Result(false, "toolbox_wait=" + why); }

    static Result check() {
        try {
            Object pm = Class.forName("android.app.AppGlobals").getMethod("getPackageManager").invoke(null);
            Class<?> api = Class.forName("android.content.pm.IPackageManager");
            Object info = api.getMethod("getApplicationInfo", String.class, int.class, int.class)
                    .invoke(pm, PACKAGE, 0, 0);
            if (info == null) return ready("absent");
            int stopped = info.getClass().getField("FLAG_STOPPED").getInt(null);
            if (!info.getClass().getField("enabled").getBoolean(info)
                    || (info.getClass().getField("flags").getInt(info) & stopped) != 0) return ready("disabled");
        } catch (Exception e) { return waitFor("package_unavailable"); }
        if (!new java.io.File("/data/user/0/" + PACKAGE).exists()) return ready("absent");
        try { return evaluate(CellCommands.run(3000, 262144, "sh", "-c", PROBE), "ru.yandex.yandexnavi"); }
        catch (Exception e) { return waitFor("probe_failed"); }
    }

    static Result evaluate(String snapshot, String targetPackage) {
        if (snapshot == null || snapshot.length() > 262144) return waitFor("invalid_snapshot");
        int split = snapshot.indexOf(XML_START);
        if (split < 0) return waitFor("incomplete_snapshot");
        Map<String, String> fields = new HashMap<>();
        for (String line : snapshot.substring(0, split).split("\n")) {
            if (line.trim().isEmpty()) continue;
            int eq = line.indexOf('=');
            if (eq < 1 || fields.put(line.substring(0, eq), line.substring(eq + 1).trim()) != null)
                return waitFor("invalid_snapshot");
        }
        for (String key : new String[]{"server_before", "server_after", "guard", "scale", "guard_status", "killed", "prefs"})
            if (!fields.containsKey(key)) return waitFor("incomplete_snapshot");
        if ("1".equals(fields.get("killed"))) return ready("disabled");
        if (!"0".equals(fields.get("killed"))) return waitFor("invalid_snapshot");

        boolean guardRequired = true, scaleRequired = false;
        if ("present".equals(fields.get("prefs"))) {
            try {
                Element settings = parseSettings(snapshot.substring(split + XML_START.length()));
                guardRequired = bool(settings, "storage_guard_enabled", true);
                scaleRequired = bool(settings, "app_scale_enabled", true) && scaled(settings, targetPackage);
            } catch (Exception e) { return waitFor("settings_unavailable"); }
        } else if (!"missing".equals(fields.get("prefs"))) return waitFor("settings_unavailable");
        // The resident guard explicitly stops protecting on "off" without removing its marker.
        if ("off".equals(fields.get("guard_status"))) guardRequired = false;
        else if (!fields.get("guard_status").isEmpty() && !"on".equals(fields.get("guard_status")))
            return waitFor("guard_status_unknown");
        if (!guardRequired && !scaleRequired) return ready("not_required");

        String server = fields.get("server_before");
        if (!server.matches("[1-9][0-9]*") || !server.equals(fields.get("server_after")))
            return waitFor("system_server_changed");
        if (guardRequired && !server.equals(fields.get("guard"))) return waitFor("system_guard");
        if (scaleRequired && !server.equals(fields.get("scale"))) return waitFor("app_scale");
        return ready("ready pid=" + server);
    }

    private static Element parseSettings(String xml) throws Exception {
        // SharedPreferences XML needs no DTD/entities. Reject those before invoking Android's
        // parser (its supported security-feature names differ from the desktop JDK's).
        if (xml.contains("<!DOCTYPE") || xml.contains("<!ENTITY")) throw new SAXException("DTD");
        DocumentBuilderFactory factory = DocumentBuilderFactory.newInstance();
        factory.setExpandEntityReferences(false);
        DocumentBuilder builder = factory.newDocumentBuilder();
        builder.setEntityResolver((publicId, systemId) -> { throw new SAXException("external entity"); });
        builder.setErrorHandler(new org.xml.sax.helpers.DefaultHandler() {
            @Override public void error(org.xml.sax.SAXParseException e) throws SAXException { throw e; }
            @Override public void fatalError(org.xml.sax.SAXParseException e) throws SAXException { throw e; }
        });
        Element root = builder.parse(new InputSource(new StringReader(xml))).getDocumentElement();
        if (!"map".equals(root.getTagName())) throw new SAXException("settings root");
        return root;
    }

    private static Element setting(Element root, String name) {
        Element found = null;
        for (Node n = root.getFirstChild(); n != null; n = n.getNextSibling()) {
            if (n instanceof Element && name.equals(((Element) n).getAttribute("name"))) {
                if (found != null) throw new IllegalArgumentException("duplicate setting");
                found = (Element) n;
            }
        }
        return found;
    }
    private static boolean bool(Element root, String name, boolean fallback) {
        Element e = setting(root, name);
        if (e == null) return fallback;
        String value = e.getAttribute("value");
        if (!"boolean".equals(e.getTagName()) || !("true".equals(value) || "false".equals(value)))
            throw new IllegalArgumentException("boolean setting");
        return "true".equals(value);
    }
    private static boolean scaled(Element root, String targetPackage) {
        Element profiles = setting(root, "app_scale");
        if (profiles == null) return false;
        if (!"set".equals(profiles.getTagName())) throw new IllegalArgumentException("scale profiles");
        for (Node n = profiles.getFirstChild(); n != null; n = n.getNextSibling()) {
            if (!(n instanceof Element) || !"string".equals(((Element) n).getTagName())) continue;
            String entry = n.getTextContent();
            if (!entry.startsWith(targetPackage + "=")) continue;
            String[] values = entry.substring(targetPackage.length() + 1).split(":", -1);
            if (values.length != 1 && values.length != 2 && values.length != 4)
                throw new IllegalArgumentException("scale format");
            boolean custom = false;
            for (String value : values) {
                int percent = Integer.parseInt(value);
                custom |= percent != 100;
            }
            if (custom) return true;
        }
        return false;
    }
}

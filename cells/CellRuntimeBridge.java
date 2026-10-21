import android.app.Application;
import android.app.AppOpsManager;
import android.content.Context;
import android.os.*;
import android.telephony.*;
import org.json.*;
import java.io.*;
import java.lang.reflect.*;
import java.util.*;

/** Temporary, reversible native-loaded integration. No ART method hooks or system_server edits. */
public final class CellRuntimeBridge {
    static final String DESCRIPTOR = "com.android.internal.telephony.ITelephony";
    static final String DIR = "/dev/wwan-cell-probe/";
    static final String PROBE = "su.dsr.f515.cell_probe";
    static final String NAVI = "ru.yandex.yandexnavi";
    static final long LIFETIME = 300000;
    static volatile boolean active;
    static volatile long generation;
    static Object packageManager, oldPm, proxyPm;
    static Field pmField, threadPmField;
    static Object oldThreadPm;
    static IBinder originalPhone;
    static CellBinder wrapper;
    static Application app;

    static void log(String text) { android.util.Log.w("WwanCells", text); }
    static void clearFeatureCache() throws Exception {
        // Android 11 caches a negative feature result independently of mPM.
        Field f = Class.forName("android.app.ApplicationPackageManager")
                .getDeclaredField("mHasSystemFeatureCache");
        f.setAccessible(true);
        Class.forName("android.app.PropertyInvalidatedCache").getMethod("clear").invoke(f.get(null));
    }
    static String read(String path) throws IOException {
        try (BufferedReader r = new BufferedReader(new FileReader(path))) {
            String s = r.readLine();
            if (s == null || s.length() > 4096) throw new IOException("invalid snapshot size");
            return s;
        }
    }
    static Object invoke(Object obj, String method, Class<?>[] types, Object... args) throws Exception {
        return obj.getClass().getMethod(method, types).invoke(obj, args);
    }
    static IBinder service() throws Exception {
        return (IBinder)Class.forName("android.os.ServiceManager")
                .getMethod("checkService", String.class).invoke(null, "phone");
    }
    static void publish(IBinder binder) throws Exception {
        Class.forName("android.os.ServiceManager").getMethod("addService", String.class, IBinder.class)
                .invoke(null, "phone", binder);
    }

    public static synchronized void start(Application application) throws Exception {
        if (active) { log("already active"); return; }
        app = application;
        final String pkg = app.getPackageName();
        if (pkg.equals("com.android.phone")) {
            originalPhone = service();
            // Forwarding across another process would change the Binder caller UID: forbid it.
            if (!(originalPhone instanceof Binder) || !DESCRIPTOR.equals(originalPhone.getInterfaceDescriptor()))
                throw new IllegalStateException("phone binder is not local");
            wrapper = new CellBinder(originalPhone, app);
            active = true;
            try {
                publish(wrapper);
                if (service() != wrapper) throw new IllegalStateException("phone service replacement not confirmed");
            } catch (Exception e) { active = false; publish(originalPhone); throw e; }
            log("native phone adapter active; normal Binder caller identity preserved");
        } else if (pkg.equals(PROBE) || pkg.equals(NAVI)) {
            // Only this process sees the feature; no global telephony/SIM capability changes.
            packageManager = app.getPackageManager();
            pmField = packageManager.getClass().getDeclaredField("mPM");
            pmField.setAccessible(true);
            oldPm = pmField.get(packageManager);
            threadPmField = Class.forName("android.app.ActivityThread").getDeclaredField("sPackageManager");
            threadPmField.setAccessible(true);
            oldThreadPm = threadPmField.get(null);
            final Class<?> pmInterface = Class.forName("android.content.pm.IPackageManager");
            final Object delegate = oldPm;
            proxyPm = Proxy.newProxyInstance(pmInterface.getClassLoader(), new Class<?>[]{pmInterface},
                    new InvocationHandler() {
                        public Object invoke(Object proxy, Method method, Object[] args) throws Throwable {
                            if (active && method.getName().equals("hasSystemFeature") && args != null
                                    && args.length == 2 && "android.hardware.telephony".equals(args[0])
                                    && ((Integer)args[1]) == 0) return true;
                            try { return method.invoke(delegate, args); }
                            catch (InvocationTargetException e) { throw e.getCause(); }
                        }
                    });
            active = true;
            try {
                pmField.set(packageManager, proxyPm);
                // New ContextImpl instances must use the same local delegate.
                threadPmField.set(null, proxyPm);
                clearFeatureCache();
            } catch (Exception e) { stop(); throw e; }
            log("local feature adapter active for " + pkg);
        } else throw new SecurityException("unsupported process " + pkg);

        final long token = ++generation;
        final long deadline = SystemClock.elapsedRealtime() + LIFETIME;
        new Thread(new Runnable() {
            public void run() {
                while (active && generation == token && SystemClock.elapsedRealtime() < deadline) {
                    try { Thread.sleep(500); } catch (InterruptedException ignored) { break; }
                }
                synchronized (CellRuntimeBridge.class) {
                    if (generation == token) stop();
                }
            }
        }, "wwan-cell-expiry").start();
    }

    public static synchronized void stop() {
        active = false;
        generation++;
        try {
            if (wrapper != null && service() == wrapper) publish(originalPhone);
            if (pmField != null && pmField.get(packageManager) == proxyPm)
                pmField.set(packageManager, oldPm);
            if (threadPmField != null && threadPmField.get(null) == proxyPm)
                threadPmField.set(null, oldThreadPm);
            if (threadPmField != null) clearFeatureCache();
            log("native adapter restored");
        } catch (Exception e) { log("restore failed: " + e); }
    }

    static final class CellBinder extends Binder {
        final IBinder original;
        final Context context;
        final int getCode, requestCode;
        final String boot;
        CellBinder(IBinder original, Context context) throws Exception {
            this.original = original; this.context = context;
            Class<?> stub = Class.forName(DESCRIPTOR + "$Stub");
            getCode = code(stub, "TRANSACTION_getAllCellInfo");
            requestCode = code(stub, "TRANSACTION_requestCellInfoUpdate");
            boot = read("/proc/sys/kernel/random/boot_id").trim();
            attachInterface(null, DESCRIPTOR);
        }
        static int code(Class<?> cls, String name) throws Exception {
            Field f = cls.getDeclaredField(name); f.setAccessible(true); return f.getInt(null);
        }
        boolean allowed(String pkg, String feature, String method) throws Exception {
            final int uid = Binder.getCallingUid(), pid = Binder.getCallingPid();
            context.getSystemService(AppOpsManager.class).checkPackage(uid, pkg);
            Class<?> builder = Class.forName("android.telephony.LocationAccessPolicy$LocationPermissionQuery$Builder");
            Object q = builder.getConstructor().newInstance();
            invoke(q, "setCallingPackage", new Class<?>[]{String.class}, pkg);
            invoke(q, "setCallingFeatureId", new Class<?>[]{String.class}, feature);
            invoke(q, "setCallingUid", new Class<?>[]{int.class}, uid);
            invoke(q, "setCallingPid", new Class<?>[]{int.class}, pid);
            invoke(q, "setMethod", new Class<?>[]{String.class}, method);
            invoke(q, "setMinSdkVersionForCoarse", new Class<?>[]{int.class}, 1);
            invoke(q, "setMinSdkVersionForFine", new Class<?>[]{int.class}, 29);
            Object query = invoke(q, "build", new Class<?>[0]);
            String verdict = Class.forName("android.telephony.LocationAccessPolicy")
                    .getMethod("checkLocationPermission", Context.class, query.getClass())
                    .invoke(null, context, query).toString();
            if (verdict.equals("DENIED_HARD")) throw new SecurityException("Not allowed to access cell info");
            return verdict.equals("ALLOWED");
        }
        @Override protected boolean onTransact(int code, Parcel data, Parcel reply, int flags)
                throws RemoteException {
            int position = data.dataPosition();
            if (active && (code == getCode || code == requestCode)) {
                data.enforceInterface(DESCRIPTOR);
                IBinder callback = null;
                if (code == requestCode) { data.readInt(); callback = data.readStrongBinder(); }
                String pkg = data.readString(), feature = data.readString();
                // Prototype allowlist. Other apps, phone/SIM management and system requests delegate.
                if (PROBE.equals(pkg) || NAVI.equals(pkg)) {
                    try {
                        List<CellInfo> list = allowed(pkg, feature,
                                code == getCode ? "getAllCellInfo" : "requestCellInfoUpdate")
                                ? cells(boot) : new ArrayList<CellInfo>();
                        if (code == getCode) {
                            reply.writeNoException(); reply.writeTypedList(list);
                        } else {
                            if (callback == null) throw new IllegalArgumentException("callback required");
                            Class<?> stub = Class.forName("android.telephony.ICellInfoCallback$Stub");
                            Object target = stub.getMethod("asInterface", IBinder.class).invoke(null, callback);
                            Class.forName("android.telephony.ICellInfoCallback")
                                    .getMethod("onCellInfo", List.class).invoke(target, list);
                            if (reply != null) reply.writeNoException();
                        }
                        log((code == getCode ? "get" : "request") + " uid=" + Binder.getCallingUid()
                                + " cells=" + list.size());
                        return true;
                    } catch (SecurityException e) { throw e; }
                    catch (Exception e) { throw new IllegalStateException("cell bridge", e); }
                }
            }
            data.setDataPosition(position);
            // original is a local Binder: transact invokes its original onTransact on this thread.
            return original.transact(code, data, reply, flags);
        }
    }

    static List<CellInfo> cells(String boot) {
        List<CellInfo> result = new ArrayList<>();
        try {
            JSONObject s = new JSONObject(read(DIR + "cell.json"));
            if (s.getInt("schema") != 1 || !"ready".equals(s.getString("status"))
                    || !CellSnapshot.usable(s.getString("bootId"), boot,
                            s.getLong("elapsedRealtimeMs"), SystemClock.elapsedRealtime())) return result;
            JSONArray cells = s.getJSONArray("cells");
            if (cells.length() != 1) return result;
            JSONObject c = cells.getJSONObject(0);
            CellObservation obs = new CellObservation(c.getString("radioType"),
                    c.getString("mcc") + c.getString("mnc"), c.getInt("area"), c.getInt("cellId"),
                    c.has("dbm") ? c.getInt("dbm") : null, c.has("pci") ? c.getInt("pci") : null);
            if (!"lte".equals(obs.radio) || !c.getBoolean("registered")) return result;
            int unknown = Integer.MAX_VALUE;
            Object identity = CellIdentityLte.class.getConstructor(int.class, int.class, int.class,
                    int.class, int.class).newInstance(Integer.parseInt(obs.mcc), Integer.parseInt(obs.mnc),
                    obs.cellId, obs.pci == null ? unknown : obs.pci, obs.area);
            for (String name : new String[]{"mMccStr", "mMncStr"}) {
                Field f = CellIdentity.class.getDeclaredField(name); f.setAccessible(true);
                f.set(identity, name.equals("mMccStr") ? obs.mcc : obs.mnc);
            }
            Object strength = CellSignalStrengthLte.class.getConstructor(int.class, int.class,
                    int.class, int.class, int.class, int.class).newInstance(unknown,
                    obs.dbm == null ? unknown : obs.dbm, unknown, unknown, unknown, unknown);
            Constructor<CellInfoLte> ctor = CellInfoLte.class.getDeclaredConstructor(); ctor.setAccessible(true);
            CellInfoLte info = ctor.newInstance();
            invoke(info, "setCellIdentity", new Class<?>[]{CellIdentityLte.class}, identity);
            invoke(info, "setCellSignalStrength", new Class<?>[]{CellSignalStrengthLte.class}, strength);
            invoke(info, "setRegistered", new Class<?>[]{boolean.class}, true);
            invoke(info, "setTimeStamp", new Class<?>[]{long.class}, s.getLong("elapsedRealtimeMs") * 1000000L);
            invoke(info, "setCellConnectionStatus", new Class<?>[]{int.class}, 1);
            result.add(info);
        } catch (Exception e) { log("sample unavailable: " + e.getClass().getSimpleName()); }
        return result;
    }
}

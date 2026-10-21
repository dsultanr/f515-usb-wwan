import android.content.Intent;
import android.content.IntentSender;
import android.content.pm.PackageInstaller;
import android.content.pm.PackageManager;
import android.os.Binder;
import android.os.IBinder;
import android.os.Parcel;
import android.os.RemoteException;
import java.io.*;
import java.lang.reflect.*;
import java.security.MessageDigest;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;

/** Root-only installation of the temporary CellInfo probe, with APK digest verification. */
public final class CellProbeInstaller {
    static final String PKG = "su.dsr.f515.cell_probe";
    static int constant(String name) throws Exception {
        Field f = PackageManager.class.getDeclaredField(name);
        f.setAccessible(true);
        return f.getInt(null);
    }
    public static void main(String[] args) throws Exception {
        if (android.os.Process.myUid() != 0) throw new SecurityException("root required");
        Class<?> at = Class.forName("android.app.ActivityThread");
        Method getPm = at.getDeclaredMethod("getPackageManager");
        getPm.setAccessible(true);
        Object pm = getPm.invoke(null);
        Class<?> ipm = Class.forName("android.content.pm.IPackageManager");
        Object binderInstaller = ipm.getMethod("getPackageInstaller").invoke(pm);
        int flags = constant("INSTALL_REPLACE_EXISTING");
        System.out.println("flags=" + flags);
        for (Constructor<?> c : PackageInstaller.class.getDeclaredConstructors())
            System.out.println("constructor=" + c);
        if (args.length == 0) return;
        if (args.length != 2) throw new IllegalArgumentException("APK SHA256");
        File apk = new File(args[0]);
        MessageDigest digest = MessageDigest.getInstance("SHA-256");
        try (InputStream in = new FileInputStream(apk)) {
            byte[] buf = new byte[65536]; int n;
            while ((n = in.read(buf)) != -1) digest.update(buf, 0, n);
        }
        StringBuilder hex = new StringBuilder();
        for (byte b : digest.digest()) hex.append(String.format("%02x", b & 255));
        if (!hex.toString().equals(args[1])) throw new SecurityException("APK hash mismatch");
        PackageInstaller installer = null;
        for (Constructor<?> c : PackageInstaller.class.getDeclaredConstructors()) {
            Class<?>[] t = c.getParameterTypes();
            if (t.length < 3 || !t[0].isInstance(binderInstaller)) continue;
            c.setAccessible(true);
            if (t.length == 3 && t[1] == String.class && t[2] == int.class)
                installer = (PackageInstaller)c.newInstance(binderInstaller, "com.seres.engineeringmode", 0);
            else if (t.length == 4 && t[1] == String.class && t[2] == String.class && t[3] == int.class)
                installer = (PackageInstaller)c.newInstance(binderInstaller, "com.seres.engineeringmode", null, 0);
        }
        if (installer == null) throw new IllegalStateException("unsupported constructor");
        PackageInstaller.SessionParams params = new PackageInstaller.SessionParams(1);
        params.setAppPackageName(PKG);
        params.setSize(apk.length());
        Field field = params.getClass().getDeclaredField("installFlags");
        field.setAccessible(true);
        field.setInt(params, field.getInt(params) | flags);
        final CountDownLatch done = new CountDownLatch(1);
        final int[] result = {-999};
        Binder callback = new Binder() {
            @Override protected boolean onTransact(int code, Parcel data, Parcel reply, int txFlags)
                    throws RemoteException {
                if (code == IBinder.FIRST_CALL_TRANSACTION) {
                    data.enforceInterface("android.content.IIntentSender");
                    data.readInt();
                    Intent intent = data.readInt() != 0 ? Intent.CREATOR.createFromParcel(data) : null;
                    if (intent != null) {
                        result[0] = intent.getIntExtra(PackageInstaller.EXTRA_STATUS, -999);
                        System.out.println("status=" + result[0] + " message="
                                + intent.getStringExtra(PackageInstaller.EXTRA_STATUS_MESSAGE));
                    }
                    done.countDown();
                    return true;
                }
                return super.onTransact(code, data, reply, txFlags);
            }
        };
        Class<?> senderClass = Class.forName("android.content.IIntentSender");
        Object sender = Class.forName("android.content.IIntentSender$Stub")
                .getMethod("asInterface", IBinder.class).invoke(null, callback);
        Constructor<IntentSender> ctor = IntentSender.class.getDeclaredConstructor(senderClass);
        ctor.setAccessible(true);
        IntentSender statusReceiver = ctor.newInstance(sender);
        int id = installer.createSession(params);
        System.out.println("session=" + id);
        boolean committed = false;
        try (PackageInstaller.Session session = installer.openSession(id)) {
            try (InputStream in = new FileInputStream(apk);
                    OutputStream out = session.openWrite("base.apk", 0, apk.length())) {
                byte[] buf = new byte[65536]; int n;
                while ((n = in.read(buf)) != -1) out.write(buf, 0, n);
                session.fsync(out);
            }
            session.commit(statusReceiver);
            committed = true;
            if (!done.await(40, TimeUnit.SECONDS)) throw new IOException("status timeout");
            if (result[0] != 0) throw new IOException("install status " + result[0]);
        } finally {
            if (!committed) installer.abandonSession(id);
        }
    }
}

import android.os.*;
import org.json.*;

/** Private status transaction; public ITelephony transactions retain Android permissions. */
final class CellProtocol {
    static final int CONTROL = 0x00574331;
    static final String TOKEN = "su.dsr.f515usbwwan.CELL.v2";
    static JSONObject call(int operation, String pkg, String phase, int queries) throws Exception {
        IBinder phone = (IBinder)Class.forName("android.os.ServiceManager")
                .getMethod("checkService", String.class).invoke(null, "phone");
        if (phone == null) throw new IllegalStateException("phone-unavailable");
        Parcel data = Parcel.obtain(), reply = Parcel.obtain();
        try {
            data.writeInterfaceToken(TOKEN); data.writeInt(operation);
            data.writeString(pkg); data.writeString(phase); data.writeInt(queries);
            if (!phone.transact(CONTROL, data, reply, 0)) throw new IllegalStateException("phone-not-ready");
            reply.readException();
            JSONObject result = new JSONObject(reply.readString());
            if (!result.optBoolean("active") || result.optInt("protocol") != 2 || !CellBuild.ID.equals(result.optString("build")))
                throw new IllegalStateException("phone-not-ready");
            return result;
        } finally { data.recycle(); reply.recycle(); }
    }
    public static void main(String[] args) throws Exception {
        System.out.println(call(0, "", "", 0).toString());
    }
}

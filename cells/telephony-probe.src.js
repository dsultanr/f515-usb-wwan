import Java from 'frida-java-bridge';

// Bounded experiment in com.android.phone, NOT system_server. No eternalization/autostart.
// Only the ordinary probe APK may receive cells; all other callers retain original behavior.
const PROBE = 'su.dsr.f515.cell_probe';
const SNAPSHOT = '/dev/wwan-cell-probe/cell.json';
const ENABLE = '/dev/wwan-cell-probe/telephony-on';
let installed = [];
let ready = false;

function restore() {
    Java.perform(function () {
        for (const method of installed) method.implementation = null;
        installed = [];
        ready = false;
        send({event: 'restored'});
    });
}

setTimeout(restore, 180000);
Java.perform(function () {
    const Phone = Java.use('com.android.phone.PhoneInterfaceManager');
    const Binder = Java.use('android.os.Binder');
    const Clock = Java.use('android.os.SystemClock');
    const ArrayList = Java.use('java.util.ArrayList');
    const AppOps = Java.use('android.app.AppOpsManager');
    const Policy = Java.use('android.telephony.LocationAccessPolicy');
    const Query = Java.use('android.telephony.LocationAccessPolicy$LocationPermissionQuery$Builder');
    const SecurityException = Java.use('java.lang.SecurityException');
    const Identity = Java.use('android.telephony.CellIdentityLte');
    const BaseIdentity = Java.use('android.telephony.CellIdentity');
    const Strength = Java.use('android.telephony.CellSignalStrengthLte');
    const Info = Java.use('android.telephony.CellInfoLte');
    const UNKNOWN = 2147483647;
    const get = Phone.getAllCellInfo.overload('java.lang.String', 'java.lang.String');
    const request = Phone.requestCellInfoUpdate.overload('int', 'android.telephony.ICellInfoCallback',
            'java.lang.String', 'java.lang.String');
    const boot = File.readAllText('/proc/sys/kernel/random/boot_id').trim();

    function enabled(pkg) {
        if (!ready || String(pkg) !== PROBE) return false;
        try { return File.readAllText(ENABLE).trim() === '1'; } catch (_) { return false; }
    }

    function permitted(self, pkg, feature, method) {
        const context = self.mApp.value;
        Java.cast(context.getSystemService('appops'), AppOps).checkPackage(Binder.getCallingUid(), pkg);
        // Keep Android's actual location/AppOps/user checks. Never forward requests as root.
        const query = Query.$new().setCallingPackage(pkg).setCallingFeatureId(feature)
                .setCallingUid(Binder.getCallingUid()).setCallingPid(Binder.getCallingPid())
                .setMethod(method).setMinSdkVersionForCoarse(1).setMinSdkVersionForFine(29).build();
        const verdict = Policy.checkLocationPermission(context, query).toString();
        if (verdict === 'DENIED_HARD') throw SecurityException.$new('Not allowed to access cell info');
        return verdict === 'ALLOWED';
    }

    function snapshot() {
        const list = ArrayList.$new();
        try {
            const raw = File.readAllText(SNAPSHOT);
            if (raw.length > 4096) return list;
            const s = JSON.parse(raw), now = Number(Clock.elapsedRealtime());
            if (s.schema !== 1 || s.status !== 'ready' || s.bootId !== boot
                    || !Number.isSafeInteger(s.elapsedRealtimeMs) || s.elapsedRealtimeMs < 0
                    || now < s.elapsedRealtimeMs || now - s.elapsedRealtimeMs >= 60000
                    || !Array.isArray(s.cells) || s.cells.length !== 1) return list;
            const c = s.cells[0];
            if (c.radioType !== 'lte' || !/^[1-9][0-9]{2}$/.test(c.mcc)
                    || !/^[0-9]{2,3}$/.test(c.mnc) || c.registered !== true
                    || !Number.isInteger(c.area) || c.area < 1 || c.area >= 65534
                    || !Number.isInteger(c.cellId) || c.cellId < 1 || c.cellId > 268435454
                    || c.cellId === 65535
                    || (c.pci !== undefined && (!Number.isInteger(c.pci) || c.pci < 0 || c.pci > 503))
                    || (c.dbm !== undefined && (!Number.isInteger(c.dbm) || c.dbm < -140 || c.dbm > -44))) return list;
            const id = Identity.$new(Number(c.mcc), Number(c.mnc), c.cellId,
                    c.pci === undefined ? UNKNOWN : c.pci, c.area);
            // The legacy constructor converts MNC to int; preserve two/three digits.
            const base = Java.cast(id, BaseIdentity);
            base.mMccStr.value = c.mcc;
            base.mMncStr.value = c.mnc;
            const strength = Strength.$new(UNKNOWN, c.dbm === undefined ? UNKNOWN : c.dbm,
                    UNKNOWN, UNKNOWN, UNKNOWN, UNKNOWN);
            const info = Info.$new();
            info.setCellIdentity(id);
            info.setCellSignalStrength(strength);
            info.setRegistered(true);
            info.setTimeStamp(s.elapsedRealtimeMs * 1000000);
            info.setCellConnectionStatus(1);
            list.add(info);
        } catch (e) { send({event: 'sample-error', error: String(e)}); }
        return list;
    }

    get.implementation = function (pkg, feature) {
        if (!enabled(pkg)) return get.call(this, pkg, feature);
        const list = permitted(this, pkg, feature, 'getAllCellInfo') ? snapshot() : ArrayList.$new();
        send({event: 'get', count: list.size()});
        return list;
    };
    installed.push(get);
    request.implementation = function (sub, callback, pkg, feature) {
        if (!enabled(pkg) || callback === null) return request.call(this, sub, callback, pkg, feature);
        const list = permitted(this, pkg, feature, 'requestCellInfoUpdate') ? snapshot() : ArrayList.$new();
        callback.onCellInfo(list);
        send({event: 'request', count: list.size()});
    };
    installed.push(request);
    ready = true;
    send({event: 'ready', target: PROBE, lifetimeSeconds: 180});
});

rpc.exports = {restore};

USB modem cells -> Android Telephony: bounded research prototype
================================================================

Status (2026-10-21)
-------------------
Native Binder integration works on the F515 Android 11/arm64 head unit.
An ordinary app receives a real Huawei E3272 LTE CellInfoLte through both
getAllCellInfo() and requestCellInfoUpdate(). Effective location AppOps denial
returns no cells; restoring access restores the result. Samples expire after
60 seconds of elapsedRealtime (including suspend) and cannot cross a reboot.

Navigator 31.1.3 (739706920) was then tested directly. The local feature adapter
was ready before Application existed; its feature query stack identifies the
real com.yandex.runtime.sensors.internal.telephony.TelephonySubscription.
The phone Binder recorded requests from Navigator's UID with counts 1 -> 0 -> 1:
fresh cell, expired sample, refreshed cell. Navigator remained in the SAME
process throughout that sequence. Its queries continued about every 90 seconds.
This establishes client delivery and recovery, not improved positioning.

This is NOT integrated into the released WWAN APK or boot service. The current
collector is an explicit single scan while other AT users are quiescent. The
native adapters revert after five minutes or an explicit stop. Nothing starts
automatically. No GPS coordinates are calculated or injected.

Files
-----
CellObservation/HuaweiCellParser/CellSnapshot: pure Java input validation and
snapshot model. No CEREG-only identity: some Huawei firmware truncates it.
CellCollector: root-only, read-only AT scan through the selected control port.
It refuses a live icon poller or WWAN bring-up, never guesses the PPP port,
and writes atomically as root:radio 0640. Its output directory must be created
as root:radio 0750. Raw cell identities must not be copied to normal logs.

CellRuntimeBridge: loaded in com.android.phone and, separately, the client.
The phone adapter replaces the registered phone Binder inside its ORIGINAL
process. Unmodified calls delegate to the original LOCAL Binder on the same
thread; the calling UID is preserved. It never forwards through a root proxy.
Only the probe and Navigator packages are allowed to request the extra cells.
checkPackage and Android LocationAccessPolicy enforce caller identity,
location permission, AppOps, location setting and Android user checks.

The client adapter changes IPackageManager only in that client's process,
for hasSystemFeature("android.hardware.telephony", 0). It also clears the
local feature cache on start/stop. No feature is added in system_server.
This matters because the tested Navigator skips TelephonySubscription
entirely when the feature is missing. Installing the adapter after that
constructor ran does not revive an existing subscription.
The native loader also supports an early start before Application exists.
The test used a short-lived PID watcher; it observed preparation 6.8 seconds
before Navigator's feature query. That observation is not a guaranteed startup
ordering for a product. Debugger-wait cannot be used to enforce ordering on
this production firmware: ro.debuggable=0 and its non-debuggable apps cannot
load the JDWP agent, so waitForDebugger returns without actually waiting.

native-bridge.c: embeds DEX in a .so, attaches a JNI worker, installs/removes
the Java adapters. No ART method patching and no Frida dependency.
injector.c and art-symbol.h: adapted from the existing F515 Maps native loader
(repo-f515-maps-speedup-native-clean/native/{injector.c,probe.c}). The loader
is Android arm64 specific; private Android 11 APIs are capability-checked.

telephony-probe.src.js/build-probe-agent.sh: the earlier, bounded Frida
experiment for the probe app only. This is research history, not a dependency
of build-native.sh and not a released app asset. It was detached before the
native test; no Frida agent remained in com.android.phone afterwards.

Build/check locally
-------------------
  bash tests/test-cells.sh
  bash cells/build-native.sh
  bash tests/android/build.sh

Requires JDK 11, Android 11 android.jar, d8 and NDK r27d. Environment overrides
are listed in the build scripts. Artifacts stay under ignored build folders.

Explicit on-device use (only in a controlled test)
------------------------------------------------
The collector does NOT stop another AT user for you. Obtain exclusive access
first and restore the user's icon state even if collection fails. Do not kill
PPP, send configuration-changing AT commands or access its data port.

  CLASSPATH=/path/cell-collector.jar app_process /system/bin CellCollector \
      /data/local/tmp/wwan /dev/ttyUSB1 /dev/wwan-cell-probe/cell.json

The selected control port must match state/at-tty; ttyUSB1 is the tested unit,
not a portable default. Verify the current PID/package before every injection.
Keep the injector root-only. The target must be able to traverse the library
directory and read the .so; snapshots must remain inaccessible to normal apps.

  native-inject PHONE_PID /absolute/libwwan_cells.so wwan_cells_start 0
  native-inject CLIENT_PID /absolute/libwwan_cells.so wwan_cells_start 0
  native-inject CLIENT_PID /absolute/libwwan_cells.so wwan_cells_stop 0
  native-inject PHONE_PID /absolute/libwwan_cells.so wwan_cells_stop 0

Entry return 0 means worker started, not installation succeeded: verify
WwanCells logs and real client results. Do not overwrite a .so that is mapped
in a running process; use a distinct filename for a new test build. A stopped
library remains mapped but its adapters are inactive. A reboot is not needed.

Evidence and remaining work
---------------------------
tests/telephony-results.json records sanitized outcomes and tested artifact
hashes. Private modem transcripts, app reports and Android sources remain in
ignored tests/results/lbs-20261021; they are not APK assets or release files.

Still required before any product release:
* The real Navigator subscription and callback delivery are now confirmed.
  Native MapKit processing follows the inspected callback code; the JNI call
  and any server-side use were not instrumented directly.
* Arrange feature readiness before that subscription is constructed. An
  arbitrary delayed injection is a startup race and is not a solution.
* Collect continuously using one coordinated AT owner/lock shared with icon,
  modem bring-up and SMS. Do not repeatedly stop the icon as production logic.
* Implement opt-in lifecycle, source loss/disable, sleep and process restart
  handling; replace the experimental five-minute adapter only after testing.
* Validate additional modems/RATs and firmware capabilities. Live results here
  cover Huawei E3272 LTE only. The parser's GSM/WCDMA fixtures do not establish
  Android delivery support for those radio types; the current adapter is LTE.
* Verify effects on location accuracy/time to fix with repeatable measurements.
  Delivering raw cells is not a promise of a network location fix from Yandex.

The direct Navigator test was followed by explicit adapter stop and a normal
Navigator launch. system_server and com.android.phone kept their original PIDs;
PPP was not stopped, the icon poller was restored, and debug-app settings were
cleared. An external-storage warning appeared exactly 328 times in BOTH the
instrumented and normal startup, so it is not specific to this adapter. No
Navigator crash or cell-request exception was found in the captured windows.
See tests/navigator-telephony-results.json for times, hashes and evidence paths.

USB modem cells -> Android Telephony (LBS)
=========================================

Included in WWAN 4.16, developed in feat/lbs-cell-source.
Tested target: F515, Android 11 arm64; Navigator 31.1.3 (739706920), Huawei E3272 LTE.
This passes real serving-cell information to Navigator. It does not calculate or
inject coordinates and does not establish improved accuracy or faster first fix.

Preference and startup
----------------------
The WWAN app has an "LBS" control; default is ON. The persistent preference
is state/cells. An absent preference is initialized atomically; an explicit OFF
is preserved across upgrades. When enabled, wwan-cells.sh starts one root app_process coordinator.
The existing WWAN boot watchdog starts/checks it as part of modem autostart.
No foreground Navigator launch, force-stop, MapKit reset or private Yandex method
hook is part of the payload. An already running Navigator which skipped telephony
may need its next ordinary process start; the user handles that. No extra prompt.
The earlier public MapKit onStop/onStart experiment was not reliable on repeated
late attachment and was removed, as requested.

Order: verify Toolbox system guard/app-scale markers against the CURRENT
system_server PID and enabled settings -> install phone Binder adapter -> verify
its private handshake -> install the process-local Navigator feature adapter ->
observe a real Navigator request. Successful dlopen is never treated as ready.
The coordinator reports waiting states separately from "subscribed". A source may
still be absent: empty successful cell callbacks keep Navigator's retry loop alive.
PID observation is asynchronous; if Navigator constructs its subscription first,
we do not pretend it is subscribed or restart it automatically.

The phone and client adapters require a fresh tmpfs lease (15 seconds, measured
with elapsedRealtime) with the same boot and build ID. Missing/expired/mismatched
lease stops delivery immediately. A five-second awake-time grace lets the coordinator
recover after suspend, returning empty cells meanwhile, then restores the original
delegates. Explicit disable/update skips that grace. The source has its own 60-second TTL,
including suspend, and cannot cross a reboot. Process death is detected and the
new phone must acknowledge readiness before clients are prepared again. A client
whose own retry loop has already stopped may need its next ordinary start.

Only one coordinator holds daemon.lock. Native libraries are copied under their
SHA-256 names and never overwritten in place while mapped. APK payload deployment
uses SHA-256 verification and atomic replacement, pauses the coordinator during
changes and restarts the icon poller when its bytecode changes. An incomplete
update remains paused. Build IDs prevent mixed native/Java adapters from working
together. Tests have not yet included a physical ignition sleep/cold boot cycle.

Sources and AT coordination
---------------------------
AT uses ONLY the selected state/at-tty, never a guessed PPP data port. Huawei
SYSINFOEX, CECELLID, LOCINFO and HCSQ are read-only, bracketed to reject handovers or
inconsistent/truncated identities. No registration-mode commands are sent.
Cell scans normally start about every 30 seconds; a busy port retries after 3 s.
A busy scan does not refresh the age of the preceding sample.

at-lock.sh locks by character-device major/minor (aliases share one lock). at.sh,
WWAN bring-up, icon polling and complete SMS transactions all participate. PPP's
data port is separate and the active PPP session is not restarted for cell scans.
The icon can keep its last signal for at most 60 seconds while another reader owns
the port. Android mksh CLOSES fd 8 on exec unless 8>&8 is explicitly inherited;
this was caught on-device and has a dedicated regression test. A surviving bounded
transaction retains the lock even when its wrapper dies. This lock coordinates
our readers; unmodified external AT tools do not automatically participate.

HTTP-only Huawei HiLink and ZTE use their read-only APIs. Requests bind to the
validated USB modem interface and its directly attached private IPv4 gateway,
ignore proxy environment settings, do not follow redirects and have size/time
limits. Huawei session/token support uses SesTokInfo without password guessing.
Unsupported signal endpoints fall back to the other supported endpoints. Missing
full cell identity is "http-cell-unsupported", not a fabricated cell from bars or
operator names. Authentication errors are distinct. ZTE cell_id AND lac_code are
hex even when digit-only; MNC leading zeros/length are preserved. Two consistent
identity readings are required. Unknown radio technologies fail closed.
The Android adapter currently delivers LTE only. GSM/WCDMA parsing is not a claim
of Android delivery support. No real HiLink/ZTE modem was available for end-to-end
HTTP testing: schemas, fallback/error handling and interface refusal have fixtures.

Android integration and data protection
---------------------------------------
Native .so embeds DEX and installs a Binder wrapper INSIDE com.android.phone.
Unmodified calls delegate to the original LOCAL Binder on the same thread; real
caller UID/PID is preserved. Only Navigator and the temporary test probe can obtain
extra cells. checkPackage plus Android LocationAccessPolicy enforce permissions,
AppOps, location setting and user checks. A private status transaction is root-only;
client acknowledgements are authenticated by Binder UID. Raw cells stay in
/dev/wwan-cells/private/cell.json, root:radio 0640, directory 0750. Status contains
counts/phase, never raw cell identities. All recurring writes are on tmpfs.

Navigator's process-local PackageManager proxy reports generic telephony support
and clears its local feature cache. No global feature/SIM capability is added;
system_server is not injected or edited. No ART patch or Frida runtime is used.
Android hidden APIs and native arm64 injection remain platform-specific.

Build and checks
----------------
  bash tests/test-cells.sh
  python3 tests/test-at-lock.py
  bash cells/build-native.sh
  bash app/build.sh

JDK 11, Android 11 android.jar, d8 and NDK r27d; overrides are in build scripts.
App signing uses the existing project key. Never create another release identity.
Build outputs and private HU observations remain ignored, not release assets.

On the HU (root; default WWAN directory):
  sh /data/local/tmp/wwan/wwan-cells.sh enable|disable|status|auto
  sh /data/local/tmp/wwan/wwan-cells.sh pause|resume    # payload update only
  CLASSPATH=/data/local/tmp/wwan/cell-collector.jar app_process /system/bin CellProtocol

The harmless Android lock test uses /dev/null only:
  sh test-at-lock-device.sh /data/local/tmp/wwan/at-lock.sh

Evidence
--------
tests/telephony-results.json and tests/navigator-telephony-results.json record the
initial native/probe and Navigator tests. tests/coordinator-results.json records
the coordinated collector and lifecycle validation. No raw cell IDs in tracked
reports. Private details are under tests/results/lbs-20261021 (ignored).
Earlier research JS remains source history only; no Frida assets are packaged.

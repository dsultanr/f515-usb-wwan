#!/usr/bin/env python3
"""Network-state fixtures: no root, device, network, or emulator access."""
import copy
import json
import os
import pathlib
import subprocess
import tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
UP = (ROOT / 'scripts/wwan-up.sh').read_text()
BOOT = (ROOT / 'scripts/wwan-boot.sh').read_text()


def function(source, name):
    start = source.index(name + '() {')
    line_end = source.index('\n', start)
    if source[start:line_end].rstrip().endswith('}'):
        return source[start:line_end] + '\n'
    return source[start:source.index('\n}\n', start) + 3]


GOOD = {
    'addr': '192.168.0.178', 'index': '7', 'tbox_addr': '192.168.72.4',
    'routes': {
        '99': ['default via 192.168.0.1 dev eth1 metric 10'],
        'main': ['default via 192.168.0.1 dev eth1 metric 20',
                 'default via 10.0.0.1 dev wlan0 metric 10'],
        'vlan72': ['default via 192.168.0.1 dev eth1 metric 5'],
    },
    'nat': ['udp', 'tcp', 'eth1', 'tun+'], 'native_dns': False, 'vendor': False,
}

FAKE = r'''#!/usr/bin/python3
import json, os, pathlib, sys
state = pathlib.Path(os.environ['FIXTURE'])
s = json.loads(state.read_text()); a = sys.argv[1:]; name = pathlib.Path(sys.argv[0]).name
with pathlib.Path(os.environ['CALLS']).open('a') as out:
    out.write(name + ' ' + ' '.join(a) + '\n')
if name == 'cat':
    if a == ['/sys/class/net/eth1/ifindex']: print(s['index']); sys.exit(0)
    os.execv('/bin/cat', ['cat'] + a)
if name == 'ip':
    if a[:4] == ['-4', '-o', 'addr', 'show']:
        ip = s['addr'] if a[4] == 'eth1' else s['tbox_addr']
        if ip: print('7: %s inet %s/24 scope global' % (a[4], ip))
    elif a[:4] == ['route', 'show', 'table', 'all']:
        for routes in s['routes'].values(): print('\n'.join(routes))
    elif a[:3] == ['route', 'show', 'table']:
        print('\n'.join(s['routes'].get(a[3], [])))
    elif a[:3] == ['route', 'replace', 'default'] and os.environ.get('ALLOW_ROUTE_CHANGE') == '1':
        table = a[a.index('table')+1]; metric = a[a.index('metric')+1]
        route = a[2:]; t = route.index('table'); del route[t:t+2]
        s['routes'][table] = [r for r in s['routes'][table] if not r.endswith('metric ' + metric)]
        s['routes'][table].append(' '.join(route)); state.write_text(json.dumps(s))
    else: sys.exit('Unexpected ip mutation/call: ' + str(a))
elif name == 'iptables':
    if '-S' in a:
        if 'udp' in s['nat']:
            print('-A OUTPUT -d 192.168.72.1/32 -p udp -m udp --dport 53 -j DNAT --to-destination '+s.get('first_dns', '192.168.0.1')+':53')
    elif '-C' in a:
        kind = a[a.index('-p')+1] if '-p' in a else a[a.index('-o')+1]
        target_ok = '--to-destination' not in a or a[a.index('--to-destination')+1] == '192.168.0.1:53'
        sys.exit(0 if kind in s['nat'] and target_ok else 1)
    else: sys.exit('Unexpected iptables mutation: ' + str(a))
elif name == 'dumpsys':
    print('type: Tbox InterfaceName: vlan72 DnsAddresses: [ /192.168.72.1 ]')
elif name == 'native-dns': sys.exit(0 if s['native_dns'] else 1)
elif name == 'vendor':
    if s['vendor']: print('9999')
else: sys.exit('Unexpected command: ' + name)
'''

checks = 0
with tempfile.TemporaryDirectory(prefix='wwan-resume-') as tmp:
    tmp = pathlib.Path(tmp); bin_dir = tmp / 'bin'; bin_dir.mkdir()
    fake = bin_dir / 'fake'; fake.write_text(FAKE); fake.chmod(0o755)
    for name in ('ip', 'iptables', 'dumpsys', 'cat', 'native-dns', 'vendor'):
        (bin_dir / name).symlink_to(fake)
    state = tmp / 'state'; state.mkdir(); (state / 'wan-iface').write_text('eth1\n')
    (state / 'system-uplink').write_text('eth1 7 192.168.0.178 192.168.0.1 192.168.0.1\n')
    fixture = tmp / 'network.json'; calls = tmp / 'calls'
    env = dict(os.environ, PATH=str(bin_dir) + ':' + os.environ['PATH'],
               FIXTURE=str(fixture), CALLS=str(calls), TEST_STATE=str(state))
    helpers = '\n'.join(function(UP, n) for n in
                        ('iface_addr', 'is_ipv4', 'dns_pick', 'tbox_net',
                         'dns_nat_active', 'default_matches', 'system_health'))
    health = tmp / 'health.sh'
    health.write_text('''#!/bin/sh
STATE=$TEST_STATE
CHECK_ONLY=1
TABLE=99
VPN_MODE=${TEST_VPN:-0}
DNS_WANT=${TEST_DNS:-auto}
DNS_AUTO_LAST=$STATE/dns-auto
find_hilink_iface() { HILINK_IF=eth1; }
dns_answers() { native-dns; }
vpn_vendor_prefs() { vendor; }
warn() { echo "$*"; }
''' + helpers + '\nsystem_health\n')

    def run_health(s, expected, extra=None):
        global checks
        fixture.write_text(json.dumps(s)); calls.write_text('')
        r = subprocess.run(['sh', str(health)], env=dict(env, **(extra or {})),
                           text=True, capture_output=True, timeout=5)
        assert r.returncode == expected, (r.returncode, r.stdout, r.stderr, s)
        assert not (state / 'dns-auto').exists(), 'read-only check wrote DNS state'
        checks += 1

    run_health(GOOD, 0)
    for table in ('99', 'main', 'vlan72'):
        bad = copy.deepcopy(GOOD); bad['routes'][table] = []; run_health(bad, 1)
    for suffix in ('linkdown', 'dead'):
        bad = copy.deepcopy(GOOD); bad['routes']['main'][0] += ' ' + suffix; run_health(bad, 1)
    for old, new in [('192.168.0.1', '192.168.0.254'), ('metric 20', 'metric 30')]:
        bad = copy.deepcopy(GOOD); bad['routes']['main'][0] = bad['routes']['main'][0].replace(old, new)
        run_health(bad, 1)
    for rule in GOOD['nat']:
        bad = copy.deepcopy(GOOD); bad['nat'].remove(rule); run_health(bad, 1)
    bad = copy.deepcopy(GOOD); bad['first_dns'] = '192.168.1.1'; run_health(bad, 1)
    for key, value in [('index', '8'), ('addr', '192.168.1.178'), ('tbox_addr', '')]:
        bad = copy.deepcopy(GOOD); bad[key] = value; run_health(bad, 1)
    bad = copy.deepcopy(GOOD); bad['nat'] = []; bad['native_dns'] = True
    run_health(bad, 0)
    run_health(bad, 1, {'TEST_DNS': '1.1.1.1'})
    bad = copy.deepcopy(GOOD); bad['vendor'] = True; run_health(bad, 1, {'TEST_VPN': '1'})
    bad = copy.deepcopy(GOOD)
    bad['routes']['vlan72'].append('default via 192.168.72.1 dev vlan72')
    run_health(bad, 1, {'TEST_VPN': '1'})
    saved = (state / 'system-uplink').read_text(); (state / 'system-uplink').unlink()
    run_health(GOOD, 1); (state / 'system-uplink').write_text(saved)

    # Execute the real watchdog loop with synthetic time and network state. A
    # direct modem ping ALWAYS succeeds, exactly the previously missed failure.
    # Only bring_up is replaced: it models the UI --system reapplication and
    # records any request to reset the modem. Normal checks/branching are real.
    loop = BOOT[BOOT.index('soft_fails=0\nwhile :; do'):]
    repair = tmp / 'repair.py'
    repair.write_text('import json,os,pathlib\npathlib.Path(os.environ["FIXTURE"]).write_text(' + repr(json.dumps(GOOD)) + ')\n')
    mutate = tmp / 'mutate.py'
    mutate.write_text('import json,os,pathlib\np=pathlib.Path(os.environ["FIXTURE"])\ns=json.loads(p.read_text()); s["nat"]=[]; p.write_text(json.dumps(s))\n')
    for scenario, initial, wake, delayed, expected_repairs in [
        ('healthy', GOOD, 0, 0, 0),
        ('wake', GOOD, 1, 0, 1),
        ('lost-dns-with-good-ping', dict(GOOD, nat=[]), 0, 0, 1),
        ('late-netd-reset', GOOD, 1, 1, 2),
    ]:
        fixture.write_text(json.dumps(initial)); (tmp/'repairs').write_text('')
        harness = tmp / 'watchdog.sh'
        harness.write_text('''#!/bin/sh
DIR=$TEST_DIR
UP=$TEST_UP
STATE=$TEST_STATE
PIDFILE=$STATE/watchdog.pid
echo $$ >"$PIDFILE"
DISABLED=$STATE/disabled
IF=eth1
LOG_FILES=
CHECK_HOST=77.88.8.8
RESTARTS=$STATE/restarts
MAX_RESTARTS_PER_HOUR=4
COOLDOWN=0
count=0
log() { echo "$*"; }
log_trim() { :; }
wan_iface() { echo eth1; }
iface_addr() { echo 192.168.0.178; }
timeout() { return 0; }
watch_sleep() {
    count=$((count + 1))
    [ "$count" -le 3 ] || exit 0
    WAKE_DETECTED=0
    if [ "$count" = 1 ]; then WAKE_DETECTED=$TEST_WAKE; fi
    if [ "$count" = 2 ] && [ "$TEST_DELAYED" = 1 ]; then python3 "$TEST_DIR/mutate.py"; fi
}
bring_up() {
    echo "normal $*" >>"$TEST_DIR/repairs"
    python3 "$TEST_DIR/repair.py"
}
''' + loop)
        r = subprocess.run(['sh', str(harness)], capture_output=True,text=True,timeout=10,
                           env=dict(env, TEST_DIR=str(tmp), TEST_UP=str(health),
                                    TEST_WAKE=str(wake), TEST_DELAYED=str(delayed)))
        repairs = (tmp / 'repairs').read_text().splitlines()
        assert r.returncode == 0 and len(repairs) == expected_repairs, (scenario, repairs, r.stdout, r.stderr)
        assert all(line.strip() == 'normal' for line in repairs), 'modem reset requested'
        checks += 1

    # The actual HiLink branch preserves an existing address on ordinary setup:
    # no link down/up, DHCP, AT or reboot, including when routes need refreshing.
    fixture.write_text(json.dumps(GOOD)); calls.write_text('')
    hilink = UP[UP.index('if [ "$MODE" = hilink ]; then', UP.index('# ================================================================ HILINK')):
                UP.index('# =================================================================== PPP')]
    script = tmp / 'hilink.sh'
    script.write_text('''#!/bin/sh
MODE=hilink
HILINK_IF=eth1
DO_RECONNECT=0
CHECK_ONLY=0
GW=
stage() { :; }
skip() { :; }
ok() { :; }
say() { :; }
warn() { :; }
have() { return 1; }
''' + function(UP, 'iface_addr') + hilink + '\n[ "$ADDR" = 192.168.0.178 ] && [ "$GW" = 192.168.0.1 ]\n')
    r = subprocess.run(['sh', str(script)], env=env, capture_output=True,text=True,timeout=5)
    assert r.returncode == 0, (r.stdout,r.stderr)
    assert all(line.startswith(('ip -4 -o addr show ', 'ip route show table ')) for line in calls.read_text().splitlines())
    checks += 1

    # Execute the real main-route setup too: retain healthy Wi-Fi and foreign
    # routes, repair our missing/stale gateway, leave a healthy route untouched.
    start = UP.index('\t_cur=$(ip route show table main', UP.index('# ------------------------------------------------- опционально: приложения'))
    end = UP.index('\n\t# ...но модем в main', start)
    main = tmp / 'main.sh'
    main.write_text('''#!/bin/sh
WAN_IF=eth1
GW=192.168.0.1
MODE=hilink
WIFI_METRIC=10
do_it() { "$@"; }
skip() { :; }
warn() { :; }
ok() { :; }
''' + function(UP, 'default_matches') + function(UP, 'add_default') + UP[start:end])
    for name, routes, should_replace in [
        ('healthy', GOOD['routes']['main'], False),
        ('missing', [GOOD['routes']['main'][1]], True),
        ('wrong-gateway', [GOOD['routes']['main'][0].replace('192.168.0.1', '192.168.0.254'), GOOD['routes']['main'][1]], True),
        ('foreign', ['default via 172.16.0.1 dev eth9 metric 20'], False),
    ]:
        s = copy.deepcopy(GOOD); s['routes']['main'] = routes
        fixture.write_text(json.dumps(s)); calls.write_text('')
        r = subprocess.run(['sh',str(main)],env=dict(env, ALLOW_ROUTE_CHANGE='1'),capture_output=True,text=True,timeout=5)
        assert r.returncode == 0, (name,r.stdout,r.stderr)
        assert ('ip route replace ' in calls.read_text()) == should_replace, (name,calls.read_text())
        after = json.loads(fixture.read_text())['routes']['main']
        if should_replace:
            assert GOOD['routes']['main'][0] in after and GOOD['routes']['main'][1] in after
        else: assert after == routes
        checks += 1

    # Shared exact-route helper still supports point-to-point PPP defaults.
    s = copy.deepcopy(GOOD); s['routes']['main'] = ['default dev ppp0 metric 20']
    fixture.write_text(json.dumps(s))
    r = subprocess.run(['sh','-c', 'WAN_IF=ppp0; GW=; '+function(UP,'default_matches')+'\ndefault_matches main 20'],
                       env=env,capture_output=True,text=True,timeout=5)
    assert r.returncode == 0, (r.stdout,r.stderr)
    checks += 1

print('HiLink resume: %d network-state, watchdog and no-reset checks passed' % checks)

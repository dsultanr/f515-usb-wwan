import os, pty, select, subprocess, tempfile, threading, time, pathlib, signal
root=pathlib.Path(__file__).resolve().parent.parent
with tempfile.TemporaryDirectory() as d:
 master,slave=pty.openpty(); port=os.ttyname(slave); alias=d+'/alias'; os.symlink(port,alias)
 # Android's sh supports read -t; use bash as its host equivalent for the SMS test.
 shim=pathlib.Path(d)/'bin';shim.mkdir();(shim/'sh').write_text('#!/bin/bash\nexec /bin/bash "$@"\n');(shim/'sh').chmod(0o755)
 env=dict(os.environ, WWAN_AT_LOCK_DIR=d+'/locks', AT_READ_SECONDS='1', PATH=str(shim)+':'+os.environ['PATH']); seen=[]; done=False
 def modem():
  buf=b''
  while not done:
   if select.select([master],[],[],.1)[0]:
    try: buf+=os.read(master,4096)
    except OSError: continue
    while b'\r' in buf:
     cmd,buf=buf.split(b'\r',1); seen.append(cmd.decode()); os.write(master,b'\r\nVALUE:'+cmd+b'\r\nOK\r\n')
 threading.Thread(target=modem,daemon=True).start()
 def at(p,*cmds,**kw): return subprocess.Popen(['sh',str(root/'scripts/at.sh'),p,*cmds],env=env,stdout=subprocess.PIPE,stderr=subprocess.PIPE,**kw)
 a=at(port,'AT+A1','AT+A2'); time.sleep(.2); b=at(alias,'AT+B1','AT+B2')
 ao=a.communicate(timeout=15); bo=b.communicate(timeout=15)
 assert a.returncode==b.returncode==0,(ao,bo)
 assert seen==['AT+A1','AT+A2','AT+B1','AT+B2'],seen
 assert b'AT+B' not in ao[0] and b'AT+A' not in bo[0],(ao,bo)
 lock=['sh',str(root/'scripts/at-lock.sh'),port]
 held=subprocess.Popen(lock+['0','sleep','5'],env=env)
 time.sleep(.2)
 t=time.monotonic(); busy=subprocess.run(lock+['0','true'],env=env,capture_output=True)
 assert busy.returncode==75 and b'WWAN_AT_BUSY' in busy.stderr
 assert time.monotonic()-t<1
 held.terminate(); held.wait()
 assert subprocess.run(lock+['1','true'],env=env).returncode==0
 # Different device is independent.
 held=subprocess.Popen(lock+['0','sleep','5'],env=env);time.sleep(.2)
 assert subprocess.run(['sh',str(root/'scripts/at-lock.sh'),'/dev/null','0','true'],env=env).returncode==0
 held.terminate();held.wait()
 # A whole SMS transaction is indivisible relative to a signal/cell scan.
 seen.clear()
 a=at(port,'AT+C1','AT+C2');time.sleep(.2)
 sms=subprocess.Popen(['bash',str(root/'scripts/sms.sh'),'list'],env=dict(env,WWAN_CTRL_TTY=alias),stdout=subprocess.PIPE,stderr=subprocess.PIPE)
 ao=a.communicate(timeout=15);so=sms.communicate(timeout=20)
 assert a.returncode==sms.returncode==0,(ao,so)
 assert seen[:2]==['AT+C1','AT+C2'] and seen[2:]==['AT','AT+CPMS="SM","SM","SM"','AT+CMGF=0','AT+CMGL=4','AT+CPMS="ME","ME","ME"','AT+CMGF=0','AT+CMGL=4'],seen
 # Bring-up callers suppress command markers but keep replies.
 plain=subprocess.run(['sh',str(root/'scripts/at.sh'),port,'AT+RAW'],env=dict(env,AT_COMMAND_MARKERS='0'),capture_output=True,timeout=10)
 assert plain.returncode==0 and b'> ' not in plain.stdout and b'VALUE:AT+RAW' in plain.stdout
 done=True;os.close(master);os.close(slave)
 print('AT: grouped exchanges, no response stealing, alias exclusion, busy exit, release after death, independent ports, complete SMS transaction, raw bring-up output passed')

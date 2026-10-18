#!/usr/bin/env python3
"""Isolated IPC fixture: no keyboard, mouse, display or power APIs."""
import os,socket,sys,threading,time
settings=sys.argv[sys.argv.index('--settings')+1]
profile=os.path.abspath(os.path.join(os.path.dirname(settings),'../..'))
trace=os.path.join(profile,'launches')
with open(trace,'a') as file:file.write(str(os.getpid())+'\n')
path=os.path.join(profile,'socket')
if os.path.exists(path):os.unlink(path)
server=socket.socket(socket.AF_UNIX,socket.SOCK_STREAM);server.bind(path);server.listen(1)
client,_=server.accept();reader=client.makefile('rb')
def connection_output():
 failing=False
 while True:
  active=os.path.exists(trace+'.linkfail')
  if active: print('[fixture] WARNING: failed to connect to server: Timed out',flush=True)
  elif failing: print('[fixture] INFO: connected to secure socket',flush=True);client.sendall(b'connectionState=Connected\n')
  failing=active
  time.sleep(.1)
threading.Thread(target=connection_output,daemon=True).start()
for data in reader:
 line=data.decode().strip()
 if os.path.exists(trace+'.crash'):sys.exit(23)
 if line.startswith('hello='):client.sendall(b'hello=fixture\n' + (b'connectionState=Disconnected\n' if os.path.exists(trace+'.linkfail') else b'connectionState=Connected\n'))
 if os.path.exists(trace+'.hold'):continue
 if line.startswith('ping='):
  open(trace+'.probing','w').close()
  if os.path.exists(trace+'.slowping'):time.sleep(.4)
  client.sendall(('pong='+line[5:]+'\n').encode())
 if line=='stop':
  open(trace+'.stopping','w').close()
  if os.path.exists(trace+'.slowstop'):time.sleep(.5)
  sys.exit(0)

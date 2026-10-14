#!/usr/bin/env python3
"""Isolated IPC fixture: no keyboard, mouse, display or power APIs."""
import os,socket,sys
settings=sys.argv[sys.argv.index('--settings')+1]
profile=os.path.abspath(os.path.join(os.path.dirname(settings),'../..'))
trace=os.path.join(profile,'launches')
with open(trace,'a') as file:file.write(str(os.getpid())+'\n')
path=os.path.join(profile,'socket')
if os.path.exists(path):os.unlink(path)
server=socket.socket(socket.AF_UNIX,socket.SOCK_STREAM);server.bind(path);server.listen(1)
client,_=server.accept();reader=client.makefile('rb')
for data in reader:
 line=data.decode().strip()
 if os.path.exists(trace+'.crash'):sys.exit(23)
 if line.startswith('hello='):client.sendall(b'hello=fixture\nconnectionState=Connected\n')
 if os.path.exists(trace+'.hold'):continue
 if line.startswith('ping='):client.sendall(('pong='+line[5:]+'\n').encode())
 if line=='stop':sys.exit(0)

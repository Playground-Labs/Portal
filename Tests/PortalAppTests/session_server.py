"""Local wire peer for final-frame delivery and an interrupted/restarted server."""
import socket, struct, sys, time
mode = sys.argv[1]
listener = socket.socket()
listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
listener.bind(('127.0.0.1',0))
port = listener.getsockname()[1]
listener.listen(1)
print(port,flush=True)
def connection(listener, color):
    peer,_=listener.accept()
    peer.settimeout(15)
    def take(n):
        data=b''
        while len(data)<n:
            chunk=peer.recv(n-len(data))
            if not chunk: raise EOFError()
            data+=chunk
        return data
    peer.sendall(b'RFB 003.008\n'); take(12)
    peer.sendall(b'\x01\x01'); take(1)
    peer.sendall(b'\0'*4); take(1)
    fmt=struct.pack('!BBBBHHHBBBxxx',32,24,0,1,255,255,255,0,8,16)
    peer.sendall(struct.pack('!HH',4,2)+fmt+struct.pack('!I',4)+b'Test')
    sent=False
    key_downs=key_ups=0
    try:
        while True:
            kind=take(1)[0]
            if kind==0: take(19)
            elif kind==2:
                _,n=struct.unpack('!BH',take(3)); encodings=struct.unpack('!'+str(n)+'i',take(n*4))
                if mode=='cursor': assert -239 in encodings
            elif kind==3:
                take(9)
                if not sent and mode != 'idle':
                    time.sleep(0.25)
                    header=struct.pack('!BBHHHHHi',0,0,1,0,0,4,2,0)
                    if mode=='pipeline':
                        peer.sendall(header[:4])
                        peer.settimeout(0.3)
                        try:
                            assert take(1)==b'\x03'
                            assert take(9)[0]==1
                            color=[0,255,0,0]
                        except socket.timeout: pass
                        peer.settimeout(15)
                        peer.sendall(header[4:]+bytes(color)*8)
                    else: peer.sendall(header+bytes(color)*8)
                    if mode=='burst':
                        peer.sendall(header+bytes([0,255,0,0])*8)
                    if mode=='cursor':
                        cursor=struct.pack('!BBHHHHHi',0,0,1,1,0,2,1,-239)
                        peer.sendall(cursor+bytes([255,0,0,0,0,255,0,0])+b'\x80')
                    sent=True
                    if mode=='reconnect' and color[0]==255:
                        time.sleep(0.3); break
            elif kind==4:
                key = take(7)
                if mode=='key-count':
                    if key[0]: key_downs+=1
                    else: key_ups+=1
                    peer.sendall(struct.pack('!BBHHHHHi',0,0,1,0,0,4,2,0)+bytes([key_downs,key_ups,0,0])*8)
                if mode=='key-delay' and key[0]:
                    header=struct.pack('!BBHHHHHi',0,0,1,0,0,4,2,0)
                    peer.sendall(header+bytes([0]))
                    peer.settimeout(0.5)
                    released=False
                    try:
                        while not released:
                            message=take(1)[0]
                            if message==3: take(9)
                            elif message==4:
                                event=take(7)
                                released=event[0]==0 and event[3:]==key[3:]
                            else: raise AssertionError(message)
                    except socket.timeout: pass
                    peer.settimeout(15)
                    color=[0,255,0,0] if released else [0,0,255,0]
                    peer.sendall((bytes(color)*8)[1:])
                if mode=='cursor': peer.sendall(struct.pack('!BBHHHHHi',0,0,1,0,0,0,0,-239))
            elif kind==5: take(5)
            else: raise AssertionError(kind)
    except (EOFError,ConnectionResetError): pass
    finally: peer.close()
connection(listener,[255,0,0,0])
listener.close()
if mode=='reconnect':
    time.sleep(4.5) # The first retry must fail; a subsequent retry must recover.
    listener=socket.socket(); listener.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1)
    listener.bind(('127.0.0.1',port)); listener.listen(1)
    connection(listener,[0,255,0,0]); listener.close()

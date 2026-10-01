"""Small real RFB peer. Expected pixels, monitor positions and PCM are fixed fixtures."""
import socket, struct, sys, json

listener = socket.socket()
listener.bind(('127.0.0.1', 0))
listener.listen(1)
print(listener.getsockname()[1], flush=True)
peer, _ = listener.accept()
peer.settimeout(8)
mode = sys.argv[2] if len(sys.argv)>2 else "multi"
def take(count):
    data = b''
    while len(data) < count:
        chunk = peer.recv(count - len(data))
        if not chunk: raise EOFError()
        data += chunk
    return data
def rect(x, y, w, h, encoding, body=b''):
    return struct.pack('!HHHHi', x,y,w,h,encoding) + body
peer.sendall(b'RFB 003.008\n')
assert take(12) == b'RFB 003.008\n'
if mode == 'unsupported':
    peer.sendall(bytes([2, 129, 5]))
    assert peer.recv(1) == b''
    with open(sys.argv[1], 'w') as f: json.dump({}, f)
    peer.close(); listener.close()
    sys.exit(0)
if mode == 'auth':
    peer.sendall(b'\x01\x02')
    assert take(1) == b'\x02'
    peer.sendall(bytes(range(16)))
    assert take(16).hex() == 'ee22539f33a5983ec12f9c2edbc995dd'
else:
    peer.sendall(b'\x01\x01')
    assert take(1) == b'\x01'
peer.sendall(b'\0'*4)
assert take(1) == b'\x01'
fmt = struct.pack('!BBBBHHHBBBxxx', 32,24,0,1,255,255,255,0,8,16)
peer.sendall(struct.pack('!HH',4,2)+fmt+struct.pack('!I',7)+b'Fixture')
if mode == "ui": peer.settimeout(300)
sent = False
observed = {}
try:
    while True:
        kind = take(1)[0]
        if kind == 0: take(19)
        elif kind == 2:
            _, count = struct.unpack('!BH',take(3))
            encodings=struct.unpack('!'+'i'*count,take(count*4))
            assert -259 in encodings and -308 in encodings
        elif kind == 3:
            take(9)
            if not sent:
                screens=(struct.pack('!Bxxx',2)+struct.pack('!IHHHHI',10,0,0,2,2,0)+struct.pack('!IHHHHI',20,2,0,2,2,0)) if mode == 'multi' else struct.pack('!Bxxx',1)+struct.pack('!IHHHHI',10,0,0,4,2,0)
                pixels=bytes([255,0,0,0, 0,255,0,0, 0,0,255,0, 255,255,255,0])*2
                payload=rect(0,0,4,2,-308,screens)+rect(0,0,0,0,-259)+rect(0,0,4,2,0,pixels)
                peer.sendall(struct.pack('!BBH',0,0,3)+payload)
                if mode != 'ui': peer.sendall(struct.pack('!BxxxI',3,5)+b'hello')
                sent=True
        elif kind == 4:
            down, key=struct.unpack('!BxxI',take(7)); observed['key']=[key,down]
        elif kind == 5:
            buttons,x,y=struct.unpack('!BHH',take(5)); observed['pointer']=[x,y,buttons]
        elif kind == 6:
            n=struct.unpack('!xxxI',take(7))[0]; observed['clipboard']=take(n).decode('latin-1')
        elif kind == 251:
            _,w,h,n=struct.unpack('!BHHB',take(6)); take(1+16*n)
            observed['resize']=[w,h]
        elif kind == 255:
            sub, op=struct.unpack('!BH',take(3)); assert sub==1
            if op==2: assert take(6)==struct.pack('!BBI',3,2,44100)
            elif op==0:
                pcm=bytes([0,0,255,127,0,128,0,0])
                peer.sendall(b'\xff\x01\x00\x01'+b'\xff\x01\x00\x02'+struct.pack('!I',len(pcm))+pcm)
                observed['audio']=True
        else: raise AssertionError(kind)
except (EOFError, ConnectionResetError): pass
finally:
    if len(sys.argv)>1:
        with open(sys.argv[1],'w') as f: json.dump(observed,f)
    peer.close(); listener.close()

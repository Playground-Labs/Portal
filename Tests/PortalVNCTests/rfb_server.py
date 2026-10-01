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
def sasl_plain():
    peer.sendall(struct.pack('!I',5)+b'PLAIN')
    if mode == 'sasl-plain-deny':
        assert peer.recv(1) == b''
        peer.close(); listener.close(); sys.exit(0)
    assert take(struct.unpack('!I',take(4))[0]) == b'PLAIN'
    data = take(struct.unpack('!I',take(4))[0]); assert data.endswith(b'\x00secret\x00')
    peer.sendall(struct.pack('!I',0)+b'\x01')
def rect(x, y, w, h, encoding, body=b''):
    return struct.pack('!HHHHi', x,y,w,h,encoding) + body
version = b'RFB 003.003\n' if mode == 'auth33' else b'RFB 003.008\n'
peer.sendall(version)
assert take(12) == version
if mode == 'unsupported':
    peer.sendall(bytes([2, 250, 251]))
    assert peer.recv(1) == b''
    with open(sys.argv[1], 'w') as f: json.dump({}, f)
    peer.close(); listener.close()
    sys.exit(0)
if mode in ('ard', 'mslogon'):
    from Crypto.Util.number import getPrime
    from Crypto.Cipher import AES, DES
    import hashlib
    security = 30 if mode == 'ard' else 113
    peer.sendall(bytes([1,security])); assert take(1) == bytes([security])
    size = 128 if mode == 'ard' else 8
    prime = getPrime(size*8); private = 1234567; public = pow(2,private,prime)
    header = struct.pack('!HH',2,size) if mode == 'ard' else (2).to_bytes(8,'big')
    peer.sendall(header + prime.to_bytes(size,'big') + public.to_bytes(size,'big'))
    if mode == 'ard':
        ciphertext = take(128); client = int.from_bytes(take(size),'big')
        shared = pow(client,private,prime).to_bytes(size,'big')
        plain = AES.new(hashlib.md5(shared).digest(),AES.MODE_ECB).decrypt(ciphertext)
        assert plain[:64].split(b'\0')[0] == b'fixture' and plain[64:].split(b'\0')[0] == b'secret'
    else:
        client = int.from_bytes(take(size),'big'); shared = pow(client,private,prime).to_bytes(size,'big')
        key = bytes(int(f'{b:08b}'[::-1],2) for b in shared)
        assert DES.new(key,DES.MODE_CBC,iv=shared).decrypt(take(256)).split(b'\0')[0] == b'fixture'
        assert DES.new(key,DES.MODE_CBC,iv=shared).decrypt(take(64)).split(b'\0')[0] == b'secret'
elif mode in ('tls', 'tls-sasl'):
    import ssl, tempfile, subprocess
    temporary = tempfile.TemporaryDirectory()
    key = temporary.name + '/key.pem'; cert = temporary.name + '/cert.pem'
    subprocess.run(['/usr/bin/openssl','req','-x509','-newkey','rsa:2048','-nodes','-keyout',key,'-out',cert,'-days','1','-subj','/CN=localhost'], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    peer.sendall(bytes([1,19])); assert take(1) == bytes([19])
    peer.sendall(bytes([0,2])); assert take(2) == bytes([0,2])
    subtype = 263 if mode == 'tls-sasl' else 262
    peer.sendall(bytes([0,1]) + struct.pack('!I',subtype)); assert take(4) == struct.pack('!I',subtype)
    peer.sendall(bytes([1]))
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER); context.load_cert_chain(cert,key)
    peer = context.wrap_socket(peer,server_side=True)
    if mode == 'tls':
        un,pn = struct.unpack('!II',take(8)); assert take(un) == b'fixture'; assert take(pn) == b'secret'
    else:
        sasl_plain()
elif mode in ('sasl-tunnel', 'sasl-plain-deny'):
    peer.sendall(bytes([1,20])); assert take(1) == bytes([20])
    sasl_plain()
elif mode in ('auth', 'auth33'):
    if mode == 'auth33': peer.sendall(struct.pack('!I',2))
    else:
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

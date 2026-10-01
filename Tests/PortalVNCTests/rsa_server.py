"""Independent RSA-AES RFB peer using PyCryptodome, including authenticated records."""
import socket, struct, sys, hashlib, json
from Crypto.PublicKey import RSA
from Crypto.Cipher import AES, PKCS1_v1_5
from Crypto.Random import get_random_bytes

mode = sys.argv[2]
security = int(mode.split('-')[1])
key_size = 32 if security in (129, 130) else 16
digest = hashlib.sha256 if key_size == 32 else hashlib.sha1
listener = socket.socket()
listener.bind(('127.0.0.1', 0)); listener.listen(1)
print(listener.getsockname()[1], flush=True)
peer, _ = listener.accept(); peer.settimeout(12)
observed = {}
def raw_take(n):
    data = b''
    while len(data) < n:
        part = peer.recv(n-len(data))
        if not part: raise EOFError()
        data += part
    return data

def public_blob(key):
    n = key.size_in_bytes()
    return struct.pack('!I', key.size_in_bits()) + key.n.to_bytes(n, 'big') + key.e.to_bytes(n, 'big')

try:
    peer.sendall(b'RFB 003.008\n'); assert raw_take(12) == b'RFB 003.008\n'
    peer.sendall(bytes([3, 1, 5, 129]) if 'preference' in mode else bytes([1, security])); assert raw_take(1) == bytes([security])
    server = RSA.generate(2048)
    server_blob = public_blob(server)
    peer.sendall(server_blob)
    bits_data = raw_take(4); n = (struct.unpack('!I', bits_data)[0]+7)//8
    client_data = raw_take(2*n); client_blob = bits_data + client_data
    client = RSA.construct((int.from_bytes(client_data[:n], 'big'), int.from_bytes(client_data[n:], 'big')))
    encrypted = raw_take(struct.unpack('!H', raw_take(2))[0])
    client_random = PKCS1_v1_5.new(server).decrypt(encrypted, b'bad')
    assert len(client_random) == key_size
    server_random = get_random_bytes(key_size)
    encrypted = PKCS1_v1_5.new(client).encrypt(server_random)
    peer.sendall(struct.pack('!H', len(encrypted)) + encrypted)
    write_key = digest(client_random + server_random).digest()[:key_size]
    read_key = digest(server_random + client_random).digest()[:key_size]
    rx = tx = 0
    buffered = b''
    def take(n):
        global rx, buffered
        while len(buffered) < n:
            header = raw_take(2); size = struct.unpack('!H', header)[0]
            cipher = AES.new(read_key, AES.MODE_EAX, nonce=rx.to_bytes(16, 'little')); cipher.update(header)
            buffered += cipher.decrypt_and_verify(raw_take(size), raw_take(16)); rx += 1
        data, buffered = buffered[:n], buffered[n:]
        return data
    def send(data):
        global tx
        header = struct.pack('!H', len(data))
        cipher = AES.new(write_key, AES.MODE_EAX, nonce=tx.to_bytes(16, 'little')); cipher.update(header)
        encrypted, tag = cipher.encrypt_and_digest(data); tx += 1
        if 'tamper' in mode: tag = bytes([tag[0]^1]) + tag[1:]
        peer.sendall(header + encrypted + tag)
    assert take(digest().digest_size) == digest(client_blob + server_blob).digest()
    send(digest(server_blob + client_blob).digest() + b'\x01')
    user = take(take(1)[0]); password = take(take(1)[0])
    assert user == b'fixture' and password == b'secret'
    observed['authenticated'] = True
    if security in (6, 130): take, send = raw_take, peer.sendall
    send(b'\0'*4)
    assert take(1) == b'\x01'
    fmt = struct.pack('!BBBBHHHBBBxxx',32,24,0,1,255,255,255,0,8,16)
    send(struct.pack('!HH',2,1)+fmt+struct.pack('!I',7)+b'Fixture')
    while True:
        kind = take(1)[0]
        if kind == 0: take(19)
        elif kind == 2: take(struct.unpack('!xH',take(3))[0]*4)
        elif kind == 3:
            take(9)
            pixels = bytes([255,0,0,0,0,255,0,0])
            send(struct.pack('!BBHHHHHi',0,0,1,0,0,2,1,0)+pixels)
        elif kind == 4:
            observed['key'] = list(struct.unpack('!BxxI',take(7)))
        else: raise AssertionError(kind)
except (EOFError, ConnectionResetError, BrokenPipeError): pass
finally:
    with open(sys.argv[1], 'w') as f: json.dump(observed, f)
    peer.close(); listener.close()

#!/usr/bin/env python3
"""Protocol/IPC regression check for the built native channel. No model requests."""
import json, os, select, socket, struct, subprocess, sys, time, uuid
binary = sys.argv[1] if len(sys.argv) > 1 else '.build/debug/AgentRouterChannel'
run, credential, message = str(uuid.uuid4()), str(uuid.uuid4()), str(uuid.uuid4())
path = f'/private/tmp/ar-channel-{os.getuid()}-{run}/input.sock'
p = subprocess.Popen([binary, run, credential], stdin=subprocess.PIPE, stdout=subprocess.PIPE)
buffer = b''
def rpc(value):
    p.stdin.write(json.dumps({'jsonrpc': '2.0', **value}).encode() + b'\n'); p.stdin.flush()
def read():
    global buffer
    until = time.monotonic() + 5
    while b'\n' not in buffer:
        assert time.monotonic() < until, 'stdio response timed out'
        if select.select([p.stdout], [], [], .1)[0]:
            chunk = os.read(p.stdout.fileno(), 65536)
            assert chunk, 'helper exited'
            buffer += chunk
    line, buffer = buffer.split(b'\n', 1)
    return json.loads(line)
def ipc(operation, token=credential, text=None):
    body = dict(operation=operation, credential=token, id=message)
    if text is not None: body['text'] = text
    data = json.dumps(body).encode()
    with socket.socket(socket.AF_UNIX) as s:
        s.settimeout(3); s.connect(path); s.sendall(struct.pack('>I', len(data)) + data)
        return s.recv(1) == b'\x01'
try:
    for _ in range(100):
        if os.path.exists(path): break
        time.sleep(.02)
    assert os.stat(os.path.dirname(path)).st_mode & 0o777 == 0o700
    assert os.stat(path).st_mode & 0o777 == 0o600
    assert not ipc('ready'), 'must not accept before MCP initialization'
    rpc(dict(id=1, method='initialize', params={'protocolVersion': '2024-11-05'}))
    assert 'claude/channel' in read()['result']['capabilities']['experimental']
    rpc(dict(method='notifications/initialized'))
    rpc(dict(id=2, method='tools/list'))
    assert read()['result']['tools'][0]['name'] == 'acknowledge'
    assert ipc('ready')
    assert not ipc('ready', token='wrong')
    text = 'Literal prompt 🧭\n$(touch never)\n`echo test`'
    assert ipc('submit', text=text)
    event = read()
    assert event['method'] == 'notifications/claude/channel'
    assert event['params'] == {'content': text, 'meta': {'message_id': message}}
    assert not ipc('status'), 'transport receipt must not imply model acknowledgment'
    assert ipc('submit', text=text), 'duplicate ID must be idempotent'
    rpc(dict(id=3, method='ping'))
    assert read()['id'] == 3, 'duplicate must not emit a second notification'
    rpc(dict(id=4, method='tools/call', params={'name':'acknowledge', 'arguments':{'message_id':str(uuid.uuid4())}}))
    assert read()['result']['isError']
    rpc(dict(id=5, method='tools/call', params={'name':'acknowledge', 'arguments':{'message_id':message}}))
    assert not read()['result']['isError']
    assert ipc('status')
    for malformed, code in [(b'\n', -32700), (b'{broken}\n', -32700), (b'\xff\n', -32700), (b'null\n', -32600), (b'42\n', -32600), (b'[]\n', -32600)]:
        p.stdin.write(malformed); p.stdin.flush()
        error = read()
        assert error['error']['code'] == code and error['id'] is None
        assert p.poll() is None, 'malformed input must not terminate helper'
        assert ipc('status'), 'malformed input must not lose receipt ledger'
    rpc(dict(id=6, method='ping'))
    assert read()['id'] == 6, 'valid requests must still work after parse errors'
    print('PASS: handshake, socket permissions, run credential, literal delivery, deduplication, explicit receipt acknowledgment, malformed-input recovery')
finally:
    p.stdin.close()
    try: p.wait(timeout=5)
    except subprocess.TimeoutExpired: p.terminate(); p.wait(timeout=5)
    assert not os.path.exists(path), 'socket must disappear on normal shutdown'
    os.rmdir(os.path.dirname(path))

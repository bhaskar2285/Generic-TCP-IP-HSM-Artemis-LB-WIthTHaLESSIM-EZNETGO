#!/bin/bash

# Load test: send NO command at 100 TPS for 3 seconds (300 total)
HSM_HOST="127.0.0.1"
HSM_PORT="9100"
REQ_HEX="0008303030304e4f3030"
TPS=20
DURATION=3

echo "--- HSM Load Test ---"
echo "Command : NO"
echo "Target  : ${TPS} TPS for ${DURATION}s ($(( TPS * DURATION )) total requests)"
echo ""

python3 - <<'EOF'
import socket, threading, time, uuid

HOST = "127.0.0.1"
PORT = 9100
TPS  = 20
DURATION = 3

success = 0
failure = 0
mismatch = 0
lock = threading.Lock()

def send_one():
    global success, failure, mismatch
    # Use a unique 4-byte ASCII header per request so we can verify the response echoes it back
    tag = uuid.uuid4().hex[:4].encode()   # 16^4 = 65536 combinations, safe for 60 concurrent
    length = 8
    req = bytes([0, length]) + tag + b'NO' + b'00'
    try:
        s = socket.socket()
        s.settimeout(10)
        s.connect((HOST, PORT))
        s.sendall(req)
        data = s.recv(4096)
        s.close()
        # Frame: [2-byte eznet len][4-byte echoed header][NP at 6-7][00 at 8-9]
        if len(data) < 10:
            with lock: failure += 1
            return
        resp_code = data[6:8]
        err_code  = data[8:10]
        echoed_hdr = data[2:6]
        if resp_code != b'\x4e\x50' or err_code != b'\x30\x30':
            with lock: failure += 1
        elif echoed_hdr != tag:
            with lock: mismatch += 1   # response matched wrong request
        else:
            with lock: success += 1
    except Exception:
        with lock: failure += 1

interval = 1.0 / TPS
end_time = time.time() + DURATION
threads = []
sent = 0

while time.time() < end_time:
    t = threading.Thread(target=send_one, daemon=True)
    t.start()
    threads.append(t)
    sent += 1
    time.sleep(interval)

# Wait for every request to complete before reporting
for t in threads:
    t.join(timeout=40)

print(f"Sent      : {sent}")
print(f"Success   : {success}")
print(f"Failure   : {failure}")
print(f"Mismatch  : {mismatch}  ← response echoed wrong header (cross-contamination)")
print(f"Success rate: {100*success/sent:.1f}%" if sent else "N/A")
EOF

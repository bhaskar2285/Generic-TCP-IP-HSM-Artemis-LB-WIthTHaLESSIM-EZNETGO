#!/bin/bash
# Measure average / percentile response time at 200 TPS for 20s.
DUR=${1:-20}
TPS=${2:-200}

echo "=== Warmup (20 TPS / 5s) ==="
python3 - <<'PY' >/dev/null
import socket,threading,time,uuid
HOST="127.0.0.1"; ports=[9105,9101]
def one(p):
    try:
        s=socket.socket(); s.settimeout(20); s.connect((HOST,p))
        tag=uuid.uuid4().hex[:4].encode()
        s.sendall(bytes([0,8])+tag+b'NO00')
        s.recv(4096); s.close()
    except: pass
ts=[]; end=time.time()+5; i=0
while time.time()<end:
    th=threading.Thread(target=one,args=(ports[i%2],),daemon=True); th.start(); ts.append(th); i+=1; time.sleep(0.05)
for t in ts: t.join(timeout=20)
PY
echo "warmup done"
echo ""
echo "=== Measure ${TPS} TPS for ${DUR}s ==="
python3 - "$TPS" "$DUR" <<'PY'
import socket,threading,time,uuid,sys,statistics
TPS=float(sys.argv[1]); DUR=int(sys.argv[2])
HOST="127.0.0.1"; ports=[9105,9101]
ok=fail=0; lock=threading.Lock(); lat=[]; errors={}
def one(port):
    global ok,fail
    tag=uuid.uuid4().hex[:4].encode()
    req=bytes([0,8])+tag+b'NO00'
    t0=time.time()
    try:
        s=socket.socket(); s.settimeout(60); s.connect((HOST,port))
        s.sendall(req); d=s.recv(4096); s.close()
        dt=(time.time()-t0)*1000
        if len(d)>=10 and d[6:8]==b'NP' and d[8:10]==b'00' and d[2:6]==tag:
            with lock: ok+=1; lat.append(dt)
        else:
            with lock: fail+=1; errors['bad_payload']=errors.get('bad_payload',0)+1
    except socket.timeout:
        with lock: fail+=1; errors['client_timeout']=errors.get('client_timeout',0)+1
    except Exception as e:
        with lock: fail+=1; errors[type(e).__name__]=errors.get(type(e).__name__,0)+1

interval=1.0/TPS; end=time.time()+DUR; ts=[]; sent=0; i=0
t0=time.time()
while time.time()<end:
    th=threading.Thread(target=one,args=(ports[i%2],),daemon=True); th.start(); ts.append(th); sent+=1; i+=1; time.sleep(interval)
sched_done=time.time()
for t in ts: t.join(timeout=120)
elapsed=time.time()-t0

print(f"requested TPS    : {TPS}")
print(f"duration target  : {DUR}s   (sched ran for {sched_done-t0:.1f}s, total {elapsed:.1f}s)")
print(f"sent             : {sent}")
print(f"success          : {ok}")
print(f"failure          : {fail}")
print(f"success rate     : {100*ok/sent:.2f}%" if sent else "n/a")
print(f"actual TPS (ok)  : {ok/elapsed:.2f}" if elapsed else "n/a")
print(f"errors           : {errors}")
print()
if lat:
    lat.sort()
    avg=sum(lat)/len(lat)
    print(f"--- latency (ms over {len(lat)} successful) ---")
    print(f"  min   : {lat[0]:.0f}")
    print(f"  avg   : {avg:.0f}")
    print(f"  median: {lat[len(lat)//2]:.0f}")
    print(f"  p90   : {lat[int(len(lat)*0.90)]:.0f}")
    print(f"  p95   : {lat[int(len(lat)*0.95)]:.0f}")
    print(f"  p99   : {lat[int(len(lat)*0.99)]:.0f}")
    print(f"  max   : {lat[-1]:.0f}")
PY
echo ""
echo "=== Per-node stats (lb-1) ==="
curl -s http://localhost:8110/api/v1/hsm-lb/status | python3 -c "
import sys,json; d=json.load(sys.stdin)
print(f'consumers={d[\"jmsActiveConsumers\"]}/{d[\"jmsMaxConsumers\"]}  sockTimeout={d[\"effectiveSocketTimeoutMs\"]}ms')
for n in d['nodes']:
    print(f\"  {n['id']}: reqs={n['totalRequests']} errs={n['totalErrors']} errPct={n['errorRatePct']}%\")"
echo "=== Per-node stats (lb-2) ==="
curl -s http://localhost:8111/api/v1/hsm-lb/status | python3 -c "
import sys,json; d=json.load(sys.stdin)
print(f'consumers={d[\"jmsActiveConsumers\"]}/{d[\"jmsMaxConsumers\"]}  sockTimeout={d[\"effectiveSocketTimeoutMs\"]}ms')
for n in d['nodes']:
    print(f\"  {n['id']}: reqs={n['totalRequests']} errs={n['totalErrors']} errPct={n['errorRatePct']}%\")"

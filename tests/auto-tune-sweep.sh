#!/bin/bash
# Linear TPS sweep with per-step auto-tune-on-fail.
# - Each request waits up to 45s for response.
# - On FAIL (rate<99%): bump socket-timeout, fast-fail, max-wait, request.max-age by 1.5x,
#   restart LBs, retry the same TPS once. After 2 retries, declare fail and continue down.
set -u

LB1_CFG=/tmp/Generic-TCP-IP-HSM-Artemis-LB/docker/config/lb-1/application.properties
LB2_CFG=/tmp/Generic-TCP-IP-HSM-Artemis-LB/docker/config/lb-2/application.properties
DUR=${DUR:-15}
PASS_RATE=${PASS_RATE:-99}
REQ_TIMEOUT=${REQ_TIMEOUT:-45}
TPS_LADDER=${TPS_LADDER:-"5 10 20 30 50 75 100"}
MAX_TUNE_ITERS=${MAX_TUNE_ITERS:-2}

read_param() {
  grep -E "^$1=" "$LB1_CFG" | head -1 | cut -d= -f2
}
set_param() {
  local key=$1 val=$2
  sed -i -E "s|^${key}=.*|${key}=${val}|" "$LB1_CFG" "$LB2_CFG"
}
restart_lbs() {
  echo "  >>> restarting LBs to apply tuned config..."
  docker restart lb-1 lb-2 >/dev/null 2>&1
  until curl -fs http://localhost:8110/actuator/health >/dev/null && curl -fs http://localhost:8111/actuator/health >/dev/null; do sleep 3; done
  echo "  >>> LBs ready"
}
reset_circuits() {
  for id in node1 node2 node3 node4 node5; do
    curl -s -X POST "http://localhost:8110/api/v1/hsm-lb/nodes/$id/circuit-reset" >/dev/null
    curl -s -X POST "http://localhost:8111/api/v1/hsm-lb/nodes/$id/circuit-reset" >/dev/null
  done
}

run_step() {
  local TPS=$1 D=$2 TO=$3
  python3 - "$TPS" "$D" "$TO" <<'PY'
import socket,threading,time,uuid,sys,urllib.request,base64,json
TPS=float(sys.argv[1]); DUR=int(sys.argv[2]); REQ_TO=int(sys.argv[3])
HOST="127.0.0.1"; ports=[9105,9101]
ok=fail=0; lock=threading.Lock(); lat=[]

JOLOKIA="http://localhost:18163/console/jolokia/read/org.apache.activemq.artemis:broker=%22artemis-master%22,component=addresses,address=%22hsm.transparent.lb.in%22,subcomponent=queues,routing-type=%22anycast%22,queue=%22hsm.transparent.lb.in%22/MessageCount,DeliveringCount,ConsumerCount"
AUTH="Basic " + base64.b64encode(b"artemis:artemis").decode()
qd_samples=[]; del_samples=[]; cons_samples=[]
qd_stop=threading.Event()
def sample_qd():
    while not qd_stop.is_set():
        try:
            req=urllib.request.Request(JOLOKIA, headers={"Authorization": AUTH})
            with urllib.request.urlopen(req, timeout=2) as r:
                v=json.load(r).get("value",{})
                qd_samples.append(v.get("MessageCount",0))
                del_samples.append(v.get("DeliveringCount",0))
                cons_samples.append(v.get("ConsumerCount",0))
        except: pass
        time.sleep(0.5)
qd_thread=threading.Thread(target=sample_qd, daemon=True); qd_thread.start()

def one(port):
    global ok,fail
    tag=uuid.uuid4().hex[:4].encode()
    req=bytes([0,8])+tag+b'NO00'
    t0=time.time()
    try:
        s=socket.socket(); s.settimeout(REQ_TO); s.connect((HOST,port))
        s.sendall(req); d=s.recv(4096); s.close()
        dt=(time.time()-t0)*1000
        if len(d)>=10 and d[6:8]==b'NP' and d[8:10]==b'00' and d[2:6]==tag:
            with lock: ok+=1; lat.append(dt)
        else:
            with lock: fail+=1
    except:
        with lock: fail+=1
interval=1.0/TPS; end=time.time()+DUR; ts=[]; sent=0; i=0
t0=time.time()
while time.time()<end:
    th=threading.Thread(target=one,args=(ports[i%2],),daemon=True); th.start(); ts.append(th); sent+=1; i+=1; time.sleep(interval)
for th in ts: th.join(timeout=REQ_TO+10)
qd_stop.set(); qd_thread.join(timeout=2)
elapsed=time.time()-t0
rate=100*ok/sent if sent else 0
atps=ok/elapsed if elapsed else 0
if lat:
    lat.sort(); avg=sum(lat)/len(lat)
    p50=lat[len(lat)//2]; p95=lat[int(len(lat)*0.95)]; p99=lat[int(len(lat)*0.99)]
else:
    avg=p50=p95=p99=0
qd_max=max(qd_samples) if qd_samples else 0
qd_avg=sum(qd_samples)//len(qd_samples) if qd_samples else 0
del_max=max(del_samples) if del_samples else 0
cons_max=max(cons_samples) if cons_samples else 0
print(f"{sent},{ok},{fail},{rate:.1f},{atps:.1f},{avg:.0f},{p50:.0f},{p95:.0f},{p99:.0f},{qd_max},{qd_avg},{del_max},{cons_max}")
PY
}

echo "=== Auto-tuning TPS sweep ==="
echo "  ladder      : $TPS_LADDER"
echo "  duration    : ${DUR}s/step"
echo "  pass rate   : >=${PASS_RATE}%"
echo "  req timeout : ${REQ_TIMEOUT}s"
echo "  retries     : up to ${MAX_TUNE_ITERS} timer-bumps per step"
echo ""
echo "Starting timers:"
echo "  socket-timeout-ms      : $(read_param hsm.lb.pool.socket-timeout-ms)"
echo "  fast-fail-timeout-ms   : $(read_param hsm.lb.pool.fast-fail-timeout-ms)"
echo "  max-wait-ms            : $(read_param hsm.lb.pool.max-wait-ms)"
echo "  request.max-age-ms     : $(read_param hsm.lb.request.max-age-ms)"
echo ""

# Warmup
echo "Warmup (10 TPS / 5s)..."
run_step 10 5 30 >/dev/null
echo "Done."
echo ""

printf "%-5s %-5s %-6s %-6s %-5s %-6s %-7s %-7s %-7s %-7s %-7s %-7s %-7s %-6s %-7s\n" \
  "TPS" "Iter" "Sent" "Ok" "Fail" "Rate%" "AtpsOk" "Avg" "p50" "p95" "p99" "qDmax" "qDavg" "Deliv" "Verdict"
echo "──────────────────────────────────────────────────────────────────────────────────────────────────────────────"

LAST_PASS=0
LAST_TUNE=""
for TPS in $TPS_LADDER; do
  ITER=0
  while [ $ITER -le $MAX_TUNE_ITERS ]; do
    reset_circuits
    sleep 2
    res=$(run_step $TPS $DUR $REQ_TIMEOUT)
    IFS=',' read sent ok fail rate atps avg p50 p95 p99 qdmax qdavg delmax consmax <<<"$res"
    pass=$(python3 -c "print(1 if float('$rate')>=$PASS_RATE else 0)")
    if [ "$pass" = "1" ]; then
      printf "%-5s %-5s %-6s %-6s %-5s %-6s %-7s %-7s %-7s %-7s %-7s %-7s %-7s %-6s \033[32mPASS\033[0m\n" \
        "$TPS" "$ITER" "$sent" "$ok" "$fail" "$rate%" "$atps" "$avg" "$p50" "$p95" "$p99" "$qdmax" "$qdavg" "$delmax"
      LAST_PASS=$TPS
      break
    else
      printf "%-5s %-5s %-6s %-6s %-5s %-6s %-7s %-7s %-7s %-7s %-7s %-7s %-7s %-6s \033[31mFAIL\033[0m\n" \
        "$TPS" "$ITER" "$sent" "$ok" "$fail" "$rate%" "$atps" "$avg" "$p50" "$p95" "$p99" "$qdmax" "$qdavg" "$delmax"
      ITER=$((ITER+1))
      [ $ITER -gt $MAX_TUNE_ITERS ] && break
      # AUTO-TUNE: bump timers 1.5x
      ST=$(read_param hsm.lb.pool.socket-timeout-ms)
      FF=$(read_param hsm.lb.pool.fast-fail-timeout-ms)
      MW=$(read_param hsm.lb.pool.max-wait-ms)
      MA=$(read_param hsm.lb.request.max-age-ms)
      ST_NEW=$(( ST * 3 / 2 ))
      FF_NEW=$(( FF * 3 / 2 ))
      MW_NEW=$(( MW * 3 / 2 ))
      MA_NEW=$(( MA * 3 / 2 ))
      echo "  >>> AUTO-TUNE: socket=${ST}->${ST_NEW}ms  fast-fail=${FF}->${FF_NEW}ms  max-wait=${MW}->${MW_NEW}ms  max-age=${MA}->${MA_NEW}ms"
      set_param hsm.lb.pool.socket-timeout-ms "$ST_NEW"
      set_param hsm.lb.pool.fast-fail-timeout-ms "$FF_NEW"
      set_param hsm.lb.pool.max-wait-ms "$MW_NEW"
      set_param hsm.lb.request.max-age-ms "$MA_NEW"
      LAST_TUNE="socket=${ST_NEW} fast-fail=${FF_NEW} max-wait=${MW_NEW} max-age=${MA_NEW}"
      restart_lbs
    fi
  done
  # If we exhausted retries without passing, stop the ladder
  if [ "$pass" != "1" ]; then
    echo ""
    echo "Stopping ladder — could not pass ${PASS_RATE}% at TPS=$TPS even after ${MAX_TUNE_ITERS} tune iterations."
    break
  fi
done

echo ""
echo "════════════════════════════════════════════════════════════════"
echo "Max sustained TPS at >=${PASS_RATE}%: $LAST_PASS"
echo "Final tuned timers:"
echo "  socket-timeout-ms    : $(read_param hsm.lb.pool.socket-timeout-ms)"
echo "  fast-fail-timeout-ms : $(read_param hsm.lb.pool.fast-fail-timeout-ms)"
echo "  max-wait-ms          : $(read_param hsm.lb.pool.max-wait-ms)"
echo "  request.max-age-ms   : $(read_param hsm.lb.request.max-age-ms)"
[ -n "$LAST_TUNE" ] && echo "Last applied auto-tune: $LAST_TUNE"
echo "════════════════════════════════════════════════════════════════"

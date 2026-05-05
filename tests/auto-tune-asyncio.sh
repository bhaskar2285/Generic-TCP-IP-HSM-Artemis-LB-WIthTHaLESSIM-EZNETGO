#!/bin/bash
# Asyncio-based TPS sweep with auto-tune-on-fail.
# Uses asyncio.open_connection so a single Python process can sustain thousands of in-flight requests.
set -u

LB1_CFG=/tmp/Generic-TCP-IP-HSM-Artemis-LB/docker/config/lb-1/application.properties
LB2_CFG=/tmp/Generic-TCP-IP-HSM-Artemis-LB/docker/config/lb-2/application.properties
DUR=${DUR:-15}
PASS_RATE=${PASS_RATE:-99}
REQ_TIMEOUT=${REQ_TIMEOUT:-45}
TPS_LADDER=${TPS_LADDER:-"500 1000 2000 4000 8000 12000 16000"}
MAX_TUNE_ITERS=${MAX_TUNE_ITERS:-2}

# Raise file-descriptor ceiling for the load gen
ulimit -n 65535 2>/dev/null || true

read_param() { grep -E "^$1=" "$LB1_CFG" | head -1 | cut -d= -f2; }
set_param()  { sed -i -E "s|^$1=.*|$1=$2|" "$LB1_CFG" "$LB2_CFG"; }
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
import asyncio, struct, time, uuid, sys, urllib.request, base64, json, threading, socket
TPS=float(sys.argv[1]); DUR=float(sys.argv[2]); REQ_TO=float(sys.argv[3])
HOST="127.0.0.1"; PORTS=[9105,9101]

ok=fail=inflight=0
lat=[]
errors={}

# ── Artemis queue depth sampler (background thread) ────────────────────────
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

async def one(port):
    global ok,fail,inflight
    inflight+=1
    tag=uuid.uuid4().hex[:4].encode()
    req=bytes([0,8])+tag+b'NO00'
    t0=time.time()
    reader=writer=None
    try:
        reader, writer = await asyncio.wait_for(
            asyncio.open_connection(HOST, port), timeout=REQ_TO)
        writer.write(req); await writer.drain()
        # length-prefixed: read 2 bytes for length, then the body
        hdr = await asyncio.wait_for(reader.readexactly(2), timeout=REQ_TO)
        n = struct.unpack(">H", hdr)[0]
        if n <= 0 or n > 8192:
            fail+=1; errors['bad_len']=errors.get('bad_len',0)+1; return
        body = await asyncio.wait_for(reader.readexactly(n), timeout=REQ_TO)
        dt=(time.time()-t0)*1000
        # body[0:4] should be tag, [4:6]='NP', [6:8]='00'
        if len(body)>=8 and body[0:4]==tag and body[4:6]==b'NP' and body[6:8]==b'00':
            ok+=1; lat.append(dt)
        else:
            fail+=1; errors['bad_payload']=errors.get('bad_payload',0)+1
    except asyncio.TimeoutError:
        fail+=1; errors['timeout']=errors.get('timeout',0)+1
    except (ConnectionResetError, BrokenPipeError, ConnectionRefusedError) as e:
        fail+=1; errors[type(e).__name__]=errors.get(type(e).__name__,0)+1
    except Exception as e:
        fail+=1; errors[type(e).__name__]=errors.get(type(e).__name__,0)+1
    finally:
        inflight-=1
        if writer is not None:
            try: writer.close()
            except: pass

async def main():
    interval = 1.0 / TPS
    tasks=[]
    sent=0
    t0=time.time()
    end=t0+DUR
    next_t=t0
    i=0
    while time.time() < end:
        # round-robin across ports
        port=PORTS[i%2]
        tasks.append(asyncio.create_task(one(port)))
        sent+=1; i+=1
        next_t += interval
        sleep_for = next_t - time.time()
        if sleep_for > 0:
            await asyncio.sleep(sleep_for)
    sched_done=time.time()
    # wait for all in-flight to finish (cap at REQ_TO+10 absolute)
    if tasks:
        await asyncio.wait(tasks, timeout=REQ_TO+10)
    elapsed=time.time()-t0
    qd_stop.set()
    qd_thread.join(timeout=2)
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
    print(f"{sent},{ok},{fail},{rate:.1f},{atps:.1f},{avg:.0f},{p50:.0f},{p95:.0f},{p99:.0f},{qd_max},{qd_avg},{del_max}")

asyncio.run(main())
PY
}

echo "=== Asyncio auto-tuning TPS sweep ==="
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

# warmup to settle JIT/connection caches
echo "Warmup (200 TPS / 5s)..."
run_step 200 5 30 >/dev/null
echo "Done."
echo ""

printf "%-6s %-5s %-7s %-7s %-6s %-7s %-9s %-7s %-7s %-7s %-7s %-7s %-7s %-7s\n" \
  "TPS" "Iter" "Sent" "Ok" "Fail" "Rate%" "AtpsOk" "Avg" "p50" "p95" "p99" "qDmax" "qDavg" "Verdict"
echo "─────────────────────────────────────────────────────────────────────────────────────────────────────────────"

LAST_PASS=0
LAST_TUNE=""
for TPS in $TPS_LADDER; do
  ITER=0
  while [ $ITER -le $MAX_TUNE_ITERS ]; do
    reset_circuits
    sleep 2
    res=$(run_step $TPS $DUR $REQ_TIMEOUT)
    IFS=',' read sent ok fail rate atps avg p50 p95 p99 qdmax qdavg delmax <<<"$res"
    pass=$(python3 -c "print(1 if float('$rate')>=$PASS_RATE else 0)")
    if [ "$pass" = "1" ]; then
      printf "%-6s %-5s %-7s %-7s %-6s %-7s %-9s %-7s %-7s %-7s %-7s %-7s %-7s \033[32mPASS\033[0m\n" \
        "$TPS" "$ITER" "$sent" "$ok" "$fail" "$rate%" "$atps" "$avg" "$p50" "$p95" "$p99" "$qdmax" "$qdavg"
      LAST_PASS=$TPS
      break
    else
      printf "%-6s %-5s %-7s %-7s %-6s %-7s %-9s %-7s %-7s %-7s %-7s %-7s %-7s \033[31mFAIL\033[0m\n" \
        "$TPS" "$ITER" "$sent" "$ok" "$fail" "$rate%" "$atps" "$avg" "$p50" "$p95" "$p99" "$qdmax" "$qdavg"
      ITER=$((ITER+1))
      [ $ITER -gt $MAX_TUNE_ITERS ] && break
      ST=$(read_param hsm.lb.pool.socket-timeout-ms)
      FF=$(read_param hsm.lb.pool.fast-fail-timeout-ms)
      MW=$(read_param hsm.lb.pool.max-wait-ms)
      MA=$(read_param hsm.lb.request.max-age-ms)
      ST_NEW=$(( ST * 3 / 2 )); FF_NEW=$(( FF * 3 / 2 )); MW_NEW=$(( MW * 3 / 2 )); MA_NEW=$(( MA * 3 / 2 ))
      echo "  >>> AUTO-TUNE: socket=${ST}->${ST_NEW}  fast-fail=${FF}->${FF_NEW}  max-wait=${MW}->${MW_NEW}  max-age=${MA}->${MA_NEW}"
      set_param hsm.lb.pool.socket-timeout-ms "$ST_NEW"
      set_param hsm.lb.pool.fast-fail-timeout-ms "$FF_NEW"
      set_param hsm.lb.pool.max-wait-ms "$MW_NEW"
      set_param hsm.lb.request.max-age-ms "$MA_NEW"
      LAST_TUNE="socket=${ST_NEW} fast-fail=${FF_NEW} max-wait=${MW_NEW} max-age=${MA_NEW}"
      restart_lbs
    fi
  done
  [ "$pass" != "1" ] && { echo ""; echo "Stopping ladder — could not pass ${PASS_RATE}% at TPS=$TPS even after ${MAX_TUNE_ITERS} retries."; break; }
done

echo ""
echo "════════════════════════════════════════════════════════════════"
echo "Max sustained requested TPS at >=${PASS_RATE}%: $LAST_PASS"
echo "Final timers:"
echo "  socket-timeout-ms    : $(read_param hsm.lb.pool.socket-timeout-ms)"
echo "  fast-fail-timeout-ms : $(read_param hsm.lb.pool.fast-fail-timeout-ms)"
echo "  max-wait-ms          : $(read_param hsm.lb.pool.max-wait-ms)"
echo "  request.max-age-ms   : $(read_param hsm.lb.request.max-age-ms)"
[ -n "$LAST_TUNE" ] && echo "Last applied auto-tune: $LAST_TUNE"
echo "════════════════════════════════════════════════════════════════"

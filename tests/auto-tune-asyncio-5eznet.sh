#!/bin/bash
# Wrapper around auto-tune-asyncio.sh that samples docker stats in the background
# during each step and reports per-container CPU% / mem (peak + avg).
set -u

LB1_CFG=/tmp/Generic-TCP-IP-HSM-Artemis-LB/docker/config/lb-1/application.properties
LB2_CFG=/tmp/Generic-TCP-IP-HSM-Artemis-LB/docker/config/lb-2/application.properties
DUR=${DUR:-15}
PASS_RATE=${PASS_RATE:-99}
REQ_TIMEOUT=${REQ_TIMEOUT:-45}
TPS_LADDER=${TPS_LADDER:-"500 1000 1500 2000"}
MAX_TUNE_ITERS=${MAX_TUNE_ITERS:-1}
CONTAINERS=${CONTAINERS:-"lb-1 lb-2 artemis-master eznet-1 eznet-2 eznet-3 eznet-4 eznet-5"}
STATS_FILE=/tmp/docker-stats-sweep.csv
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

# Background stats sampler — writes one CSV row per sample per container.
# Format: timestamp,container,cpu_pct,mem_mib
# stdout/stderr redirected to /dev/null so the backgrounded subshell doesn't
# keep the parent's command-substitution pipe open.
start_stats() {
  : > "$STATS_FILE"
  (
    while true; do
      docker stats --no-stream --format '{{.Name}},{{.CPUPerc}},{{.MemUsage}}' $CONTAINERS 2>/dev/null | while IFS=, read -r name cpu mem; do
        cpu_num=${cpu%\%}
        mem_num=${mem%% *}
        unit=$(echo "$mem_num" | sed -E 's/[0-9.]+//')
        val=$(echo  "$mem_num" | sed -E 's/[A-Za-z]+//')
        case "$unit" in
          GiB) val=$(echo "$val * 1024" | bc -l) ;;
          KiB) val=$(echo "$val / 1024" | bc -l) ;;
        esac
        echo "$(date +%s.%N),$name,$cpu_num,$val" >> "$STATS_FILE"
      done
      sleep 2
    done
  ) </dev/null >/dev/null 2>&1 &
  echo $!
}

stop_stats() {
  kill "$1" 2>/dev/null
  wait "$1" 2>/dev/null
}

run_step() {
  local TPS=$1 D=$2 TO=$3
  python3 - "$TPS" "$D" "$TO" <<'PY'
import asyncio, struct, time, uuid, sys, urllib.request, base64, json, threading
TPS=float(sys.argv[1]); DUR=float(sys.argv[2]); REQ_TO=float(sys.argv[3])
HOST="127.0.0.1"; PORTS=[9105,9101,9106,9107,9108]
ok=fail=0; lat=[]
JOLOKIA="http://localhost:18163/console/jolokia/read/org.apache.activemq.artemis:broker=%22artemis-master%22,component=addresses,address=%22hsm.transparent.lb.in%22,subcomponent=queues,routing-type=%22anycast%22,queue=%22hsm.transparent.lb.in%22/MessageCount,DeliveringCount"
AUTH="Basic " + base64.b64encode(b"artemis:artemis").decode()
qd=[]; qd_stop=threading.Event()
def sample_qd():
    while not qd_stop.is_set():
        try:
            r=urllib.request.Request(JOLOKIA, headers={"Authorization": AUTH})
            with urllib.request.urlopen(r, timeout=2) as rr:
                v=json.load(rr).get("value",{}); qd.append(v.get("MessageCount",0))
        except: pass
        time.sleep(0.5)
threading.Thread(target=sample_qd, daemon=True).start()
async def one(port):
    global ok,fail
    tag=uuid.uuid4().hex[:4].encode(); req=bytes([0,8])+tag+b'NO00'
    t0=time.time(); reader=writer=None
    try:
        reader,writer=await asyncio.wait_for(asyncio.open_connection(HOST,port), timeout=REQ_TO)
        writer.write(req); await writer.drain()
        hdr=await asyncio.wait_for(reader.readexactly(2), timeout=REQ_TO)
        n=struct.unpack(">H",hdr)[0]
        body=await asyncio.wait_for(reader.readexactly(n), timeout=REQ_TO)
        dt=(time.time()-t0)*1000
        if len(body)>=8 and body[0:4]==tag and body[4:6]==b'NP' and body[6:8]==b'00':
            ok+=1; lat.append(dt)
        else: fail+=1
    except Exception: fail+=1
    finally:
        if writer is not None:
            try: writer.close()
            except: pass
async def main():
    interval=1.0/TPS; tasks=[]; sent=0; t0=time.time(); end=t0+DUR; nxt=t0; i=0
    while time.time()<end:
        tasks.append(asyncio.create_task(one(PORTS[i%len(PORTS)])))
        sent+=1; i+=1; nxt+=interval
        s=nxt-time.time()
        if s>0: await asyncio.sleep(s)
    if tasks: await asyncio.wait(tasks, timeout=REQ_TO+10)
    qd_stop.set()
    elapsed=time.time()-t0
    rate=100*ok/sent if sent else 0
    atps=ok/elapsed if elapsed else 0
    if lat:
        lat.sort(); avg=sum(lat)/len(lat)
        p50=lat[len(lat)//2]; p95=lat[int(len(lat)*0.95)]; p99=lat[int(len(lat)*0.99)]
    else: avg=p50=p95=p99=0
    qm=max(qd) if qd else 0; qa=sum(qd)//len(qd) if qd else 0
    print(f"{sent},{ok},{fail},{rate:.1f},{atps:.1f},{avg:.0f},{p50:.0f},{p95:.0f},{p99:.0f},{qm},{qa}")
asyncio.run(main())
PY
}

summarize_stats() {
  local t_from=$1 t_to=$2
  python3 - "$STATS_FILE" "$t_from" "$t_to" "$CONTAINERS" <<'PY'
import sys, statistics
fp, t0, t1, container_str = sys.argv[1], float(sys.argv[2]), float(sys.argv[3]), sys.argv[4]
containers = container_str.split()
data = {c: {"cpu": [], "mem": []} for c in containers}
with open(fp) as f:
    for line in f:
        try:
            ts, name, cpu, mem = line.strip().split(",")
            ts = float(ts)
            if t0 <= ts <= t1 and name in data:
                data[name]["cpu"].append(float(cpu))
                data[name]["mem"].append(float(mem))
        except: pass
parts=[]
for c in containers:
    cpus=data[c]["cpu"]; mems=data[c]["mem"]
    if cpus:
        cpu_avg=sum(cpus)/len(cpus); cpu_max=max(cpus)
        mem_avg=sum(mems)/len(mems); mem_max=max(mems)
        parts.append(f"{c}: cpu {cpu_avg:.0f}%/{cpu_max:.0f}%  mem {mem_avg:.0f}/{mem_max:.0f} MiB")
    else:
        parts.append(f"{c}: no samples")
print(" | ".join(parts))
PY
}

echo "=== Asyncio sweep + docker stats ==="
echo "  ladder      : $TPS_LADDER"
echo "  duration    : ${DUR}s/step"
echo "  containers  : $CONTAINERS"
echo ""

stats_pid=$(start_stats)
echo "stats sampler PID=$stats_pid -> $STATS_FILE"

# warmup
echo "Warmup..."
run_step 200 5 30 >/dev/null
echo "Done."
echo ""
printf "%-6s %-7s %-7s %-7s %-7s %-7s %-7s %-7s %-7s\n" \
  "TPS" "Sent" "Ok" "Fail" "Rate%" "AtpsOk" "Avg" "p95" "qDmax"
echo "──────────────────────────────────────────────────────────────────────"

LAST_PASS=0
for TPS in $TPS_LADDER; do
  reset_circuits
  sleep 2
  t_from=$(date +%s.%N)
  res=$(run_step $TPS $DUR $REQ_TIMEOUT)
  t_to=$(date +%s.%N)
  IFS=',' read sent ok fail rate atps avg p50 p95 p99 qdmax qdavg <<<"$res"
  pass=$(python3 -c "print(1 if float('$rate')>=$PASS_RATE else 0)")
  if [ "$pass" = "1" ]; then
    color=$'\033[32m'; verdict="PASS"; LAST_PASS=$TPS
  else
    color=$'\033[31m'; verdict="FAIL"
  fi
  reset=$'\033[0m'
  printf "${color}%-6s %-7s %-7s %-7s %-7s %-7s %-7s %-7s %-7s ${verdict}${reset}\n" \
    "$TPS" "$sent" "$ok" "$fail" "$rate%" "$atps" "$avg" "$p95" "$qdmax"
  echo "  STATS: $(summarize_stats $t_from $t_to)"
  [ "$pass" != "1" ] && break
done

stop_stats "$stats_pid"
echo ""
echo "Max sustained TPS: $LAST_PASS"

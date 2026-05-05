#!/bin/bash
# 2^5 = 32 HSM enable/disable combinations.
# For each combo, drive ${TPS} for ${DUR}s via asyncio and report rate + per-node dispatch.
set -u

LB1_API="http://localhost:8110/api/v1/hsm-lb"
LB2_API="http://localhost:8111/api/v1/hsm-lb"
TPS=${TPS:-500}
DUR=${DUR:-12}
REQ_TIMEOUT=${REQ_TIMEOUT:-45}
NODES=(node1 node2 node3 node4 node5)

ulimit -n 65535 2>/dev/null || true

set_node() {
  curl -s -X POST "$LB1_API/nodes/$1/enabled?value=$2" >/dev/null
  curl -s -X POST "$LB2_API/nodes/$1/enabled?value=$2" >/dev/null
}
reset_circuit() {
  curl -s -X POST "$LB1_API/nodes/$1/circuit-reset" >/dev/null
  curl -s -X POST "$LB2_API/nodes/$1/circuit-reset" >/dev/null
}
restore_all() {
  for id in "${NODES[@]}"; do set_node "$id" true; reset_circuit "$id"; done
  sleep 2
}

# Snapshot per-node totals (sum across both LBs) to compute deltas.
snapshot_totals() {
  python3 - <<PY
import urllib.request, json
out=[]
for url in ["$LB1_API/status", "$LB2_API/status"]:
    with urllib.request.urlopen(url) as r:
        d=json.load(r)
        for n in d['nodes']:
            out.append(f"{n['id']}:{n['totalRequests']}:{n['totalErrors']}")
print(",".join(out))
PY
}

run_step() {
  local TPS=$1 D=$2 TO=$3
  python3 - "$TPS" "$D" "$TO" <<'PY'
import asyncio, struct, time, uuid, sys
TPS=float(sys.argv[1]); DUR=float(sys.argv[2]); REQ_TO=float(sys.argv[3])
HOST="127.0.0.1"; PORTS=[9105,9101]
ok=fail=0; lat=[]
async def one(port):
    global ok,fail
    tag=uuid.uuid4().hex[:4].encode()
    req=bytes([0,8])+tag+b'NO00'
    t0=time.time(); reader=writer=None
    try:
        reader,writer = await asyncio.wait_for(asyncio.open_connection(HOST,port), timeout=REQ_TO)
        writer.write(req); await writer.drain()
        hdr = await asyncio.wait_for(reader.readexactly(2), timeout=REQ_TO)
        n=struct.unpack(">H",hdr)[0]
        body = await asyncio.wait_for(reader.readexactly(n), timeout=REQ_TO)
        dt=(time.time()-t0)*1000
        if len(body)>=8 and body[0:4]==tag and body[4:6]==b'NP' and body[6:8]==b'00':
            ok+=1; lat.append(dt)
        else:
            fail+=1
    except Exception:
        fail+=1
    finally:
        if writer is not None:
            try: writer.close()
            except: pass

async def main():
    interval=1.0/TPS; tasks=[]; sent=0; t0=time.time(); end=t0+DUR; next_t=t0; i=0
    while time.time()<end:
        tasks.append(asyncio.create_task(one(PORTS[i%2])))
        sent+=1; i+=1; next_t+=interval
        s=next_t-time.time()
        if s>0: await asyncio.sleep(s)
    if tasks: await asyncio.wait(tasks, timeout=REQ_TO+10)
    elapsed=time.time()-t0
    rate=100*ok/sent if sent else 0
    if lat:
        lat.sort(); avg=sum(lat)/len(lat); p95=lat[int(len(lat)*0.95)]
    else: avg=p95=0
    print(f"{sent},{ok},{fail},{rate:.1f},{avg:.0f},{p95:.0f}")

asyncio.run(main())
PY
}

echo "=== 32-combo (2^5) HSM enable/disable test ==="
echo "  per-step TPS  : $TPS"
echo "  per-step DUR  : ${DUR}s"
echo ""
printf "%-7s %-6s %-7s %-6s %-7s %-7s %-7s   %s\n" \
  "Combo" "Active" "Sent" "Ok" "Fail" "Rate%" "Avgms" "Per-node Δ requests (lb1+lb2)"
echo "──────────────────────────────────────────────────────────────────────────────────────────────────────────"

for combo in $(seq 0 31); do
  # Decode 5-bit mask: bit i (0..4) = nodeI+1 enabled
  bits=""
  for i in 0 1 2 3 4; do
    if (( (combo >> i) & 1 )); then bits="${bits}1"; else bits="${bits}0"; fi
  done
  active=0
  restore_all
  for i in 0 1 2 3 4; do
    if [ "${bits:$i:1}" = "0" ]; then set_node "${NODES[$i]}" false; else active=$((active+1)); fi
  done
  sleep 4   # allow disable to take effect

  if [ $active -eq 0 ]; then
    printf "%-7s %-6s %-7s %-6s %-7s %-7s %-7s   %s\n" "$bits" "$active" "-" "-" "-" "-" "-" "all nodes disabled, skipping"
    continue
  fi

  before=$(snapshot_totals)
  res=$(run_step $TPS $DUR $REQ_TIMEOUT)
  IFS=',' read sent ok fail rate avg p95 <<<"$res"
  after=$(snapshot_totals)
  # compute deltas per node-id (sum across both lbs)
  delta=$(python3 - "$before" "$after" <<'PY'
import sys
b={}; a={}
for tok in sys.argv[1].split(','):
    nid,r,e=tok.split(':'); b[nid]=b.get(nid,0)+int(r)
for tok in sys.argv[2].split(','):
    nid,r,e=tok.split(':'); a[nid]=a.get(nid,0)+int(r)
parts=[f"{nid}={a[nid]-b.get(nid,0)}" for nid in ['node1','node2','node3','node4','node5']]
print(" ".join(parts))
PY
)

  if (( $(python3 -c "print(1 if float('$rate')>=99 else 0)") )); then
    color=$'\033[32m'
  elif (( $(python3 -c "print(1 if float('$rate')>=90 else 0)") )); then
    color=$'\033[33m'
  else
    color=$'\033[31m'
  fi
  reset=$'\033[0m'
  printf "%-7s %-6s %-7s %-6s %-7s ${color}%-7s${reset} %-7s   %s\n" \
    "$bits" "$active" "$sent" "$ok" "$fail" "$rate%" "$avg" "$delta"
done
restore_all
echo ""
echo "Done. All nodes restored."

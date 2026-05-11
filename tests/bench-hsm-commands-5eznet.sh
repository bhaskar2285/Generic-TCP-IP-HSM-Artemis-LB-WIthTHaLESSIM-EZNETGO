#!/bin/bash
# HSM Command Benchmark — 5 EZNet instances (ports 8120-8125 → eznet, 9105/9101/9106/9107/9108 → direct)
# Tests real HSM commands: NO (status), BM (gen ZMK), A0 (gen key), BA (encrypt), BC (decrypt), CA (verify PIN)
# Usage: DUR=15 TPS_LADDER="500 1000 2000 3000" CMD=mix bash bench-hsm-commands-5eznet.sh
set -u

DUR=${DUR:-15}
PASS_RATE=${PASS_RATE:-99}
REQ_TIMEOUT=${REQ_TIMEOUT:-45}
TPS_LADDER=${TPS_LADDER:-"500 1000 1500 2000 2500 3000"}
CMD=${CMD:-mix}    # no | bm | a0 | ba | mix
CONTAINERS=${CONTAINERS:-"lb-1 lb-2 eznet-1 eznet-2 eznet-3 eznet-4 eznet-5 hsm-sim-1 hsm-sim-2 hsm-sim-3 hsm-sim-4 hsm-sim-5"}
STATS_FILE=/tmp/docker-stats-hsm-cmd.csv
ulimit -n 65535 2>/dev/null || true

reset_circuits() {
  for id in node1 node2 node3 node4 node5; do
    curl -s -X POST "http://localhost:8110/api/v1/hsm-lb/nodes/$id/circuit-reset" >/dev/null 2>&1
    curl -s -X POST "http://localhost:8111/api/v1/hsm-lb/nodes/$id/circuit-reset" >/dev/null 2>&1
  done
}

start_stats() {
  : > "$STATS_FILE"
  (
    while true; do
      docker stats --no-stream --format '{{.Name}},{{.CPUPerc}},{{.MemUsage}}' $CONTAINERS 2>/dev/null \
      | while IFS=, read -r name cpu mem; do
          cpu_num=${cpu%\%}
          mem_num=${mem%% *}
          unit=$(echo "$mem_num" | sed -E 's/[0-9.]+//')
          val=$(echo  "$mem_num" | sed -E 's/[A-Za-z]+//')
          case "$unit" in GiB) val=$(echo "$val * 1024" | bc -l) ;; KiB) val=$(echo "$val / 1024" | bc -l) ;; esac
          echo "$(date +%s.%N),$name,$cpu_num,$val" >> "$STATS_FILE"
        done
      sleep 2
    done
  ) </dev/null >/dev/null 2>&1 &
  echo $!
}

stop_stats()     { kill "$1" 2>/dev/null; wait "$1" 2>/dev/null; }

summarize_stats() {
  local t_from=$1 t_to=$2
  python3 - "$STATS_FILE" "$t_from" "$t_to" "$CONTAINERS" <<'PY'
import sys
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
        parts.append(f"{c}: cpu {cpu_avg:.0f}%/{cpu_max:.0f}%  mem {mem_avg:.0f}/{mem_max:.0f}MiB")
    else:
        parts.append(f"{c}: no data")
print(" | ".join(parts))
PY
}

run_step() {
  local TPS=$1 D=$2 TO=$3 CMD=$4
  python3 - "$TPS" "$D" "$TO" "$CMD" <<'PY'
import asyncio, struct, time, sys, os, random, binascii

TPS   = float(sys.argv[1])
DUR   = float(sys.argv[2])
REQ_TO= float(sys.argv[3])
CMD   = sys.argv[4]

HOST  = "127.0.0.1"
# Direct EZNet ports (bypasses LB — hits eznet->hsm directly)
PORTS = [9105, 9101, 9106, 9107, 9108]

ok = fail = 0
lat = []
cmd_counts = {}

# ── Wire helpers ─────────────────────────────────────────────────────────────
def frame(tag4: bytes, payload: bytes) -> bytes:
    body = tag4 + payload
    return struct.pack(">H", len(body)) + body

def parse(data: bytes, tag4: bytes, expect_resp: bytes):
    """Returns (ok:bool, error_code:str)"""
    if len(data) < 8: return False, "short"
    if data[0:4] != tag4: return False, "tag_mismatch"
    if data[4:6] != expect_resp: return False, f"resp={data[4:6]}"
    ec = data[6:8].decode(errors="replace")
    return ec == "00", ec

# ── Command builders ──────────────────────────────────────────────────────────

def build_NO(tag): return frame(tag, b'NO00'), b'NP'

def build_BM(tag):   return frame(tag, b'BM000UU'), b'BN'       # Generate ZMK
def build_A0(tag):   return frame(tag, b'A00002U'), b'A1'       # Generate ZPK
def build_NC(tag):   return frame(tag, b'NC'), b'ND'             # Diagnostics random
def build_B2(tag):   return frame(tag, b'B2PING'), b'B3'        # Echo
def build_RA(tag):   return frame(tag, b'RA'), b'RB'             # Cancel auth state
def build_JA(tag):   return frame(tag, b'JA12345678901204'), b'JB'  # Generate PIN
def build_GM(tag):   return frame(tag, b'GM010000BDEADBEEFCAFE1234'), b'GN'  # Hash SHA-1

# Key generation family — all mode-0, various key types
def build_AS(tag):   return frame(tag, b'AS;0U0'), b'AT'         # Generate CVK pair
def build_BI(tag):   return frame(tag, b'BI;0U0'), b'BJ'         # Generate BDK
def build_IA(tag):   return frame(tag, b'IA' + b'U' + b'U'*33 + b';UU1'), b'IB'  # skip complex

# Simple status/check commands
def build_BU(tag):   return frame(tag, b'BU001U' + b'A'*32 + b';' + b'001;001'), b'BV'  # Check value — simplified

COMMANDS = {
    "no":  (build_NO,  b'NP'),
    "bm":  (build_BM,  b'BN'),
    "a0":  (build_A0,  b'A1'),
    "nc":  (build_NC,  b'ND'),
    "b2":  (build_B2,  b'B3'),
    "ra":  (build_RA,  b'RB'),
    "ja":  (build_JA,  b'JB'),
    "gm":  (build_GM,  b'GN'),
}
# Core mix: commands with no side-state, all verified implemented
MIX_CMDS = ["no", "bm", "a0", "nc", "b2", "ra", "ja", "gm"]

async def one(port, cmd_name):
    global ok, fail
    tag = os.urandom(4)
    builder, expect = COMMANDS[cmd_name]
    req, _ = builder(tag)
    t0 = time.time()
    reader = writer = None
    try:
        reader, writer = await asyncio.wait_for(
            asyncio.open_connection(HOST, port), timeout=REQ_TO)
        writer.write(req); await writer.drain()
        hdr = await asyncio.wait_for(reader.readexactly(2), timeout=REQ_TO)
        n = struct.unpack(">H", hdr)[0]
        body = await asyncio.wait_for(reader.readexactly(n), timeout=REQ_TO)
        dt = (time.time() - t0) * 1000
        good, ec = parse(body, tag, expect)
        if good:
            ok += 1; lat.append(dt)
            cmd_counts[cmd_name] = cmd_counts.get(cmd_name, 0) + 1
        else:
            fail += 1
    except Exception:
        fail += 1
    finally:
        if writer is not None:
            try: writer.close()
            except: pass

async def main():
    interval = 1.0 / TPS
    tasks = []; sent = 0; i = 0
    t0 = time.time(); end = t0 + DUR; nxt = t0
    while time.time() < end:
        port = PORTS[i % len(PORTS)]
        cmd_name = random.choice(MIX_CMDS) if CMD == "mix" else CMD
        tasks.append(asyncio.create_task(one(port, cmd_name)))
        sent += 1; i += 1; nxt += interval
        s = nxt - time.time()
        if s > 0: await asyncio.sleep(s)
    if tasks: await asyncio.wait(tasks, timeout=REQ_TO + 10)
    elapsed = time.time() - t0
    rate  = 100 * ok / sent if sent else 0
    atps  = ok / elapsed if elapsed else 0
    if lat:
        lat.sort()
        avg = sum(lat) / len(lat)
        p50 = lat[len(lat) // 2]
        p95 = lat[int(len(lat) * 0.95)]
        p99 = lat[int(len(lat) * 0.99)]
    else:
        avg = p50 = p95 = p99 = 0
    cmd_str = "|".join(f"{k}:{v}" for k, v in sorted(cmd_counts.items()))
    print(f"{sent},{ok},{fail},{rate:.1f},{atps:.1f},{avg:.0f},{p50:.0f},{p95:.0f},{p99:.0f},{cmd_str}")

asyncio.run(main())
PY
}

# ── Main ──────────────────────────────────────────────────────────────────────
echo "=== HSM Command Benchmark (5 EZNet) ==="
echo "  cmd         : $CMD"
echo "  ladder      : $TPS_LADDER"
echo "  duration    : ${DUR}s/step"
echo "  pass rate   : ${PASS_RATE}%"
echo "  containers  : $CONTAINERS"
echo ""

stats_pid=$(start_stats)
echo "stats sampler PID=$stats_pid"
echo ""

# warmup
echo "Warmup (200 TPS, 5s)..."
run_step 200 5 30 "$CMD" >/dev/null
echo "Done."
echo ""

printf "%-6s %-7s %-7s %-7s %-7s %-7s %-7s %-7s %-7s %-30s\n" \
  "TPS" "Sent" "Ok" "Fail" "Rate%" "ActTPS" "Avg" "p95" "p99" "CmdBreakdown"
echo "──────────────────────────────────────────────────────────────────────────────────────────────────"

LAST_PASS=0
for TPS in $TPS_LADDER; do
  reset_circuits
  sleep 1
  t_from=$(date +%s.%N)
  res=$(run_step "$TPS" "$DUR" "$REQ_TIMEOUT" "$CMD")
  t_to=$(date +%s.%N)
  IFS=',' read sent ok fail rate atps avg p50 p95 p99 cmds <<<"$res"
  pass=$(python3 -c "print(1 if float('$rate')>=$PASS_RATE else 0)")
  if [ "$pass" = "1" ]; then
    color=$'\033[32m'; verdict="PASS"; LAST_PASS=$TPS
  else
    color=$'\033[31m'; verdict="FAIL"
  fi
  reset=$'\033[0m'
  printf "${color}%-6s %-7s %-7s %-7s %-7s %-7s %-7s %-7s %-7s %-30s ${verdict}${reset}\n" \
    "$TPS" "$sent" "$ok" "$fail" "$rate%" "$atps" "$avg" "$p95" "$p99" "$cmds"
  echo "  STATS: $(summarize_stats "$t_from" "$t_to")"
  [ "$pass" != "1" ] && break
done

stop_stats "$stats_pid"
echo ""
echo "Max sustained TPS (≥${PASS_RATE}% pass): $LAST_PASS"

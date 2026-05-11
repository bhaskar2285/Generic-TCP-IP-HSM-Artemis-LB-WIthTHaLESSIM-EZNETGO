#!/bin/bash
# Go EZNet vs Java EZNet benchmark
# Java EZNet: ports 9105-9108, 9101
# Go  EZNet:  ports 9110-9114
# Usage: DUR=15 TPS_LADDER="500 1000 2000 3000" bash bench-go-eznet-vs-java.sh
set -u

DUR=${DUR:-15}
PASS_RATE=${PASS_RATE:-99}
REQ_TIMEOUT=${REQ_TIMEOUT:-45}
TPS_LADDER=${TPS_LADDER:-"500 1000 1500 2000 2500 3000"}
CMD=${CMD:-mix}

JAVA_PORTS=(9105 9101 9106 9107 9108)
GO_PORTS=(9110 9111 9112 9113 9114)

ulimit -n 65535 2>/dev/null || true

run_bench() {
  local name=$1; shift
  local ports=("$@")
  python3 - "${ports[@]}" "$TPS" "$DUR" "$REQ_TIMEOUT" "$CMD" <<'PY'
import asyncio, struct, time, sys, os, random

PORTS = [int(p) for p in sys.argv[1:-4]]
TPS   = float(sys.argv[-4])
DUR   = float(sys.argv[-3])
REQ_TO= float(sys.argv[-2])
CMD   = sys.argv[-1]
HOST  = "127.0.0.1"

ok = fail = 0
lat = []
cmd_counts = {}

def frame(tag4, payload):
    body = tag4 + payload
    return struct.pack(">H", len(body)) + body

def parse(data, tag4, expect_resp):
    if len(data) < 8: return False
    if data[0:4] != tag4: return False
    if data[4:6] != expect_resp: return False
    return data[6:8].decode(errors="replace") == "00"

COMMANDS = {
    "no": (lambda t: (frame(t, b'NO00'),   b'NP')),
    "bm": (lambda t: (frame(t, b'BM000UU'), b'BN')),
    "a0": (lambda t: (frame(t, b'A00002U'), b'A1')),
    "nc": (lambda t: (frame(t, b'NC'),       b'ND')),
    "b2": (lambda t: (frame(t, b'B2PING'),   b'B3')),
    "ra": (lambda t: (frame(t, b'RA'),        b'RB')),
    "ja": (lambda t: (frame(t, b'JA12345678901204'), b'JB')),
    "gm": (lambda t: (frame(t, b'GM010000BDEADBEEFCAFE1234'), b'GN')),
}
MIX = list(COMMANDS.keys())

async def one(port, cmd_name):
    global ok, fail
    tag = os.urandom(4)
    req, expect = COMMANDS[cmd_name](tag)
    t0 = time.time()
    try:
        r, w = await asyncio.wait_for(asyncio.open_connection(HOST, port), timeout=REQ_TO)
        w.write(req); await w.drain()
        hdr = await asyncio.wait_for(r.readexactly(2), timeout=REQ_TO)
        n = struct.unpack(">H", hdr)[0]
        body = await asyncio.wait_for(r.readexactly(n), timeout=REQ_TO)
        dt = (time.time()-t0)*1000
        if parse(body, tag, expect):
            ok += 1; lat.append(dt)
            cmd_counts[cmd_name] = cmd_counts.get(cmd_name, 0) + 1
        else:
            fail += 1
        try: w.close()
        except: pass
    except:
        fail += 1

async def main():
    interval = 1.0/TPS
    tasks=[]; sent=0; i=0
    t0=time.time(); end=t0+DUR; nxt=t0
    while time.time()<end:
        port=PORTS[i%len(PORTS)]
        cmd=random.choice(MIX) if CMD=='mix' else CMD
        tasks.append(asyncio.create_task(one(port,cmd)))
        sent+=1; i+=1; nxt+=interval
        s=nxt-time.time()
        if s>0: await asyncio.sleep(s)
    if tasks: await asyncio.wait(tasks, timeout=REQ_TO+10)
    elapsed=time.time()-t0
    rate=100*ok/sent if sent else 0
    atps=ok/elapsed if elapsed else 0
    if lat:
        lat.sort()
        avg=sum(lat)/len(lat)
        p95=lat[int(len(lat)*0.95)]
        p99=lat[int(len(lat)*0.99)]
    else:
        avg=p95=p99=0
    print(f"{sent},{ok},{fail},{rate:.1f},{atps:.1f},{avg:.0f},{p95:.0f},{p99:.0f}")

asyncio.run(main())
PY
}

header() {
  printf "\n%-8s %-6s %-7s %-7s %-7s %-7s %-7s %-7s %-7s\n" \
    "EZNet" "TPS" "Sent" "Ok" "Fail" "Rate%" "ActTPS" "p95ms" "p99ms"
  echo "────────────────────────────────────────────────────────────────────"
}

echo "=== Go EZNet vs Java EZNet Benchmark ==="
echo "  TPS ladder : $TPS_LADDER"
echo "  Duration   : ${DUR}s/step"
echo "  Cmd mix    : $CMD"
echo ""

header

for TPS in $TPS_LADDER; do
  for VARIANT in java go; do
    if [ "$VARIANT" = "java" ]; then
      PORTS=("${JAVA_PORTS[@]}")
    else
      PORTS=("${GO_PORTS[@]}")
    fi

    res=$(run_bench "$VARIANT" "${PORTS[@]}")
    IFS=',' read sent ok fail rate atps avg p95 p99 <<<"$res"
    pass=$(python3 -c "print('PASS' if float('$rate')>=$PASS_RATE else 'FAIL')")

    if [ "$pass" = "PASS" ]; then color=$'\033[32m'; else color=$'\033[31m'; fi
    reset=$'\033[0m'
    printf "${color}%-8s %-6s %-7s %-7s %-7s %-7s %-7s %-7s %-7s %s${reset}\n" \
      "$VARIANT" "$TPS" "$sent" "$ok" "$fail" "$rate%" "$atps" "$p95" "$p99" "$pass"
  done
  echo ""
done

echo "Done."

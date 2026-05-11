#!/bin/bash
# HSM Command Benchmark — 10 Go EZNet instances (ports 9110-9119)
# Usage: DUR=15 TPS_LADDER="500 1000 2000 3000" CMD=mix bash bench-hsm-commands-5go-eznet.sh
set -u

DUR=${DUR:-15}
PASS_RATE=${PASS_RATE:-99}
REQ_TIMEOUT=${REQ_TIMEOUT:-45}
TPS_LADDER=${TPS_LADDER:-"500 1000 1500 2000 2500 3000"}
CMD=${CMD:-mix}
CONTAINERS=${CONTAINERS:-"lb-1 lb-2 go-eznet-1 go-eznet-2 go-eznet-3 go-eznet-4 go-eznet-5 hsm-sim-1 hsm-sim-2 hsm-sim-3 hsm-sim-4 hsm-sim-5"}

ulimit -n 65535 2>/dev/null || true

reset_circuits() {
  for id in node1 node2 node3 node4 node5; do
    curl -s -X POST "http://localhost:8110/api/v1/hsm-lb/nodes/$id/circuit-reset" >/dev/null 2>&1
    curl -s -X POST "http://localhost:8111/api/v1/hsm-lb/nodes/$id/circuit-reset" >/dev/null 2>&1
  done
}

run_step() {
  local TPS=$1 D=$2 TO=$3 CMD=$4
  python3 - "$TPS" "$D" "$TO" "$CMD" <<'PY'
import asyncio, struct, time, sys, os, random

TPS   = float(sys.argv[1])
DUR   = float(sys.argv[2])
REQ_TO= float(sys.argv[3])
CMD   = sys.argv[4]

HOST  = "127.0.0.1"
# Go EZNet ports only
PORTS = [9110, 9111, 9112, 9113, 9114]

ok = fail = 0
lat = []
cmd_counts = {}

def frame(tag4, payload):
    body = tag4 + payload
    return struct.pack(">H", len(body)) + body

def parse(data, tag4, expect_resp):
    if len(data) < 8: return False, "short"
    if data[0:4] != tag4: return False, "tag_mismatch"
    if data[4:6] != expect_resp: return False, f"resp={data[4:6]}"
    ec = data[6:8].decode(errors="replace")
    return ec == "00", ec

def build_NO(tag): return frame(tag, b'NO00'), b'NP'
def build_BM(tag): return frame(tag, b'BM000UU'), b'BN'
def build_A0(tag): return frame(tag, b'A00002U'), b'A1'
def build_NC(tag): return frame(tag, b'NC'), b'ND'
def build_B2(tag): return frame(tag, b'B2PING'), b'B3'
def build_RA(tag): return frame(tag, b'RA'), b'RB'
def build_JA(tag): return frame(tag, b'JA12345678901204'), b'JB'
def build_GM(tag): return frame(tag, b'GM010000BDEADBEEFCAFE1234'), b'GN'
# Phase 2 — payShield 10K data protection + key management
def build_M0(tag): return frame(tag, b'M0' + b'0'*32 + b'0'*32), b'M1'   # Encrypt Data Block
def build_M2(tag): return frame(tag, b'M2' + b'0'*32 + b'0'*32), b'M3'   # Decrypt Data Block
def build_M4(tag): return frame(tag, b'M4' + b'0'*32 + b'0'*32), b'M5'   # Translate Data Block
def build_M6(tag): return frame(tag, b'M6' + b'0'*32 + b'0'*32), b'M7'   # Generate MAC
def build_M8(tag): return frame(tag, b'M8' + b'0'*32 + b'0'*16), b'M9'   # Verify MAC
def build_A8(tag): return frame(tag, b'A8' + b'0'*3 + b'0'*32 + b'0'*32 + b'U'), b'A9'  # Export Key
def build_EI(tag): return frame(tag, b'EI' + b'0'*4 + b'01'), b'EJ'      # Generate Key Pair
def build_KW(tag): return frame(tag, b'KW' + b'0'*16 + b'0'*16), b'KX'  # ARQC/ARPC (Cloud SKD)
def build_KU(tag): return frame(tag, b'KU' + b'0'*16 + b'0'*16), b'KV'  # Secure Message EMV 3.1.1
# AES-256 LMK keyblock commands (TR-31 / TR-34)
# A8 keyblock: scheme 'R' = TR-31 AES-256; key type '009' = AES-256; 32H ZMK + 32H key + 'R'
def build_A8kb(tag): return frame(tag, b'A8009' + b'0'*32 + b'0'*32 + b'R'), b'A9'  # Export TR-31 keyblock
# B8/B9  TR-34 key export: key type 'ZPK'(3A) + scheme 'R' + 32H key
def build_B8(tag):   return frame(tag, b'B8ZPK' + b'R' + b'0'*32), b'B9'            # TR-34 Key Export
# CS/CT  Modify Key Block Header: 32H keyblock + new header attributes
def build_CS(tag):   return frame(tag, b'CS' + b'R' + b'0'*32 + b'00P0AES     '), b'CT' # Modify Keyblock Header
# BU/BV  Generate Key Check Value: 32H LMK-encrypted AES key
def build_BU(tag):   return frame(tag, b'BU' + b'0'*32), b'BV'                        # Gen KCV
# A6/A7  Import Key (keyblock): scheme 'R' + TR-31 keyblock (32H)
def build_A6kb(tag): return frame(tag, b'A6' + b'R' + b'0'*32), b'A7'                # Import TR-31 keyblock

COMMANDS = {
    "no": (build_NO,  b'NP'),
    "bm": (build_BM,  b'BN'),
    "a0": (build_A0,  b'A1'),
    "nc": (build_NC,  b'ND'),
    "b2": (build_B2,  b'B3'),
    "ra": (build_RA,  b'RB'),
    "ja": (build_JA,  b'JB'),
    "gm": (build_GM,  b'GN'),
    # Phase 2
    "m0": (build_M0,  b'M1'),
    "m2": (build_M2,  b'M3'),
    "m4": (build_M4,  b'M5'),
    "m6": (build_M6,  b'M7'),
    "m8": (build_M8,  b'M9'),
    "a8": (build_A8,  b'A9'),
    "ei": (build_EI,  b'EJ'),
    "kw": (build_KW,  b'KX'),
    "ku":    (build_KU,   b'KV'),
    # AES-256 LMK keyblock
    "a8kb":  (build_A8kb, b'A9'),
    "b8":    (build_B8,   b'B9'),
    "cs":    (build_CS,   b'CT'),
    "bu":    (build_BU,   b'BV'),
    "a6kb":  (build_A6kb, b'A7'),
}
MIX_CMDS     = ["no", "bm", "a0", "nc", "b2", "ra", "ja", "gm"]
MIX_P2_CMDS  = ["m0", "m2", "m4", "m6", "m8", "a8", "ei", "kw", "ku"]
MIX_KB_CMDS  = ["a8kb", "b8", "cs", "bu", "a6kb"]   # AES-256 LMK keyblock
MIX_ALL_CMDS = MIX_CMDS + MIX_P2_CMDS + MIX_KB_CMDS
# Online transaction commands only — no EI/keygen, no key import/export
MIX_ONLINE_CMDS = ["no", "bm", "a0", "nc", "b2", "ra", "ja", "gm", "m0", "m2", "m4", "m6", "m8", "kw", "ku"]

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
        if   CMD == "mix":        cmd_name = random.choice(MIX_CMDS)
        elif CMD == "mix-p2":     cmd_name = random.choice(MIX_P2_CMDS)
        elif CMD == "mix-kb":     cmd_name = random.choice(MIX_KB_CMDS)
        elif CMD == "mix-all":    cmd_name = random.choice(MIX_ALL_CMDS)
        elif CMD == "mix-online": cmd_name = random.choice(MIX_ONLINE_CMDS)
        else:                     cmd_name = CMD
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
        p95 = lat[int(len(lat) * 0.95)]
        p99 = lat[int(len(lat) * 0.99)]
    else:
        avg = p95 = p99 = 0
    cmd_str = "|".join(f"{k}:{v}" for k, v in sorted(cmd_counts.items()))
    print(f"{sent},{ok},{fail},{rate:.1f},{atps:.1f},{avg:.0f},{p95:.0f},{p99:.0f},{cmd_str}")

asyncio.run(main())
PY
}

echo "=== HSM Command Benchmark (5 Go EZNet) ==="
echo "  cmd         : $CMD"
echo "  ladder      : $TPS_LADDER"
echo "  duration    : ${DUR}s/step"
echo "  pass rate   : ${PASS_RATE}%"
echo "  ports       : 9110-9119 (go-eznet-1..10)"
echo ""

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
  res=$(run_step "$TPS" "$DUR" "$REQ_TIMEOUT" "$CMD")
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
  [ "$pass" != "1" ] && break
done

echo ""
echo "Max sustained TPS (≥${PASS_RATE}% pass): $LAST_PASS"

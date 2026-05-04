#!/bin/bash
# HSM Load Balancer — Resilience Benchmark
# Tests: max TPS, circuit breaker trip, failover to surviving node, recovery

HSM_ADDR="127.0.0.1:9100"
LB_API="http://localhost:8110/api/v1/hsm-lb"

RED='\033[1;31m'; GREEN='\033[1;32m'; YELLOW='\033[1;33m'
CYAN='\033[1;36m'; WHITE='\033[1;37m'; BG_RED='\033[41m'
BG_GREEN='\033[42m'; RESET='\033[0m'; BOLD='\033[1m'

banner() { echo -e "${CYAN}${BOLD}$1${RESET}"; }
ok()     { echo -e "${GREEN}✓ $1${RESET}"; }
fail()   { echo -e "${RED}✗ $1${RESET}"; }
warn()   { echo -e "${YELLOW}⚠ $1${RESET}"; }
event()  { echo -e "${BG_RED}${WHITE}  !! $1  ${RESET}"; }
recover(){ echo -e "${BG_GREEN}${WHITE}  ✓✓ $1  ${RESET}"; }

node_status() {
    curl -s "$LB_API/status" 2>/dev/null | python3 -c "
import sys,json
d=json.load(sys.stdin)
for n in d['nodes']:
    cb='OPEN' if n.get('circuitOpen') else 'closed'
    h='healthy' if n['healthy'] else 'UNHEALTHY'
    en='enabled' if n['enabled'] else 'DISABLED'
    print(f\"  node={n['id']} port={n['port']} {h} circuit={cb} {en} reqs={n['totalRequests']} errs={n['totalErrors']} errPct={n['errorRatePct']}%\")
"
}

disable_node() {
    curl -s -X POST "$LB_API/nodes/$1/enabled?value=false" > /dev/null 2>&1
}
enable_node() {
    curl -s -X POST "$LB_API/nodes/$1/enabled?value=true" > /dev/null 2>&1
}
reset_circuit() {
    curl -s -X POST "$LB_API/nodes/$1/circuit-reset" > /dev/null 2>&1
}

run_test() {
    local label="$1" tps=$2 duration=$3
    python3 - "$tps" "$duration" <<'EOF'
import socket,threading,time,uuid,sys
tps=float(sys.argv[1]); dur=int(sys.argv[2])
HOST="127.0.0.1"; PORT=9100
success=0;failure=0;mismatch=0;lock=threading.Lock()
def send_one():
    global success,failure,mismatch
    tag=uuid.uuid4().hex[:4].encode()
    req=bytes([0,8])+tag+b'NO'+b'00'
    try:
        s=socket.socket();s.settimeout(15);s.connect((HOST,PORT))
        s.sendall(req);data=s.recv(4096);s.close()
        if len(data)<10: 
            with lock:failure+=1;return
        if data[6:8]!=b'NP' or data[8:10]!=b'00':
            with lock:failure+=1
        elif data[2:6]!=tag:
            with lock:mismatch+=1
        else:
            with lock:success+=1
    except:
        with lock:failure+=1
interval=1.0/tps;end=time.time()+dur;threads=[];sent=0
while time.time()<end:
    t=threading.Thread(target=send_one,daemon=True);t.start();threads.append(t);sent+=1;time.sleep(interval)
for t in threads: t.join(timeout=35)
rate=100*success/sent if sent else 0
print(f"{sent},{success},{failure},{mismatch},{rate:.1f}")
EOF
}

echo ""
banner "════════════════════════════════════════════════════════"
banner "   HSM LOAD BALANCER — RESILIENCE BENCHMARK"
banner "════════════════════════════════════════════════════════"
echo ""

# ── Phase 1: Max TPS sweep ──────────────────────────────────
banner "PHASE 1: Max Sustainable TPS (2 nodes, ROUND_ROBIN)"
echo ""
printf "${BOLD}%-8s %-6s %-8s %-6s %-9s %-10s${RESET}\n" "TPS" "Sent" "Success" "Fail" "Mismatch" "Rate"
echo "────────────────────────────────────────────────────────"

max_tps=0
for tps in 5 8 9 10 12 15 20; do
    result=$(run_test "tps=$tps" $tps 6)
    IFS=',' read sent success failure mismatch rate <<< "$result"
    if (( $(echo "$rate >= 98" | python3 -c "import sys; print(1 if eval(sys.stdin.read()) else 0)") )); then
        echo -e "${GREEN}$(printf "%-8s %-6s %-8s %-6s %-9s %-10s [98%+]" "$tps" "$sent" "$success" "$failure" "$mismatch" "$rate%")${RESET}"
        max_tps=$tps
    else
        echo -e "${RED}$(printf "%-8s %-6s %-8s %-6s %-9s %-10s ✗" "$tps" "$sent" "$success" "$failure" "$mismatch" "$rate%")${RESET}"
    fi
done
echo ""
if [ $max_tps -gt 0 ]; then
    ok "Max sustained TPS at ≥98% success: ${BOLD}${max_tps} TPS${RESET}"
else
    warn "No TPS level achieved 98% — check HSM tunnel stability"
fi
echo ""

# ── Phase 2: Node failure + circuit breaker ─────────────────
banner "PHASE 2: Node Failure Resilience (node2 disabled mid-flight)"
echo ""
echo "Starting 9 TPS load (6s baseline)..."
baseline=$(run_test "baseline" 9 6)
IFS=',' read sent success failure mismatch rate <<< "$baseline"
echo -e "  Baseline: Sent=$sent Success=$success Fail=$failure Rate=${rate}%"
echo ""

echo "Node status before failure:"
node_status
echo ""

event "SIMULATING node2 FAILURE — disabling node2 at runtime"
disable_node "node2"
sleep 1

echo "Running 9 TPS for 10s with node2 DOWN..."
result_down=$(run_test "node2-down" 9 10)
IFS=',' read sent success failure mismatch rate_down <<< "$result_down"

echo ""
echo "Node status during failure:"
node_status
echo ""

if (( $(echo "$rate_down >= 95" | python3 -c "import sys; print(1 if eval(sys.stdin.read()) else 0)") )); then
    ok "Failover SUCCESS — ${BOLD}${rate_down}%${RESET} success on single node (node1 only)"
else
    warn "Failover partial — ${rate_down}% (expected ≥95% on surviving node)"
fi
echo ""

recover "RESTORING node2 — re-enabling at runtime"
enable_node "node2"
reset_circuit "node2"
sleep 2

echo "Running 9 TPS for 6s after node2 restored..."
result_up=$(run_test "node2-restored" 9 6)
IFS=',' read sent success failure mismatch rate_up <<< "$result_up"

echo ""
echo "Node status after recovery:"
node_status
echo ""

if (( $(echo "$rate_up >= 98" | python3 -c "import sys; print(1 if eval(sys.stdin.read()) else 0)") )); then
    ok "Recovery SUCCESS — ${BOLD}${rate_up}%${RESET} after node2 restored (both nodes serving)"
else
    warn "Recovery partial — ${rate_up}% (may need more time for health check)"
fi

echo ""
banner "════════════════════════════════════════════════════════"
banner "   BENCHMARK COMPLETE"
banner "════════════════════════════════════════════════════════"
echo -e "  ${WHITE}Max TPS at 98%:${RESET}         ${GREEN}${BOLD}${max_tps} TPS${RESET}"
echo -e "  ${WHITE}Single-node failover:${RESET}   ${GREEN}${BOLD}${rate_down}%${RESET}"
echo -e "  ${WHITE}Post-recovery rate:${RESET}     ${GREEN}${BOLD}${rate_up}%${RESET}"
echo ""

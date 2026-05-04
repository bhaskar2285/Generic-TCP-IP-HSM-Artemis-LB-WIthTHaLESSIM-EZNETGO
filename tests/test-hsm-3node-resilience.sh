#!/bin/bash
# HSM Load Balancer — 3-Node Resilience Benchmark
# All 8 binary combos (node1/node2/node3 on/off) + max TPS sweep

LB_API="http://localhost:8110/api/v1/hsm-lb"
HSM_HOST="127.0.0.1"; HSM_PORT=9100

RED='\033[1;31m'; GREEN='\033[1;32m'; YELLOW='\033[1;33m'
CYAN='\033[1;36m'; WHITE='\033[1;37m'; BG_RED='\033[41m'
BG_GREEN='\033[42m'; RESET='\033[0m'; BOLD='\033[1m'

banner()  { echo -e "${CYAN}${BOLD}$1${RESET}"; }
ok()      { echo -e "${GREEN}✓ $1${RESET}"; }
fail()    { echo -e "${RED}✗ $1${RESET}"; }
warn()    { echo -e "${YELLOW}⚠ $1${RESET}"; }
event()   { echo -e "${BG_RED}${WHITE}  !! $1  ${RESET}"; }
recover() { echo -e "${BG_GREEN}${WHITE}  ✓✓ $1  ${RESET}"; }

node_status() {
    curl -s "$LB_API/status" 2>/dev/null | python3 -c "
import sys,json
d=json.load(sys.stdin)
print(f\"  healthy={d['healthyNodes']}/{d['totalNodes']}\")
for n in d['nodes']:
    cb='OPEN' if n.get('circuitOpen') else 'closed'
    h='healthy' if n['healthy'] else 'UNHEALTHY'
    en='enabled' if n['enabled'] else 'DISABLED'
    print(f\"    {n['id']}:{n['port']} {h}/{en} circuit={cb} reqs={n['totalRequests']} errs={n['totalErrors']} errPct={n['errorRatePct']}%\")
"
}

set_node() {
    local id=$1 val=$2
    curl -s -X POST "$LB_API/nodes/$id/enabled?value=$val" > /dev/null 2>&1
}

reset_circuit() {
    curl -s -X POST "$LB_API/nodes/$1/circuit-reset" > /dev/null 2>&1
}

restore_all() {
    for id in node1 node2 node3; do
        set_node $id true
        reset_circuit $id
    done
    sleep 2
}

run_tps() {
    local tps=$1 duration=$2
    python3 - "$tps" "$duration" "$HSM_HOST" "$HSM_PORT" <<'EOF'
import socket,threading,time,uuid,sys
tps=float(sys.argv[1]); dur=int(sys.argv[2])
HOST=sys.argv[3]; PORT=int(sys.argv[4])
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
banner "════════════════════════════════════════════════════════════════"
banner "   HSM LB — 3-NODE RESILIENCE BENCHMARK"
banner "════════════════════════════════════════════════════════════════"
echo ""

# ── Phase 1: Max TPS sweep (all 3 nodes) ─────────────────────────────────────
banner "PHASE 1: Max Sustainable TPS (3 nodes, ROUND_ROBIN)"
echo ""
printf "${BOLD}%-8s %-6s %-8s %-6s %-9s %-10s${RESET}\n" "TPS" "Sent" "Success" "Fail" "Mismatch" "Rate"
echo "────────────────────────────────────────────────────────"

max_tps=0
for tps in 5 8 10 12 15 18 20 25 30; do
    result=$(run_tps $tps 6)
    IFS=',' read sent success failure mismatch rate <<< "$result"
    pass=$(python3 -c "print(1 if float('$rate')>=98 else 0)")
    if [ "$pass" = "1" ]; then
        echo -e "${GREEN}$(printf "%-8s %-6s %-8s %-6s %-9s %-10s [98%+]" "$tps" "$sent" "$success" "$failure" "$mismatch" "$rate%")${RESET}"
        max_tps=$tps
    else
        echo -e "${RED}$(printf "%-8s %-6s %-8s %-6s %-9s %-10s ✗" "$tps" "$sent" "$success" "$failure" "$mismatch" "$rate%")${RESET}"
        break
    fi
done
echo ""
[ $max_tps -gt 0 ] && ok "Max sustained TPS at ≥98%: ${BOLD}${max_tps} TPS${RESET}" || warn "No TPS level hit 98% — check tunnels"

# pick benchmark TPS = 80% of max (floor), min 5
BENCH_TPS=$(python3 -c "print(max(5, int($max_tps * 0.8)))")
echo -e "  Benchmark TPS for combo tests: ${BOLD}${BENCH_TPS}${RESET}"
echo ""

# ── Phase 2: All 8 node combinations ─────────────────────────────────────────
banner "PHASE 2: All 8 Node Combinations (on=1, off=0 per node1/node2/node3)"
echo ""
printf "${BOLD}%-14s %-8s %-8s %-6s %-8s %-10s %-12s${RESET}\n" "Combo(1/2/3)" "Sent" "Success" "Fail" "Rate" "Status" "Notes"
echo "──────────────────────────────────────────────────────────────────────────"

declare -A COMBO_RESULTS

for combo in 000 001 010 011 100 101 110 111; do
    n1=${combo:0:1}; n2=${combo:1:1}; n3=${combo:2:1}
    active=$(( n1 + n2 + n3 ))

    restore_all
    [ "$n1" = "0" ] && set_node node1 false
    [ "$n2" = "0" ] && set_node node2 false
    [ "$n3" = "0" ] && set_node node3 false
    sleep 12  # wait for health check + consumer scaling to fire (interval=10s)

    if [ $active -eq 0 ]; then
        # All down — expect all failures
        result=$(run_tps $BENCH_TPS 5)
        IFS=',' read sent success failure mismatch rate <<< "$result"
        echo -e "${RED}$(printf "%-14s %-8s %-8s %-6s %-8s %-10s %-12s" "$combo" "$sent" "$success" "$failure" "$rate%" "ALL DOWN" "expected 0%")${RESET}"
        COMBO_RESULTS[$combo]="$rate"
    else
        result=$(run_tps $BENCH_TPS 8)
        IFS=',' read sent success failure mismatch rate <<< "$result"
        pass=$(python3 -c "print(1 if float('$rate')>=95 else 0)")
        nodes_label="${active}/${3} node(s)"
        if [ "$pass" = "1" ]; then
            echo -e "${GREEN}$(printf "%-14s %-8s %-8s %-6s %-8s %-10s %-12s" "$combo" "$sent" "$success" "$failure" "$rate%" "OK" "$nodes_label")${RESET}"
        else
            echo -e "${YELLOW}$(printf "%-14s %-8s %-8s %-6s %-8s %-10s %-12s" "$combo" "$sent" "$success" "$failure" "$rate%" "PARTIAL" "$nodes_label")${RESET}"
        fi
        COMBO_RESULTS[$combo]="$rate"
    fi
done

restore_all
echo ""

# ── Phase 3: Hot failover — 2 nodes die mid-flight ───────────────────────────
banner "PHASE 3: Hot Failover — 2 Nodes Fail Mid-Flight"
echo ""
echo "Starting ${BENCH_TPS} TPS baseline (6s)..."
baseline=$(run_tps $BENCH_TPS 6)
IFS=',' read sent success failure mismatch rate <<< "$baseline"
echo -e "  Baseline: sent=$sent success=$success fail=$failure rate=${rate}%"
echo ""

event "KILLING node2 + node3 — only node1 survives"
set_node node2 false; set_node node3 false
sleep 12  # wait for health check + consumer scaling

echo "Running ${BENCH_TPS} TPS for 10s (node1 only, consumers scaled down)..."
result_1node=$(run_tps $BENCH_TPS 10)
IFS=',' read sent success failure mismatch rate_1node <<< "$result_1node"
echo ""
node_status
echo ""
pass=$(python3 -c "print(1 if float('$rate_1node')>=90 else 0)")
[ "$pass" = "1" ] && ok "Single-node failover: ${BOLD}${rate_1node}%${RESET}" || warn "Single-node failover: ${rate_1node}% (below 90%)"
echo ""

recover "RESTORING node2 + node3"
set_node node2 true; set_node node3 true
reset_circuit node2; reset_circuit node3
sleep 12  # wait for health check + consumer scaling back up

echo "Running ${BENCH_TPS} TPS for 6s (all 3 nodes restored)..."
result_restored=$(run_tps $BENCH_TPS 6)
IFS=',' read sent success failure mismatch rate_restored <<< "$result_restored"
echo ""
node_status
echo ""
pass=$(python3 -c "print(1 if float('$rate_restored')>=98 else 0)")
[ "$pass" = "1" ] && ok "Post-recovery: ${BOLD}${rate_restored}%${RESET}" || warn "Post-recovery: ${rate_restored}% (below 98%)"

echo ""
banner "════════════════════════════════════════════════════════════════"
banner "   BENCHMARK SUMMARY"
banner "════════════════════════════════════════════════════════════════"
echo -e "  ${WHITE}Max TPS at ≥98% (3 nodes):${RESET}     ${GREEN}${BOLD}${max_tps} TPS${RESET}"
echo -e "  ${WHITE}Single-node failover rate:${RESET}     ${GREEN}${BOLD}${rate_1node}%${RESET}"
echo -e "  ${WHITE}Post-recovery rate:${RESET}            ${GREEN}${BOLD}${rate_restored}%${RESET}"
echo ""
echo -e "  ${BOLD}Combo results (node1/node2/node3):${RESET}"
for combo in 000 001 010 011 100 101 110 111; do
    rate=${COMBO_RESULTS[$combo]:-N/A}
    n1=${combo:0:1}; n2=${combo:1:1}; n3=${combo:2:1}
    active=$(( n1 + n2 + n3 ))
    label="$active active"
    if [ $active -eq 0 ]; then
        echo -e "    ${RED}$combo → ${rate}% ($label — expected all-fail)${RESET}"
    else
        pass=$(python3 -c "print(1 if '${rate}'!='N/A' and float('${rate}')>=95 else 0)")
        [ "$pass" = "1" ] && echo -e "    ${GREEN}$combo → ${rate}% ($label)${RESET}" || echo -e "    ${YELLOW}$combo → ${rate}% ($label) ⚠${RESET}"
    fi
done
echo ""

#!/bin/bash
LB1_API="http://localhost:8110/api/v1/hsm-lb"
LB2_API="http://localhost:8111/api/v1/hsm-lb"
HSM_HOST="127.0.0.1"
PORT1=9100; PORT2=9101
GREEN='\033[1;32m'; RED='\033[1;31m'; YELLOW='\033[1;33m'; CYAN='\033[1;36m'; BOLD='\033[1m'; RESET='\033[0m'

run_dual_tps() {
    local tps=$1 duration=$2
    # Split TPS evenly across both EZNet ports
    python3 - "$tps" "$duration" "$HSM_HOST" "$PORT1" "$PORT2" <<'EOF'
import socket,threading,time,uuid,sys
tps=float(sys.argv[1]); dur=int(sys.argv[2])
HOST=sys.argv[3]; P1=int(sys.argv[4]); P2=int(sys.argv[5])
success=0;failure=0;lock=threading.Lock()
ports=[P1,P2]
idx=0; idx_lock=threading.Lock()

def send_one(port):
    global success,failure
    tag=uuid.uuid4().hex[:4].encode()
    req=bytes([0,8])+tag+b'NO'+b'00'
    try:
        s=socket.socket();s.settimeout(15);s.connect((HOST,port))
        s.sendall(req);data=s.recv(4096);s.close()
        if len(data)>=10 and data[6:8]==b'NP' and data[8:10]==b'00' and data[2:6]==tag:
            with lock: success+=1
        else:
            with lock: failure+=1
    except:
        with lock: failure+=1

interval=1.0/tps; end=time.time()+dur; threads=[]; sent=0; port_toggle=0
while time.time()<end:
    port=ports[port_toggle % 2]; port_toggle+=1
    t=threading.Thread(target=send_one,args=(port,),daemon=True)
    t.start(); threads.append(t); sent+=1; time.sleep(interval)
for t in threads: t.join(timeout=35)
rate=100*success/sent if sent else 0
print(f"{sent},{success},{failure},{rate:.1f}")
EOF
}

lb_stats() {
    echo -e "${CYAN}lb-1:${RESET}"
    curl -s "$LB1_API/status" 2>/dev/null | python3 -c "
import sys,json; d=json.load(sys.stdin)
print(f\"  instance={d['instanceId']} healthy={d['healthyNodes']}/{d['totalNodes']} consumers={d['jmsActiveConsumers']}/{d['jmsMaxConsumers']}\")
for n in d['nodes']: print(f\"    {n['id']} reqs={n['totalRequests']} errs={n['totalErrors']} errPct={n['errorRatePct']}%\")"
    echo -e "${CYAN}lb-2:${RESET}"
    curl -s "$LB2_API/status" 2>/dev/null | python3 -c "
import sys,json; d=json.load(sys.stdin)
print(f\"  instance={d['instanceId']} healthy={d['healthyNodes']}/{d['totalNodes']} consumers={d['jmsActiveConsumers']}/{d['jmsMaxConsumers']}\")
for n in d['nodes']: print(f\"    {n['id']} reqs={n['totalRequests']} errs={n['totalErrors']} errPct={n['errorRatePct']}%\")"
}

echo ""
echo -e "${CYAN}${BOLD}════════════════════════════════════════════════════════════════${RESET}"
echo -e "${CYAN}${BOLD}   DUAL EZNET + DUAL LB BENCHMARK (ports 9100+9101)${RESET}"
echo -e "${CYAN}${BOLD}════════════════════════════════════════════════════════════════${RESET}"
echo ""

# Phase 1: TPS sweep
echo -e "${CYAN}${BOLD}PHASE 1: Max TPS Sweep (2x EZNet → 2x LB → 3x HSM)${RESET}"
echo ""
printf "${BOLD}%-8s %-6s %-8s %-6s %-10s${RESET}\n" "TPS" "Sent" "Success" "Fail" "Rate"
echo "────────────────────────────────────────────"
max_tps=0
for tps in 5 8 10 12 15 18 20 25 30; do
    result=$(run_dual_tps $tps 6)
    IFS=',' read sent success failure rate <<< "$result"
    pass=$(python3 -c "print(1 if float('$rate')>=98 else 0)")
    if [ "$pass" = "1" ]; then
        echo -e "${GREEN}$(printf "%-8s %-6s %-8s %-6s %-10s" "$tps" "$sent" "$success" "$failure" "$rate%") ✓${RESET}"
        max_tps=$tps
    else
        echo -e "${RED}$(printf "%-8s %-6s %-8s %-6s %-10s" "$tps" "$sent" "$success" "$failure" "$rate%") ✗${RESET}"
        break
    fi
done
echo ""
echo -e "${GREEN}Max TPS: ${BOLD}${max_tps}${RESET}"
BENCH_TPS=$(python3 -c "print(max(5, int($max_tps * 0.8)))")
echo -e "Benchmark TPS: ${BOLD}${BENCH_TPS}${RESET}"
echo ""

# Phase 2: LB distribution check
echo -e "${CYAN}${BOLD}PHASE 2: Load Distribution Across Both LB Instances${RESET}"
echo ""
echo "Running ${BENCH_TPS} TPS for 15s..."
result=$(run_dual_tps $BENCH_TPS 15)
IFS=',' read sent success failure rate <<< "$result"
echo -e "  sent=$sent success=$success fail=$failure rate=${rate}%"
echo ""
lb_stats
echo ""

# Phase 3: Kill lb-1 mid-flight — lb-2 must absorb
echo -e "${CYAN}${BOLD}PHASE 3: Kill lb-1 — lb-2 absorbs all traffic${RESET}"
echo ""
echo "Baseline ${BENCH_TPS} TPS (6s)..."
result=$(run_dual_tps $BENCH_TPS 6)
IFS=',' read sent success failure rate <<< "$result"
echo -e "  Baseline: sent=$sent success=$success fail=$failure rate=${rate}%"
echo ""
echo -e "${RED}${BOLD}!! STOPPING thales-lb1${RESET}"
supervisorctl stop thales-lb 2>/dev/null
sleep 3
echo "Running ${BENCH_TPS} TPS for 10s (lb-2 only)..."
result=$(run_dual_tps $BENCH_TPS 10)
IFS=',' read sent success failure rate <<< "$result"
pass=$(python3 -c "print(1 if float('$rate')>=95 else 0)")
[ "$pass" = "1" ] && echo -e "${GREEN}lb-1 dead, lb-2 alone: ${BOLD}${rate}%${RESET}" || echo -e "${YELLOW}lb-1 dead, lb-2 alone: ${rate}% (below 95%)${RESET}"
echo ""
echo -e "${GREEN}${BOLD}✓✓ RESTORING thales-lb1${RESET}"
supervisorctl start thales-lb 2>/dev/null
sleep 5
echo "Post-recovery ${BENCH_TPS} TPS (6s)..."
result=$(run_dual_tps $BENCH_TPS 6)
IFS=',' read sent success failure rate <<< "$result"
echo -e "  Post-recovery: rate=${rate}%"
echo ""

echo -e "${CYAN}${BOLD}════════════════════════════════════════════════════════════════${RESET}"
echo -e "${CYAN}${BOLD}   SUMMARY${RESET}"
echo -e "${CYAN}${BOLD}════════════════════════════════════════════════════════════════${RESET}"
echo -e "  Max TPS (2xEZNet 2xLB 3xHSM): ${GREEN}${BOLD}${max_tps} TPS${RESET}"
echo -e "  lb-1 failover rate:            ${GREEN}${BOLD}${rate}%${RESET}"
echo ""
lb_stats

#!/bin/bash
LB_API="http://localhost:8110/api/v1/hsm-lb"
HSM_HOST="127.0.0.1"; HSM_PORT=9100
GREEN='\033[1;32m'; RED='\033[1;31m'; YELLOW='\033[1;33m'; CYAN='\033[1;36m'; BOLD='\033[1m'; RESET='\033[0m'

run_tps() {
    local tps=$1 duration=$2
    python3 - "$tps" "$duration" "$HSM_HOST" "$HSM_PORT" <<'PYEOF'
import socket,threading,time,uuid,sys
tps=float(sys.argv[1]); dur=int(sys.argv[2])
HOST=sys.argv[3]; PORT=int(sys.argv[4])
success=0;failure=0;lock=threading.Lock()
def send_one():
    global success,failure
    tag=uuid.uuid4().hex[:4].encode()
    req=bytes([0,8])+tag+b'NO'+b'00'
    try:
        s=socket.socket();s.settimeout(15);s.connect((HOST,PORT))
        s.sendall(req);data=s.recv(4096);s.close()
        if len(data)>=10 and data[6:8]==b'NP' and data[8:10]==b'00' and data[2:6]==tag:
            with lock: success+=1
        else:
            with lock: failure+=1
    except:
        with lock: failure+=1
interval=1.0/tps;end=time.time()+dur;threads=[];sent=0
while time.time()<end:
    t=threading.Thread(target=send_one,daemon=True);t.start();threads.append(t);sent+=1;time.sleep(interval)
for t in threads: t.join(timeout=35)
rate=100*success/sent if sent else 0
print(f"{sent},{success},{failure},{rate:.1f}")
PYEOF
}

set_node() { curl -s -X POST "$LB_API/nodes/$1/enabled?value=$2" > /dev/null; }
reset_circuit() { curl -s -X POST "$LB_API/nodes/$1/circuit-reset" > /dev/null; }
restore_all() { for id in node1 node2 node3; do set_node $id true; reset_circuit $id; done; sleep 2; }

echo -e "${CYAN}${BOLD}HSM 8-COMBO HIGH TPS TEST${RESET}"
echo ""

for TEST_TPS in 20 25 30; do
    echo -e "${CYAN}${BOLD}── TPS=$TEST_TPS ──────────────────────────────────────${RESET}"
    printf "${BOLD}%-14s %-6s %-8s %-6s %-8s %-6s${RESET}\n" "Combo" "Sent" "Success" "Fail" "Rate" "Status"
    echo "────────────────────────────────────────────────────"
    for combo in 000 001 010 011 100 101 110 111; do
        n1=${combo:0:1}; n2=${combo:1:1}; n3=${combo:2:1}
        active=$(( n1 + n2 + n3 ))
        restore_all
        [ "$n1" = "0" ] && set_node node1 false
        [ "$n2" = "0" ] && set_node node2 false
        [ "$n3" = "0" ] && set_node node3 false
        sleep 12
        if [ $active -eq 0 ]; then
            result=$(run_tps $TEST_TPS 5)
            IFS=',' read sent success failure rate <<< "$result"
            echo -e "${RED}$(printf "%-14s %-6s %-8s %-6s %-8s %-6s" "$combo" "$sent" "$success" "$failure" "$rate%" "ALL DOWN")${RESET}"
        else
            result=$(run_tps $TEST_TPS 8)
            IFS=',' read sent success failure rate <<< "$result"
            pass=$(python3 -c "print(1 if float('$rate')>=95 else 0)")
            [ "$pass" = "1" ] && echo -e "${GREEN}$(printf "%-14s %-6s %-8s %-6s %-8s %-6s" "$combo" "$sent" "$success" "$failure" "$rate%" "OK")${RESET}" \
                              || echo -e "${YELLOW}$(printf "%-14s %-6s %-8s %-6s %-8s %-6s" "$combo" "$sent" "$success" "$failure" "$rate%" "PARTIAL")${RESET}"
        fi
    done
    restore_all
    echo ""
done

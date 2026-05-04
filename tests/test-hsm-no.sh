#!/bin/bash

# Configuration
HSM_HOST="127.0.0.1"
HSM_PORT="9100"

# COMMAND SELECTION: NO = Generate Random Number, NP = Diagnostics
CMD="${1:-NO}"

# --- FRAME CONSTRUCTION ---
# Frame: [2-byte length][4-byte header "0000"][2-byte command][2-byte mode "00"]
# Header "0000" = 30 30 30 30 (4 ASCII chars, echoed back by payShield)
# Length = 8 (header 4 + command 2 + mode 2)

case "$CMD" in
    NO) REQ_HEX="0008303030304e4f3030" ;;   # NO + mode "00" = Generate Random Number
    NP) REQ_HEX="0008303030304e503030" ;;   # NP + mode "00" = Diagnostics
    *)
        echo "Unknown command: $CMD (use NO or NP)"
        exit 1
        ;;
esac

echo "--- HSM Test ---"
echo "Host   : $HSM_HOST:$HSM_PORT"
echo "Command: $CMD"
echo "Hex    : $REQ_HEX"
echo ""

RESPONSE_HEX=$(python3 -c "
import socket, sys
s = socket.socket()
s.connect(('$HSM_HOST', $HSM_PORT))
s.settimeout(15)
s.sendall(bytes.fromhex('$REQ_HEX'))
data = s.recv(4096)
s.close()
print(data.hex())
" 2>/dev/null)

if [ -z "$RESPONSE_HEX" ]; then
    echo "FAILED: No response received."
    echo "Check: eznet-inbound and thales-lb are running (supervisorctl status)"
    exit 1
fi

echo "Raw Hex Response: $RESPONSE_HEX"
echo ""

# Parse response frame
# [0-3]   = 2-byte length (4 hex chars)
# [4-11]  = 4-byte header (8 hex chars, echoed)
# [12-15] = 2-byte response code (4 hex chars)
# [16-19] = 2-byte error code (4 hex chars)
# [20+]   = data (random number for NO, etc.)

RESP_LEN_HEX="${RESPONSE_HEX:0:4}"
RESP_HEADER="${RESPONSE_HEX:4:8}"
RESP_CODE="${RESPONSE_HEX:12:4}"
RESP_ERR="${RESPONSE_HEX:16:4}"
RESP_DATA="${RESPONSE_HEX:20}"

echo "Length       : 0x$RESP_LEN_HEX"
echo "Header       : $RESP_HEADER"
echo "Response Code: $RESP_CODE"
echo "Error Code   : $RESP_ERR"
[ -n "$RESP_DATA" ] && echo "Data         : $RESP_DATA"
echo ""

# NP response code (hex 4e50) + error 00 (hex 3030) = success
if [[ "$RESP_CODE" == "4e50" && "$RESP_ERR" == "3030" ]]; then
    echo "SUCCESS: HSM Online — Error Code 00"
    if [ "$CMD" == "NO" ] && [ -n "$RESP_DATA" ]; then
        echo "Random Number: $RESP_DATA"
    fi
else
    echo "WARNING: HSM responded with error code 0x$RESP_ERR"
fi

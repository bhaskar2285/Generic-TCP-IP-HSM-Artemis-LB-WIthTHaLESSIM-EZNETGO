# HSM Transparent Load Balancer
## Implementation, Deployment & Test Guide

**Project:** `thales-transparent-lb`  
**Version:** 1.0.0  
**Date:** 2026-04-25  
**Owner:** ISC Internal Projects  
**Classification:** Internal — Restricted  

---

## Table of Contents

1. [Executive Summary](#1-executive-summary)
2. [Architecture](#2-architecture)
3. [Key Design Decisions](#3-key-design-decisions)
4. [Component Reference](#4-component-reference)
5. [Installation & Deployment](#5-installation--deployment)
6. [Configuration Reference](#6-configuration-reference)
7. [Load Balancing Algorithms](#7-load-balancing-algorithms)
8. [Test Cases & Validation](#8-test-cases--validation)
9. [Test Results (Executed 2026-04-25)](#9-test-results-executed-2026-04-25)
10. [HSM Brand Compatibility](#10-hsm-brand-compatibility)
11. [Operations & Monitoring](#11-operations--monitoring)
12. [Troubleshooting](#12-troubleshooting)

---

## 1. Executive Summary

`thales-transparent-lb` is a **generic TCP/IP Hardware Security Module (HSM) Load Balancer**. It acts as a transparent proxy between any client application and a pool of N HSM nodes. It does **not** parse, format, or modify HSM commands in any way — raw bytes are forwarded as-is and raw bytes are returned as-is.

**What it solves:**
- A single HSM node becomes a bottleneck and single point of failure
- Different applications need access to HSMs without managing connections themselves
- HSM nodes can be added or removed without changing client applications
- Unhealthy HSM nodes are automatically bypassed

**Key capabilities:**
| Capability | Detail |
|---|---|
| Protocol | Any TCP/IP binary protocol (Thales, Utimaco, SafeNet, nCipher, etc.) |
| Framing | 2-byte big-endian length prefix (configurable) |
| Load balancing | Round Robin, Least Connections, Weighted Round Robin, Random |
| Health checking | Active probe every 5 seconds using configurable command |
| Connection pooling | Apache Commons Pool2 — per-node socket pool |
| JMS integration | ActiveMQ — receives requests, returns replies via correlation ID |
| Concurrency | 20–100 JMS consumers (configurable) |
| Status API | REST endpoint: `GET /api/v1/hsm-lb/status` |

---

## 2. Architecture

### 2.1 Full Flow Diagram

```
┌─────────────────────────────────────────────────────────────────┐
│                      CLIENT APPLICATION                         │
│  (Payment Switch / Auth Engine / Any App)                       │
└────────────────────────┬────────────────────────────────────────┘
                         │ TCP/IP (raw HSM commands)
                         │ Port: 9100
                         ▼
┌─────────────────────────────────────────────────────────────────┐
│                   EZNET INBOUND ADAPTER                         │
│                  eznet-tcp2jms.war                              │
│                                                                 │
│  • Listens on TCP port 9100                                     │
│  • Reads 2-byte length-prefixed frames                          │
│  • Publishes BytesMessage to ActiveMQ                           │
│  • Sets JMSReplyTo + JMSCorrelationID for response routing      │
└────────────────────────┬────────────────────────────────────────┘
                         │ JMS BytesMessage
                         │ Queue: hsm.transparent.lb.in
                         ▼
┌─────────────────────────────────────────────────────────────────┐
│                      ACTIVEMQ BROKER                            │
│                   tcp://127.0.0.1:61616                         │
└────────────────────────┬────────────────────────────────────────┘
                         │
                         ▼
┌─────────────────────────────────────────────────────────────────┐
│              THALES TRANSPARENT LOAD BALANCER                   │
│                thales-transparent-lb.jar                        │
│                     Port: 8110 (REST)                           │
│                                                                 │
│  ┌──────────────────┐   ┌────────────────────────────────────┐  │
│  │  JMS Listener    │   │       Load Balancer Core           │  │
│  │  (20–100 threads)│──▶│  Algorithm: Round Robin /          │  │
│  │                  │   │  Least Connections /               │  │
│  │  Consumes from   │   │  Weighted Round Robin /            │  │
│  │  hsm.transparent │   │  Random                            │  │
│  │  .lb.in          │   └────────────────┬───────────────────┘  │
│  └──────────────────┘                    │                      │
│                                          │ Select healthy node  │
│  ┌──────────────────┐                    ▼                      │
│  │  Health Checker  │   ┌────────────────────────────────────┐  │
│  │  (every 5s)      │   │     Node Registry & Pools          │  │
│  │  NO / NP command │   │                                    │  │
│  └──────────────────┘   │  Node 1 Pool (Commons Pool2)       │  │
│                         │  Node 2 Pool (Commons Pool2)       │  │
│                         │  Node N Pool (Commons Pool2)       │  │
│                         └────────────────┬───────────────────┘  │
└──────────────────────────────────────────┼──────────────────────┘
                                           │ Raw TCP bytes
              ┌────────────────────────────┼────────────────────┐
              ▼                            ▼                    ▼
    ┌──────────────────┐       ┌──────────────────┐   ┌──────────────────┐
    │   HSM Node 1     │       │   HSM Node 2     │   │   HSM Node N     │
    │ 127.0.0.1:7004   │       │ 10.9.x.x:1500    │   │ 10.9.x.x:1500    │
    │ (tunnel/test)    │       │ (Thales/any)     │   │ (any brand)      │
    └──────────────────┘       └──────────────────┘   └──────────────────┘
```

### 2.2 Reply Flow

```
HSM Node → socket response → LB Pool → JMS reply (correlation ID) 
→ ActiveMQ → EzNet Inbound → TCP reply → Client Application
```

---

## 3. Key Design Decisions

| Decision | Choice | Reason |
|---|---|---|
| Command passthrough | No parsing | Works with any HSM brand, any command type |
| JMS framing | 2-byte big-endian length prefix | Matches Thales payShield standard framing |
| Socket pooling | Apache Commons Pool2 | Industry standard, proven at high TPS |
| Health check | Active TCP probe with NO/NP command | Detects node failure within 5 seconds |
| Reply routing | JMS correlation ID + ReplyTo | EzNet handles this natively; no custom code needed |
| Transport direction | JMS inbound only; LB owns outbound sockets | Simpler than double-EzNet; LB controls pooling |
| ActiveMQ for inbound | Decouples clients from HSM availability | SAF behaviour — if all HSMs are down, JMS queues |

---

## 4. Component Reference

### 4.1 Components and Ports

| Component | Binary | Port | Purpose |
|---|---|---|---|
| EzNet Inbound | `eznet-tcp2jms.war` | **9100** (TCP) / 8120 (HTTP) | Receives TCP commands from client apps |
| ActiveMQ Broker | (existing) | **61616** (OpenWire) | JMS transport |
| HSM Load Balancer | `thales-transparent-lb.jar` | **8110** (REST status) | Core LB logic |
| HSM Node 1 (test) | Thales payShield | **7004** (SSH tunnel) | Test HSM node |

### 4.2 JMS Queues

| Queue | Direction | Purpose |
|---|---|---|
| `hsm.transparent.lb.in` | Client → LB | Inbound HSM command requests |
| `hsm.transparent.lb.reply` | LB → Client | Replies routed via EzNet |
| `hsm.transparent.lb.control` | Admin | Future use (dynamic node registration) |

### 4.3 Source Code Structure

```
thales-transparent-lb/
├── pom.xml
├── src/main/java/com/isc/hsm/transparentlb/
│   ├── ThalesTransparentLbApplication.java     Main entry point
│   ├── config/
│   │   └── LbProperties.java                  All config (Spring @ConfigurationProperties)
│   ├── node/
│   │   ├── ThalesNode.java                    Node model (health, counters, weight)
│   │   ├── ThalesNodePool.java                Commons Pool2 socket pool per node
│   │   ├── ThalesSocketFactory.java           Pool2 factory — creates/validates sockets
│   │   └── ThalesNodeRegistry.java            Registry of all node pools
│   ├── health/
│   │   └── NodeHealthChecker.java             Scheduled probe every 5s
│   ├── lb/
│   │   ├── LoadBalancer.java                  Interface
│   │   ├── RoundRobinLb.java                  Algorithm: Round Robin
│   │   ├── LeastConnectionsLb.java            Algorithm: Least Connections
│   │   ├── WeightedRoundRobinLb.java          Algorithm: Weighted Round Robin
│   │   ├── RandomLb.java                      Algorithm: Random
│   │   └── LoadBalancerSelector.java          Picks active algorithm from config
│   ├── jms/
│   │   ├── HsmRequestListener.java            JMS consumer — drives passthrough
│   │   └── JmsConfig.java                     Listener container wiring
│   └── handler/
│       ├── PassthroughHandler.java            Core: selects node, sends bytes, returns bytes
│       └── StatusController.java             REST: GET /api/v1/hsm-lb/status
├── deploy/
│   ├── eznet-inbound/config/
│   │   └── application.properties             EzNet inbound config
│   ├── supervisor/
│   │   └── thales-lb.conf                     supervisord config
│   └── deploy.sh                              One-command deploy script
└── src/main/resources/
    └── application.properties                 LB config (nodes, algorithm, pool)
```

---

## 5. Installation & Deployment

### 5.1 Prerequisites

| Item | Requirement |
|---|---|
| Java | Temurin JDK 25 (`/usr/lib/jvm/temurin-25-jdk-arm64/`) |
| ActiveMQ | Running on `127.0.0.1:61616` |
| EzNet WAR | `/home/xenticate/bank_deploy/bin/eznet/eznet-tcp2jms.war` |
| Network | Outbound TCP from this server to each HSM node |
| Supervisor | `supervisord` running |

### 5.2 Build

```bash
cd /home/xenticate/thales-transparent-lb
mvn clean package -DskipTests
# Output: target/thales-transparent-lb.jar
```

### 5.3 Deploy (One Command)

```bash
bash /home/xenticate/thales-transparent-lb/deploy/deploy.sh
```

This script:
1. Creates `/data1/xenticate/hsm-lb/` directories
2. Copies LB jar and EzNet WAR to `/data1/xenticate/hsm-lb/bin/`
3. Copies config files to `/data1/xenticate/hsm-lb/config/` and `eznet-inbound/config/`
4. Installs supervisor config to `/etc/supervisor/conf.d/thales-lb.conf`
5. Runs `supervisorctl reread && update`

### 5.4 Manual Start (for testing)

```bash
# Start LB only (no EzNet, for JMS-direct testing)
/usr/lib/jvm/temurin-25-jdk-arm64/bin/java \
  -jar /home/xenticate/thales-transparent-lb/target/thales-transparent-lb.jar

# With external config file
/usr/lib/jvm/temurin-25-jdk-arm64/bin/java \
  -jar target/thales-transparent-lb.jar \
  --spring.config.location=/data1/xenticate/hsm-lb/config/application.properties
```

### 5.5 Verify Running

```bash
# Check processes
supervisorctl status thales-lb thales-lb-inbound

# Check LB health via REST
curl http://localhost:8110/api/v1/hsm-lb/status

# Check logs
tail -f /var/log/xenticate/thales-lb.log
```

---

## 6. Configuration Reference

### 6.1 LB Application Config (`application.properties`)

```properties
# HTTP port for REST status API
server.port=8110

# ActiveMQ connection
spring.activemq.broker-url=failover:(tcp://127.0.0.1:61616)

# JMS queue names
hsm.lb.queue.inbound=hsm.transparent.lb.in
hsm.lb.queue.control=hsm.transparent.lb.control

# JMS listener concurrency (tune for TPS)
hsm.lb.jms.concurrent-consumers=20
hsm.lb.jms.max-concurrent-consumers=100

# Load balancing algorithm
# Options: ROUND_ROBIN | LEAST_CONNECTIONS | WEIGHTED_ROUND_ROBIN | RANDOM
hsm.lb.algorithm=ROUND_ROBIN

# Health check interval
hsm.lb.health.interval-ms=5000
# NO command hex (Thales standard health check)
hsm.lb.health.command-hex=0008303030304e4f3030

# Socket pool settings (applied per node)
hsm.lb.pool.max-total=20          # max sockets per node
hsm.lb.pool.min-idle=2            # warm sockets kept ready
hsm.lb.pool.max-wait-ms=3000      # wait for socket from pool
hsm.lb.pool.socket-timeout-ms=10000
hsm.lb.pool.connect-timeout-ms=3000

# Node list: id:host:port:weight (comma separated)
# Add as many nodes as needed
hsm.lb.nodes=node1:127.0.0.1:7004:1
# Multi-node example:
# hsm.lb.nodes=node1:10.9.224.33:1500:1,node2:10.9.224.34:1500:1,node3:10.9.224.35:1500:2
```

### 6.2 EzNet Inbound Config

```properties
server.port=8120
tcp2jms.tcp.serializer.header-size=2      # 2-byte length prefix
tcp2jms.tcp.local.port=9100               # TCP port clients connect to
tcp2jms.jms.connection.broker-url=failover:(tcp://127.0.0.1:61616)
tcp2jms.jms.destination.self=hsm-transparent-lb-inbound
tcp2jms.jms.destination.inbound=hsm.transparent.lb.in
tcp2jms.jms.destination.outbound=hsm.transparent.lb.reply
tcp2jms.jms.listener.inbound-request.concurrent-consumers=20
tcp2jms.jms.listener.inbound-request.max-concurrent-consumers=100
```

---

## 7. Load Balancing Algorithms

### 7.1 Overview

| Algorithm | Property Value | How It Works | Best Used When |
|---|---|---|---|
| Round Robin | `ROUND_ROBIN` | Sends request 1 to node1, request 2 to node2, request 3 to node3, then repeats | All nodes have equal capability; most common choice |
| Least Connections | `LEAST_CONNECTIONS` | Always picks the node with fewest active socket connections right now | Requests vary in processing time; avoids piling up on a busy node |
| Weighted Round Robin | `WEIGHTED_ROUND_ROBIN` | Node weight = how many requests it gets per cycle | Nodes have different hardware capacity (e.g. node3 is twice as fast) |
| Random | `RANDOM` | Picks any healthy node at random | Simple spread; good for stateless equal-capacity nodes |

### 7.2 Weight Explained (Weighted Round Robin Only)

Weight defines what share of total requests a node receives.

**Example config:**
```properties
hsm.lb.nodes=node1:10.9.224.33:1500:1,node2:10.9.224.34:1500:2,node3:10.9.224.35:1500:1
```

Expanded rotation list: `[node1, node2, node2, node3]`  
Traffic split: node1=25%, node2=50%, node3=25%

Weight has no effect in ROUND_ROBIN, LEAST_CONNECTIONS, or RANDOM modes.

### 7.3 Changing Algorithm at Runtime

Edit `application.properties`, change `hsm.lb.algorithm`, then:
```bash
supervisorctl restart thales-lb
```

---

## 8. Test Cases & Validation

### Prerequisites for All Tests

```bash
# Verify ActiveMQ is running
nc -z 127.0.0.1 61616 && echo "ActiveMQ UP"

# Verify Thales tunnel is up on port 7004
bash /data1/xenticate/hsm/tryhsm3.sh

# Verify LB is running and at least one node is healthy
curl http://localhost:8110/api/v1/hsm-lb/status
# Expected: "healthyNodes": 1 (or more)
```

### Test Classpath Setup

```bash
JMS_JAR=/home/xenticate/.m2/repository/jakarta/jms/jakarta.jms-api/3.1.0/jakarta.jms-api-3.1.0.jar
AMQ_ALL=/home/xenticate/dumps/apache-activemq-6.2.2/activemq-all-6.2.2.jar
LOG4J="/home/xenticate/dumps/apache-activemq-6.2.2/lib/optional/log4j-api-2.25.3.jar:\
/home/xenticate/dumps/apache-activemq-6.2.2/lib/optional/log4j-core-2.25.3.jar:\
/home/xenticate/dumps/apache-activemq-6.2.2/lib/optional/log4j-slf4j2-impl-2.25.3.jar"
TESTCP="/tmp:$JMS_JAR:$AMQ_ALL:$LOG4J"
```

---

### TC-001: Direct Socket Health Check

**Purpose:** Verify the Thales tunnel port 7004 is accepting connections and responding.  
**Tool:** `nc` (netcat)  
**Command:**
```bash
bash /data1/xenticate/hsm/tryhsm3.sh
```

**Request bytes (hex):** `0008 3030 3030 4E4F 3030`  
**Frame breakdown:**

| Bytes | Hex | ASCII | Description |
|---|---|---|---|
| 1-2 | `00 08` | — | Length prefix = 8 bytes |
| 3-6 | `30 30 30 30` | `0000` | Message Header |
| 7-8 | `4E 4F` | `NO` | Command Code: Random Number |
| 9-10 | `30 30` | `00` | Parameters |

**Expected Response:**

| Bytes | Hex | ASCII | Description |
|---|---|---|---|
| 1-2 | `00 1A` | — | Length prefix = 26 bytes |
| 3-6 | `30 30 30 30` | `0000` | Message Header |
| 7-8 | `4E 50` | `NP` | Response Code (NO→NP) |
| 9-10 | `30 30` | `00` | Error Code 00 = Success |
| 11-26 | varies | random data | Generated random number |

**Pass Criteria:** Response contains `4E31 3030` (N100) or `4E50 3030` (NP00) with 2-byte length > 0.

---

### TC-002: NO Command via JMS Load Balancer (3 attempts, max 3)

**Purpose:** Verify end-to-end flow: JMS → LB → HSM → reply.  
**Test data:**

| Field | Value |
|---|---|
| Queue | `hsm.transparent.lb.in` |
| Command | `NO` — Random Number |
| Request hex | `0008303030304E4F3030` |
| Expected response prefix | `....0000NP00` |
| Error code position | bytes 9-10 of response body |
| Max retries | 3 |

**Manual test steps:**
```bash
# 1. Compile test
javac -cp "$JMS_JAR:$AMQ_ALL" /tmp/TestAllAlgorithms.java -d /tmp

# 2. Run
java -cp "$TESTCP" TestAllAlgorithms
```

**Expected output per attempt:**
```
Request: 0008303030304E4F3030
Response hex: 001A303030304E50303033313634313530302D303032343139313030
Response text: ..0000NP0031641500-002419100
PASS
```

---

### TC-003: L0 Command — Generate HMAC Secret Key (3 attempts, max 3)

**Purpose:** Verify LB transparently passes a real HSM command and returns a real HSM response.

**Request frame breakdown:**

| Field | ASCII | Hex | Bytes |
|---|---|---|---|
| TCP/IP Length Header | — | `0010` | 2 |
| Message Header | `ISC1` | `49 53 43 31` | 4 |
| Command Code | `L0` | `4C 30` | 2 |
| Hash Identifier | `06` (SHA-256) | `30 36` | 2 |
| HMAC Key Usage | `03` (Gen+Verify) | `30 33` | 2 |
| HMAC Key Length | `0020` (32 bytes) | `30 30 32 30` | 4 |
| HMAC Key Format | `00` (Thales format) | `30 30` | 2 |
| **Total body** | | | **16 bytes = 0x0010** |

**Full request hex:**
```
0010 49534331 4C30 3036 3033 30303230 3030
```
Written as single string: `0010495343314C303036303330303230 3030`

**Expected response breakdown (L1 — Generate HMAC Secret Key Response):**

| Field | ASCII | Hex | Description |
|---|---|---|---|
| TCP/IP Length | — | `002C` (44 bytes) | Response body length |
| Message Header | `ISC1` | `49534331` | |
| Command Code | `L1` | `4C31` | Response to L0 |
| Error Code | `00` | `3030` | No error |
| HMAC Key Length | `0032` | `30303332` | 50 hex chars = 25 bytes key block |
| HMAC Key | (binary) | varies | Encrypted HMAC key block |

**Reference response from your test data:**
```
TCP/IP Header: *[002C] 44 Bytes
Message Header: [ISC1]
Command Code:   [L1] Generate an HMAC Secret Key Response
Error Code:     [00] No error
HMAC Key Length:[0032]
HMAC Key:      *[8A3FF59073096419C36687668E3B0BE0EA253F03EC607D0D87A24422CA96E31E]B2
```

**Pass criteria:** Error code bytes 9-10 of response = `00`.  
Each call returns a **different HMAC key** (cryptographically random — this is correct and expected).

---

### TC-004: Round Robin Algorithm Verification

**Purpose:** With 2+ nodes, verify requests are distributed evenly.  
**Setup:** Add a second node to config:
```properties
hsm.lb.nodes=node1:127.0.0.1:7004:1,node2:127.0.0.1:7004:1
```
(Same physical HSM, two logical entries — for testing only)

**Expected:** With 4 requests, node1 gets 2, node2 gets 2.  
**Verify via:** `curl http://localhost:8110/api/v1/hsm-lb/status` — check `totalRequests` per node.

---

### TC-005: Least Connections Algorithm

**Set algorithm:**
```properties
hsm.lb.algorithm=LEAST_CONNECTIONS
```

**Purpose:** Verify LB routes to node with fewer active connections.  
**Expected:** Under concurrent load, requests spread across nodes based on active count, not fixed rotation.  
**Verify via:** Status API `activeConnections` field while under load.

---

### TC-006: Weighted Round Robin

**Set config:**
```properties
hsm.lb.algorithm=WEIGHTED_ROUND_ROBIN
hsm.lb.nodes=node1:127.0.0.1:7004:1,node2:127.0.0.1:7004:3
```

**Expected distribution for 8 requests:**
- node1: 2 requests (weight 1 out of 4 = 25%)
- node2: 6 requests (weight 3 out of 4 = 75%)

**Verify:** Status API `totalRequests` ratio ≈ 1:3.

---

### TC-007: Node Failure & Recovery

**Purpose:** Verify LB marks unhealthy node, routes only to healthy nodes.

**Steps:**
1. Start LB with 2 nodes configured
2. Block port of node2: `iptables -A OUTPUT -p tcp --dport <node2port> -j DROP`
3. Wait 10 seconds (2 health check cycles)
4. Check status: `healthyNodes` should drop to 1
5. Send 5 requests — all should succeed via node1
6. Unblock port: `iptables -D OUTPUT -p tcp --dport <node2port> -j DROP`
7. Wait 10 seconds — node2 should come back healthy

**Pass criteria:** No requests fail during node2 outage; all route to node1.

---

### TC-008: Connection Pool Reuse Under Burst Load

**Purpose:** Verify socket pool is reused, not creating a new socket per request.

**Command:**
```bash
# Send 5 rapid NO commands and check idleConnections > 0 after
for i in {1..5}; do
  # (use test script or JMS client)
done
curl http://localhost:8110/api/v1/hsm-lb/status
# Expected: idleConnections >= 1 (sockets returned to pool)
```

**Pass criteria:** `totalErrors: 0` and `idleConnections >= 1` after burst.

---

### TC-009: Status API Validation

```bash
curl -s http://localhost:8110/api/v1/hsm-lb/status | python3 -m json.tool
```

**Expected response structure:**
```json
{
  "algorithm": "ROUND_ROBIN",
  "totalNodes": 1,
  "healthyNodes": 1,
  "nodes": [
    {
      "id": "node1",
      "host": "127.0.0.1",
      "port": 7004,
      "weight": 1,
      "healthy": true,
      "activeConnections": 0,
      "idleConnections": 1,
      "totalRequests": 12,
      "totalErrors": 0,
      "lastHealthCheckMs": 1777093893290
    }
  ]
}
```

**Pass criteria:** HTTP 200, JSON valid, `healthyNodes >= 1`.

---

## 9. Test Results (Executed 2026-04-25)

All tests executed against Thales payShield tunnel on `127.0.0.1:7004`.

### TC-001 — Direct Socket Health Check
**PASS**
```
Status: HSM Online (Response Code 00: Success)
Raw response: 001a303030304e50303033313634313530302d303032343139313030
```

### TC-002 — NO Command via JMS LB (3/3)
**PASS**

| Attempt | Request | Response | Error Code | Result |
|---|---|---|---|---|
| 1 | `0008303030304E4F3030` | `001A303030304E503030...` | 00 | PASS |
| 2 | `0008303030304E4F3030` | `001A303030304E503030...` | 00 | PASS |
| 3 | `0008303030304E4F3030` | `001A303030304E503030...` | 00 | PASS |

### TC-003 — L0 Generate HMAC Secret Key (3/3)
**PASS** — Each response carries a different random HMAC key (correct behaviour)

| Attempt | Error Code | HMAC Key (hex, truncated) | Result |
|---|---|---|---|
| 1 | 00 | `C0B210D52E3B5D6D77A652CC44C4E369846C5967...` | PASS |
| 2 | 00 | `19A93BEDD48273A4D6E3614287DA258D0AF295262...` | PASS |
| 3 | 00 | `850B626D8233A558AD7834D3D0215BB2A11668...` | PASS |

**Note:** The HMAC key is different each time — this is correct. The HSM generates a new random key on each L0 call.

### TC-008 — Burst Pool Reuse (5/5)
**PASS**
```
5/5 passed in 1662ms
idleConnections: 1  (socket returned to pool, not destroyed)
totalErrors: 0
```

### Final LB Status After All Tests
```json
{
  "algorithm": "ROUND_ROBIN",
  "totalNodes": 1,
  "healthyNodes": 1,
  "totalRequests": 12,
  "totalErrors": 0,
  "idleConnections": 1,
  "healthy": true
}
```

---

## 10. HSM Brand Compatibility

**This load balancer works with any HSM that uses a TCP/IP socket with a length-prefixed binary protocol.**

| HSM Brand / Model | Protocol | Compatible? | Notes |
|---|---|---|---|
| Thales payShield 10K | Proprietary TCP, 2-byte length | **YES** (tested) | Default config matches |
| Thales payShield 9000 | Proprietary TCP, 2-byte length | **YES** | Same protocol |
| Thales Luna Network HSM | NTLS/TCP | YES | May need custom length prefix size |
| Utimaco SecurityServer | TCP binary | YES | Configure header-size accordingly |
| SafeNet (Gemalto) ProtectServer | TCP binary | YES | Adjust framing if needed |
| nCipher (Entrust) nShield | TCP binary | YES | Adjust framing if needed |
| AWS CloudHSM (on-prem PKCS#11) | TCP via PKCS#11 client | Not applicable | Uses library, not raw socket |
| SoftHSM2 | Custom TCP | YES | Useful for testing |

**Why it's brand-agnostic:**

The LB does exactly three things with your HSM command bytes:
1. Read them from the JMS `BytesMessage`
2. Write them to the selected HSM node's socket as-is
3. Read the response bytes back (using the 2-byte length prefix to know when response is complete)

It never inspects or modifies the payload. The only thing that must match your HSM is the **framing** — how many bytes the length prefix uses. This is controlled by `tcp2jms.tcp.serializer.header-size` in the EzNet config. Most HSMs use 2 bytes; some use 4 bytes.

**To connect a different HSM brand:**
1. Set `hsm.lb.nodes=nodeX:hsm-host:hsm-port:1` for each node
2. Set the correct `health-command-hex` for that brand's status probe
3. Adjust `header-size` in EzNet config to match framing (2 or 4 bytes)
4. That's it — no code changes

### 10.1 Quick-Reference: Connecting Any HSM Brand

> **This load balancer is 100% brand-agnostic.**
>
> It only does three things with HSM bytes:
> 1. **Read** raw bytes from JMS (what the client sent)
> 2. **Write** them to the selected HSM node's socket — unchanged, no modification
> 3. **Read** the response bytes back using the length prefix to know when the message is complete
>
> To switch or add a different brand (Utimaco, SafeNet, nCipher, Luna):
> - Change `hsm.lb.nodes` to point to the new `host:port`
> - Change `health-command-hex` to that brand's status probe command
> - Adjust `header-size=2` (EzNet config) if the brand uses 4-byte length framing instead of 2-byte
>
> No code changes. No recompile. Restart LB only.

### 10.2 Per-Brand Configuration Cheat Sheet

| HSM Brand | health-command-hex | header-size | Notes |
|---|---|---|---|
| Thales payShield 10K / 9000 | `0008303030304e4f3030` | `2` | Tested — default config |
| Thales payShield (ISC1 header) | `0006495343314e4f` | `2` | If using ISC1 message header |
| Utimaco SecurityServer | Vendor-specific PING | `4` | Check Utimaco admin guide |
| SafeNet ProtectServer | Vendor-specific | `2` or `4` | Check SafeNet docs |
| nCipher nShield | Vendor-specific | `4` | nShield uses 4-byte header |
| Luna Network HSM | Vendor-specific | `2` | Confirm with Thales Luna docs |
| SoftHSM2 (test) | Same as payShield | `2` | Use for dev/test environments |

**If you do not know the health probe command for your HSM brand**, set `health-command-hex` to empty and the health checker will use a TCP connect-only probe (just verifying the port is open). The LB will mark the node healthy if the TCP connection succeeds, without sending any bytes.

---

## 11. Operations & Monitoring

### Starting / Stopping

```bash
# Start both components
supervisorctl start thales-lb-inbound thales-lb

# Stop
supervisorctl stop thales-lb thales-lb-inbound

# Restart LB only (e.g. after config change)
supervisorctl restart thales-lb

# Status
supervisorctl status thales-lb thales-lb-inbound
```

### Log Files

| Log | Path | Contains |
|---|---|---|
| LB application | `/var/log/xenticate/thales-lb.log` | All LB events, routing decisions, errors |
| LB stderr | `/var/log/xenticate/thales-lb-err.log` | JVM errors |
| EzNet inbound | `/var/log/xenticate/thales-lb-inbound.log` | TCP connections, JMS publish |

### Monitoring Commands

```bash
# Live request counters
watch -n 2 'curl -s http://localhost:8110/api/v1/hsm-lb/status | python3 -m json.tool'

# Check active connections in pool
curl -s http://localhost:8110/api/v1/hsm-lb/status | python3 -c "
import sys,json
d=json.load(sys.stdin)
for n in d['nodes']:
    print(f'{n[\"id\"]}: healthy={n[\"healthy\"]} active={n[\"activeConnections\"]} idle={n[\"idleConnections\"]} req={n[\"totalRequests\"]} err={n[\"totalErrors\"]}')
"

# Tail logs for live events
tail -f /var/log/xenticate/thales-lb.log | grep -E "Routing|replied|health|ERROR"
```

### Adding a New HSM Node (no restart needed for next restart)

1. Edit `/data1/xenticate/hsm-lb/config/application.properties`
2. Add to `hsm.lb.nodes`:
   ```properties
   hsm.lb.nodes=node1:127.0.0.1:7004:1,node2:10.9.224.33:1500:1
   ```
3. `supervisorctl restart thales-lb`
4. Health checker will probe node2 within 5 seconds and mark it healthy

---

## 12. Troubleshooting

| Symptom | Likely Cause | Fix |
|---|---|---|
| `healthyNodes: 0` | All HSM tunnels/connections down | Check tunnel, verify `nc -z <host> <port>` works |
| `totalErrors > 0` | Socket timeout or HSM rejecting commands | Check HSM logs; increase `pool.socket-timeout-ms` |
| No JMS replies | EzNet not running or wrong queue name | `supervisorctl status thales-lb-inbound`; check queue names match |
| LB won't start | ActiveMQ not running | `supervisorctl start unit.activemq` |
| `NoClassDefFoundError` at startup | Wrong Java version | Confirm `java -version` is Temurin 25 |
| Requests piling up in queue | All nodes unhealthy | Check `healthyNodes` in status; LB falls back to all nodes on startup |
| Response is 2 zero bytes `0000` | LB received error from HSM passthrough | Check HSM node is accepting connections; check command framing |

---

*Document prepared: 2026-04-25*  
*Owner: ISC Internal Projects*  
*Tested on: Thales payShield tunnel, 127.0.0.1:7004*  
*Total test requests executed: 12 | Errors: 0*

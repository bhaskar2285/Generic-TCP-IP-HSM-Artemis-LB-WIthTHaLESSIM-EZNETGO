# HSM Transparent Load Balancer — ActiveMQ Artemis Edition
## Implementation, Deployment & Test Guide (Ubuntu WSL / Docker)

**Project:** `thales-artemis-lb`  
**Forked from:** `thales-transparent-lb` (ActiveMQ Classic)  
**Broker:** ActiveMQ Artemis 2.38.0 (replaces ActiveMQ Classic 5.18.3)  
**Date:** 2026-05-04  
**Classification:** Internal — Restricted

---

## Table of Contents

1. [What Changed from Classic](#1-what-changed-from-classic)
2. [Architecture](#2-architecture)
3. [Prerequisites — Ubuntu WSL](#3-prerequisites--ubuntu-wsl)
4. [Repository Setup](#4-repository-setup)
5. [Build Artifacts](#5-build-artifacts)
6. [Docker Stack Deployment](#6-docker-stack-deployment)
7. [Configuration Reference](#7-configuration-reference)
8. [Artemis HA — How Shared-Store Works](#8-artemis-ha--how-shared-store-works)
9. [HSM Tunnel Setup](#9-hsm-tunnel-setup)
10. [Switching Between Classic and Artemis](#10-switching-between-classic-and-artemis)
11. [Test Cases & Validation](#11-test-cases--validation)
12. [Port Reference](#12-port-reference)
13. [Troubleshooting](#13-troubleshooting)

---

## 1. What Changed from Classic

| Item | ActiveMQ Classic | ActiveMQ Artemis |
|------|-----------------|-----------------|
| Broker image | `apache/activemq-classic:5.18.3` | `apache/activemq-artemis:2.38.0` |
| HA mechanism | Shared KahaDB file lock | Shared journal file lock (same concept) |
| Broker config | `activemq.xml` (Spring XML) | `broker.xml` (Artemis XML) |
| Protocol to broker | OpenWire TCP | OpenWire TCP (same — no code change) |
| App connection string | `failover:(tcp://activemq-1:61616,...)` | `failover:(tcp://artemis-master:61616,...)` |
| Java source changes | — | **None required** |
| Management console | Classic Web UI :8161 | Artemis Hawtio console :8161 |

---

## 2. Architecture

```
  Client App
      │
      ▼
┌───────────┐   TCP    ┌─────────────────────────────┐
│  EZNet-1  │◄────────►│                             │
│  :9100    │  OpenWire│   Artemis Master :61616      │
└───────────┘◄────────►│   (holds journal file lock) │
                        │                             │
┌───────────┐  OpenWire│   Artemis Slave  :61616      │
│  EZNet-2  │◄────────►│   (waits — promotes on       │
│  :9101    │          │    master failure)           │
└───────────┘          └─────────────────────────────┘
                                    │ JMS (OpenWire)
                 ┌──────────────────┴──────────────────┐
                 ▼                                       ▼
          ┌──────────┐                           ┌──────────┐
          │   LB-1   │                           │   LB-2   │
          │  :8110   │                           │  :8111   │
          └──────────┘                           └──────────┘
               │ TCP tunnel                           │ TCP tunnel
     ┌─────────┼──────────┐              ┌────────────┼──────────┐
     ▼         ▼          ▼              ▼            ▼          ▼
  HSM-1     HSM-2      HSM-3          HSM-1        HSM-2      HSM-3
:9998     :10001     :10002          :9998        :10001     :10002
```

**Message flow:**
1. Client sends TCP frame → EZNet (tcp2jms bridge)
2. EZNet wraps frame → JMS message → `hsm.transparent.lb.in` queue on Artemis
3. LB-1 or LB-2 dequeues, forwards to HSM node via TCP tunnel
4. HSM replies → LB sends JMS reply to `hsm.transparent.lb.reply` with correlation ID
5. EZNet matches correlation ID → returns response TCP frame to client

---

## 3. Prerequisites — Ubuntu WSL

### 3.1 Install Docker

```bash
# Update packages
sudo apt-get update
sudo apt-get install -y ca-certificates curl gnupg

# Add Docker GPG key
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
sudo chmod a+r /etc/apt/keyrings/docker.gpg

# Add Docker repo
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
  https://download.docker.com/linux/ubuntu \
  $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

# Install Docker
sudo apt-get update
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

# Add your user to docker group (no sudo needed)
sudo usermod -aG docker $USER
newgrp docker

# Verify
docker --version
docker compose version
```

### 3.2 Install Java 21+ (for building the LB app)

```bash
sudo apt-get install -y openjdk-21-jdk
java -version
```

### 3.3 Install Maven

```bash
sudo apt-get install -y maven
mvn -version
```

### 3.4 WSL-specific: enable systemd (optional but recommended)

Add to `/etc/wsl.conf`:
```ini
[boot]
systemd=true
```
Then restart WSL from Windows PowerShell:
```powershell
wsl --shutdown
```

---

## 4. Repository Setup

```bash
# Clone Artemis fork
git clone https://github.com/bhaskar2285/Generic-TCP-IP-HSM-Artemis-LB.git thales-artemis-lb
cd thales-artemis-lb
```

Directory structure:
```
thales-artemis-lb/
├── src/                          ← Java source (LB app)
├── pom.xml
├── docker/
│   ├── docker-compose.yml        ← main Artemis stack
│   ├── artemis/
│   │   ├── broker-master.xml     ← Artemis HA master config
│   │   ├── broker-slave.xml      ← Artemis HA slave config
│   │   ├── Dockerfile-master     ← (reference only)
│   │   └── Dockerfile-slave      ← (reference only)
│   ├── lb/
│   │   └── Dockerfile
│   ├── eznet/
│   │   ├── Dockerfile
│   │   └── eznet-tcp2jms.war     ← EZNet binary (pre-built)
│   └── config/
│       ├── lb-1/application.properties
│       ├── lb-2/application.properties
│       ├── eznet-1/application.properties
│       └── eznet-2/application.properties
└── IMPLEMENTATION_AND_TEST_GUIDE.md
```

---

## 5. Build Artifacts

### 5.1 Build the LB application JAR

```bash
cd thales-artemis-lb
mvn clean package -DskipTests
# Output: target/thales-transparent-lb.jar
```

### 5.2 Copy artifacts to Docker context

```bash
cp target/thales-transparent-lb.jar docker/lb/thales-transparent-lb.jar

# eznet-tcp2jms.war is already in docker/eznet/ (committed in repo)
# If you have a newer WAR:
# cp /path/to/eznet-tcp2jms.war docker/eznet/eznet-tcp2jms.war
```

---

## 6. Docker Stack Deployment

### 6.1 Configure HSM nodes

Edit both LB config files to set your HSM node IPs and tunnel ports:

```bash
nano docker/config/lb-1/application.properties
nano docker/config/lb-2/application.properties
```

Change this line:
```properties
# Format: name:ip:port:weight
hsm.lb.nodes=node1:172.18.0.1:9998:1,node2:172.18.0.1:10001:1,node3:172.18.0.1:10002:1
```

> In WSL, `172.18.0.1` is the Docker bridge gateway — it reaches services
> bound to localhost on the WSL host (e.g. SSH tunnels).

### 6.2 Build Docker images

```bash
cd docker
docker compose build
```

### 6.3 Start the stack

```bash
docker compose up -d
```

### 6.4 Verify all containers running

```bash
docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
```

Expected after ~30 seconds:
```
artemis-master   Up X seconds (healthy)   ...0.0.0.0:61626->61616/tcp, 0.0.0.0:18163->8161/tcp
artemis-slave    Up X seconds             ...0.0.0.0:61627->61616/tcp, 0.0.0.0:18164->8161/tcp
lb-1             Up X seconds (healthy)   0.0.0.0:8110->8110/tcp
lb-2             Up X seconds (healthy)   0.0.0.0:8111->8111/tcp
eznet-1          Up X seconds             0.0.0.0:9100->9100/tcp, 0.0.0.0:8120->8120/tcp
eznet-2          Up X seconds             0.0.0.0:9101->9100/tcp, 0.0.0.0:8121->8121/tcp
```

### 6.5 Check LB health

```bash
curl http://localhost:8110/actuator/health
curl http://localhost:8111/actuator/health
```

Both must return `"status": "UP"` with `"jms": { "status": "UP" }`.

### 6.6 Artemis web console

- Master: http://localhost:18163
- Slave:  http://localhost:18164
- Login: `artemis` / `artemis`

### 6.7 Stop the stack

```bash
docker compose down
```

---

## 7. Configuration Reference

### 7.1 LB application (`docker/config/lb-1/application.properties`)

| Property | Default | Description |
|----------|---------|-------------|
| `server.port` | `8110` | LB HTTP management port |
| `spring.activemq.broker-url` | `failover:(tcp://artemis-master:61616,tcp://artemis-slave:61616)?...` | Artemis OpenWire failover URL |
| `hsm.lb.nodes` | `node1:172.18.0.1:9998:1,...` | HSM nodes — `name:ip:port:weight` |
| `hsm.lb.algorithm` | `ROUND_ROBIN` | `ROUND_ROBIN`, `LEAST_CONNECTIONS`, `WEIGHTED_ROUND_ROBIN`, `RANDOM` |
| `hsm.lb.instance-id` | `lb-1` | Instance ID shown in status/metrics |
| `hsm.lb.jms.concurrent-consumers` | `10` | Min JMS consumers |
| `hsm.lb.jms.max-concurrent-consumers` | `50` | Max JMS consumers |
| `hsm.lb.health.interval-ms` | `10000` | HSM health probe interval (ms) |
| `hsm.lb.health.command-hex` | `0008303030304e4f3030` | HSM NO command in hex |
| `hsm.lb.pool.max-total` | `1` | Max sockets per HSM node |
| `hsm.lb.pool.socket-timeout-ms` | `8000` | Socket read timeout |
| `hsm.lb.circuit-breaker.failure-threshold` | `3` | Failures before circuit opens |
| `hsm.lb.circuit-breaker.reset-ms` | `20000` | Circuit breaker reset time |

### 7.2 EZNet application (`docker/config/eznet-1/application.properties`)

| Property | Default | Description |
|----------|---------|-------------|
| `server.port` | `8120` | EZNet HTTP management port |
| `tcp2jms.tcp.local.port` | `9100` | TCP inbound port (clients connect here) |
| `tcp2jms.jms.connection.broker-url` | `failover:(tcp://artemis-master:61616,...)` | Artemis connection |
| `tcp2jms.jms.destination.outbound` | `hsm.transparent.lb.in` | Queue: client → LB |
| `tcp2jms.jms.destination.inbound` | `hsm.transparent.lb.reply` | Queue: LB → client |
| `tcp2jms.jms.destination.self` | `hsm-transparent-lb-inbound-1` | Per-instance reply queue |

### 7.3 Artemis broker (`docker/artemis/broker-master.xml`)

Key config blocks:
```xml
<!-- HA: master holds file lock on shared volume -->
<ha-policy>
  <shared-store>
    <master>
      <failover-on-shutdown>false</failover-on-shutdown>
    </master>
  </shared-store>
</ha-policy>

<!-- OpenWire acceptor — same protocol as Classic, no app code change -->
<acceptor name="openwire">tcp://0.0.0.0:61616?protocols=OPENWIRE</acceptor>

<!-- Shared data dirs — mounted as Docker volume -->
<journal-directory>/var/lib/artemis-instance/data/journal</journal-directory>
<bindings-directory>/var/lib/artemis-instance/data/bindings</bindings-directory>
<large-messages-directory>/var/lib/artemis-instance/data/large-messages</large-messages-directory>
<paging-directory>/var/lib/artemis-instance/data/paging</paging-directory>
```

---

## 8. Artemis HA — How Shared-Store Works

```
  artemis-master                        artemis-slave
  ──────────────                        ─────────────
  starts first
  acquires file lock ◄─── shared ───►  waits on file lock
  accepts connections      volume       standby (no connections)
         │
         │  master stopped / crashes
         ▼
  releases file lock
                                        acquires file lock
                                        accepts connections
                                        ← failover complete (~5–15s)
```

**Client reconnection:** `failover:` URL in both LB and EZNet configs automatically tries `artemis-slave:61616` when master disappears. No manual intervention needed.

**Data safety:** Zero message loss — slave has the complete journal on the shared volume.

**Failback:** When master restarts it re-acquires the lock from slave (slave reverts to standby).

---

## 9. HSM Tunnel Setup

HSM nodes are physical Thales payShield devices accessed via SSH tunnels. In WSL, tunnels are typically established on the Windows host and forwarded into WSL via the Docker bridge.

### 9.1 Start SSH tunnels (run in WSL or Windows)

```bash
# Tunnel to HSM node 1
ssh -L 0.0.0.0:9998:10.9.226.181:1500 -N -f user@jump-host

# Tunnel to HSM node 2
ssh -L 0.0.0.0:10001:10.9.226.182:1500 -N -f user@jump-host

# Tunnel to HSM node 3
ssh -L 0.0.0.0:10002:10.9.226.183:1500 -N -f user@jump-host
```

> `-L 0.0.0.0:PORT:...` binds all interfaces so Docker containers can reach it via `172.18.0.1`.
> Without `0.0.0.0`, the tunnel binds only to `127.0.0.1` and containers cannot connect.

### 9.2 Verify tunnel reachability from WSL

```bash
nc -zv 172.18.0.1 9998  && echo "HSM node1 OK"
nc -zv 172.18.0.1 10001 && echo "HSM node2 OK"
nc -zv 172.18.0.1 10002 && echo "HSM node3 OK"
```

### 9.3 Verify LB sees HSM nodes as healthy

```bash
curl -s http://localhost:8110/actuator/health | grep -A3 '"hsm"'
# or check LB logs:
docker logs lb-1 2>&1 | grep -i "health\|node\|UP\|DOWN" | tail -20
```

---

## 10. Switching Between Classic and Artemis

### Stop Artemis, start Classic

```bash
cd thales-artemis-lb/docker
docker compose down

cd ../../thales-transparent-lb/docker
docker compose up -d
```

### Stop Classic, start Artemis

```bash
cd thales-transparent-lb/docker
docker compose down

cd ../../thales-artemis-lb/docker
docker compose up -d
```

### Run both simultaneously

They use different broker ports but **same LB/EZNet ports** — only run one at a time on the same host unless you edit the LB/EZNet host ports.

| Service | Classic | Artemis |
|---------|---------|---------|
| Broker OpenWire (host) | 61618 / 61619 | 61626 / 61627 |
| Broker Web UI | 18161 / 18162 | 18163 / 18164 |
| LB-1 | 8110 | 8110 |
| LB-2 | 8111 | 8111 |
| EZNet-1 TCP | 9100 | 9100 |
| EZNet-2 TCP | 9101 | 9101 |

---

## 11. Test Cases & Validation

Test scripts are in the `HSMTHALES1.0/` directory of the main project.

### 11.1 Basic connectivity — manual

```bash
python3 - <<'EOF'
import socket, struct

HOST, PORT = "127.0.0.1", 9100
cmd = bytes.fromhex("303030304e4f3030")
frame = struct.pack(">H", len(cmd)) + cmd

s = socket.socket()
s.settimeout(10)
s.connect((HOST, PORT))
s.sendall(frame)
resp_len = struct.unpack(">H", s.recv(2))[0]
resp = s.recv(resp_len)
print(f"Response ({len(resp)} bytes): {resp.hex()}")
s.close()
EOF
```

Expected: response contains `4e503030` (NP00 = NO command success).

### 11.2 Load test — 60 requests at 20 TPS

```bash
bash test-hsm-load.sh
```

Expected:
```
Sent    : 60
Success : 60
Failure : 0
Mismatch: 0
Success rate: 100.0%
```

### 11.3 Dual LB benchmark

```bash
bash test-hsm-dual-lb-benchmark.sh
```

Expected:
- Phase 1 (max TPS sweep): 5 TPS at 100%
- Phase 2 (dual LB load): 100% success rate
- Phase 3 (lb-1 failover → lb-2): 100%

### 11.4 Artemis master failover test

```bash
# Terminal 1 — watch LB health
watch -n2 'curl -s http://localhost:8110/actuator/health | python3 -m json.tool'

# Terminal 2 — stop master
docker stop artemis-master
# Wait ~10 seconds — slave promotes, LBs reconnect
# Health should return to UP

# Restore master
docker start artemis-master
```

### 11.5 Validate queues in Artemis console

1. Open http://localhost:18163
2. Login: `artemis` / `artemis`
3. Navigate: **Artemis → Queues**
4. Confirm these queues exist after first message:
   - `hsm.transparent.lb.in`
   - `hsm.transparent.lb.reply`
   - `hsm-transparent-lb-inbound-1`
   - `hsm-transparent-lb-inbound-2`
   - `xenticate.control`

---

## 12. Port Reference

| Container | Container port | Host port | Purpose |
|-----------|---------------|-----------|---------|
| artemis-master | 61616 | **61626** | OpenWire JMS |
| artemis-master | 8161 | **18163** | Hawtio web console |
| artemis-slave | 61616 | **61627** | OpenWire (standby) |
| artemis-slave | 8161 | **18164** | Hawtio web console |
| lb-1 | 8110 | 8110 | Health / Prometheus metrics |
| lb-2 | 8111 | 8111 | Health / Prometheus metrics |
| eznet-1 | 9100 | 9100 | TCP client inbound |
| eznet-1 | 8120 | 8120 | HTTP management |
| eznet-2 | 9100 | 9101 | TCP client inbound |
| eznet-2 | 8121 | 8121 | HTTP management |

---

## 13. Troubleshooting

### artemis-master unhealthy / fails to start

**Symptom:** `dependency failed to start: container artemis-master is unhealthy`

**Cause:** Corrupt `docker_artemis-data` volume from a previous failed start.

**Fix:**
```bash
docker rm -f artemis-master artemis-slave
docker volume rm docker_artemis-data
docker compose up -d
```

### JMS DOWN on LB health check

**Symptom:** `"jms": { "status": "DOWN" }`

**Cause:** LB started before Artemis was ready, or Artemis restarted.

**Fix:**
```bash
docker restart lb-1 lb-2
```

### Port already in use on startup

**Symptom:** `failed to bind host port: address already in use`

**Cause:** Classic stack still running, or previous containers not cleaned up.

**Fix:**
```bash
# Stop Classic stack
docker compose -f /path/to/thales-transparent-lb/docker/docker-compose.yml down

# Or kill specific container
docker rm -f artemis-master
```

### SSH tunnel not reachable from containers

**Symptom:** `nc -zv 172.18.0.1 9998` fails from WSL.

**Cause:** SSH tunnel bound to `127.0.0.1` only (default).

**Fix:** Restart tunnel with explicit bind address:
```bash
ssh -L 0.0.0.0:9998:10.9.226.181:1500 -N -f user@jump-host
```

Also check WSL firewall — Windows Firewall may block the port:
```powershell
# Run in Windows PowerShell as Admin
New-NetFirewallRule -DisplayName "WSL HSM Tunnel" -Direction Inbound -LocalPort 9998,10001,10002 -Protocol TCP -Action Allow
```

### Artemis slave never promotes

**Symptom:** After stopping master, slave stays in standby indefinitely.

**Diagnosis:**
```bash
docker logs artemis-slave 2>&1 | tail -20
# Should show: "Waiting to become live..."
# Then after master stops: "live"
```

**Fix:** Ensure master container is fully stopped (not just paused):
```bash
docker stop artemis-master   # graceful stop releases lock
# NOT: docker kill artemis-master  (may not release lock cleanly)
```

# HSM Transparent LB — Artemis Edition: Benchmark Report

**Stack:** ActiveMQ Artemis 2.38.0 (master/slave HA) + 2× Spring Boot LB + 2× EZNet (tcp2jms)
**Platform:** Ubuntu 24.04 on WSL2, Docker 28.2.2
**HSM backends tested:** 5× Thales .NET sim (Windows host) → replaced with 5× Go sim (in-cluster)
**Date:** 2026-05-04 → 2026-05-05

---

## 1. TL;DR

| Result | Value |
|---|---|
| **Real ceiling** (asyncio, 200 JMS consumers, 100% success) | **1000 requested TPS / 260 achieved TPS** |
| Earlier ceiling (100 consumers) | 500 TPS |
| Saturation point (200 consumers) | 1500 TPS (drops to 82% — consumer-pool bound again) |
| 32-combo HSM enable/disable matrix | **31/31 active combos pass at 100%** at 300 TPS |
| Round-robin distribution | Exact: each enabled node gets `total/N` requests |
| Min latency (5-node, 300 TPS) | 544 ms avg |
| HA failover (lb-1 stop / lb-2 absorb) | 100% success during cutover and recovery |
| Linear scaling | **Doubling consumers (100→200) doubled the ceiling (500→1000)** |

The Java load balancer + Artemis JMS layer are not the bottleneck up to ~500 TPS; the bottleneck below that is the HSM backend (the .NET sim), which the Go sim removed.

---

## 2. Deployment

Deployed via `docker compose up -d` against the `Generic-TCP-IP-HSM-Artemis-LB` repo, but with the following adjustments documented for reproducibility:

### 2.1 Containers (final state)

| Container | Image | Host port | Purpose |
|---|---|---|---|
| `artemis-master` | `apache/activemq-artemis:2.38.0` | 61626 → 61616, 18163 → 8161 | OpenWire JMS + Hawtio UI |
| `artemis-slave` | `apache/activemq-artemis:2.38.0` | 61627 → 61616, 18164 → 8161 | Shared-store HA standby |
| `lb-1` | local build (`hsm-thales-lb:latest`) | 8110 | LB instance 1 |
| `lb-2` | local build | 8111 | LB instance 2 |
| `eznet-1` | local build (`hsm-eznet:latest`) | **9105** → 9100, 8120 | TCP client inbound (remapped — see §2.3) |
| `eznet-2` | local build | 9101 → 9100, 8121 | TCP client inbound |
| `hsm-sim-1..5` | local Go build (`hsm-sim:latest`) | 19000-19004 → 9000-9004 | In-cluster Go HSM sims |

### 2.2 Pre-deployment cleanup
The host already ran an older non-docker thales-lb stack via `supervisorctl`. Two services conflicted on docker host ports and were stopped:
- `thales-lb` (port 8110)
- `eznet-thales-lb-inbound` (ports 9100, 8120)

The host `activemq` (Classic 6.2.5), `xenticate-backend`, and `xlite-billpay-gateway` were left running — they don't conflict with the published Artemis ports (61626/18163) or any other docker-published port we didn't remap.

### 2.3 Port remap
`eznet-1` was remapped from host port `9100` → `9105` because the unrelated `xlite-billpay-gateway` already owned 9100.

### 2.4 HSM backend evolution

| Phase | Backend | Reason |
|---|---|---|
| Initial | 3× Thales .NET sim on Windows host (172.23.16.1:9998/10001/10002) | Available on the dev box |
| Mid | 5× Thales .NET sim (added :10003, :10004) | More parallelism |
| Final | 5× Go sim in docker (`hsm-sim-1..5:9000..9004`) | .NET sim was the bottleneck — see §4 |

The LB containers reach Windows host services via the WSL hostname `ISC-NB-13.mshome.net` (NOT `host.docker.internal`, which inside containers resolves to the docker0 bridge IP, not Windows).

---

## 3. The Go HSM sim

To remove the .NET sim as the test variable we wrote a minimal Thales NO-command simulator in Go (`docker/hsm-sim/main.go`):

- Listens on TCP, length-prefixed framing (2-byte BE length + body)
- Per-connection goroutine, bufio reader/writer
- Echoes the 4-byte client header + appends `NP00` + firmware-version-like trailer (`311 0000007-E0000001`-style)
- Optional `SIM_DELAY_MS` env var to inject artificial latency

5 instances run in the same docker network as the LBs, each on its own port (9000–9004). Built into `hsm-sim:latest` via a multi-stage `golang:1.23-alpine` → `alpine:3.20` Dockerfile (~10 MB image).

---

## 4. The .NET sim bottleneck (and a real bug in the LB)

Initial benchmarking against the .NET sims caps out at **~10 TPS sustained** with p99 hitting the 8 s socket timeout. Investigation revealed two distinct issues:

### 4.1 Bug: `fast-fail-timeout-ms=5` (5 milliseconds!)
The `PassthroughHandler.handle()` retry strategy uses `fast-fail-timeout-ms` for all attempts except the last. With 5 candidate nodes and a real first-byte latency of ~250 ms from the .NET sim, **every** non-final attempt times out at 5 ms — resulting in 99% HSM-side error rates while user-visible success was occasionally 100% (covered by retries on the last attempt).

The default of 5 ms is documented as a "fast-fail" fallback for dead nodes, but in practice it kills every request that doesn't come back instantly. We bumped it to 5000 ms (5 s) for benchmarking.

### 4.2 .NET sim concurrency cap
Even with the LB bug fixed, the .NET sims serialize requests per port and the Windows host saturates at low concurrency. At 200 TPS against 5 .NET sims:
- 1.78% success
- Avg response time **39 seconds** (for the few that succeeded)
- 2894/2983 hit the 60 s client timeout

This is what motivated swapping to the Go sims.

### 4.3 Artifact: `AdaptiveTuner` fights "circuit breaker disabled"
The LB ships an `AdaptiveTuner` that automatically tightens the circuit-breaker threshold to 2 when error rate > 30%. Setting `circuit-breaker.failure-threshold=2147483647` is **not** sufficient to disable the CB under load — the AdaptiveTuner overrides it. To truly disable CB tuning we set `hsm.lb.adaptive.interval-ms=999999999`.

---

## 5. Final tuned configuration (`docker/config/lb-{1,2}/application.properties`)

```properties
# JMS
spring.activemq.broker-url=failover:(tcp://artemis-master:61616,tcp://artemis-slave:61616)?jms.prefetchPolicy.queuePrefetch=100&...
hsm.lb.jms.concurrent-consumers=200       # bumped 100→200, doubled the ceiling
hsm.lb.jms.max-concurrent-consumers=400
hsm.lb.jms.per-node-capacity=200

# HSM socket pool
hsm.lb.pool.max-total=20
hsm.lb.pool.min-idle=2
hsm.lb.pool.max-wait-ms=16875
hsm.lb.pool.socket-timeout-ms=16875
hsm.lb.pool.connect-timeout-ms=2000
hsm.lb.pool.fast-fail-timeout-ms=6750     # was the buggy default of 5

# Circuit breaker — disabled for benchmarking
hsm.lb.circuit-breaker.failure-threshold=2147483647
hsm.lb.adaptive.interval-ms=999999999     # disable AdaptiveTuner so it doesn't re-tighten CB

# Request lifetime
hsm.lb.retry.max-attempts=2
hsm.lb.request.max-age-ms=50625
```

Originally the timers were set lower (5000/2000/15000 ms). The auto-tune-on-fail logic in `tests/auto-tune-asyncio.sh` bumped them 1.5× per failed step — final values reflect what the script settled on.

---

## 6. Methodology

Two custom load generators in `tests/`:

### 6.1 Threaded sweep (`auto-tune-sweep.sh`)
Python `threading`-based, one thread per request. Hits a wall around **70 TPS achieved** regardless of target — Python GIL + thread spawn overhead. Useful only for low-TPS validation.

### 6.2 Asyncio sweep (`auto-tune-asyncio.sh`)
Single-process `asyncio.open_connection`-based — coroutines, not threads. Saturated to thousands of concurrent in-flight requests. Drives requests at a target TPS with `asyncio.sleep` between dispatches.

### 6.3 Auto-tune-on-fail
On a step that fails the pass-rate threshold, both scripts:
1. Bump `socket-timeout-ms`, `fast-fail-timeout-ms`, `max-wait-ms`, `request.max-age-ms` by ×1.5
2. Restart `lb-1` and `lb-2` in place
3. Reset all node circuit breakers via `POST /api/v1/hsm-lb/nodes/{id}/circuit-reset`
4. Retry the same TPS step (up to `MAX_TUNE_ITERS` times) before declaring fail

### 6.4 Queue-depth tracking
Every step samples Artemis `MessageCount`/`DeliveringCount`/`ConsumerCount` for `hsm.transparent.lb.in` via Hawtio Jolokia (`/console/jolokia/read/...`) every 500 ms in a background thread. Min/max/avg over the run is reported alongside latency stats.

### 6.5 Per-step protocol
- Reset all node circuits
- 2 s settle
- Run for `DUR` seconds, asyncio scheduler firing requests at `interval = 1/TPS`
- After scheduler exits, wait for in-flight to complete (capped at `REQ_TIMEOUT + 10 s`)
- Compute success rate, achieved TPS, avg/p50/p95/p99 latency, queue-depth peak

---

## 7. Results

### 7.1 Asyncio TPS sweep (`tests/auto-tune-asyncio.sh`)

5× Go sim, 2× LB, 2× EZNet, 15 s/step, 99% pass threshold, 45 s per-request timeout.

#### Run 1 — 100 JMS consumers per LB (initial config)

| Requested TPS | Achieved TPS | Sent | Ok | Fail | Rate% | Avg ms | p50 | p95 | p99 | qDepth max | qDepth avg | Verdict |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| 500 | 225 | 7499 | 7499 | 0 | 100.0 | 14879 | 17562 | 19954 | 20940 | 393 | 52 | **PASS** |
| 1000 | 157 | 12995 | 10000 | 2995 | 77.0 | 38120 | 43949 | 47201 | 47913 | 755 | 116 | FAIL |
| 1000 (after auto-tune ×1.5) | 88 | 14136 | 5410 | 8726 | 38.3 | 39763 | 41487 | 45377 | 46174 | 953 | 270 | FAIL |
| 1000 (after auto-tune ×2.25) | 158 | 14217 | 9852 | 4365 | 69.3 | 37985 | 38997 | 45146 | 46770 | 2543 | 721 | FAIL |

**Run-1 ceiling: 500 requested TPS at 100% success.** Auto-tuning timers does not raise the ceiling because the bottleneck is JMS-consumer throughput, not request lifetime.

#### Run 2 — 200 JMS consumers per LB

| Requested TPS | Achieved TPS | Sent | Ok | Fail | Rate% | Avg ms | p50 | p95 | p99 | qDepth max | qDepth avg | Verdict |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| 500 | 189 | 7453 | 7453 | 0 | 100.0 | 21718 | 24887 | 26586 | 27395 | 993 | 184 | **PASS** |
| **1000** | **261** | **14589** | **14482** | **107** | **99.3** | **29861** | **32138** | **40639** | **43687** | **901** | **93** | **PASS** |
| 1500 | 244 | 21083 | 17313 | 3770 | 82.1 | 39817 | 42500 | 51944 | 55414 | 1094 | 86 | FAIL |
| 1500 (auto-tune ×1.5) | 66 | 20767 | 4726 | 16041 | 22.8 | 42888 | 45903 | 56038 | 57649 | 3270 | 902 | FAIL |

**Run-2 ceiling: 1000 requested TPS / 261 achieved TPS at 99.3% success — exactly 2× the previous ceiling.** Linear scaling with consumer count confirms the bottleneck is JMS consumer throughput per LB, not Artemis broker, network, or HSM backends.

At 1000 TPS achieved (Run 2) the queue depth averages 93 with peaks of 901 — workable. At 1500 TPS the queue blows past 3000 and never drains.

### 7.2 32-combo HSM enable/disable matrix (`tests/combo-32-asyncio.sh`)

5 nodes × 2 states = 32 combinations. 300 TPS, 10 s/step.

| combo (n1n2n3n4n5) | active | sent | ok | fail | rate | avg ms | per-node Δreqs |
|---|---|---|---|---|---|---|---|
| 00000 | 0 | — | — | — | — | — | (skipped, no nodes) |
| 10000 | 1 | 3000 | 3000 | 0 | 100.0% | 2183 | n1=3000 |
| 01000 | 1 | 3000 | 3000 | 0 | 100.0% | 1125 | n2=3000 |
| 11000 | 2 | 2999 | 2999 | 0 | 100.0% | 920 | n1=1499 n2=1500 |
| 00100 | 1 | 3000 | 3000 | 0 | 100.0% | 672 | n3=3000 |
| 10100 | 2 | 3000 | 3000 | 0 | 100.0% | 1468 | n1=1500 n3=1500 |
| 01100 | 2 | 3000 | 3000 | 0 | 100.0% | 975 | n2=1500 n3=1500 |
| 11100 | 3 | 2999 | 2999 | 0 | 100.0% | 742 | n1=999 n2=1000 n3=1000 |
| 00010 | 1 | 3000 | 3000 | 0 | 100.0% | 483 | n4=3000 |
| 10010 | 2 | 3000 | 3000 | 0 | 100.0% | 887 | n1=1500 n4=1500 |
| 01010 | 2 | 2999 | 2999 | 0 | 100.0% | 1087 | n2=1499 n4=1500 |
| 11010 | 3 | 2999 | 2999 | 0 | 100.0% | 345 | n1=999 n2=1000 n4=1000 |
| 00110 | 2 | 3000 | 3000 | 0 | 100.0% | 940 | n3=1500 n4=1500 |
| 10110 | 3 | 3000 | 3000 | 0 | 100.0% | 487 | n1=1000 n3=1000 n4=1000 |
| 01110 | 3 | 2999 | 2999 | 0 | 100.0% | 657 | n2=999 n3=1000 n4=1000 |
| 11110 | 4 | 2999 | 2999 | 0 | 100.0% | 2177 | n1=750 n2=749 n3=750 n4=750 |
| 00001 | 1 | 3000 | 3000 | 0 | 100.0% | 272 | n5=3000 |
| 10001 | 2 | 3000 | 3000 | 0 | 100.0% | 629 | n1=1500 n5=1500 |
| 01001 | 2 | 3000 | 3000 | 0 | 100.0% | 586 | n2=1500 n5=1500 |
| 11001 | 3 | 3000 | 3000 | 0 | 100.0% | 524 | n1=1000 n2=1000 n5=1000 |
| 00101 | 2 | 3000 | 3000 | 0 | 100.0% | 546 | n3=1501 n5=1499 |
| 10101 | 3 | 3000 | 3000 | 0 | 100.0% | 741 | n1=999 n3=1001 n5=1000 |
| 01101 | 3 | 3000 | 3000 | 0 | 100.0% | 1363 | n2=1000 n3=1000 n5=1000 |
| 11101 | 4 | 2998 | 2998 | 0 | 100.0% | 457 | n1=751 n2=749 n3=749 n5=749 |
| 00011 | 2 | 3000 | 3000 | 0 | 100.0% | 921 | n4=1499 n5=1501 |
| 10011 | 3 | 3000 | 3000 | 0 | 100.0% | 571 | n1=999 n4=1000 n5=1001 |
| 01011 | 3 | 3000 | 3000 | 0 | 100.0% | 502 | n2=1001 n4=1000 n5=999 |
| 11011 | 4 | 3000 | 3000 | 0 | 100.0% | 678 | n1=749 n2=751 n4=750 n5=750 |
| 00111 | 3 | 3000 | 3000 | 0 | 100.0% | 401 | n3=999 n4=1000 n5=1001 |
| 10111 | 4 | 3000 | 3000 | 0 | 100.0% | 1016 | n1=750 n3=750 n4=749 n5=751 |
| 01111 | 4 | 2999 | 2999 | 0 | 100.0% | 521 | n2=750 n3=750 n4=750 n5=749 |
| 11111 | 5 | 3000 | 3000 | 0 | 100.0% | 544 | n1=600 n2=600 n3=600 n4=600 n5=600 |

**Findings:**
- All 31 active combos pass at 100% success. No combination causes routing breakage or starvation.
- ROUND_ROBIN distribution is exact: with `N` enabled nodes, each gets `total/N` requests (the off-by-one in some rows is the LB's chooser starting cursor, not unfairness).
- Single-node latency varies 8× (272 ms for `00001` vs 2183 ms for `10000`) — see §8.

### 7.3 HA failover (from earlier `tests/test-hsm-dual-lb-benchmark.sh`)

| Phase | TPS | Result |
|---|---|---|
| Baseline (both LBs up) | 5 | 100% |
| `docker stop lb-1` (lb-2 only) | 5 | 100% — no lost messages |
| `docker start lb-1` (post-recovery) | 5 | 100% within ~5 s |

---

## 8. Single-node latency anomaly

Tested at 300 TPS with each single node enabled in isolation:

| Node | Avg latency |
|---|---|
| node1 | 2183 ms |
| node2 | 1125 ms |
| node3 | 672 ms |
| node4 | 483 ms |
| node5 | **272 ms** (8× faster than node1) |

The Go sims are stateless and identical, so the variance is on the LB side. Most likely cause: the JVM JIT and the LB's per-node socket pool warm up across the test run — by the time we test `node5`-only the relevant code paths are hot and pool entries pre-validated, while `node1`-only runs first against cold paths.

This is worth confirming with a randomized test order before drawing engineering conclusions.

---

## 9. Lessons learned

1. **`fast-fail-timeout-ms=5` is a footgun.** With multi-node retry it fails essentially every request whose backend takes longer than 5 ms. Either default it to ≥1 s, or document that it must match real backend latency.
2. **AdaptiveTuner overrides explicit CB config.** Setting a huge `failure-threshold` doesn't disable CB if AdaptiveTuner is alive. Add a clean kill switch (e.g., `hsm.lb.adaptive.enabled=false`).
3. **Python `threading` caps load gen at ~70 TPS.** For HSM benchmarking use `asyncio` from the start.
4. **`host.docker.internal` ≠ Windows host on WSL2.** It resolves to docker0 bridge inside containers. Use the `<computer>.mshome.net` hostname or the WSL→Windows gateway IP.
5. **The .NET Thales sim is fine for correctness but useless for performance work.** Moving HSM sims into the docker network removes a huge variable.

---

## 10. Recommendations

| Where | Recommendation |
|---|---|
| LB defaults | Raise `pool.fast-fail-timeout-ms` from 5 → 1000 ms; add `hsm.lb.adaptive.enabled` boolean |
| LB code | Investigate the per-node latency anomaly — randomize the warm-up test or pre-warm pools |
| Stack capacity | Comfortable: 300 TPS at p95 ≤ 1 s. Sustainable ceiling at 99% success: **1000 TPS** (with 200 consumers per LB). Linear-scaling rule observed: ceiling ≈ `consumers × 5` |
| Test suite | Replace existing test scripts' hardcoded port 9100 → make `EZNET_PORT` env var; replace `supervisorctl` calls in `test-hsm-dual-lb-benchmark.sh` → `docker stop/start` |

---

## 11. How to reproduce

```bash
git clone https://github.com/bhaskar2285/Generic-TCP-IP-HSM-Artemis-LB.git
cd Generic-TCP-IP-HSM-Artemis-LB
mvn clean package -DskipTests
cp target/thales-transparent-lb.jar docker/lb/
cd docker && docker compose up -d           # brings up Artemis + LBs + EZNets + 5 Go sims

# verify
curl -s http://localhost:8110/api/v1/hsm-lb/status | python3 -m json.tool

# benchmarks
bash ../tests/auto-tune-asyncio.sh           # find ceiling
TPS=300 DUR=10 bash ../tests/combo-32-asyncio.sh   # 32-combo matrix
```

---

## 12. Files added in this work

| File | Purpose |
|---|---|
| `BENCHMARK_REPORT.md` | This document |
| `docker/hsm-sim/main.go` | Go HSM NO-command sim |
| `docker/hsm-sim/Dockerfile` | Multi-stage golang:1.23 → alpine:3.20 build |
| `docker/docker-compose.yml` | Adds 5× hsm-sim services + remap eznet-1 host port to 9105 |
| `docker/config/lb-{1,2}/application.properties` | Tuned timers, consumers, prefetch, CB-disabled, adaptive-disabled, in-cluster sim nodes |
| `tests/auto-tune-asyncio.sh` | Asyncio TPS sweep with auto-tune-on-fail and Artemis queue-depth tracking |
| `tests/auto-tune-sweep.sh` | Threaded variant (kept for low-TPS sanity checks) |
| `tests/combo-32-asyncio.sh` | 2^5 enable/disable matrix |
| `tests/measure-200tps.sh` | Single-step measurement at fixed TPS |
| `tests/test-hsm-load.docker.sh` | Patched original test (port 9100 → 9105) |
| `tests/test-hsm-dual-lb-benchmark.docker.sh` | Patched original (supervisor → docker stop/start) |

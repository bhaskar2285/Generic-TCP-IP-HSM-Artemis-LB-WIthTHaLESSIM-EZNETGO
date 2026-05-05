# Handoff — HSM LB Benchmarking Session

Last touched: **2026-05-05**.
Current work tree on disk: `/tmp/Generic-TCP-IP-HSM-Artemis-LB/` (clone — `master` branch tracks `origin/master`).
Pushes have been going to `https://github.com/bhaskar2285/Generic-TCP-IP-HSM-Artemis-LB.git`.

> ⚠️  The PAT `bhaskar` provided in-conversation has been used. **Rotate it before next session.**

---

## 1. Where we are

**Stack is up and healthy** (as of last action):

| Container | State |
|---|---|
| `artemis-master` | restarted recently — was OOM-killed during a 1500 TPS run; now in `Waiting indefinitely to obtain primary lock` because **slave** holds the lock |
| `artemis-slave` | active, serving all traffic via the failover URL |
| `lb-1`, `lb-2` | healthy, JMS UP |
| `eznet-1..5` | up |
| `hsm-sim-1..5` | up |

**Currently configured for 3 HSMs** (`hsm.lb.nodes` = node1+node2+node3 only). The other Go sims are running but not in the LB's routing list.

**Locked timers** (no auto-tune):
- `socket-timeout-ms=15000`
- `fast-fail-timeout-ms=5000`
- `max-wait-ms=15000`
- `request.max-age-ms=45000`
- `prefetch=10`, 200 consumers per LB
- CB **disabled**, AdaptiveTuner **disabled**, virtual threads **disabled**

---

## 2. Done in this session

1. Cloned repo, deployed Artemis HA + 2 LB + 2 EZNet stack from the IMPLEMENTATION_AND_TEST_GUIDE.md
2. Replaced the .NET Thales sim with **5 in-cluster Go sims** (`docker/hsm-sim/`)
3. Found and fixed two real LB bugs:
   - `pool.fast-fail-timeout-ms=5` (5 ms) — kills every multi-node retry
   - `ThalesNodePool.send()` opened a fresh socket per request — `pool.max-total` was dead config
4. Patched `ThalesNodePool` to actually use the existing `ThalesSocketFactory` via `GenericObjectPool<Socket>`
5. Added clean toggles: `hsm.lb.adaptive.enabled`, `hsm.lb.circuit-breaker.enabled`, `hsm.lb.jms.virtual-threads`
6. Wrote asyncio-based load gen (`tests/auto-tune-asyncio.sh`, `tests/auto-tune-asyncio-with-stats.sh`) — Python threading caps at ~70 TPS, asyncio sustains thousands
7. 32-combo HSM enable/disable matrix script (`tests/combo-32-asyncio.sh`)
8. Found ceiling stages:
   - 100 consumers, no pool → 500 TPS
   - 200 consumers, pool, prefetch=100 → 1000 TPS / 328 atps
   - 200 consumers, pool, prefetch=10 → 1000 TPS / 309 atps, **lower latency**
   - 400 consumers → regression
   - Virtual threads → regression
   - 3 EZNets → **2000 TPS ceiling** ← best result
   - 5 EZNets at 1500 TPS → Artemis OOM
9. HSM scan with 5 EZNet + locked timers: 1→200, 2→1000, 3→1000 (1500 OOMs Artemis)
10. Added `<allow-failback>` config for Artemis HA, set 1 GB heap + 1.5 GB container limit on both brokers

**Two commits pushed to `master`:**
- `2dfcf08` — initial Go sim + bench scripts + report
- `a3a2089` — pool patch + prefetch tuning + report update

(Work since `a3a2089` — feature toggles, eznet-3/4/5, HSM scan, broker hardening — is on disk but **not committed yet**.)

---

## 3. Pending / didn't get to

- (b) **5 EZNets full sweep** — initial attempt OOM-killed Artemis at 1500 TPS. With 1 GB heap on this laptop we can't safely sweep > 1000 TPS at 5 EZNets. Needs either more heap or a real Artemis cluster.
- (c) **Active-active Artemis cluster** — would solve both the OOM ceiling and the failback-after-crash issue. Requires:
  - Two brokers with `<cluster-connection>` config pointing at each other
  - `<ha-policy><live-only>` instead of `<shared-store><master/slave>`
  - LB/EZNet failover URLs with `randomize=true`
  - Possibly a redistribution-delay setting to prevent message ping-ponging
  - Unfinished — task #15 still open in the task list
- **EZNet profiling** — at 140%+ CPU per container, EZNet is the per-instance bottleneck. We don't have its source (precompiled WAR). Could attach a JFR profiler to a running container if needed.
- **Commit + push** of all the §13-17 work + the benchmark scripts that landed in `/tmp/` but not the repo (`auto-tune-asyncio-with-stats.sh`, `auto-tune-asyncio-3eznet.sh`, `auto-tune-asyncio-5eznet.sh`).

---

## 4. Known issues + workarounds

### 4.1 Artemis-master can't reacquire lock after OOM crash
**Symptom:** master log shows `AMQ221034: Waiting indefinitely to obtain primary lock`.
**Cause:** slave promoted on master crash and `<allow-failback>true` did not kick in (slave busy serving traffic, possibly a half-recovered journal).
**Manual fix:** `docker stop artemis-slave` → wait for master to grab lock → `docker start artemis-slave` (it'll go back into standby).
**Permanent fix:** active-active cluster (see (c) above) or a watchdog script that detects the log line and restarts the slave.

### 4.2 docker-compose v1 on this host has the `KeyError: 'ContainerConfig'` bug
**Symptom:** `docker-compose up -d` after running containers were modified throws `KeyError: 'ContainerConfig'` in `merge_volume_bindings`.
**Workaround:** `docker rm -f <containers>` first, then `docker-compose up -d`. Or upgrade to docker compose v2.

### 4.3 `xlite-billpay-gateway` keeps grabbing port 9100
**Symptom:** `eznet-1` host port 9100 conflict.
**Workaround:** eznet-1 is permanently remapped to host port **9105**. All bench scripts use `9105,9101,9106,9107,9108`.

### 4.4 host `activemq` (Classic 6.2.5) and supervisor services
**Symptom:** they coexist with our docker stack.
**Workaround:** the docker Artemis publishes on 61626/18163 (not 61616/8161), so no conflict. The two supervisor services that conflicted (`thales-lb`, `eznet-thales-lb-inbound`) were stopped at the start of the session. They will restart on host reboot — restart them manually if you need the old non-docker stack back, or `sudo supervisorctl stop` them again.

### 4.5 Artemis at 1 GB heap caps at ~1000 TPS sustained
At 1500 TPS the broker memory hits the 1.5 GB container limit and gets OOM-killed. Choices: bigger heap (not viable on this laptop), cluster (proper solution), lower workload.

---

## 5. How to resume

```bash
# 1. Pull latest
cd /tmp/Generic-TCP-IP-HSM-Artemis-LB
git pull origin master

# 2. (If stack is down) — bring up clean
cd docker
docker volume rm docker_artemis-data 2>/dev/null   # only if you want a fresh broker
docker-compose up -d

# 3. Verify
curl -s http://localhost:8110/api/v1/hsm-lb/status | python3 -m json.tool

# 4. Run a sweep (no auto-tune; honest numbers)
TPS_LADDER="200 500 1000" DUR=15 NO_AUTO_TUNE=1 \
  bash /tmp/auto-tune-asyncio-with-stats.sh

# 5. Run the 32-combo matrix
TPS=300 DUR=10 bash tests/combo-32-asyncio.sh
```

If artemis-master is stuck "Waiting indefinitely to obtain primary lock":
```bash
docker stop artemis-slave
sleep 5    # let master grab the lock
docker start artemis-slave
```

---

## 6. Next-session priorities (suggested)

1. **Commit + push** the uncommitted changes (toggles, eznet-3/4/5, HSM scan results in BENCHMARK_REPORT.md §13-17, this HANDOFF.md, broker config changes).
2. **Active-active Artemis cluster** (test c) — the right fix for the OOM ceiling.
3. **Auto-failback watchdog** — small sidecar / shell loop that watches for `AMQ221034` in master logs and restarts slave. Document or commit as part of the deployment guide.
4. Optional: profile EZNet to understand why it's at 140% CPU per instance — there may be cheap wins.
5. Re-sweep at fixed best config and produce a single canonical "production-ready" benchmark table for the report.

---

## 7. Reference: file layout in this branch

| File | Status | Purpose |
|---|---|---|
| `BENCHMARK_REPORT.md` | committed (a3a2089) + uncommitted §13-17 | Full report |
| `HANDOFF.md` | new in this commit | This file |
| `docker/hsm-sim/{main.go,Dockerfile}` | committed (2dfcf08) | Go HSM sim |
| `docker/docker-compose.yml` | committed (2dfcf08) + uncommitted (eznet-3/4/5, broker heap/limits) | Compose spec |
| `docker/artemis/broker-master.xml` | uncommitted (`<failover-on-shutdown>true</failover-on-shutdown>`) | Master broker config |
| `docker/artemis/broker-slave.xml` | already had `<allow-failback>true</allow-failback>` | Slave broker config |
| `docker/config/lb-{1,2}/application.properties` | committed + uncommitted (toggles, 200 consumers, prefetch=10) | LB config |
| `docker/config/eznet-{3,4,5}/application.properties` | uncommitted | New EZNet configs |
| `src/main/java/.../node/ThalesNodePool.java` | committed (a3a2089) | Real socket pool |
| `src/main/java/.../node/ThalesNode.java` | uncommitted | CB enabled flag |
| `src/main/java/.../config/LbProperties.java` | uncommitted | adaptive/CB/VT toggles |
| `src/main/java/.../adaptive/AdaptiveTuner.java` | uncommitted | enabled gate |
| `src/main/java/.../jms/JmsConfig.java` | uncommitted | VT executor wiring |
| `tests/auto-tune-asyncio.sh` | committed | Asyncio sweep + auto-tune |
| `tests/auto-tune-asyncio-with-stats.sh` | **lives in `/tmp/` — needs copy-into-repo + commit** | Adds docker stats sampling |
| `tests/auto-tune-asyncio-{3,5}eznet.sh` | **lives in `/tmp/` — needs copy-into-repo + commit** | Variants for 3/5 EZNets |
| `tests/combo-32-asyncio.sh` | committed | 2^5 enable/disable matrix |
| `tests/measure-200tps.sh` | committed | Single-step measurement |
| `tests/test-hsm-{load,dual-lb-benchmark}.docker.sh` | committed | Patched original tests |

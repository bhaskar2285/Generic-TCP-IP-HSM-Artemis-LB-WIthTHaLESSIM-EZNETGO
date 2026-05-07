# Handoff — HSM LB Monitoring Session

Last touched: **2026-05-07**.
Work tree: `/home/xenticate/thales-artemis-lb/` — git repo, `master` branch.
Remote: `https://github.com/bhaskar2285/Generic-TCP-IP-HSM-Artemis-LB.git`

---

## 1. Where we are

**Full stack running** — 17 containers up:

| Container | State |
|---|---|
| `artemis-master` | healthy, holds journal lock |
| `artemis-slave` | standby |
| `lb-1`, `lb-2` | healthy — now routing to **all 5 HSMs** |
| `eznet-1..5` | up |
| `hsm-sim-1..5` | up, Prometheus metrics on port 9100 |
| `prometheus` | up, scraping 15 targets |
| `grafana` | up at `http://localhost:3000` (admin/admin) |
| `cadvisor` | up at host port 8085 |

**All 5 HSM sims now in LB rotation** — `hsm.lb.nodes` updated from 3 to 5 nodes in both lb-1 and lb-2 `application.properties`.

**Locked timers (unchanged from last session):**
- `socket-timeout-ms=15000`, `fast-fail-timeout-ms=5000`, `max-wait-ms=15000`, `request.max-age-ms=45000`
- `prefetch=10`, 200 consumers per LB
- CB **disabled**, AdaptiveTuner **disabled**, virtual threads **disabled**

---

## 2. Done this session

1. **Full Grafana monitoring stack** added to `docker/docker-compose.yml`:
   - Prometheus + Grafana + cAdvisor
   - jmx_prometheus_javaagent wired into Artemis master (port 9404) and slave (port 9405)
   - EZNet 1..5 actuator/prometheus endpoint enabled
   - HSM sim Go code patched to expose `/metrics` on port 9100
   - Dashboard auto-provisioned at startup — no manual setup needed

2. **Dashboard panels (5 rows):**
   - LB Overview: req/s, error rate, avg+max latency, node health (5 bars), circuit breakers (5 bars)
   - Artemis Brokers: queue depth, consumer counts, JVM heap
   - EZNet Instances: JVM threads, JVM heap (summed by instance)
   - HSM Simulators: req/s, p95/p99 latency, active connections
   - Container Health: cAdvisor system slice CPU/mem

3. **Dashboard PromQL fixes applied:**
   - Error rate: `sum by (exported_instance)` to avoid silent NaN
   - Latency: switched from missing `_bucket` histogram to `_sum/_count/_max` (LB uses summary not histogram)
   - Node health/CB: `max by (node)` — deduplicates lb-1+lb-2 reporting same nodes (was 10 stats, now 5)
   - EZNet heap: `sum by (instance)` — collapses memory pool IDs (was 40 lines, now 5)

4. **cAdvisor note:** overlayfs storage driver prevents per-container `name`/`image` label population. Container row shows host system.slice cgroup metrics instead. Per-container names need `docker-stats-exporter` (registry blocked this session — `ghcr.io` denied).

5. **All 5 HSMs added** to lb-1 and lb-2 `application.properties` — `node4:hsm-sim-4:9003:1,node5:hsm-sim-5:9004:1` appended.

**Commits this session (master branch):**
- `b61b16a` — jmx_prometheus_javaagent download script
- `70fb11b` — JMX scrape rules for Artemis
- `60985e3` — Prometheus scrape config (15 targets)
- `7cd7255` — EZNet actuator/prometheus enabled
- `54f7dfb` — HSM sim /metrics endpoint (Go)
- `3a146b4` — Grafana datasource + dashboard provider provisioning
- `5d5a88f` — Grafana dashboard JSON (5-row full stack)
- `a2d1e79` — docker-compose: Prometheus + Grafana + cAdvisor + JMX agent
- `db27dc3` — fix: datasource UID case, dead goroutine, unused volume
- `4751704` — complete monitoring stack commit
- Latest uncommitted: lb-1/lb-2 nodes→5, dashboard PromQL fixes

---

## 3. Pending / next priorities

1. **Active-active Artemis cluster** — OOM ceiling fix. Needs `<cluster-connection>` config, `<ha-policy><live-only>`, LB/EZNet failover URLs with `randomize=true`.
2. **Auto-failback watchdog** — shell loop watching `AMQ221034` in master logs, restarts slave. Can be a simple sidecar container or supervisord script.
3. **Container metrics fix** — replace cAdvisor with `docker-stats-exporter` (needs registry access). Image: `ghcr.io/prometheus-community/docker-exporter:latest` on port 9417.
4. **5-EZNet full TPS sweep** — with Grafana live, now can watch queue depth + consumer counts during sweep. Artemis OOMs at 1500 TPS — keep at ≤1000 TPS or fix heap first.
5. **EZNet profiling** — 140%+ CPU per instance, no source (precompiled WAR). Can attach JFR profiler.

---

## 4. Known issues + workarounds

### 4.1 Artemis-master lock after OOM crash
**Symptom:** `AMQ221034: Waiting indefinitely to obtain primary lock`
**Fix:** `docker stop artemis-slave && sleep 5 && docker start artemis-slave`

### 4.2 cAdvisor per-container metrics broken
**Cause:** overlayfs Docker storage driver — cAdvisor can't read layerdb mounts.
**Symptom:** Container Health row shows system.slice services, not docker container names.
**Fix:** replace with `ghcr.io/prometheus-community/docker-exporter:latest` (port 9417). Update compose + prometheus.yml scrape target from `cadvisor:8080` to `cadvisor:9417`.

### 4.3 port 8080 conflict
**Symptom:** cAdvisor remapped to host port 8085 (local Java process holds 8080).

### 4.4 host activemq + supervisor services
Artemis on 61626/18163, no conflict. `thales-lb` and `eznet-thales-lb-inbound` supervisor services stopped — restart on reboot, re-stop with `sudo supervisorctl stop`.

### 4.5 Artemis at 1 GB heap caps ~1000 TPS
OOM at 1500 TPS. Need active-active cluster or reduced load.

---

## 5. How to resume

```bash
cd /home/xenticate/thales-artemis-lb/docker

# Stack already up — verify
docker compose ps
curl -s http://localhost:8110/api/v1/hsm-lb/status | python3 -m json.tool

# Open Grafana
xdg-open http://localhost:3000   # admin / admin

# If stack is down — bring up
docker compose up -d

# If artemis-master stuck on lock
docker stop artemis-slave && sleep 5 && docker start artemis-slave

# Run a TPS sweep (5 HSMs, 5 EZNets, watch Grafana)
TPS_LADDER="200 500 1000" DUR=30 NO_AUTO_TUNE=1 \
  bash tests/auto-tune-asyncio-with-stats.sh
```

---

## 6. File layout — monitoring additions

| File | Status | Purpose |
|---|---|---|
| `docker/docker-compose.yml` | committed | prometheus + grafana + cadvisor + JMX agent in Artemis |
| `docker/prometheus/prometheus.yml` | committed | 15 scrape targets |
| `docker/prometheus/jmx-artemis.yml` | committed | Artemis JMX rules |
| `docker/jmx-exporter/download.sh` | committed | downloads jmx_prometheus_javaagent-1.0.1.jar |
| `docker/jmx-exporter/jmx_prometheus_javaagent-1.0.1.jar` | gitignored, on disk | mounted into Artemis containers |
| `docker/grafana/provisioning/datasources/prometheus.yml` | committed | Prometheus datasource |
| `docker/grafana/provisioning/dashboards/provider.yml` | committed | dashboard file provider |
| `docker/grafana/provisioning/dashboards/hsm-lb.json` | committed + local fixes | 5-row dashboard |
| `docker/hsm-sim/main.go` | committed | Go sim + /metrics on :9100 |
| `docker/config/lb-{1,2}/application.properties` | **uncommitted** | nodes=5 (was 3) |
| `docs/superpowers/plans/2026-05-07-grafana-monitoring.md` | committed | implementation plan |

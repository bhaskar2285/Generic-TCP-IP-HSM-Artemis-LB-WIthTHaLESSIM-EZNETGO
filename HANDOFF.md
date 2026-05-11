# Session Handoff — HSM LB Benchmark
> Last updated: 2026-05-09 (end of session). Pick up exactly from here.

---

## NEXT ACTION: Artemis Active-Active Clustering

Replace current master/slave HA with **symmetric active-active cluster** (2 brokers, both active, messages redistributed). This removes single-broker dispatch as bottleneck.

### What changes:
1. `docker/artemis/broker-master.xml` → cluster mode (no shared journal, own data dir)
2. `docker/artemis/broker-slave.xml` → second active cluster node (own data dir)
3. `docker/docker-compose.yml` → separate volumes per broker
4. LB broker-url already connects to both — no LB change needed

### Artemis cluster config key additions to broker.xml:
```xml
<cluster-connections>
  <cluster-connection name="hsm-cluster">
    <connector-ref>netty-connector</connector-ref>
    <message-load-balancing>ON_DEMAND</message-load-balancing>
    <max-hops>1</max-hops>
    <static-connectors>
      <connector-ref>broker2-connector</connector-ref>
    </static-connectors>
  </cluster-connection>
</cluster-connections>
```

---

## Current Container State

| Container | Status | Ports |
|-----------|--------|-------|
| artemis-master | up (healthcheck broken — ignore) | 61616, 18163 |
| artemis-slave | up | 61616 |
| lb-1 | healthy | 8110 |
| lb-2 | healthy | 8111 |
| lb-3 | healthy | 8112 (added this session, currently prefetch=3) |
| hsm-sim-1..5 | up | 9000 internal |
| go-eznet-1..5 | up | 9110-9114 |
| go-eznet-6..10 | stopped | — |
| docker-stats-exporter | up | 9487 |
| prometheus | up | 9090 |
| grafana | up | 3000 |

---

## REVERT NEEDED BEFORE NEXT TEST

lb-1/lb-2/lb-3 currently have **prefetch=3** (left from failed test). Revert to prefetch=10:
```bash
sed -i 's/queuePrefetch=3&/queuePrefetch=10\&/' \
  docker/config/lb-{1,2,3}/application.properties
docker compose restart lb-1 lb-2 lb-3
```

---

## Session Findings Summary

### Bottleneck confirmed: Artemis single-broker dispatch
- HSM sim p95 = **1.3ms** (from Prometheus) — NOT bottleneck
- End-to-end p95 at 1000 TPS = 2-17s — all Artemis queue wait
- Adding lb-3 (3 LBs): 1000 TPS p95 improved but 2000 TPS hard-failed (0%)
- prefetch=3 with 3 LBs: 1500 TPS ok but 2000 TPS 0% fail — Artemis overloaded dispatching small batches to 1200 consumers

### Winning config (2 LBs, prefetch=10, consumers=400)
```
TPS    Rate    ActTPS  p95
500    100%    499     193ms
1000   100%    967     2992ms
1500   100%    1036    9692ms   ← needs warmup (start from 500)
2000   100%    1007    18511ms
2500   99.6%   724     46225ms
```

### JVM warmup required
Always start bench ladder from 500 TPS. Without warmup p95 at 1500=20s. With warmup p95=9.7s.

### Go vs Java EZNet
Java eznet fails at 500 TPS. Go eznet handles 2500 TPS. See §18 in BENCHMARK_REPORT.md.

---

## Infrastructure (all working)

- **docker-stats-exporter** replaced cadvisor (port 9487, metrics: `dockerstats_cpu_usage_ratio`, `dockerstats_memory_usage_bytes`)
- **Grafana** dashboard rebuilt: TPS, p50/p95/p99, LB rate, Artemis queue, go-eznet pending, container CPU/RAM
- **Prometheus** scrapes go-eznet (job=go-eznet, port 8120) and docker-stats-exporter
- **lb-3** config at `docker/config/lb-3/application.properties`
- **BENCHMARK_REPORT.md** has §18 Go vs Java EZNet comparison

---

## Bench Script
`tests/bench-hsm-commands-5go-eznet.sh` — currently set to 5 eznets ports 9110-9114.
Run: `CMD=mix-online DUR=30 TPS_LADDER="500 1000 1500 2000" bash tests/bench-hsm-commands-5go-eznet.sh`

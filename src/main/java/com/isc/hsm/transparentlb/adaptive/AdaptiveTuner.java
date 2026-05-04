package com.isc.hsm.transparentlb.adaptive;

import com.isc.hsm.transparentlb.config.LbProperties;
import com.isc.hsm.transparentlb.node.NodeResponseStats;
import com.isc.hsm.transparentlb.node.ThalesNode;
import com.isc.hsm.transparentlb.node.ThalesNodePool;
import com.isc.hsm.transparentlb.node.ThalesNodeRegistry;
import io.micrometer.core.instrument.Gauge;
import io.micrometer.core.instrument.MeterRegistry;
import jakarta.annotation.PostConstruct;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.scheduling.annotation.Scheduled;
import org.springframework.stereotype.Component;

import java.util.List;
import java.util.concurrent.atomic.AtomicLong;

/**
 * Learns from observed response latencies and error rates to auto-tune:
 *   - effectiveSocketTimeoutMs  → P99 latency across healthy nodes × 2.0, clamped [minTimeout, configuredMax]
 *   - circuit breaker threshold → tightened when node error rate > 30%, relaxed when < 5%
 *   - request TTL (maxAgeMs)    → kept in sync with effective timeout × maxAttempts + buffer
 *
 * Runs every 30s. Requires at least 20 samples per node before adjusting.
 */
@Component
public class AdaptiveTuner {

    private static final Logger log = LoggerFactory.getLogger(AdaptiveTuner.class);

    private static final int    MIN_SAMPLES          = 20;
    private static final double TIMEOUT_MULTIPLIER   = 2.0;   // P99 × 2 = effective timeout
    private static final int    MIN_TIMEOUT_MS        = 2000;
    private static final double HIGH_ERROR_THRESHOLD  = 0.30;  // tighten CB above 30% errors
    private static final double LOW_ERROR_THRESHOLD   = 0.05;  // relax CB below 5% errors
    private static final int    MIN_CB_THRESHOLD      = 2;
    private static final int    TTL_BUFFER_MS         = 5000;

    private final ThalesNodeRegistry registry;
    private final LbProperties props;
    private final MeterRegistry meters;

    // Track last tuned values for gauges
    private final AtomicLong lastTunedTimeoutMs = new AtomicLong(0);

    public AdaptiveTuner(ThalesNodeRegistry registry, LbProperties props, MeterRegistry meters) {
        this.registry = registry;
        this.props = props;
        this.meters = meters;
    }

    @PostConstruct
    public void registerGauges() {
        Gauge.builder("hsm.lb.adaptive.tuned_timeout_ms", lastTunedTimeoutMs, AtomicLong::get)
            .description("Last socket timeout set by adaptive tuner").register(meters);
    }

    @Scheduled(fixedDelayString = "${hsm.lb.adaptive.interval-ms:30000}")
    public void tune() {
        tuneSocketTimeout();
        tuneCircuitBreakers();
        syncRequestTtl();
    }

    private void tuneSocketTimeout() {
        List<ThalesNodePool> healthy = registry.getHealthyPools();
        if (healthy.isEmpty()) return;

        long maxP99 = 0;
        int nodesWithData = 0;

        for (ThalesNodePool pool : healthy) {
            NodeResponseStats stats = pool.getNode().getResponseStats();
            if (stats.getSampleCount() < MIN_SAMPLES) continue;
            nodesWithData++;
            long p99 = stats.getP99Ms();
            if (p99 > maxP99) maxP99 = p99;
            log.debug("Node {} stats: p95={}ms p99={}ms emaLatency={}ms emaErrRate={:.3f} samples={}",
                pool.getNode().getId(),
                stats.getP95Ms(), p99,
                (long) stats.getEmaLatencyMs(),
                stats.getEmaErrorRate(),
                stats.getSampleCount());
        }

        if (nodesWithData == 0) return;

        int configuredMax = props.getPool().getConfiguredSocketTimeoutMs();
        int target = (int) Math.min(configuredMax, Math.max(MIN_TIMEOUT_MS, maxP99 * TIMEOUT_MULTIPLIER));

        int current = props.getPool().getSocketTimeoutMs();
        if (Math.abs(current - target) > 200) { // only adjust if diff > 200ms to avoid noise
            props.getPool().setEffectiveSocketTimeoutMs(target);
            lastTunedTimeoutMs.set(target);
            log.warn("AdaptiveTuner: socket timeout {} -> {}ms (P99={}ms across {} nodes)",
                current, target, maxP99, nodesWithData);
        }
    }

    private void tuneCircuitBreakers() {
        int configuredThreshold = props.getCircuitBreaker().getFailureThreshold();

        for (ThalesNodePool pool : registry.getAllPools()) {
            ThalesNode node = pool.getNode();
            NodeResponseStats stats = node.getResponseStats();
            if (stats.getSampleCount() < MIN_SAMPLES) continue;

            double errRate = stats.getWindowErrorRate();
            int current = node.getCircuitFailureThreshold();

            if (errRate > HIGH_ERROR_THRESHOLD) {
                // Node is struggling — trip circuit faster
                int tighter = Math.max(MIN_CB_THRESHOLD, current - 1);
                if (tighter != current) {
                    node.setCircuitFailureThreshold(tighter);
                    log.warn("AdaptiveTuner: node {} CB threshold tightened {} -> {} (errRate={:.1f}%)",
                        node.getId(), current, tighter, errRate * 100);
                }
            } else if (errRate < LOW_ERROR_THRESHOLD && current < configuredThreshold) {
                // Node recovering — relax circuit threshold back toward configured
                int relaxed = Math.min(configuredThreshold, current + 1);
                node.setCircuitFailureThreshold(relaxed);
                log.info("AdaptiveTuner: node {} CB threshold relaxed {} -> {} (errRate={:.1f}%)",
                    node.getId(), current, relaxed, errRate * 100);
            }
        }
    }

    private void syncRequestTtl() {
        int effectiveTimeout = props.getPool().getSocketTimeoutMs();
        int maxAttempts = props.getRetry().getMaxAttempts();
        int targetTtl = effectiveTimeout * maxAttempts + TTL_BUFFER_MS;
        int configuredTtl = (int) props.getRequest().getMaxAgeMs();

        // Only tighten or expand within 2x of configured to avoid runaway
        int configuredBase = (int) props.getRequest().getMaxAgeMs();
        if (Math.abs(targetTtl - configuredTtl) > 1000) {
            props.getRequest().setMaxAgeMs(targetTtl);
            log.info("AdaptiveTuner: request TTL synced {}ms -> {}ms (timeout={}ms × attempts={})",
                configuredTtl, targetTtl, effectiveTimeout, maxAttempts);
        }
    }
}

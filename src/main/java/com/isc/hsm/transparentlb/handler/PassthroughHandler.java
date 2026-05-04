package com.isc.hsm.transparentlb.handler;

import com.isc.hsm.transparentlb.config.LbProperties;
import com.isc.hsm.transparentlb.lb.LoadBalancerSelector;
import com.isc.hsm.transparentlb.node.ThalesNodePool;
import com.isc.hsm.transparentlb.node.ThalesNodeRegistry;
import io.micrometer.core.instrument.MeterRegistry;
import io.micrometer.core.instrument.Timer;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.stereotype.Component;

import java.util.ArrayList;
import java.util.List;
import java.util.Optional;
import java.util.concurrent.TimeUnit;

@Component
public class PassthroughHandler {

    private static final Logger log        = LoggerFactory.getLogger(PassthroughHandler.class);
    private static final Logger payloadLog = LoggerFactory.getLogger("com.isc.hsm.transparentlb.PAYLOAD");

    private final ThalesNodeRegistry registry;
    private final LoadBalancerSelector lbSelector;
    private final LbProperties props;
    private final MeterRegistry meters;

    public PassthroughHandler(ThalesNodeRegistry registry,
                              LoadBalancerSelector lbSelector,
                              LbProperties props,
                              MeterRegistry meters) {
        this.registry = registry;
        this.lbSelector = lbSelector;
        this.props = props;
        this.meters = meters;
    }

    public byte[] handle(byte[] rawCommand) throws Exception {
        // Prefer healthy nodes; fall back to any available (circuit-closed) node
        List<ThalesNodePool> candidates = registry.getHealthyPools();
        if (candidates.isEmpty()) candidates = registry.getAvailablePools();
        if (candidates.isEmpty()) {
            meters.counter("hsm.lb.requests", "result", "no_nodes").increment();
            throw new IllegalStateException("No HSM nodes available");
        }

        // Retry strategy:
        // - Multiple nodes: try each once, no same-node retry (avoids TTL exhaustion)
        // - Single node only: retry that node up to maxAttempts times
        int configuredMax = props.getRetry().getMaxAttempts();
        int totalAttempts = candidates.size() == 1 ? configuredMax : candidates.size();
        List<ThalesNodePool> tried = new ArrayList<>();
        Exception lastError = null;

        for (int attempt = 1; attempt <= totalAttempts; attempt++) {
            List<ThalesNodePool> remaining = candidates.stream()
                .filter(p -> !tried.contains(p))
                .toList();
            if (remaining.isEmpty()) tried.clear(); // single-node retry: reset
            remaining = candidates.stream().filter(p -> !tried.contains(p)).toList();
            if (remaining.isEmpty()) break;

            Optional<ThalesNodePool> selected = lbSelector.get().select(remaining);
            if (selected.isEmpty()) break;

            ThalesNodePool pool = selected.get();
            tried.add(pool);
            String nodeId = pool.getNode().getId();
            long t0 = System.currentTimeMillis();

            if (props.getPayload().isLogEnabled()) {
                payloadLog.debug(">>> REQUEST  node={} attempt={} bytes={} hex={}",
                    nodeId, attempt, rawCommand.length, toHex(rawCommand));
            }
            log.debug(">>> REQUEST  node={} attempt={} bytes={} hex={}",
                nodeId, attempt, rawCommand.length, toHex(rawCommand));

            try {
                // Use fast-fail timeout when more nodes remain to try; full timeout on last node
                List<ThalesNodePool> stillRemaining = candidates.stream()
                    .filter(p -> !tried.contains(p))
                    .toList();
                int timeoutMs = stillRemaining.isEmpty()
                    ? props.getPool().getSocketTimeoutMs()
                    : props.getPool().getFastFailTimeoutMs();
                byte[] response = pool.send(rawCommand, timeoutMs);
                long latency = System.currentTimeMillis() - t0;

                Timer.builder("hsm.lb.request.duration")
                    .tag("node", nodeId)
                    .tag("result", "success")
                    .register(meters)
                    .record(latency, TimeUnit.MILLISECONDS);
                meters.counter("hsm.lb.requests", "node", nodeId, "result", "success").increment();

                log.debug("<<< RESPONSE node={} attempt={} bytes={} latency={}ms hex={}",
                    nodeId, attempt, response.length, latency, toHex(response));
                if (props.getPayload().isLogEnabled()) {
                    payloadLog.debug("<<< RESPONSE node={} attempt={} bytes={} latency={}ms hex={}",
                        nodeId, attempt, response.length, latency, toHex(response));
                }

                if (attempt > 1) {
                    log.info("Request succeeded on attempt {} via node={}", attempt, nodeId);
                }
                return response;

            } catch (Exception e) {
                long latency = System.currentTimeMillis() - t0;
                Timer.builder("hsm.lb.request.duration")
                    .tag("node", nodeId)
                    .tag("result", "error")
                    .register(meters)
                    .record(latency, TimeUnit.MILLISECONDS);
                meters.counter("hsm.lb.requests", "node", nodeId, "result", "error").increment();

                log.warn("!!! ERROR    node={} attempt={}/{} latency={}ms error={}",
                    nodeId, attempt, totalAttempts, latency, e.getMessage());
                lastError = e;
            }
        }

        meters.counter("hsm.lb.requests", "result", "exhausted").increment();
        throw lastError != null ? lastError
            : new IllegalStateException("All HSM nodes exhausted after " + totalAttempts + " attempts");
    }

    private static String toHex(byte[] bytes) {
        StringBuilder sb = new StringBuilder(bytes.length * 2);
        for (byte b : bytes) sb.append(String.format("%02X", b));
        return sb.toString();
    }
}

package com.isc.hsm.transparentlb.node;

import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.concurrent.atomic.AtomicLong;

public class ThalesNode {

    private final String id;
    private final String host;
    private final int port;
    private final int weight;

    private final NodeResponseStats responseStats = new NodeResponseStats();

    private final AtomicBoolean healthy = new AtomicBoolean(false);
    private final AtomicBoolean enabled = new AtomicBoolean(true);
    private final AtomicInteger activeConnections = new AtomicInteger(0);
    private final AtomicLong totalRequests = new AtomicLong(0);
    private final AtomicLong totalErrors = new AtomicLong(0);
    private volatile long lastHealthCheckMs = 0;

    // Circuit breaker state
    private final AtomicInteger consecutiveErrors = new AtomicInteger(0);
    private volatile long circuitOpenedAt = 0;
    private int circuitFailureThreshold = 5;
    private long circuitResetMs = 30_000;

    public ThalesNode(String id, String host, int port, int weight) {
        this.id = id;
        this.host = host;
        this.port = port;
        this.weight = weight;
    }

    public void configureCircuitBreaker(int failureThreshold, long resetMs) {
        this.circuitFailureThreshold = failureThreshold;
        this.circuitResetMs = resetMs;
    }

    public String getId() { return id; }
    public String getHost() { return host; }
    public int getPort() { return port; }
    public int getWeight() { return weight; }

    public boolean isHealthy() { return healthy.get(); }

    public void setHealthy(boolean v) {
        healthy.set(v);
        lastHealthCheckMs = System.currentTimeMillis();
        if (v) {
            consecutiveErrors.set(0);
            circuitOpenedAt = 0;
        }
    }

    public boolean isEnabled() { return enabled.get(); }
    public void setEnabled(boolean v) { enabled.set(v); }

    public boolean isCircuitOpen() {
        int errors = consecutiveErrors.get();
        if (errors < circuitFailureThreshold) return false;
        long openedAt = circuitOpenedAt;
        if (openedAt == 0) return false;
        if (System.currentTimeMillis() - openedAt >= circuitResetMs) {
            // half-open: allow one probe through
            return false;
        }
        return true;
    }

    public boolean isAvailable() {
        return enabled.get() && !isCircuitOpen();
    }

    public int getActiveConnections() { return activeConnections.get(); }
    public void incrementActive() { activeConnections.incrementAndGet(); }
    public void decrementActive() { activeConnections.decrementAndGet(); }

    public void recordRequest() { totalRequests.incrementAndGet(); }

    public void recordError() {
        totalErrors.incrementAndGet();
        int errs = consecutiveErrors.incrementAndGet();
        if (errs >= circuitFailureThreshold && circuitOpenedAt == 0) {
            circuitOpenedAt = System.currentTimeMillis();
        }
    }

    public void recordSuccess() {
        consecutiveErrors.set(0);
        circuitOpenedAt = 0;
    }

    public long getTotalRequests() { return totalRequests.get(); }
    public long getTotalErrors() { return totalErrors.get(); }
    public long getLastHealthCheckMs() { return lastHealthCheckMs; }
    public int getConsecutiveErrors() { return consecutiveErrors.get(); }
    public long getCircuitOpenedAt() { return circuitOpenedAt; }
    public int getCircuitFailureThreshold() { return circuitFailureThreshold; }
    public void setCircuitFailureThreshold(int v) { this.circuitFailureThreshold = v; }
    public NodeResponseStats getResponseStats() { return responseStats; }

    @Override
    public String toString() {
        return id + "(" + host + ":" + port + " healthy=" + healthy.get()
                + " circuit=" + (isCircuitOpen() ? "OPEN" : "CLOSED")
                + " active=" + activeConnections.get() + ")";
    }
}

package com.isc.hsm.transparentlb.node;

import java.util.Arrays;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.concurrent.atomic.AtomicLong;

/**
 * Rolling per-node response statistics over a fixed window.
 * Thread-safe circular buffer — lock-free writes, sorted-copy reads.
 */
public class NodeResponseStats {

    private static final int WINDOW = 200;

    private final long[] latencies = new long[WINDOW];
    private final boolean[] errors = new boolean[WINDOW];
    private final AtomicInteger cursor = new AtomicInteger(0);
    private final AtomicInteger totalSamples = new AtomicInteger(0);

    // EMA of latency and error rate for smooth trending
    private volatile double emaLatencyMs = 0;
    private volatile double emaErrorRate = 0;
    private static final double ALPHA = 0.1; // EMA smoothing factor

    public void record(long latencyMs, boolean isError) {
        int slot = cursor.getAndIncrement() % WINDOW;
        latencies[slot] = latencyMs;
        errors[slot] = isError;
        totalSamples.incrementAndGet();

        emaLatencyMs = ALPHA * latencyMs + (1 - ALPHA) * emaLatencyMs;
        emaErrorRate = ALPHA * (isError ? 1.0 : 0.0) + (1 - ALPHA) * emaErrorRate;
    }

    public int getSampleCount() {
        return Math.min(totalSamples.get(), WINDOW);
    }

    /** P95 latency over the current window. Returns 0 if no samples. */
    public long getP95Ms() {
        return percentile(0.95);
    }

    /** P99 latency over the current window. Returns 0 if no samples. */
    public long getP99Ms() {
        return percentile(0.99);
    }

    public double getEmaLatencyMs() { return emaLatencyMs; }
    public double getEmaErrorRate() { return emaErrorRate; }

    /** Error rate (0.0–1.0) over current window. */
    public double getWindowErrorRate() {
        int n = getSampleCount();
        if (n == 0) return 0.0;
        int errCount = 0;
        for (int i = 0; i < n; i++) {
            if (errors[i]) errCount++;
        }
        return (double) errCount / n;
    }

    private long percentile(double p) {
        int n = getSampleCount();
        if (n == 0) return 0;
        long[] snap = Arrays.copyOf(latencies, n);
        Arrays.sort(snap);
        int idx = (int) Math.ceil(p * n) - 1;
        return snap[Math.max(0, Math.min(idx, n - 1))];
    }
}

package com.isc.hsm.transparentlb.config;

import org.springframework.boot.context.properties.ConfigurationProperties;
import org.springframework.stereotype.Component;

import java.util.ArrayList;
import java.util.List;

@Component
@ConfigurationProperties(prefix = "hsm.lb")
public class LbProperties {

    private String algorithm = "ROUND_ROBIN";
    private String nodes = "";

    private QueueConfig queue = new QueueConfig();
    private JmsConfig jms = new JmsConfig();
    private PoolConfig pool = new PoolConfig();
    private HealthConfig health = new HealthConfig();
    private CircuitBreakerConfig circuitBreaker = new CircuitBreakerConfig();
    private RetryConfig retry = new RetryConfig();
    private PayloadConfig payload = new PayloadConfig();
    private RequestConfig request = new RequestConfig();
    private AdaptiveConfig adaptive = new AdaptiveConfig();

    public static class AdaptiveConfig {
        private long intervalMs = 30000;
        public long getIntervalMs() { return intervalMs; }
        public void setIntervalMs(long v) { intervalMs = v; }
    }
    public AdaptiveConfig getAdaptive() { return adaptive; }
    public void setAdaptive(AdaptiveConfig v) { adaptive = v; }

    public List<NodeEntry> parsedNodes() {
        List<NodeEntry> result = new ArrayList<>();
        if (nodes == null || nodes.isBlank()) return result;
        for (String token : nodes.split(",")) {
            String[] parts = token.trim().split(":");
            if (parts.length < 3) continue;
            String id = parts[0];
            String host = parts[1];
            int port = Integer.parseInt(parts[2]);
            int weight = parts.length >= 4 ? Integer.parseInt(parts[3]) : 1;
            result.add(new NodeEntry(id, host, port, weight));
        }
        return result;
    }

    public record NodeEntry(String id, String host, int port, int weight) {}

    public static class QueueConfig {
        private String inbound = "hsm.transparent.lb.in";
        private String control = "hsm.transparent.lb.control";
        private String reply = "hsm.transparent.lb.reply";
        public String getInbound() { return inbound; }
        public void setInbound(String v) { inbound = v; }
        public String getControl() { return control; }
        public void setControl(String v) { control = v; }
        public String getReply() { return reply; }
        public void setReply(String v) { reply = v; }
    }

    public static class JmsConfig {
        private int concurrentConsumers = 20;
        private int maxConcurrentConsumers = 100;
        private int perNodeCapacity = 10;
        public int getConcurrentConsumers() { return concurrentConsumers; }
        public void setConcurrentConsumers(int v) { concurrentConsumers = v; }
        public int getMaxConcurrentConsumers() { return maxConcurrentConsumers; }
        public void setMaxConcurrentConsumers(int v) { maxConcurrentConsumers = v; }
        public int getPerNodeCapacity() { return perNodeCapacity; }
        public void setPerNodeCapacity(int v) { perNodeCapacity = v; }
    }

    public static class PoolConfig {
        private int maxTotal = 20;
        private int minIdle = 2;
        private long maxWaitMs = 3000;
        private int socketTimeoutMs = 10000;
        private volatile int effectiveSocketTimeoutMs = 10000;
        private int connectTimeoutMs = 3000;
        private int fastFailTimeoutMs = 5;
        public int getMaxTotal() { return maxTotal; }
        public void setMaxTotal(int v) { maxTotal = v; }
        public int getMinIdle() { return minIdle; }
        public void setMinIdle(int v) { minIdle = v; }
        public long getMaxWaitMs() { return maxWaitMs; }
        public void setMaxWaitMs(long v) { maxWaitMs = v; }
        public int getSocketTimeoutMs() { return effectiveSocketTimeoutMs; }
        public void setSocketTimeoutMs(int v) { socketTimeoutMs = v; effectiveSocketTimeoutMs = v; }
        public int getConfiguredSocketTimeoutMs() { return socketTimeoutMs; }
        public void setEffectiveSocketTimeoutMs(int v) { effectiveSocketTimeoutMs = v; }
        public int getConnectTimeoutMs() { return connectTimeoutMs; }
        public void setConnectTimeoutMs(int v) { connectTimeoutMs = v; }
        public int getFastFailTimeoutMs() { return fastFailTimeoutMs; }
        public void setFastFailTimeoutMs(int v) { fastFailTimeoutMs = v; }
    }

    public static class HealthConfig {
        private long intervalMs = 20000;
        private String commandHex = "0008303030304e4f3030";
        public long getIntervalMs() { return intervalMs; }
        public void setIntervalMs(long v) { intervalMs = v; }
        public String getCommandHex() { return commandHex; }
        public void setCommandHex(String v) { commandHex = v; }
    }

    public static class CircuitBreakerConfig {
        private int failureThreshold = 5;
        private long resetMs = 30000;
        public int getFailureThreshold() { return failureThreshold; }
        public void setFailureThreshold(int v) { failureThreshold = v; }
        public long getResetMs() { return resetMs; }
        public void setResetMs(long v) { resetMs = v; }
    }

    public static class RetryConfig {
        private int maxAttempts = 2;
        public int getMaxAttempts() { return maxAttempts; }
        public void setMaxAttempts(int v) { maxAttempts = v; }
    }

    public static class PayloadConfig {
        private boolean logEnabled = false;
        public boolean isLogEnabled() { return logEnabled; }
        public void setLogEnabled(boolean v) { logEnabled = v; }
    }

    public static class RequestConfig {
        private long maxAgeMs = 30000;
        public long getMaxAgeMs() { return maxAgeMs; }
        public void setMaxAgeMs(long v) { maxAgeMs = v; }
    }

    public String getAlgorithm() { return algorithm; }
    public void setAlgorithm(String v) { algorithm = v; }
    public String getNodes() { return nodes; }
    public void setNodes(String v) { nodes = v; }
    public QueueConfig getQueue() { return queue; }
    public void setQueue(QueueConfig v) { queue = v; }
    public JmsConfig getJms() { return jms; }
    public void setJms(JmsConfig v) { jms = v; }
    public PoolConfig getPool() { return pool; }
    public void setPool(PoolConfig v) { pool = v; }
    public HealthConfig getHealth() { return health; }
    public void setHealth(HealthConfig v) { health = v; }
    public CircuitBreakerConfig getCircuitBreaker() { return circuitBreaker; }
    public void setCircuitBreaker(CircuitBreakerConfig v) { circuitBreaker = v; }
    public RetryConfig getRetry() { return retry; }
    public void setRetry(RetryConfig v) { retry = v; }
    public PayloadConfig getPayload() { return payload; }
    public void setPayload(PayloadConfig v) { payload = v; }
    public RequestConfig getRequest() { return request; }
    public void setRequest(RequestConfig v) { request = v; }
}

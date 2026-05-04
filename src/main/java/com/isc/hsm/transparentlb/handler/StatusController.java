package com.isc.hsm.transparentlb.handler;

import com.isc.hsm.transparentlb.config.LbProperties;
import com.isc.hsm.transparentlb.lb.LoadBalancerSelector;
import com.isc.hsm.transparentlb.node.ThalesNode;
import com.isc.hsm.transparentlb.node.ThalesNodePool;
import com.isc.hsm.transparentlb.node.ThalesNodeRegistry;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.http.ResponseEntity;
import org.springframework.jms.listener.DefaultMessageListenerContainer;
import org.springframework.web.bind.annotation.*;

import java.time.Instant;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

@RestController
@RequestMapping("/api/v1/hsm-lb")
public class StatusController {

    private final ThalesNodeRegistry registry;
    private final LoadBalancerSelector lbSelector;
    private final DefaultMessageListenerContainer listenerContainer;
    private final LbProperties props;

    @Value("${hsm.lb.instance-id:}")
    private String configuredInstanceId;

    public StatusController(ThalesNodeRegistry registry,
                            LoadBalancerSelector lbSelector,
                            DefaultMessageListenerContainer listenerContainer,
                            LbProperties props) {
        this.registry = registry;
        this.lbSelector = lbSelector;
        this.listenerContainer = listenerContainer;
        this.props = props;
    }

    private String instanceId() {
        if (configuredInstanceId != null && !configuredInstanceId.isBlank()) return configuredInstanceId;
        try { return java.net.InetAddress.getLocalHost().getHostName(); }
        catch (Exception e) { return "unknown"; }
    }

    @GetMapping("/status")
    public Map<String, Object> status() {
        List<ThalesNodePool> all = registry.getAllPools();
        List<Map<String, Object>> nodes = all.stream().map(p -> nodeMap(p)).toList();

        Map<String, Object> result = new LinkedHashMap<>();
        result.put("instanceId", instanceId());
        result.put("algorithm", lbSelector.get().name());
        result.put("totalNodes", all.size());
        result.put("healthyNodes", registry.getHealthyPools().size());
        result.put("availableNodes", registry.getAvailablePools().size());
        result.put("jmsMaxConsumers", listenerContainer.getMaxConcurrentConsumers());
        result.put("jmsActiveConsumers", listenerContainer.getActiveConsumerCount());
        result.put("effectiveSocketTimeoutMs", props.getPool().getSocketTimeoutMs());
        result.put("configuredSocketTimeoutMs", props.getPool().getConfiguredSocketTimeoutMs());
        result.put("nodes", nodes);
        return result;
    }

    /** Enable or disable a node at runtime. */
    @PostMapping("/nodes/{id}/enabled")
    public ResponseEntity<Map<String, Object>> setEnabled(@PathVariable String id,
                                                          @RequestParam boolean value) {
        return registry.findById(id).map(pool -> {
            pool.getNode().setEnabled(value);
            Map<String, Object> resp = new LinkedHashMap<>();
            resp.put("node", id);
            resp.put("enabled", value);
            return ResponseEntity.ok(resp);
        }).orElse(ResponseEntity.notFound().build());
    }

    /** Reset circuit breaker for a node. */
    @PostMapping("/nodes/{id}/circuit-reset")
    public ResponseEntity<Map<String, Object>> resetCircuit(@PathVariable String id) {
        return registry.findById(id).map(pool -> {
            pool.getNode().recordSuccess();
            Map<String, Object> resp = new LinkedHashMap<>();
            resp.put("node", id);
            resp.put("circuitReset", true);
            return ResponseEntity.ok(resp);
        }).orElse(ResponseEntity.notFound().build());
    }

    private Map<String, Object> nodeMap(ThalesNodePool p) {
        ThalesNode n = p.getNode();
        long totalReq = n.getTotalRequests();
        long totalErr = n.getTotalErrors();
        double errorRate = totalReq > 0 ? (100.0 * totalErr / totalReq) : 0.0;

        Map<String, Object> m = new LinkedHashMap<>();
        m.put("id", n.getId());
        m.put("host", n.getHost());
        m.put("port", n.getPort());
        m.put("weight", n.getWeight());
        m.put("enabled", n.isEnabled());
        m.put("healthy", n.isHealthy());
        m.put("circuitOpen", n.isCircuitOpen());
        m.put("consecutiveErrors", n.getConsecutiveErrors());
        if (n.getCircuitOpenedAt() > 0) {
            m.put("circuitOpenedAt", Instant.ofEpochMilli(n.getCircuitOpenedAt()).toString());
        }
        m.put("activeConnections", p.getNumActive());
        m.put("totalRequests", totalReq);
        m.put("totalErrors", totalErr);
        m.put("errorRatePct", Math.round(errorRate * 10.0) / 10.0);
        if (n.getLastHealthCheckMs() > 0) {
            m.put("lastHealthCheck", Instant.ofEpochMilli(n.getLastHealthCheckMs()).toString());
        }
        return m;
    }
}

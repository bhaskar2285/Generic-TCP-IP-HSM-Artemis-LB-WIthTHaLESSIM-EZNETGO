package com.isc.hsm.transparentlb.node;

import com.isc.hsm.transparentlb.config.LbProperties;
import jakarta.annotation.PostConstruct;
import jakarta.annotation.PreDestroy;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.stereotype.Component;

import java.util.ArrayList;
import java.util.Collections;
import java.util.List;
import java.util.Optional;

@Component
public class ThalesNodeRegistry {

    private static final Logger log = LoggerFactory.getLogger(ThalesNodeRegistry.class);

    private final LbProperties props;
    private final List<ThalesNodePool> nodePools = new ArrayList<>();

    public ThalesNodeRegistry(LbProperties props) {
        this.props = props;
    }

    @PostConstruct
    public void init() {
        List<LbProperties.NodeEntry> entries = props.parsedNodes();
        if (entries.isEmpty()) {
            throw new IllegalStateException(
                "No HSM nodes configured — set hsm.lb.nodes=id:host:port:weight in application.properties");
        }
        for (LbProperties.NodeEntry entry : entries) {
            ThalesNode node = new ThalesNode(entry.id(), entry.host(), entry.port(), entry.weight());
            ThalesNodePool pool = new ThalesNodePool(node, props);
            nodePools.add(pool);
            log.info("Registered HSM node: {}", node);
        }
    }

    public List<ThalesNodePool> getAllPools() {
        return Collections.unmodifiableList(nodePools);
    }

    /** Returns pools that are enabled AND not circuit-open (healthy flag is advisory for routing priority). */
    public List<ThalesNodePool> getAvailablePools() {
        List<ThalesNodePool> available = nodePools.stream()
            .filter(p -> p.getNode().isAvailable())
            .toList();
        if (!available.isEmpty()) return available;
        // Fallback: return all enabled pools even if circuit-open (last-resort)
        return nodePools.stream().filter(p -> p.getNode().isEnabled()).toList();
    }

    /** Returns pools that are both available AND healthy (for preferred routing). */
    public List<ThalesNodePool> getHealthyPools() {
        return nodePools.stream()
            .filter(p -> p.getNode().isAvailable() && p.getNode().isHealthy())
            .toList();
    }

    public Optional<ThalesNodePool> findById(String id) {
        return nodePools.stream().filter(p -> p.getNode().getId().equals(id)).findFirst();
    }

    @PreDestroy
    public void shutdown() {
        log.info("Shutting down {} HSM node connections", nodePools.size());
        nodePools.forEach(ThalesNodePool::close);
    }
}

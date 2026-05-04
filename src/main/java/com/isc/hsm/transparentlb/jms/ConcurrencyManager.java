package com.isc.hsm.transparentlb.jms;

import com.isc.hsm.transparentlb.config.LbProperties;
import com.isc.hsm.transparentlb.node.ThalesNodeRegistry;
import io.micrometer.core.instrument.Gauge;
import io.micrometer.core.instrument.MeterRegistry;
import jakarta.annotation.PostConstruct;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.jms.listener.DefaultMessageListenerContainer;
import org.springframework.stereotype.Component;

/**
 * Adjusts JMS consumer concurrency in response to node health changes.
 * Prevents surviving nodes from being overwhelmed when peers go down.
 *
 * Formula: maxConcurrent = healthyNodes * perNodeCapacity, clamped to [minConsumers, configuredMax].
 */
@Component
public class ConcurrencyManager {

    private static final Logger log = LoggerFactory.getLogger(ConcurrencyManager.class);

    private final DefaultMessageListenerContainer container;
    private final ThalesNodeRegistry registry;
    private final LbProperties props;
    private final MeterRegistry meters;

    public ConcurrencyManager(DefaultMessageListenerContainer container,
                              ThalesNodeRegistry registry,
                              LbProperties props,
                              MeterRegistry meters) {
        this.container = container;
        this.registry = registry;
        this.props = props;
        this.meters = meters;
    }

    @PostConstruct
    public void registerGauges() {
        Gauge.builder("hsm.lb.jms.max_consumers", container,
                DefaultMessageListenerContainer::getMaxConcurrentConsumers)
            .register(meters);
        Gauge.builder("hsm.lb.jms.active_consumers", container,
                DefaultMessageListenerContainer::getActiveConsumerCount)
            .register(meters);
        Gauge.builder("hsm.lb.jms.healthy_nodes", registry,
                r -> r.getHealthyPools().size())
            .register(meters);
        Gauge.builder("hsm.lb.socket.effective_timeout_ms", props.getPool(),
                p -> p.getSocketTimeoutMs())
            .register(meters);
    }

    public void adjustConcurrency() {
        int totalNodes = registry.getAllPools().size();
        int healthy = registry.getHealthyPools().size();
        int effectiveHealthy = healthy == 0 ? 1 : healthy;

        // Scale consumers: healthyNodes * perNodeCapacity, clamped to [min, configuredMax]
        int perNode = props.getJms().getPerNodeCapacity();
        int min = props.getJms().getConcurrentConsumers();
        int configuredMax = props.getJms().getMaxConcurrentConsumers();
        int targetConsumers = Math.min(Math.max(effectiveHealthy * perNode, min), configuredMax);

        int currentConsumers = container.getMaxConcurrentConsumers();
        if (currentConsumers != targetConsumers) {
            container.setMaxConcurrentConsumers(targetConsumers);
            log.warn("Consumer concurrency adjusted: {} -> {} (healthyNodes={}/{})",
                currentConsumers, targetConsumers, healthy, totalNodes);
            meters.counter("hsm.lb.concurrency.adjustments",
                "direction", targetConsumers > currentConsumers ? "up" : "down").increment();
        }

        // Socket timeout is owned exclusively by AdaptiveTuner (P99-learned).
        // ConcurrencyManager only scales consumer count — not timeout.
    }
}

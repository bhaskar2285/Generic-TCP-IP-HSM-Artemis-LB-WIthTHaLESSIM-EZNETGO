package com.isc.hsm.transparentlb.lb;

import com.isc.hsm.transparentlb.node.ThalesNodePool;
import org.springframework.stereotype.Component;

import java.util.ArrayList;
import java.util.List;
import java.util.Optional;
import java.util.concurrent.atomic.AtomicInteger;

@Component("WEIGHTED_ROUND_ROBIN")
public class WeightedRoundRobinLb implements LoadBalancer {

    private final AtomicInteger counter = new AtomicInteger(0);

    @Override
    public Optional<ThalesNodePool> select(List<ThalesNodePool> healthyPools) {
        if (healthyPools.isEmpty()) return Optional.empty();

        // Expand list by weight
        List<ThalesNodePool> weighted = new ArrayList<>();
        for (ThalesNodePool p : healthyPools) {
            int w = Math.max(1, p.getNode().getWeight());
            for (int i = 0; i < w; i++) weighted.add(p);
        }

        int idx = Math.abs(counter.getAndIncrement() % weighted.size());
        return Optional.of(weighted.get(idx));
    }

    @Override
    public String name() { return "WEIGHTED_ROUND_ROBIN"; }
}

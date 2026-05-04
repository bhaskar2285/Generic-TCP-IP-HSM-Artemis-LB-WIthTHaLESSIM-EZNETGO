package com.isc.hsm.transparentlb.lb;

import com.isc.hsm.transparentlb.node.ThalesNodePool;
import org.springframework.stereotype.Component;

import java.util.List;
import java.util.Optional;
import java.util.concurrent.atomic.AtomicInteger;

@Component("ROUND_ROBIN")
public class RoundRobinLb implements LoadBalancer {

    private final AtomicInteger counter = new AtomicInteger(0);

    @Override
    public Optional<ThalesNodePool> select(List<ThalesNodePool> healthyPools) {
        if (healthyPools.isEmpty()) return Optional.empty();
        int idx = Math.abs(counter.getAndIncrement() % healthyPools.size());
        return Optional.of(healthyPools.get(idx));
    }

    @Override
    public String name() { return "ROUND_ROBIN"; }
}

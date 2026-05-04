package com.isc.hsm.transparentlb.lb;

import com.isc.hsm.transparentlb.node.ThalesNodePool;
import org.springframework.stereotype.Component;

import java.util.List;
import java.util.Optional;
import java.util.concurrent.ThreadLocalRandom;

@Component("RANDOM")
public class RandomLb implements LoadBalancer {

    @Override
    public Optional<ThalesNodePool> select(List<ThalesNodePool> healthyPools) {
        if (healthyPools.isEmpty()) return Optional.empty();
        int idx = ThreadLocalRandom.current().nextInt(healthyPools.size());
        return Optional.of(healthyPools.get(idx));
    }

    @Override
    public String name() { return "RANDOM"; }
}

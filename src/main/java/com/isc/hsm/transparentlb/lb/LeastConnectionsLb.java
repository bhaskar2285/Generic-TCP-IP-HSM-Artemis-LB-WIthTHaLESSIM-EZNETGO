package com.isc.hsm.transparentlb.lb;

import com.isc.hsm.transparentlb.node.ThalesNodePool;
import org.springframework.stereotype.Component;

import java.util.Comparator;
import java.util.List;
import java.util.Optional;

@Component("LEAST_CONNECTIONS")
public class LeastConnectionsLb implements LoadBalancer {

    @Override
    public Optional<ThalesNodePool> select(List<ThalesNodePool> healthyPools) {
        return healthyPools.stream()
            .min(Comparator.comparingInt(ThalesNodePool::getNumActive));
    }

    @Override
    public String name() { return "LEAST_CONNECTIONS"; }
}

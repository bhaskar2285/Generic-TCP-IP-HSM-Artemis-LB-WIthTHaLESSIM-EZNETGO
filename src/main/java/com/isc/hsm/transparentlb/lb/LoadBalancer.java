package com.isc.hsm.transparentlb.lb;

import com.isc.hsm.transparentlb.node.ThalesNodePool;

import java.util.List;
import java.util.Optional;

public interface LoadBalancer {
    Optional<ThalesNodePool> select(List<ThalesNodePool> healthyPools);
    String name();
}

package com.isc.hsm.transparentlb.lb;

import com.isc.hsm.transparentlb.config.LbProperties;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.stereotype.Component;

import java.util.Map;

@Component
public class LoadBalancerSelector {

    private static final Logger log = LoggerFactory.getLogger(LoadBalancerSelector.class);

    private final LoadBalancer active;

    public LoadBalancerSelector(LbProperties props, Map<String, LoadBalancer> allBalancers) {
        String algo = props.getAlgorithm().toUpperCase();
        this.active = allBalancers.getOrDefault(algo, allBalancers.get("ROUND_ROBIN"));
        log.info("Active load balancing algorithm: {}", this.active.name());
    }

    public LoadBalancer get() {
        return active;
    }
}

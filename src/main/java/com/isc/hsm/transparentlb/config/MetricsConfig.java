package com.isc.hsm.transparentlb.config;

import io.micrometer.core.instrument.MeterRegistry;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.boot.actuate.autoconfigure.metrics.MeterRegistryCustomizer;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;

import java.net.InetAddress;

@Configuration
public class MetricsConfig {

    @Value("${hsm.lb.instance-id:}")
    private String instanceId;

    @Bean
    public MeterRegistryCustomizer<MeterRegistry> instanceTags() {
        String id = resolveInstanceId();
        return registry -> registry.config().commonTags("instance", id);
    }

    private String resolveInstanceId() {
        if (instanceId != null && !instanceId.isBlank()) return instanceId;
        try { return InetAddress.getLocalHost().getHostName(); }
        catch (Exception e) { return "unknown"; }
    }
}

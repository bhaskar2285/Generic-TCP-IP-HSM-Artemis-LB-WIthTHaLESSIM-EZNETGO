package com.isc.hsm.transparentlb.jms;

import com.isc.hsm.transparentlb.config.LbProperties;
import jakarta.jms.ConnectionFactory;
import jakarta.jms.Session;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.core.task.VirtualThreadTaskExecutor;
import org.springframework.jms.listener.DefaultMessageListenerContainer;

@Configuration
public class JmsConfig {

    private static final Logger log = LoggerFactory.getLogger(JmsConfig.class);

    @Bean
    public DefaultMessageListenerContainer hsmListenerContainer(
            LbProperties props,
            HsmRequestListener listener,
            ConnectionFactory connectionFactory) {

        LbProperties.JmsConfig jmsCfg = props.getJms();
        DefaultMessageListenerContainer container = new DefaultMessageListenerContainer();
        container.setConnectionFactory(connectionFactory);
        container.setDestinationName(props.getQueue().getInbound());
        container.setMessageListener(listener);
        container.setConcurrentConsumers(jmsCfg.getConcurrentConsumers());
        container.setMaxConcurrentConsumers(jmsCfg.getMaxConcurrentConsumers());
        // CLIENT_ACKNOWLEDGE: message re-delivered if processing throws before acknowledge
        container.setSessionAcknowledgeMode(Session.CLIENT_ACKNOWLEDGE);
        container.setSessionTransacted(false);
        // Drain in-flight messages before stopping
        container.setAcceptMessagesWhileStopping(false);

        // Virtual-thread executor — opt-in via hsm.lb.jms.virtual-threads=true.
        // spring.threads.virtual.enabled only affects Tomcat / @Async — DMLC keeps
        // platform threads unless we wire a VT executor in directly.
        if (jmsCfg.isVirtualThreads()) {
            container.setTaskExecutor(new VirtualThreadTaskExecutor("hsm-jms-vt-"));
            log.info("JMS listener container using VirtualThreadTaskExecutor (consumers={}-{})",
                jmsCfg.getConcurrentConsumers(), jmsCfg.getMaxConcurrentConsumers());
        } else {
            log.info("JMS listener container using platform threads (consumers={}-{})",
                jmsCfg.getConcurrentConsumers(), jmsCfg.getMaxConcurrentConsumers());
        }
        return container;
    }
}

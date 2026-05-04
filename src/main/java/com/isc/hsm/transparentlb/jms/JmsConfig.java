package com.isc.hsm.transparentlb.jms;

import com.isc.hsm.transparentlb.config.LbProperties;
import jakarta.jms.ConnectionFactory;
import jakarta.jms.Session;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.jms.listener.DefaultMessageListenerContainer;

@Configuration
public class JmsConfig {

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
        return container;
    }
}

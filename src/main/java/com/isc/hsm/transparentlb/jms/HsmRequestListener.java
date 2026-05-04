package com.isc.hsm.transparentlb.jms;

import com.isc.hsm.transparentlb.config.LbProperties;
import com.isc.hsm.transparentlb.handler.PassthroughHandler;
import io.micrometer.core.instrument.MeterRegistry;
import jakarta.jms.BytesMessage;
import jakarta.jms.Destination;
import jakarta.jms.JMSException;
import jakarta.jms.Message;
import jakarta.jms.MessageListener;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.jms.core.JmsTemplate;
import org.springframework.stereotype.Component;

@Component
public class HsmRequestListener implements MessageListener {

    private static final Logger log = LoggerFactory.getLogger(HsmRequestListener.class);

    private final PassthroughHandler handler;
    private final JmsTemplate jmsTemplate;
    private final LbProperties props;
    private final MeterRegistry meters;

    public HsmRequestListener(PassthroughHandler handler,
                              JmsTemplate jmsTemplate,
                              LbProperties props,
                              MeterRegistry meters) {
        this.handler = handler;
        this.jmsTemplate = jmsTemplate;
        this.props = props;
        this.meters = meters;
    }

    @Override
    public void onMessage(Message message) {
        String correlationId = null;
        Destination replyTo = null;
        try {
            // TTL enforcement: drop messages older than configured max age
            long maxAgeMs = props.getRequest().getMaxAgeMs();
            if (maxAgeMs > 0) {
                long timestamp = message.getJMSTimestamp();
                if (timestamp > 0 && System.currentTimeMillis() - timestamp > maxAgeMs) {
                    log.warn("Dropping expired JMS message (age={}ms, max={}ms)",
                        System.currentTimeMillis() - timestamp, maxAgeMs);
                    meters.counter("hsm.lb.messages.dropped", "reason", "expired").increment();
                    return;
                }
            }

            correlationId = message.getStringProperty("ip_connectionId");
            String eznetReplyTo = message.getStringProperty("gw_replyTo");
            replyTo = message.getJMSReplyTo();
            if (replyTo == null && eznetReplyTo != null) {
                final String dest = eznetReplyTo;
                replyTo = jmsTemplate.execute(session -> session.createQueue(dest));
            }
            if (correlationId == null) correlationId = message.getJMSMessageID();
            log.debug("Request connectionId={} replyTo={}", correlationId, replyTo);

            byte[] rawCommand = extractBytes(message);
            if (rawCommand == null || rawCommand.length == 0) {
                log.warn("Received empty message, correlationId={}", correlationId);
                meters.counter("hsm.lb.messages.dropped", "reason", "empty").increment();
                return;
            }

            meters.counter("hsm.lb.messages.received").increment();
            byte[] response = handler.handle(rawCommand);
            sendReply(replyTo, correlationId, response);

        } catch (Exception e) {
            log.error("Failed to process HSM request correlationId={}: {}", correlationId, e.getMessage(), e);
            meters.counter("hsm.lb.messages.errors").increment();
            if (correlationId != null) {
                sendErrorReply(replyTo, correlationId);
            }
        }
    }

    private byte[] extractBytes(Message message) throws JMSException {
        if (message instanceof BytesMessage bm) {
            byte[] buf = new byte[(int) bm.getBodyLength()];
            bm.readBytes(buf);
            return buf;
        }
        log.warn("Received non-BytesMessage: {}", message.getClass().getSimpleName());
        return null;
    }

    private void sendReply(Destination replyTo, String correlationId, byte[] response) {
        final String corrId = correlationId;
        if (replyTo != null) {
            jmsTemplate.send(replyTo, session -> {
                BytesMessage reply = session.createBytesMessage();
                reply.writeBytes(response);
                if (corrId != null) {
                    reply.setJMSCorrelationID(corrId);
                    reply.setStringProperty("ip_connectionId", corrId);
                }
                return reply;
            });
        } else {
            String fallback = props.getQueue().getReply();
            log.debug("No replyTo, falling back to queue={} correlationId={}", fallback, corrId);
            jmsTemplate.send(fallback, session -> {
                BytesMessage reply = session.createBytesMessage();
                reply.writeBytes(response);
                if (corrId != null) {
                    reply.setJMSCorrelationID(corrId);
                    reply.setStringProperty("ip_connectionId", corrId);
                }
                return reply;
            });
        }
    }

    private void sendErrorReply(Destination replyTo, String correlationId) {
        if (replyTo != null) {
            jmsTemplate.send(replyTo, session -> {
                BytesMessage reply = session.createBytesMessage();
                reply.writeBytes(new byte[]{0, 0});
                reply.setJMSCorrelationID(correlationId);
                reply.setStringProperty("ip_connectionId", correlationId);
                return reply;
            });
        } else {
            String fallback = props.getQueue().getReply();
            jmsTemplate.send(fallback, session -> {
                BytesMessage reply = session.createBytesMessage();
                reply.writeBytes(new byte[]{0, 0});
                reply.setJMSCorrelationID(correlationId);
                reply.setStringProperty("ip_connectionId", correlationId);
                return reply;
            });
        }
    }
}

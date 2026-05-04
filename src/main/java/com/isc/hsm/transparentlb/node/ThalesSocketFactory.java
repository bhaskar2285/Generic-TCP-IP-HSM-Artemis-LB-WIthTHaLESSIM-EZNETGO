package com.isc.hsm.transparentlb.node;

import org.apache.commons.pool2.PooledObject;
import org.apache.commons.pool2.PooledObjectFactory;
import org.apache.commons.pool2.impl.DefaultPooledObject;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

import java.net.InetSocketAddress;
import java.net.Socket;
import java.net.SocketTimeoutException;

public class ThalesSocketFactory implements PooledObjectFactory<Socket> {

    private static final Logger log = LoggerFactory.getLogger(ThalesSocketFactory.class);

    private final String host;
    private final int port;
    private final int connectTimeoutMs;
    private final int socketTimeoutMs;

    public ThalesSocketFactory(String host, int port, int connectTimeoutMs, int socketTimeoutMs) {
        this.host = host;
        this.port = port;
        this.connectTimeoutMs = connectTimeoutMs;
        this.socketTimeoutMs = socketTimeoutMs;
    }

    @Override
    public PooledObject<Socket> makeObject() throws Exception {
        Socket socket = new Socket();
        socket.setSoTimeout(socketTimeoutMs);
        socket.setKeepAlive(true);
        socket.setTcpNoDelay(true);
        socket.connect(new InetSocketAddress(host, port), connectTimeoutMs);
        log.debug("Created socket to {}:{}", host, port);
        return new DefaultPooledObject<>(socket);
    }

    @Override
    public void destroyObject(PooledObject<Socket> p) {
        try {
            p.getObject().close();
        } catch (Exception ignored) {}
    }

    @Override
    public boolean validateObject(PooledObject<Socket> p) {
        Socket s = p.getObject();
        if (!s.isConnected() || s.isClosed()) return false;
        // Probe with 1ms read — SocketTimeoutException = alive, -1 or IOException = dead
        try {
            s.setSoTimeout(1);
            int b = s.getInputStream().read();
            return b != -1;
        } catch (SocketTimeoutException e) {
            return true;
        } catch (Exception e) {
            return false;
        } finally {
            try { s.setSoTimeout(socketTimeoutMs); } catch (Exception ignored) {}
        }
    }

    @Override
    public void activateObject(PooledObject<Socket> p) {}

    @Override
    public void passivateObject(PooledObject<Socket> p) {}
}

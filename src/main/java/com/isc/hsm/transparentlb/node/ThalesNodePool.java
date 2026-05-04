package com.isc.hsm.transparentlb.node;

import com.isc.hsm.transparentlb.config.LbProperties;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

import java.io.InputStream;
import java.io.OutputStream;
import java.net.Socket;

public class ThalesNodePool {

    private static final Logger log = LoggerFactory.getLogger(ThalesNodePool.class);

    private final ThalesNode node;
    private final LbProperties props;

    public ThalesNodePool(ThalesNode node, LbProperties props) {
        this.node = node;
        this.props = props;
        node.configureCircuitBreaker(
            props.getCircuitBreaker().getFailureThreshold(),
            props.getCircuitBreaker().getResetMs()
        );
    }

    public byte[] send(byte[] rawCommand) throws Exception {
        return send(rawCommand, props.getPool().getSocketTimeoutMs());
    }

    public byte[] send(byte[] rawCommand, int timeoutMs) throws Exception {
        node.incrementActive();
        node.recordRequest();
        long t0 = System.currentTimeMillis();
        try (Socket socket = new Socket()) {
            socket.setSoTimeout(timeoutMs);
            socket.setTcpNoDelay(true);
            socket.connect(
                new java.net.InetSocketAddress(node.getHost(), node.getPort()),
                Math.min(timeoutMs, props.getPool().getConnectTimeoutMs())
            );

            OutputStream out = socket.getOutputStream();
            InputStream in = socket.getInputStream();

            // payShield expects 2-byte big-endian length prefix; eznet strips it before JMS
            int len = rawCommand.length;
            out.write((len >> 8) & 0xFF);
            out.write(len & 0xFF);
            out.write(rawCommand);
            out.flush();

            byte[] response = readResponse(in);

            // Verify payShield echoes request header (first 4 bytes of body = request header).
            // Guards against stale/misrouted HSM responses reaching wrong client.
            if (rawCommand.length >= 4 && response.length >= 4) {
                for (int i = 0; i < 4; i++) {
                    if (response[i] != rawCommand[i]) {
                        throw new Exception(String.format(
                            "HSM node %s response header mismatch at byte %d: req=0x%02X resp=0x%02X",
                            node.getId(), i, rawCommand[i] & 0xFF, response[i] & 0xFF));
                    }
                }
            }

            node.getResponseStats().record(System.currentTimeMillis() - t0, false);
            node.recordSuccess();
            return response;

        } catch (Exception e) {
            node.getResponseStats().record(System.currentTimeMillis() - t0, true);
            node.recordError();
            throw e;
        } finally {
            node.decrementActive();
        }
    }

    private byte[] readResponse(InputStream in) throws Exception {
        // Read 2-byte length header, then body. Return body only —
        // eznet re-adds the 2-byte TCP framing on the way back to the client.
        byte[] lenBuf = new byte[2];
        readFully(in, lenBuf, 2);
        int bodyLen = ((lenBuf[0] & 0xFF) << 8) | (lenBuf[1] & 0xFF);
        if (bodyLen <= 0 || bodyLen > 65535) {
            throw new Exception("Invalid response length from HSM node " + node.getId() + ": " + bodyLen);
        }
        byte[] body = new byte[bodyLen];
        readFully(in, body, bodyLen);
        return body;
    }

    private void readFully(InputStream in, byte[] buf, int len) throws Exception {
        int read = 0;
        while (read < len) {
            int n = in.read(buf, read, len - read);
            if (n < 0) throw new Exception("Connection closed by HSM node " + node.getId());
            read += n;
        }
    }

    public void close() {}

    public ThalesNode getNode() { return node; }

    public int getNumActive() { return node.getActiveConnections(); }

    public int getNumIdle() { return 0; }
}

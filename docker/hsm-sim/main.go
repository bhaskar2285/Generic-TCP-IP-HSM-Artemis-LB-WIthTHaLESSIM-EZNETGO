// Minimal Thales payShield NO command simulator.
// Wire format (matches real payShield):
//   request : [2-byte BE length][N-byte body]
//   body    : [4-byte client header][2-byte cmd][N-6 byte payload]
// Reply for "NO" (and anything we don't recognise we still NP-echo):
//   body    : [4-byte echoed header]"NP""00""311 0000007-E0000001"
//
// One goroutine per accepted connection; loops reading frames until EOF.
// Optional latency injection via SIM_DELAY_MS env var (default 0).

package main

import (
	"bufio"
	"encoding/binary"
	"errors"
	"io"
	"log"
	"net"
	"net/http"
	"os"
	"strconv"
	"sync/atomic"
	"time"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promauto"
	"github.com/prometheus/client_golang/prometheus/promhttp"
)

var (
	listenAddr  = getenv("SIM_LISTEN", ":9000")
	metricsAddr = getenv("SIM_METRICS_LISTEN", ":9100")
	delayMs     = getenvInt("SIM_DELAY_MS", 0)
	idTag       = getenv("SIM_ID", "hsm-sim")
	connCount   atomic.Int64
)

var (
	reqTotal = promauto.NewCounterVec(prometheus.CounterOpts{
		Name: "hsm_sim_requests_total",
		Help: "Total HSM requests handled",
	}, []string{"sim_id"})

	reqDuration = promauto.NewHistogramVec(prometheus.HistogramOpts{
		Name:    "hsm_sim_request_duration_seconds",
		Help:    "HSM request processing duration",
		Buckets: []float64{.001, .005, .01, .025, .05, .1, .25, .5, 1},
	}, []string{"sim_id"})

	activeConns = promauto.NewGaugeVec(prometheus.GaugeOpts{
		Name: "hsm_sim_active_connections",
		Help: "Current active TCP connections",
	}, []string{"sim_id"})
)

// Hard-coded NP body that mimics a real payShield NO reply.
var npTrailer = []byte("NP0031100007-E0000001")

func main() {
	ln, err := net.Listen("tcp", listenAddr)
	if err != nil {
		log.Fatalf("[%s] listen %s: %v", idTag, listenAddr, err)
	}
	log.Printf("[%s] TCP listening on %s, latency=%dms", idTag, listenAddr, delayMs)

	// Start Prometheus metrics HTTP server
	go func() {
		mux := http.NewServeMux()
		mux.Handle("/metrics", promhttp.Handler())
		log.Printf("[%s] metrics listening on %s", idTag, metricsAddr)
		if err := http.ListenAndServe(metricsAddr, mux); err != nil {
			log.Fatalf("[%s] metrics server: %v", idTag, err)
		}
	}()

	go reportStats()

	for {
		c, err := ln.Accept()
		if err != nil {
			log.Printf("[%s] accept: %v", idTag, err)
			continue
		}
		connCount.Add(1)
		activeConns.WithLabelValues(idTag).Inc()
		go handle(c)
	}
}

func handle(c net.Conn) {
	defer func() {
		c.Close()
		connCount.Add(-1)
		activeConns.WithLabelValues(idTag).Dec()
	}()
	_ = c.(*net.TCPConn).SetNoDelay(true)

	r := bufio.NewReaderSize(c, 4096)
	w := bufio.NewWriterSize(c, 4096)
	hdr := make([]byte, 2)

	for {
		if _, err := io.ReadFull(r, hdr); err != nil {
			if !errors.Is(err, io.EOF) && !errors.Is(err, io.ErrUnexpectedEOF) {
				log.Printf("[%s] read hdr: %v", idTag, err)
			}
			return
		}
		n := int(binary.BigEndian.Uint16(hdr))
		if n < 6 || n > 8192 {
			log.Printf("[%s] bad length %d", idTag, n)
			return
		}
		body := make([]byte, n)
		if _, err := io.ReadFull(r, body); err != nil {
			log.Printf("[%s] read body: %v", idTag, err)
			return
		}

		start := time.Now()

		reply := make([]byte, 4+len(npTrailer))
		copy(reply[:4], body[:4])
		copy(reply[4:], npTrailer)

		if delayMs > 0 {
			time.Sleep(time.Duration(delayMs) * time.Millisecond)
		}

		out := make([]byte, 2+len(reply))
		binary.BigEndian.PutUint16(out[:2], uint16(len(reply)))
		copy(out[2:], reply)

		if _, err := w.Write(out); err != nil {
			log.Printf("[%s] write: %v", idTag, err)
			return
		}
		if err := w.Flush(); err != nil {
			log.Printf("[%s] flush: %v", idTag, err)
			return
		}

		reqTotal.WithLabelValues(idTag).Inc()
		reqDuration.WithLabelValues(idTag).Observe(time.Since(start).Seconds())
	}
}

func reportStats() {
	prev := int64(0)
	for range time.Tick(10 * time.Second) {
		conns := connCount.Load()
		log.Printf("[%s] conns=%d", idTag, conns)
		_ = prev
		prev = conns
	}
}

func getenv(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
}

func getenvInt(k string, def int) int {
	if v := os.Getenv(k); v != "" {
		if n, err := strconv.Atoi(v); err == nil {
			return n
		}
	}
	return def
}

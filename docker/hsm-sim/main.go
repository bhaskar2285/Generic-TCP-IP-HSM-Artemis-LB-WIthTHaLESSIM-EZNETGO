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
	"os"
	"strconv"
	"sync/atomic"
	"time"
)

var (
	listenAddr = getenv("SIM_LISTEN", ":9000")
	delayMs    = getenvInt("SIM_DELAY_MS", 0)
	idTag      = getenv("SIM_ID", "hsm-sim")
	connCount  atomic.Uint64
	reqCount   atomic.Uint64
)

// Hard-coded NP body that mimics a real payShield NO reply.
// "NP" + "00" + firmware-version-like trailer. Total reply body = 4 (header) + 22 = 26 bytes.
var npTrailer = []byte("NP0031100007-E0000001")

func main() {
	ln, err := net.Listen("tcp", listenAddr)
	if err != nil {
		log.Fatalf("[%s] listen %s: %v", idTag, listenAddr, err)
	}
	log.Printf("[%s] listening on %s, latency=%dms", idTag, listenAddr, delayMs)

	go reportStats()

	for {
		c, err := ln.Accept()
		if err != nil {
			log.Printf("[%s] accept: %v", idTag, err)
			continue
		}
		connCount.Add(1)
		go handle(c)
	}
}

func handle(c net.Conn) {
	defer c.Close()
	_ = c.(*net.TCPConn).SetNoDelay(true)

	r := bufio.NewReaderSize(c, 4096)
	w := bufio.NewWriterSize(c, 4096)
	hdr := make([]byte, 2)

	for {
		// length prefix
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

		reqCount.Add(1)

		// Reply body: echo client header (4) + NP + 00 + firmware trailer (22 total post-header).
		reply := make([]byte, 4+len(npTrailer))
		copy(reply[:4], body[:4])
		copy(reply[4:], npTrailer)

		if delayMs > 0 {
			time.Sleep(time.Duration(delayMs) * time.Millisecond)
		}

		// length-prefix + reply body
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
	}
}

func reportStats() {
	prev := uint64(0)
	for range time.Tick(10 * time.Second) {
		cur := reqCount.Load()
		log.Printf("[%s] conns=%d total_reqs=%d (+%d in 10s = %.1f rps)",
			idTag, connCount.Load(), cur, cur-prev, float64(cur-prev)/10.0)
		prev = cur
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

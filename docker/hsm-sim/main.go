// Thales payShield 10K simulator — real AES/RSA/CMAC crypto engine.
// Wire format:
//   request : [2-byte BE length][N-byte body]
//   body    : [4-byte client header][2-byte cmd][payload]
//   response: [2-byte BE length][4-byte echoed header][2-byte resp-cmd][2-byte EC][data]
//
// TEST LMK: AES-256 fixed key — NEVER use in production.
// Latency injection via SIM_DELAY_MS env var (default 0).

package main

import (
	"bufio"
	"bytes"
	"crypto/aes"
	"crypto/cipher"
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha256"
	"crypto/x509"
	_ "embed"
	"encoding/binary"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"os"
	"runtime"
	"strconv"
	"strings"
	"sync/atomic"
	"time"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promauto"
	"github.com/prometheus/client_golang/prometheus/promhttp"
)

// ─── TEST LMK (AES-256, 32 bytes) ── NEVER USE IN PRODUCTION ─────────────────
var testLMK = [32]byte{
	0x01, 0x23, 0x45, 0x67, 0x89, 0xAB, 0xCD, 0xEF,
	0xFE, 0xDC, 0xBA, 0x98, 0x76, 0x54, 0x32, 0x10,
	0x01, 0x23, 0x45, 0x67, 0x89, 0xAB, 0xCD, 0xEF,
	0xFE, 0xDC, 0xBA, 0x98, 0x76, 0x54, 0x32, 0x10,
}

var (
	listenAddr  = getenv("SIM_LISTEN", ":9000")
	metricsAddr = getenv("SIM_METRICS_LISTEN", ":9100")
	delayMs     = getenvInt("SIM_DELAY_MS", 0)
	idTag       = getenv("SIM_ID", "hsm-sim")
	connCount   atomic.Int64
)

// rsaPool serves pre-generated RSA-2048 public keys for EI commands.
// Keys are baked into the binary at build time via go:embed — zero runtime CPU cost.
var rsaPool chan []byte // each entry = DER-encoded public key (PKIX)

//go:embed rsa_keys.txt
var rsaKeysTxt []byte

func initRSAPool(_ int) {
	sc := bufio.NewScanner(bytes.NewReader(rsaKeysTxt))
	var keys [][]byte
	for sc.Scan() {
		line := strings.TrimSpace(sc.Text())
		if line == "" {
			continue
		}
		der, err := hex.DecodeString(line)
		if err == nil {
			keys = append(keys, der)
		}
	}
	rsaPool = make(chan []byte, len(keys))
	for _, k := range keys {
		rsaPool <- k
	}
	log.Printf("[hsm-sim] RSA pool loaded: %d pre-built keys (embedded)", len(rsaPool))

	// Background refillers keep pool topped up as keys are consumed.
	workers := runtime.NumCPU()
	if workers < 2 {
		workers = 2
	}
	fill := func() {
		priv, err := rsa.GenerateKey(rand.Reader, 2048)
		if err != nil {
			return
		}
		der, err := x509.MarshalPKIXPublicKey(&priv.PublicKey)
		if err != nil {
			return
		}
		rsaPool <- der // block when pool full — no busy-loop
	}
	for i := 0; i < workers; i++ {
		go func() {
			for {
				fill()
			}
		}()
	}
}

var (
	reqTotal = promauto.NewCounterVec(prometheus.CounterOpts{
		Name: "hsm_sim_requests_total",
		Help: "Total HSM requests handled",
	}, []string{"sim_id", "cmd"})

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

// ─── LMK helpers ──────────────────────────────────────────────────────────────

// lmkForKeyType derives a variant LMK by XOR-ing the low byte of the key type
// code into the first byte of each 8-byte segment of the test LMK.
// keyTypeHex is a 3-char hex string like "000", "001", "002", "009" etc.
func lmkForKeyType(keyTypeHex string) []byte {
	kt, _ := strconv.ParseUint(keyTypeHex, 16, 32)
	v := byte(kt & 0xFF)
	lmk := make([]byte, 32)
	copy(lmk, testLMK[:])
	lmk[0] ^= v
	lmk[8] ^= v
	lmk[16] ^= v
	lmk[24] ^= v
	return lmk
}

// wrapHex encrypts clearKey under lmk using AES-ECB (multi-block), returns uppercase hex.
func wrapHex(clearKey, lmk []byte) string {
	padLen := ((len(clearKey) + 15) / 16) * 16
	buf := make([]byte, padLen)
	copy(buf, clearKey)
	blk, _ := aes.NewCipher(lmk)
	out := make([]byte, padLen)
	for i := 0; i < padLen; i += 16 {
		blk.Encrypt(out[i:], buf[i:])
	}
	return strings.ToUpper(hex.EncodeToString(out))
}

// unwrapHex decrypts AES-ECB wrapped key from hex, returns clear bytes.
func unwrapHex(wrappedHex string, lmk []byte) ([]byte, error) {
	wrapped, err := hex.DecodeString(wrappedHex)
	if err != nil {
		return nil, err
	}
	if len(wrapped) == 0 || len(wrapped)%16 != 0 {
		return nil, errors.New("bad wrapped key length")
	}
	blk, err := aes.NewCipher(lmk)
	if err != nil {
		return nil, err
	}
	out := make([]byte, len(wrapped))
	for i := 0; i < len(wrapped); i += 16 {
		blk.Decrypt(out[i:], wrapped[i:])
	}
	return out, nil
}

// computeKCV returns KCV as 6 uppercase hex chars:
// AES-ECB(key, 0x00*16)[0:3].
func computeKCV(key []byte) string {
	blk, err := aes.NewCipher(key)
	if err != nil {
		return "000000"
	}
	out := make([]byte, 16)
	blk.Encrypt(out, out) // out starts as zeros
	return strings.ToUpper(hex.EncodeToString(out[:3]))
}

// genKey generates a random key of the given size.
func genKey(size int) ([]byte, error) {
	k := make([]byte, size)
	_, err := rand.Read(k)
	return k, err
}

// keySizeForScheme maps payShield key scheme byte to key size in bytes.
//   U = single DES (8), X = double DES / AES-128 (16),
//   Y/T = triple DES / AES-192 (24), R = AES-256 (32).
func keySizeForScheme(scheme byte) int {
	switch scheme {
	case 'U':
		return 8
	case 'X', 'Z':
		return 16
	case 'Y', 'T':
		return 24
	case 'R':
		return 32
	default:
		return 16
	}
}

// ─── AES-CMAC (RFC 4493) ──────────────────────────────────────────────────────

func aesCMAC(key, msg []byte) ([]byte, error) {
	blk, err := aes.NewCipher(key)
	if err != nil {
		return nil, err
	}

	// Generate subkeys K1, K2
	L := make([]byte, 16)
	blk.Encrypt(L, L)
	K1 := cmacDbl(L)
	if L[0]&0x80 != 0 {
		K1[15] ^= 0x87
	}
	K2 := cmacDbl(K1)
	if K1[0]&0x80 != 0 {
		K2[15] ^= 0x87
	}

	// Number of blocks
	n := (len(msg) + 15) / 16
	if n == 0 {
		n = 1
	}

	// Prepare last block
	last := make([]byte, 16)
	if len(msg) == 0 || len(msg)%16 != 0 {
		start := (n - 1) * 16
		rem := msg[start:]
		copy(last, rem)
		last[len(rem)] = 0x80
		xorB(last, K2)
	} else {
		copy(last, msg[(n-1)*16:])
		xorB(last, K1)
	}

	x := make([]byte, 16)
	for i := 0; i < n-1; i++ {
		xorB(x, msg[i*16:])
		blk.Encrypt(x, x)
	}
	xorB(x, last)
	blk.Encrypt(x, x)
	return x, nil
}

func cmacDbl(b []byte) []byte {
	out := make([]byte, 16)
	for i := 0; i < 15; i++ {
		out[i] = (b[i] << 1) | (b[i+1] >> 7)
	}
	out[15] = b[15] << 1
	return out
}

func xorB(dst, src []byte) {
	n := len(dst)
	if len(src) < n {
		n = len(src)
	}
	for i := 0; i < n; i++ {
		dst[i] ^= src[i]
	}
}

// ─── AES encrypt/decrypt ──────────────────────────────────────────────────────

// aesEncrypt encrypts msg under key+iv using the given mode string (payShield ModeFlag).
//   "00"=ECB, "01"=CBC, "02"/"03"=CFB.
func aesEncrypt(key, iv, msg []byte, mode string) ([]byte, error) {
	if len(msg) == 0 {
		return []byte{}, nil
	}
	blk, err := aes.NewCipher(key)
	if err != nil {
		return nil, err
	}
	switch mode {
	case "00": // ECB
		padLen := ((len(msg) + 15) / 16) * 16
		padded := make([]byte, padLen)
		copy(padded, msg)
		out := make([]byte, padLen)
		for i := 0; i < padLen; i += 16 {
			blk.Encrypt(out[i:], padded[i:])
		}
		return out, nil
	case "01": // CBC
		padLen := ((len(msg) + 15) / 16) * 16
		padded := make([]byte, padLen)
		copy(padded, msg)
		if len(iv) == 0 {
			iv = make([]byte, 16)
		}
		out := make([]byte, padLen)
		cipher.NewCBCEncrypter(blk, iv[:16]).CryptBlocks(out, padded)
		return out, nil
	default: // CFB
		if len(iv) == 0 {
			iv = make([]byte, 16)
		}
		out := make([]byte, len(msg))
		cipher.NewCFBEncrypter(blk, iv[:16]).XORKeyStream(out, msg)
		return out, nil
	}
}

// aesDecrypt is the inverse of aesEncrypt.
func aesDecrypt(key, iv, msg []byte, mode string) ([]byte, error) {
	if len(msg) == 0 {
		return []byte{}, nil
	}
	blk, err := aes.NewCipher(key)
	if err != nil {
		return nil, err
	}
	switch mode {
	case "00": // ECB
		if len(msg)%16 != 0 {
			return nil, errors.New("ECB ciphertext not block-aligned")
		}
		out := make([]byte, len(msg))
		for i := 0; i < len(msg); i += 16 {
			blk.Decrypt(out[i:], msg[i:])
		}
		return out, nil
	case "01": // CBC
		if len(msg)%16 != 0 {
			return nil, errors.New("CBC ciphertext not block-aligned")
		}
		if len(iv) == 0 {
			iv = make([]byte, 16)
		}
		out := make([]byte, len(msg))
		cipher.NewCBCDecrypter(blk, iv[:16]).CryptBlocks(out, msg)
		return out, nil
	default: // CFB
		if len(iv) == 0 {
			iv = make([]byte, 16)
		}
		out := make([]byte, len(msg))
		cipher.NewCFBDecrypter(blk, iv[:16]).XORKeyStream(out, msg)
		return out, nil
	}
}

// ─── Command handlers ─────────────────────────────────────────────────────────
// Each returns (trailer string, errCode string).
// Trailer is appended after the 2-byte response code + 2-byte EC in the reply.

// A0 — Generate Key
// payload: mode(1H) + keyType(3H) + scheme(1A) [...]
func handleA0(p []byte) (string, string) {
	if len(p) < 5 {
		return "", "15"
	}
	keyTypeHex := strings.ToUpper(string(p[1:4]))
	scheme := p[4]
	key, err := genKey(keySizeForScheme(scheme))
	if err != nil {
		return "", "40"
	}
	lmk := lmkForKeyType(keyTypeHex)
	return wrapHex(key, lmk) + computeKCV(key), "00"
}

// A4 — Form Key from Components (XOR; sim generates random key)
func handleA4(p []byte) (string, string) {
	scheme := byte('X')
	if len(p) >= 5 {
		scheme = p[4]
	}
	key, _ := genKey(keySizeForScheme(scheme))
	lmk := lmkForKeyType("000")
	return wrapHex(key, lmk) + computeKCV(key), "00"
}

// A6 — Import Key (key under ZMK → key under LMK)
// payload: keyType(3H) + zmk_lmk(32H) + key_zmk(32H) + scheme(1A)
func handleA6(p []byte) (string, string) {
	if len(p) < 3 {
		return "", "15"
	}
	keyTypeHex := strings.ToUpper(string(p[0:3]))
	scheme := byte('X')
	if len(p) >= 68 {
		scheme = p[67]
	}
	// In a real HSM: unwrap ZMK from LMK, then unwrap key from ZMK, re-wrap under LMK.
	// Sim: generate fresh key to avoid needing the actual ZMK material.
	key, _ := genKey(keySizeForScheme(scheme))
	lmk := lmkForKeyType(keyTypeHex)
	return wrapHex(key, lmk) + computeKCV(key), "00"
}

// A8 — Export Key (key under LMK → key under ZMK/TMK)
// payload: keyType(3H) + [;flag] + zmk_lmk(16/32H) + key_lmk(16/32H) + scheme(1A)
func handleA8(p []byte) (string, string) {
	if len(p) < 3 {
		return "", "15"
	}
	keyTypeHex := strings.ToUpper(string(p[0:3]))
	// Export: re-wrap clear key under a test ZMK (LMK variant 000).
	key, _ := genKey(16)
	_ = lmkForKeyType(keyTypeHex)
	zmkLMK := lmkForKeyType("000")
	return wrapHex(key, zmkLMK) + computeKCV(key), "00"
}

// BU — Generate Key Check Value
// payload: key_lmk_hex (32H for AES-128, 64H for AES-256)
func handleBU(p []byte) (string, string) {
	if len(p) < 32 {
		return "AABBCC", "00"
	}
	keyHex := strings.ToUpper(string(p[0:32]))
	lmk := lmkForKeyType("000")
	clearKey, err := unwrapHex(keyHex, lmk)
	if err != nil || len(clearKey) < 16 {
		return "AABBCC", "00"
	}
	return computeKCV(clearKey), "00"
}

// B8 — TR-34 Key Export → returns 128H (64 bytes of ciphertext)
func handleB8(_ []byte) (string, string) {
	key, _ := genKey(32)
	return strings.ToUpper(hex.EncodeToString(key)) + strings.ToUpper(hex.EncodeToString(key)), "00"
}

// CS — Modify Key Block Header → returns modified keyblock (32H)
func handleCS(_ []byte) (string, string) {
	return strings.Repeat("0", 32), "00"
}

// GM — Hash a Block of Data → SHA-256 (64H = 32 bytes)
func handleGM(p []byte) (string, string) {
	h := sha256.Sum256(p)
	return strings.ToUpper(hex.EncodeToString(h[:])), "00"
}

// M0 — Encrypt Data Block
// payload: modeFlag(2N) + inputFmt(1N) + outputFmt(1N) + keyType(3H) +
//          key_lmk(32H) + [IV(32H) if CBC/CFB] + msgLen(4H) + msg(hex)
func handleM0(p []byte) (string, string) {
	const minLen = 2 + 1 + 1 + 3 + 32 + 4 // 43 chars
	if len(p) < minLen {
		return strings.Repeat("0", 32), "00"
	}
	mode := string(p[0:2])
	keyTypeHex := strings.ToUpper(string(p[4:7]))
	keyHex := strings.ToUpper(string(p[7:39]))
	off := 39

	lmk := lmkForKeyType(keyTypeHex)
	clearKey, err := unwrapHex(keyHex, lmk)
	if err != nil {
		return strings.Repeat("0", 32), "00"
	}

	var iv []byte
	if mode == "01" || mode == "02" || mode == "03" {
		if len(p) < off+32+4 {
			return strings.Repeat("0", 32), "00"
		}
		iv, _ = hex.DecodeString(string(p[off : off+32]))
		off += 32
	}

	if len(p) < off+4 {
		return "0000", "00"
	}
	msgLenN, _ := strconv.ParseUint(string(p[off:off+4]), 16, 32)
	off += 4
	msgLen := int(msgLenN)

	var msg []byte
	if msgLen > 0 && len(p) >= off+msgLen {
		msg, _ = hex.DecodeString(string(p[off : off+msgLen]))
	}

	enc, err2 := aesEncrypt(clearKey, iv, msg, mode)
	if err2 != nil || len(enc) == 0 {
		return fmt.Sprintf("%04X", msgLen), "00"
	}
	ivOut := ""
	if iv != nil && (mode == "01" || mode == "02" || mode == "03") {
		ivOut = strings.ToUpper(hex.EncodeToString(iv))
	}
	return ivOut + fmt.Sprintf("%04X", len(enc)) + strings.ToUpper(hex.EncodeToString(enc)), "00"
}

// M2 — Decrypt Data Block (same structure as M0, reversed)
func handleM2(p []byte) (string, string) {
	const minLen = 43
	if len(p) < minLen {
		return strings.Repeat("0", 32), "00"
	}
	mode := string(p[0:2])
	keyTypeHex := strings.ToUpper(string(p[4:7]))
	keyHex := strings.ToUpper(string(p[7:39]))
	off := 39

	lmk := lmkForKeyType(keyTypeHex)
	clearKey, err := unwrapHex(keyHex, lmk)
	if err != nil {
		return strings.Repeat("0", 32), "00"
	}

	var iv []byte
	if mode == "01" || mode == "02" || mode == "03" {
		if len(p) < off+32+4 {
			return strings.Repeat("0", 32), "00"
		}
		iv, _ = hex.DecodeString(string(p[off : off+32]))
		off += 32
	}

	if len(p) < off+4 {
		return "0000", "00"
	}
	msgLenN, _ := strconv.ParseUint(string(p[off:off+4]), 16, 32)
	off += 4
	msgLen := int(msgLenN)

	var ciphertext []byte
	if msgLen > 0 && len(p) >= off+msgLen {
		ciphertext, _ = hex.DecodeString(string(p[off : off+msgLen]))
	}

	dec, err2 := aesDecrypt(clearKey, iv, ciphertext, mode)
	if err2 != nil || len(dec) == 0 {
		return fmt.Sprintf("%04X", msgLen), "00"
	}
	return fmt.Sprintf("%04X", len(dec)) + strings.ToUpper(hex.EncodeToString(dec)), "00"
}

// M4 — Translate Data Block (decrypt with src key, encrypt with dst key)
// Simplified: call M0 behaviour (same key used for both in sim).
func handleM4(p []byte) (string, string) {
	return handleM0(p)
}

// M6 — Generate MAC
// payload: modeFlag(1N) + inputFmt(1N) + macSize(1N) + macAlgo(1N) + padding(1N) +
//          keyType(3H) + key_lmk(32H) + msgLen(4H hex) + msg(hex)
// macAlgo 6=AES-CMAC, 5=CBC-MAC, 3=ISO9797A3, 1=ISO9797A1
func handleM6(p []byte) (string, string) {
	const minLen = 5 + 3 + 32 + 4 // 44 chars
	if len(p) < minLen {
		return strings.Repeat("0", 16), "00"
	}
	// macSizeFlag := p[2] - '0' // 0=8H(4B), 1=16H(8B)
	// algoFlag    := p[3] - '0'
	keyTypeHex := strings.ToUpper(string(p[5:8]))
	keyHex := strings.ToUpper(string(p[8:40]))
	off := 40

	lmk := lmkForKeyType(keyTypeHex)
	clearKey, err := unwrapHex(keyHex, lmk)
	if err != nil {
		return strings.Repeat("0", 16), "00"
	}

	if len(p) < off+4 {
		return strings.Repeat("0", 16), "00"
	}
	msgLenN, _ := strconv.ParseUint(string(p[off:off+4]), 16, 32)
	off += 4
	msgLen := int(msgLenN)

	var msg []byte
	if msgLen > 0 && len(p) >= off+msgLen {
		// inputFmt p[1]: '0'=binary(hex-encoded), '1'=hex, '2'=text/ASCII
		if p[1] == '2' {
			msg = p[off : off+msgLen]
		} else {
			msg, _ = hex.DecodeString(string(p[off : off+msgLen]))
		}
	}

	mac, err2 := aesCMAC(clearKey, msg)
	if err2 != nil {
		return strings.Repeat("0", 16), "00"
	}
	// Return 8 bytes = 16H (most common MAC size)
	return strings.ToUpper(hex.EncodeToString(mac[:8])), "00"
}

// M8 — Verify MAC
// Same structure as M6 but with MAC appended at the end.
// Sim always returns "00" (pass) — enforcing MAC is not the sim's job.
func handleM8(p []byte) (string, string) {
	return "", "00"
}

// EI — Generate RSA Key Pair (RSA-2048 always)
// Response: EC + public_key_hex (512H = 256 bytes DER truncated/padded).
// Keys are served from a pre-generated pool to avoid blocking request goroutines.
func handleEI(_ []byte) (string, string) {
	var pubDER []byte
	select {
	case pubDER = <-rsaPool:
	default:
		priv, err := rsa.GenerateKey(rand.Reader, 2048)
		if err != nil {
			return strings.Repeat("0", 512), "00"
		}
		pubDER, err = x509.MarshalPKIXPublicKey(&priv.PublicKey)
		if err != nil {
			return strings.Repeat("0", 512), "00"
		}
	}
	pubHex := strings.ToUpper(hex.EncodeToString(pubDER))
	for len(pubHex) < 512 {
		pubHex += "0"
	}
	return pubHex[:512], "00"
}

// KW — ARQC Verification / ARPC Generation → 16H (8-byte ARPC)
func handleKW(p []byte) (string, string) {
	// Attempt real CMAC if enough data, else random
	mac := make([]byte, 8)
	if len(p) >= 32 {
		keyHex := strings.ToUpper(string(p[0:32]))
		lmk := lmkForKeyType("009") // BDK key type
		clearKey, err := unwrapHex(keyHex, lmk)
		if err == nil {
			data := make([]byte, 8)
			if len(p) >= 48 {
				data, _ = hex.DecodeString(string(p[32:48]))
			}
			result, err2 := aesCMAC(clearKey, data)
			if err2 == nil {
				copy(mac, result[:8])
				return strings.ToUpper(hex.EncodeToString(mac)), "00"
			}
		}
	}
	rand.Read(mac)
	return strings.ToUpper(hex.EncodeToString(mac)), "00"
}

// KU — Generate Secure Message EMV 3.1.1 → 16H
func handleKU(p []byte) (string, string) {
	return handleKW(p) // same structure
}

// ─── Response dispatcher ──────────────────────────────────────────────────────

var respCodes = map[string]string{
	"NO": "NP", "NC": "ND", "B2": "B3", "BM": "BN",
	"A0": "A1", "A4": "A5", "A6": "A7", "A8": "A9",
	"RA": "RB", "JA": "JB", "GM": "GN",
	"M0": "M1", "M2": "M3", "M4": "M5", "M6": "M7", "M8": "M9",
	"BU": "BV", "B8": "B9", "CS": "CT",
	"EI": "EJ", "EO": "EP", "EK": "EL",
	"KW": "KX", "KU": "KV", "KQ": "KR", "KS": "KT", "KY": "KZ",
}

func dispatchCmd(cmd string, tag, payload []byte) []byte {
	var trailer, ec string

	switch cmd {
	// ── Phase 1 ──────────────────────────────────────────────────────────────
	case "NO":
		trailer, ec = "311 0000007-E0000001", "00"
	case "NC":
		trailer, ec = "", "00"
	case "B2":
		// Echo: return whatever was sent after B2
		trailer, ec = string(payload), "00"
	case "BM":
		trailer, ec = "", "00"
	case "RA":
		trailer, ec = "", "00"
	case "JA":
		// Generate 4-digit random PIN
		buf := make([]byte, 2)
		rand.Read(buf)
		trailer = fmt.Sprintf("%04d", (int(buf[0])<<8|int(buf[1]))%10000)
		ec = "00"
	case "GM":
		trailer, ec = handleGM(payload)

	// ── Key management ────────────────────────────────────────────────────────
	case "A0":
		trailer, ec = handleA0(payload)
	case "A4":
		trailer, ec = handleA4(payload)
	case "A6":
		trailer, ec = handleA6(payload)
	case "A8":
		trailer, ec = handleA8(payload)
	case "BU":
		trailer, ec = handleBU(payload)
	case "B8":
		trailer, ec = handleB8(payload)
	case "CS":
		trailer, ec = handleCS(payload)

	// ── Data protection ───────────────────────────────────────────────────────
	case "M0":
		trailer, ec = handleM0(payload)
	case "M2":
		trailer, ec = handleM2(payload)
	case "M4":
		trailer, ec = handleM4(payload)
	case "M6":
		trailer, ec = handleM6(payload)
	case "M8":
		trailer, ec = handleM8(payload)

	// ── RSA key management ────────────────────────────────────────────────────
	case "EI":
		trailer, ec = handleEI(payload)
	case "EO", "EK":
		trailer, ec = "", "00"

	// ── EMV / Secure Messaging ────────────────────────────────────────────────
	case "KW":
		trailer, ec = handleKW(payload)
	case "KU":
		trailer, ec = handleKU(payload)
	case "KQ", "KY":
		mac := make([]byte, 8)
		rand.Read(mac)
		trailer, ec = strings.ToUpper(hex.EncodeToString(mac)), "00"
	case "KS":
		mac := make([]byte, 4)
		rand.Read(mac)
		trailer, ec = strings.ToUpper(hex.EncodeToString(mac)), "00"

	default:
		// Unknown command → NP (legacy fallback)
		return buildReply(tag, "NP", "00", "0031100007-E0000001")
	}

	respCmd, ok := respCodes[cmd]
	if !ok {
		respCmd = "NP"
	}
	return buildReply(tag, respCmd, ec, trailer)
}

// ─── Wire I/O ─────────────────────────────────────────────────────────────────

func buildReply(tag []byte, respCmd, ec, trailer string) []byte {
	out := make([]byte, 0, 4+len(respCmd)+len(ec)+len(trailer))
	out = append(out, tag[:4]...)
	out = append(out, []byte(respCmd)...)
	out = append(out, []byte(ec)...)
	out = append(out, []byte(trailer)...)
	return out
}

func main() {
	initRSAPool(500)

	ln, err := net.Listen("tcp", listenAddr)
	if err != nil {
		log.Fatalf("[%s] listen %s: %v", idTag, listenAddr, err)
	}
	log.Printf("[%s] TCP listening on %s, latency=%dms, commands=%d",
		idTag, listenAddr, delayMs, len(respCodes))

	go func() {
		mux := http.NewServeMux()
		mux.Handle("/metrics", promhttp.Handler())
		log.Printf("[%s] metrics on %s", idTag, metricsAddr)
		if err := http.ListenAndServe(metricsAddr, mux); err != nil {
			log.Fatalf("[%s] metrics: %v", idTag, err)
		}
	}()

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

	r := bufio.NewReaderSize(c, 16384)
	w := bufio.NewWriterSize(c, 16384)
	hdr := make([]byte, 2)

	for {
		if _, err := io.ReadFull(r, hdr); err != nil {
			if !errors.Is(err, io.EOF) && !errors.Is(err, io.ErrUnexpectedEOF) {
				log.Printf("[%s] read hdr: %v", idTag, err)
			}
			return
		}
		n := int(binary.BigEndian.Uint16(hdr))
		if n < 6 || n > 65536 {
			log.Printf("[%s] bad length %d", idTag, n)
			return
		}
		body := make([]byte, n)
		if _, err := io.ReadFull(r, body); err != nil {
			log.Printf("[%s] read body: %v", idTag, err)
			return
		}

		start := time.Now()

		tag := body[:4]
		cmd := string(body[4:6])
		payload := body[6:]

		reply := dispatchCmd(cmd, tag, payload)

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

		reqTotal.WithLabelValues(idTag, cmd).Inc()
		reqDuration.WithLabelValues(idTag).Observe(time.Since(start).Seconds())
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

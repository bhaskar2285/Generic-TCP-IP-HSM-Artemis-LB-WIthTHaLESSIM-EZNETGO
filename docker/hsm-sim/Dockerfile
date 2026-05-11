FROM golang:1.23-alpine AS keygen
WORKDIR /keys
RUN cat > keygen.go << 'EOF'
package main

import (
	"crypto/rand"
	"crypto/rsa"
	"crypto/x509"
	"encoding/hex"
	"fmt"
	"os"
	"runtime"
	"sync"
)

func main() {
	n := 500
	workers := runtime.NumCPU()
	keys := make([][]byte, n)
	var mu sync.Mutex
	var wg sync.WaitGroup
	sem := make(chan struct{}, workers)
	for i := 0; i < n; i++ {
		idx := i
		sem <- struct{}{}
		wg.Add(1)
		go func() {
			defer wg.Done()
			defer func() { <-sem }()
			priv, _ := rsa.GenerateKey(rand.Reader, 2048)
			der, _ := x509.MarshalPKIXPublicKey(&priv.PublicKey)
			mu.Lock()
			keys[idx] = der
			mu.Unlock()
		}()
	}
	wg.Wait()
	f, _ := os.Create("rsa_keys.txt")
	defer f.Close()
	for _, k := range keys {
		fmt.Fprintln(f, hex.EncodeToString(k))
	}
}
EOF
RUN go run keygen.go

FROM golang:1.23-alpine AS build
WORKDIR /src
COPY main.go ./
COPY --from=keygen /keys/rsa_keys.txt ./
RUN go mod init hsm-sim && \
    go get github.com/prometheus/client_golang/prometheus@v1.19.1 && \
    go get github.com/prometheus/client_golang/prometheus/promauto@v1.19.1 && \
    go get github.com/prometheus/client_golang/prometheus/promhttp@v1.19.1 && \
    CGO_ENABLED=0 go build -ldflags="-s -w" -o /out/hsm-sim main.go

FROM alpine:3.20
COPY --from=build /out/hsm-sim /usr/local/bin/hsm-sim
EXPOSE 9000 9100
ENTRYPOINT ["/usr/local/bin/hsm-sim"]

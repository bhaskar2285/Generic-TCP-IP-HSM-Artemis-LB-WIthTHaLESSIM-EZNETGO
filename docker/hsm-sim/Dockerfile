FROM golang:1.23-alpine AS build
WORKDIR /src
COPY main.go ./
RUN go mod init hsm-sim && CGO_ENABLED=0 go build -ldflags="-s -w" -o /out/hsm-sim main.go

FROM alpine:3.20
COPY --from=build /out/hsm-sim /usr/local/bin/hsm-sim
EXPOSE 9000
ENTRYPOINT ["/usr/local/bin/hsm-sim"]

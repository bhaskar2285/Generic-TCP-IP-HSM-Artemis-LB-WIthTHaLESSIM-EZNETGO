#!/bin/bash
set -e
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

echo "==> Copying artifacts..."
cp "$PROJECT_DIR/target/thales-transparent-lb.jar" "$SCRIPT_DIR/lb/thales-transparent-lb.jar"
cp /data1/xenticate/hsm-lb/bin/eznet-tcp2jms.war "$SCRIPT_DIR/eznet/eznet-tcp2jms.war"

echo "==> Building images..."
docker compose -f "$SCRIPT_DIR/docker-compose.yml" build

echo "==> Done. Start with: docker compose -f docker/docker-compose.yml up -d"

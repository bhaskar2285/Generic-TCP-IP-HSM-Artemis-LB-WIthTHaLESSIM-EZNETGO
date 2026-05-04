#!/bin/bash
# Deploy script for Thales Transparent Load Balancer
# Run from project root after: mvn clean package -DskipTests
#
# Usage:
#   bash deploy/deploy.sh
# Requires sudo access. You will be prompted for your password if needed.

set -e

BIN_DIR=/data1/xenticate/hsm-lb/bin
CONFIG_DIR=/data1/xenticate/hsm-lb/config
EZNET_DIR=/data1/xenticate/hsm-lb/eznet-inbound
LOG_DIR=/var/log/xenticate
SUPERVISOR_CONF=/etc/supervisor/conf.d/thales-lb.conf
EZNET_WAR=/home/xenticate/bank_deploy/bin/eznet/eznet-tcp2jms.war

echo "=== Thales Transparent LB Deploy ==="

echo "Creating directories..."
sudo mkdir -p "$BIN_DIR" "$CONFIG_DIR" "$EZNET_DIR/config" "$EZNET_DIR/tmp" "$LOG_DIR"

echo "Copying LB jar..."
sudo cp target/thales-transparent-lb.jar "$BIN_DIR/"

echo "Copying EzNet war..."
sudo cp "$EZNET_WAR" "$BIN_DIR/"

echo "Copying configs..."
sudo cp deploy/eznet-inbound/config/application.properties "$EZNET_DIR/config/"
sudo cp src/main/resources/application.properties "$CONFIG_DIR/"
sudo cp deploy/config/logback.xml "$CONFIG_DIR/"

echo "Copying supervisor conf..."
sudo cp deploy/supervisor/thales-lb.conf "$SUPERVISOR_CONF"

echo "Setting ownership..."
sudo chown -R xenticate:xenticate /data1/xenticate/hsm-lb

echo "Reloading supervisord..."
sudo supervisorctl reread
sudo supervisorctl update

echo ""
echo "=== Deploy complete ==="
sudo supervisorctl status thales-lb-inbound thales-lb

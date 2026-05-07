#!/bin/bash
set -e
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
JAR="$SCRIPT_DIR/jmx_prometheus_javaagent-1.0.1.jar"

if [ -f "$JAR" ]; then
  echo "==> JMX agent jar already present, skipping download"
  exit 0
fi

echo "==> Downloading jmx_prometheus_javaagent-1.0.1.jar..."
curl -fL -o "$JAR" \
  "https://repo1.maven.org/maven2/io/prometheus/jmx/jmx_prometheus_javaagent/1.0.1/jmx_prometheus_javaagent-1.0.1.jar"
echo "==> Downloaded: $JAR"

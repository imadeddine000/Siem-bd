#!/bin/bash

echo "==================================="
echo "Stopping SIEM Stack"
echo "==================================="

# Stop background processes
echo "[1/3] Stopping background processes..."
pkill -f "python3.*consumer.py"
pkill -f "fluent-bit"
pkill -f "node"

# Stop containers
echo "[2/3] Stopping containers..."
podman-compose down

# Final check
echo "[3/3] Final check..."
sleep 2

REMAINING=$(pgrep -f "consumer.py|fluent-bit|node")
if [ -z "$REMAINING" ]; then
    echo "✓ All processes stopped"
else
    echo "⚠ Force killing remaining processes..."
    pkill -9 -f "consumer.py|fluent-bit|node"
fi

echo "==================================="
echo "SIEM stack stopped"
echo "==================================="
#!/bin/bash

echo "Stopping all services..."

# Stop Python script using PID file
if [ -f /tmp/python_script.pid ]; then
    PID=$(cat /tmp/python_script.pid)
    kill $PID 2>/dev/null || pkill -f "python3 /root/siem/consumer.py"
    rm /tmp/python_script.pid
    echo "Python script stopped"
else
    pkill -f "python3 /root/siem/consumer.py"
    echo "Python script stopped (found by process name)"
fi

# Stop Fluent Bit using PID file
if [ -f /tmp/fluent_bit.pid ]; then
    PID=$(cat /tmp/fluent_bit.pid)
    kill $PID 2>/dev/null || pkill -f "fluent-bit"
    rm /tmp/fluent_bit.pid
    echo "Fluent Bit stopped"
else
    pkill -f "fluent-bit"
    echo "Fluent Bit stopped (found by process name)"
fi

# Stop Podman containers with timeout and force if needed
echo "Stopping Podman containers..."

for container in kibana kafka elasticsearch; do
    if podman ps -q -f name=$container | grep -q .; then
        echo "Stopping $container..."
        podman stop -t 10 $container || podman kill $container
        echo "$container stopped"
    else
        echo "$container is not running"
    fi
done

# Verify all processes are stopped
sleep 2

# Check if any processes are still running
if pgrep -f "python3 /root/siem/consumer.py" > /dev/null; then
    echo "Warning: Python script still running, forcing kill..."
    pkill -9 -f "python3 /root/siem/consumer.py"
fi

if pgrep -f "fluent-bit" > /dev/null; then
    echo "Warning: Fluent Bit still running, forcing kill..."
    pkill -9 -f "fluent-bit"
fi

echo "All services stopped successfully"

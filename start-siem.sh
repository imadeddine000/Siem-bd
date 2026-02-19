#!/bin/bash

echo "==================================="
echo "Starting SIEM Stack"
echo "==================================="

# Start containers with podman-compose
echo "[1/5] Starting Elasticsearch, Kibana, and Kafka..."
podman-compose up -d

if [ $? -ne 0 ]; then
    echo "ERROR: Failed to start containers"
    exit 1
fi

echo "Waiting for services to be ready..."
sleep 15

# Check Elasticsearch
echo "[2/5] Checking Elasticsearch..."
if curl -s http://localhost:9200 >/dev/null 2>&1; then
    echo "✓ Elasticsearch is ready"
else
    echo "⚠ Elasticsearch not ready yet"
fi

# Check Kibana
echo "[3/5] Checking Kibana..."
if curl -s http://localhost:5601 >/dev/null 2>&1; then
    echo "✓ Kibana is ready"
else
    echo "⚠ Kibana not ready yet"
fi

# Check Kafka and create topic
echo "[4/5] Checking Kafka..."
if podman exec kafka /opt/kafka/bin/kafka-topics.sh --bootstrap-server localhost:9092 --list >/dev/null 2>&1; then
    echo "✓ Kafka is ready"
    
    # Create Kafka topic
    echo "Creating Kafka topic 'logs.raw'..."
    podman exec kafka /opt/kafka/bin/kafka-topics.sh \
        --bootstrap-server localhost:9092 \
        --create \
        --topic logs.raw \
        --partitions 1 \
        --replication-factor 1 2>/dev/null || echo "Topic 'logs.raw' already exists"
else
    echo "⚠ Kafka not ready yet"
fi

# Start Python consumer
echo "[5/5] Starting Python consumer..."
ES_HOST=localhost \
KAFKA_BROKER=localhost:9092 \
nohup python3 /root/siem/consumer.py > /root/siem/python_output.log 2>&1 &

CONSUMER_PID=$!
echo "✓ Python consumer started (PID: $CONSUMER_PID)"

# Start Fluent Bit
echo "Starting Fluent Bit..."
nohup /opt/fluent-bit/bin/fluent-bit -c /root/siem/receiver.conf > /root/siem/fluent_output.log 2>&1 &

FLUENT_PID=$!
echo "✓ Fluent Bit started (PID: $FLUENT_PID)"

# Start Node.js app (if exists)
if [ -f "/root/siem/package.json" ]; then
    echo "Starting Node.js app..."
    cd /root/siem
    if [ ! -d "node_modules" ]; then
        npm install
    fi
    nohup npm start > /root/siem/node_output.log 2>&1 &
    NODE_PID=$!
    echo "✓ Node.js app started (PID: $NODE_PID)"
fi

# Optional: Start Spark if you want it
echo ""
echo "==================================="
echo "To start Spark (optional), run:"
echo "podman-compose --profile spark up -d spark"
echo "==================================="

# Final status
echo ""
echo "==================================="
echo "Final Status:"
echo "==================================="
podman-compose ps

echo ""
echo "Services:"
echo "Elasticsearch: http://localhost:9200"
echo "Kibana:        http://localhost:5601"
echo "Kafka:         localhost:9092"
echo ""
echo "Processes:"
ps aux | grep -E "consumer.py|fluent-bit|node" | grep -v grep

echo ""
echo "Logs:"
echo "Python consumer: tail -f /root/siem/python_output.log"
echo "Fluent Bit:      tail -f /root/siem/fluent_output.log"
echo "Containers:      podman-compose logs -f"

echo "==================================="
echo "SIEM stack started successfully!"
echo "==================================="
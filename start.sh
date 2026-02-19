#!/bin/bash
set -e

# =========================
# Helper: Check if a container exists
# =========================
function ensure_container() {
    local name=$1
    if podman ps -a --format "{{.Names}}" | grep -q "^$name$"; then
        echo "Container $name exists, restarting..."
        podman restart $name
    else
        echo "Container $name does not exist, will create."
    fi
}

# =========================
# Start Elasticsearch
# =========================
ensure_container elasticsearch
if ! podman ps --format "{{.Names}}" | grep -q "^elasticsearch$"; then
    podman run -d \
        --name elasticsearch \
        -p 9200:9200 \
        -p 9300:9300 \
        -e "discovery.type=single-node" \
        -e "xpack.security.enabled=true" \
        -e "xpack.security.authc.api_key.enabled=true" \
        -e "ELASTIC_PASSWORD=admin123" \
        docker.io/library/elasticsearch:8.11.0
fi
echo "Waiting 20 seconds for Elasticsearch to be ready..."
sleep 20

# =========================
# Start Kibana
# =========================
ensure_container kibana
if ! podman ps --format "{{.Names}}" | grep -q "^kibana$"; then
    podman run -d \
        --name kibana \
        -p 5601:5601 \
        -e "ELASTICSEARCH_HOSTS=http://10.88.0.11:9200" \
        -e "ELASTICSEARCH_USERNAME=kibana_system" \
        -e "ELASTICSEARCH_PASSWORD=admin123" \
        -e "XPACK_SECURITY_ENABLED=true" \
        docker.io/library/kibana:8.11.0
fi
echo "Waiting 10 seconds for Kibana..."
sleep 10

# =========================
# Start Kafka
# =========================
ensure_container kafka
if ! podman ps --format "{{.Names}}" | grep -q "^kafka$"; then
    podman run -d \
        --name kafka \
        -p 9092:9092 \
        -e KAFKA_NODE_ID=1 \
        -e KAFKA_PROCESS_ROLES=broker,controller \
        -e KAFKA_LISTENERS=PLAINTEXT://0.0.0.0:9092,CONTROLLER://0.0.0.0:9093 \
        -e KAFKA_ADVERTISED_LISTENERS=PLAINTEXT://127.0.0.1:9092 \
        -e KAFKA_CONTROLLER_LISTENER_NAMES=CONTROLLER \
        -e KAFKA_LISTENER_SECURITY_PROTOCOL_MAP=PLAINTEXT:PLAINTEXT,CONTROLLER:PLAINTEXT \
        -e KAFKA_CONTROLLER_QUORUM_VOTERS=1@127.0.0.1:9093 \
        -e KAFKA_OFFSETS_TOPIC_REPLICATION_FACTOR=1 \
        -e KAFKA_TRANSACTION_STATE_LOG_REPLICATION_FACTOR=1 \
        -e KAFKA_TRANSACTION_STATE_LOG_MIN_ISR=1 \
        docker.io/apache/kafka:4.1.1
fi
echo "Waiting 10 seconds for Kafka..."
sleep 10

# =========================
# Start Node.js Web Server
# =========================
echo "Starting Node.js web server..."
cd /root/siem
npm start &

# =========================
# Start Kafka Consumer
# =========================
echo "Starting Python Kafka consumer..."
nohup python3 /root/siem/consumer.py &

# =========================
# Start Fluent Bit Receiver
# =========================
echo "Starting Fluent Bit receiver..."
sudo /opt/fluent-bit/bin/fluent-bit -c /root/siem/receiver.conf &

echo "All services started!"


from kafka import KafkaConsumer
from elasticsearch import Elasticsearch
import json
import os
import time
import logging

# Set up logging
logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(levelname)s - %(message)s')

# Get configuration from environment variables (with fallbacks)
ES_HOST = os.getenv('ES_HOST', 'localhost')
ES_PORT = os.getenv('ES_PORT', 9200)
ES_INDEX = os.getenv('ES_INDEX', 'logs')
ES_USER = os.getenv('ES_USER', 'elastic')
ES_PASSWORD = os.getenv('ES_PASSWORD', 'admin123')
KAFKA_BROKER = os.getenv('KAFKA_BROKER', 'localhost:9092')
KAFKA_TOPIC = os.getenv('KAFKA_TOPIC', 'logs.raw')

print(f"Connecting to Kafka at: {KAFKA_BROKER}")
print(f"Connecting to Elasticsearch at: {ES_HOST}:{ES_PORT}")

# Connect to Elasticsearch
es = Elasticsearch(
    f"http://{ES_HOST}:{ES_PORT}",
    request_timeout=30,
    max_retries=3,
    retry_on_timeout=True,
    verify_certs=False
)

if not es.ping():
    print("Could not connect to Elasticsearch")
    exit(1)
else:
    print("Connected to Elasticsearch successfully")

# Connect to Kafka with retry logic
max_retries = 5
retry_count = 0
consumer = None

while retry_count < max_retries:
    try:
        consumer = KafkaConsumer(
            KAFKA_TOPIC,
            bootstrap_servers=[KAFKA_BROKER],
            auto_offset_reset='earliest',
            group_id='siem-consumer-group',
            value_deserializer=lambda x: x.decode('utf-8'),
            # REMOVED consumer_timeout_ms - this was causing the exit!
            # consumer_timeout_ms=10000,  # REMOVE THIS LINE
            session_timeout_ms=30000,
            heartbeat_interval_ms=10000,
            retry_backoff_ms=1000,
            metadata_max_age_ms=300000,
            max_poll_records=100,
            enable_auto_commit=True,
            auto_commit_interval_ms=5000
        )
        print("Connected to Kafka successfully")
        break
    except Exception as e:
        retry_count += 1
        print(f"Failed to connect to Kafka (attempt {retry_count}/{max_retries}): {e}")
        if retry_count < max_retries:
            print("Retrying in 5 seconds...")
            time.sleep(5)
        else:
            print("Max retries reached. Exiting.")
            exit(1)

print(f"Started consuming from Kafka topic '{KAFKA_TOPIC}' and sending to Elasticsearch...")
print("Consumer will run indefinitely. Press Ctrl+C to stop.")

# Main consumption loop - runs forever
try:
    for message in consumer:
        try:
            # Try to parse as JSON
            data = json.loads(message.value)
        except json.JSONDecodeError:
            # If not JSON, store as plain message
            data = {
                "message": message.value,
                "topic": message.topic,
                "partition": message.partition,
                "offset": message.offset
            }

        # Add timestamp
        data['@timestamp'] = data.get('@timestamp', time.strftime('%Y-%m-%dT%H:%M:%S.%fZ'))

        # Index into Elasticsearch
        try:
            response = es.index(index=ES_INDEX, document=data)
            print(f"✓ Indexed message from partition {message.partition} at offset {message.offset}")
        except Exception as e:
            print(f"✗ Failed to index to Elasticsearch: {e}")

except KeyboardInterrupt:
    print("\nShutting down consumer...")
except Exception as e:
    print(f"Unexpected error: {e}")
    print("Consumer will restart in 5 seconds...")
    time.sleep(5)
finally:
    if consumer:
        consumer.close()
        print("Consumer closed.")

# Keep-alive loop (just in case)
print("Entering keep-alive mode...")
try:
    while True:
        time.sleep(60)
        print(f"[{time.strftime('%Y-%m-%d %H:%M:%S')}] Consumer alive and waiting...")
except KeyboardInterrupt:
    print("Shutdown complete.")

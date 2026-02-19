version: '3.8'

networks:
  siem-network:
    name: siem-network
    driver: bridge

volumes:
  spark-iceberg:
  spark-checkpoints:

services:
  # ============================================
  # Elasticsearch - Data Storage
  # ============================================
  elasticsearch:
    image: docker.io/library/elasticsearch:8.11.0
    container_name: elasticsearch
    networks:
      - siem-network
    ports:
      - "9200:9200"
    environment:
      - discovery.type=single-node
      - xpack.security.enabled=false
      - xpack.security.enrollment.enabled=false
      - xpack.security.transport.ssl.enabled=false
      - xpack.security.http.ssl.enabled=false
      - ES_JAVA_OPTS=-Xms512m -Xmx512m
    restart: unless-stopped
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:9200"]
      interval: 30s
      timeout: 10s
      retries: 5

  # ============================================
  # Kibana - Visualization
  # ============================================
  kibana:
    image: docker.io/library/kibana:8.11.0
    container_name: kibana
    networks:
      - siem-network
    ports:
      - "5601:5601"
    environment:
      - ELASTICSEARCH_HOSTS=http://elasticsearch:9200
      - SERVER_NAME=kibana
    depends_on:
      elasticsearch:
        condition: service_healthy
    restart: unless-stopped

  # ============================================
  # Kafka - Message Broker
  # ============================================
  kafka:
    image: docker.io/apache/kafka:4.1.1
    container_name: kafka
    networks:
      - siem-network
    ports:
      - "9092:9092"
    environment:
      - KAFKA_PROCESS_ROLES=broker,controller
      - KAFKA_NODE_ID=1
      - KAFKA_CONTROLLER_QUORUM_VOTERS=1@localhost:9093
      - KAFKA_LISTENERS=PLAINTEXT://0.0.0.0:9092,CONTROLLER://0.0.0.0:9093
      - KAFKA_ADVERTISED_LISTENERS=PLAINTEXT://localhost:9092,PLAINTEXT://kafka:9092
      - KAFKA_LISTENER_SECURITY_PROTOCOL_MAP=PLAINTEXT:PLAINTEXT,CONTROLLER:PLAINTEXT
      - KAFKA_OFFSETS_TOPIC_REPLICATION_FACTOR=1
      - KAFKA_CONTROLLER_LISTENER_NAMES=CONTROLLER
    restart: unless-stopped
    healthcheck:
      test: ["CMD", "/opt/kafka/bin/kafka-topics.sh", "--bootstrap-server", "localhost:9092", "--list"]
      interval: 30s
      timeout: 10s
      retries: 5

  # ============================================
  # Spark Master
  # ============================================
  spark-master:
    image: docker.io/bitnami/spark:3.5.1
    container_name: spark-master
    networks:
      - siem-network
    ports:
      - "8080:8080"  # Spark Web UI
      - "7077:7077"  # Spark Master port
    environment:
      - SPARK_MODE=master
      - SPARK_RPC_AUTHENTICATION_ENABLED=no
      - SPARK_RPC_ENCRYPTION_ENABLED=no
      - SPARK_LOCAL_STORAGE_ENCRYPTION_ENABLED=no
      - SPARK_SSL_ENABLED=no
    volumes:
      - /root/siem/spark-apps:/opt/spark-apps  # Your Spark scripts
      - spark-checkpoints:/tmp/checkpoints     # Checkpoint storage
    restart: unless-stopped
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:8080"]
      interval: 30s
      timeout: 10s
      retries: 3

  # ============================================
  # Spark Worker (can scale multiple workers)
  # ============================================
  spark-worker:
    image: docker.io/bitnami/spark:3.5.1
    container_name: spark-worker
    networks:
      - siem-network
    ports:
      - "8081:8081"  # Spark Worker Web UI
    environment:
      - SPARK_MODE=worker
      - SPARK_MASTER_URL=spark://spark-master:7077
      - SPARK_WORKER_MEMORY=2G
      - SPARK_WORKER_CORES=2
      - SPARK_RPC_AUTHENTICATION_ENABLED=no
      - SPARK_RPC_ENCRYPTION_ENABLED=no
      - SPARK_LOCAL_STORAGE_ENCRYPTION_ENABLED=no
      - SPARK_SSL_ENABLED=no
    volumes:
      - /root/siem/spark-apps:/opt/spark-apps
      - spark-checkpoints:/tmp/checkpoints
    depends_on:
      spark-master:
        condition: service_healthy
    restart: unless-stopped

  # ============================================
  # Spark Job Launcher (runs the streaming job)
  # ============================================
  spark-job:
    image: docker.io/bitnami/spark:3.5.1
    container_name: spark-job
    networks:
      - siem-network
    depends_on:
      kafka:
        condition: service_healthy
      elasticsearch:
        condition: service_healthy
      spark-master:
        condition: service_healthy
    volumes:
      - /root/siem/spark-apps:/opt/spark-apps
      - spark-checkpoints:/tmp/checkpoints
    command: >
      /bin/bash -c "
        echo 'Waiting for Kafka and Elasticsearch...' &&
        sleep 20 &&
        echo 'Creating Kafka topic if needed...' &&
        /opt/bitnami/kafka/bin/kafka-topics.sh --bootstrap-server kafka:9092 --create --topic logs.raw --partitions 3 --replication-factor 1 || true &&
        echo 'Submitting Spark job...' &&
        spark-submit \
          --master spark://spark-master:7077 \
          --deploy-mode client \
          --packages org.apache.spark:spark-sql-kafka-0-10_2.12:3.5.1,org.elasticsearch:elasticsearch-spark-30_2.12:8.11.0 \
          --conf spark.sql.shuffle.partitions=3 \
          --conf spark.es.nodes=elasticsearch \
          --conf spark.es.port=9200 \
          --conf spark.es.nodes.wan.only=true \
          --conf spark.sql.streaming.checkpointLocation=/tmp/checkpoints \
          --driver-memory 1G \
          --executor-memory 1G \
          /opt/spark-apps/spark_streaming.py
      "
    restart: "no"  # Don't restart, let it complete/restart on failure

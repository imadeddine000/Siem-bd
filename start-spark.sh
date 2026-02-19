#!/bin/bash

echo "Submitting Spark Streaming job..."

podman exec spark-master spark-submit \
  --master spark://spark-master:7077 \
  --packages org.apache.spark:spark-sql-kafka-0-10_2.12:3.5.1,org.elasticsearch:elasticsearch-spark-30_2.12:8.11.0 \
  --driver-memory 1G \
  --executor-memory 1G \
  /opt/spark-apps/kafka_to_es.py

echo "Spark job submitted"

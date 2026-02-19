from pyspark.sql import SparkSession
from pyspark.sql.functions import *
from pyspark.sql.types import *
from pyspark.sql.window import Window

# ============================================
# Create Spark session
# ============================================
spark = SparkSession.builder \
    .appName("SIEM Threat Detection") \
    .config("spark.sql.streaming.schemaInference", "true") \
    .getOrCreate()

spark.sparkContext.setLogLevel("WARN")

# ============================================
# Define schema for agent data
# ============================================
schema = StructType([
    StructField("type",           StringType(), True),
    StructField("agent_ip",       StringType(), True),
    StructField("timestamp",      StringType(), True),
    StructField("user",           StringType(), True),
    StructField("source_ip",      StringType(), True),
    StructField("command",        StringType(), True),
    StructField("remote_address", StringType(), True),
    StructField("local_address",  StringType(), True),
    StructField("cpu_p",          FloatType(),  True),
    StructField("mem_p",          FloatType(),  True)
])

print("🔄 Reading from Kafka...")

# ============================================
# Read from Kafka  (internal listener kafka:29092)
# ============================================
df = spark.readStream \
    .format("kafka") \
    .option("kafka.bootstrap.servers", "kafka:29092") \
    .option("subscribe", "logs.raw") \
    .option("startingOffsets", "latest") \
    .load()

# Parse JSON
parsed = df.selectExpr("CAST(value AS STRING) as json") \
    .select(from_json("json", schema).alias("data")) \
    .select("data.*") \
    .withColumn("event_time", to_timestamp("timestamp", "yyyy-MM-dd'T'HH:mm:ss'Z'"))

# Filter out nulls
parsed = parsed.filter(col("type").isNotNull())

print("🚀 Starting threat detection queries...")

# ============================================
# DETECTION 1: Brute Force (5+ failures in 5 min)
# ============================================
brute_force = parsed \
    .filter(col("type") == "auth_failure") \
    .withWatermark("event_time", "10 minutes") \
    .groupBy(
        window(col("event_time"), "5 minutes"),
        col("source_ip")
    ) \
    .agg(
        count("*").alias("failures"),
        collect_list("user").alias("users_attempted")
    ) \
    .filter(col("failures") >= 5) \
    .select(
        lit("BRUTE_FORCE").alias("alert_type"),
        col("source_ip"),
        col("failures"),
        col("users_attempted"),
        current_timestamp().alias("alert_time")
    )

# ============================================
# DETECTION 2: Privilege Escalation (sudo after auth)
# FIX: Added watermarks on both sides before stream-stream join
# ============================================
auth_success = parsed \
    .filter(col("type") == "auth_success") \
    .withWatermark("event_time", "10 minutes") \
    .select(
        col("agent_ip"),
        col("user"),
        col("source_ip"),
        col("event_time").alias("login_time")
    )

sudo_events = parsed \
    .filter(col("type") == "sudo_command") \
    .withWatermark("event_time", "10 minutes") \
    .select(
        col("agent_ip"),
        col("user"),
        col("command"),
        col("event_time").alias("sudo_time")
    )

privilege_escalation = auth_success.alias("auth") \
    .join(
        sudo_events.alias("sudo"),
        (col("auth.agent_ip") == col("sudo.agent_ip")) &
        (col("auth.user") == col("sudo.user")) &
        (col("sudo.sudo_time") > col("auth.login_time")) &
        (col("sudo.sudo_time") < col("auth.login_time") + expr("INTERVAL 2 MINUTES"))
    ) \
    .select(
        lit("PRIV_ESCALATION").alias("alert_type"),
        col("auth.agent_ip"),
        col("auth.user"),
        col("auth.source_ip"),
        col("sudo.command"),
        col("auth.login_time"),
        col("sudo.sudo_time")
    )

# ============================================
# DETECTION 3: Suspicious Outbound Connections
# FIX: Removed col("process") — not in schema
# ============================================
suspicious_ports = [22, 23, 3389, 5900, 445, 1433, 3306, 5432]

suspicious_outbound = parsed \
    .filter(col("type") == "network_connection") \
    .filter(col("remote_address").isNotNull()) \
    .select(
        col("agent_ip"),
        col("remote_address"),
        col("event_time"),
        when(
            col("remote_address").rlike(":(" + "|".join(str(p) for p in suspicious_ports) + ")$"),
            regexp_extract("remote_address", ":([0-9]+)$", 1)
        ).alias("suspicious_port")
    ) \
    .filter(col("suspicious_port").isNotNull()) \
    .select(
        lit("SUSPICIOUS_PORT").alias("alert_type"),
        col("agent_ip"),
        col("remote_address"),
        col("suspicious_port"),
        col("event_time")
    )

# ============================================
# DETECTION 4: High CPU Process
# FIX: Removed broken baseline readStream on missing file
# ============================================
high_cpu = parsed \
    .filter(col("type") == "process") \
    .filter(col("cpu_p") > 50) \
    .select(
        lit("HIGH_CPU").alias("alert_type"),
        col("agent_ip"),
        col("command"),
        col("cpu_p"),
        col("event_time")
    )

# ============================================
# Write alerts to Kafka topic: security_alerts
# FIX: kafka bootstrap uses internal listener kafka:29092
# FIX: cache df.count() to avoid calling action twice
# ============================================
def write_to_kafka(df, epoch_id):
    count = df.count()
    if count > 0:
        df.selectExpr("to_json(struct(*)) AS value") \
          .write \
          .format("kafka") \
          .option("kafka.bootstrap.servers", "kafka:29092") \
          .option("topic", "security_alerts") \
          .save()
        print(f"⚠️  ALERT: {count} threats detected in epoch {epoch_id}")

# ============================================
# Start all streaming queries
# ============================================
query1 = brute_force.writeStream \
    .outputMode("append") \
    .foreachBatch(write_to_kafka) \
    .option("checkpointLocation", "/tmp/checkpoints/bruteforce") \
    .trigger(processingTime="30 seconds") \
    .start()

query2 = privilege_escalation.writeStream \
    .outputMode("append") \
    .foreachBatch(write_to_kafka) \
    .option("checkpointLocation", "/tmp/checkpoints/privilege") \
    .trigger(processingTime="30 seconds") \
    .start()

query3 = suspicious_outbound.writeStream \
    .outputMode("append") \
    .foreachBatch(write_to_kafka) \
    .option("checkpointLocation", "/tmp/checkpoints/outbound") \
    .trigger(processingTime="30 seconds") \
    .start()

query4 = high_cpu.writeStream \
    .outputMode("append") \
    .foreachBatch(write_to_kafka) \
    .option("checkpointLocation", "/tmp/checkpoints/highcpu") \
    .trigger(processingTime="30 seconds") \
    .start()

print("✅ All threat detection queries running!")
print("📡 Alerts being sent to Kafka topic: security_alerts")

# Wait for any query to terminate (or fail)
spark.streams.awaitAnyTermination()
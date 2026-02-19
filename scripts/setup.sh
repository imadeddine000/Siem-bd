#!/bin/bash
set -e

# ----------------------------
# Collector IP - injected by main script
# ----------------------------
HOST="__COLLECTOR_IP__"
echo "🔗 Collector IP: $HOST"
# ----------------------------
# Install Fluent Bit
# ----------------------------
echo "📦 Installing Fluent Bit..."
curl -s https://raw.githubusercontent.com/fluent/fluent-bit/master/install.sh | sudo sh

# ----------------------------
# Get Agent IP
# ----------------------------
export AGENT_IP=$(hostname -I | awk '{print $1}')
echo "🌐 Agent IP: $AGENT_IP"

# ----------------------------
# Create directories for logs and scripts
# ----------------------------
sudo mkdir -p /var/log/agent
sudo mkdir -p /etc/fluent-bit/scripts

# ----------------------------
# Heartbeat Script (every 2 seconds)
# ----------------------------
AGENT_IP=$(hostname -I | awk '{print $1}')
COLLECTOR_IP="$HOST"

sudo tee /var/log/agent/heartbeat.sh > /dev/null <<EOF
#!/bin/bash
export AGENT_IP=$(hostname -I | awk '{print $1}')
COLLECTOR_IP="$COLLECTOR_IP"

while true; do
  TIMESTAMP=\$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  JSON=\$(jq -n \
    --arg type "heartbeat" \
    --arg agent_ip "\$AGENT_IP" \
    --arg hostname "\$(hostname)" \
    --arg timestamp "\$TIMESTAMP" \
    '{type: \$type, agent_ip: \$agent_ip, hostname: \$hostname, timestamp: \$timestamp}')

  curl -s -X POST "http://\$COLLECTOR_IP:3000/agent-heartbeat" \
       -H "Content-Type: application/json" \
       -d "\$JSON" >/dev/null 2>&1

  sleep 2
done
EOF

sudo chmod +x /var/log/agent/heartbeat.sh
sudo nohup /var/log/agent/heartbeat.sh >> /var/log/agent/heartbeat.log 2>&1 &


# ----------------------------
# Process Monitoring Script (every 5 seconds, all processes)
# ----------------------------
sudo tee /var/log/agent/process.sh > /dev/null << 'EOF'
#!/bin/bash
export AGENT_IP=$(hostname -I | awk '{print $1}')
while true; do
  ps aux --sort=-%cpu | while read line; do
    user=$(echo $line | awk '{print $1}')
    pid=$(echo $line | awk '{print $2}')
    cpu=$(echo $line | awk '{print $3}')
    mem=$(echo $line | awk '{print $4}')
    command=$(echo $line | awk '{$1=$2=$3=$4=$5=$6=$7=$8=$9=$10=""; print $0}' | sed 's/^ *//')
    if [[ ! -z "$pid" && "$pid" != "PID" ]]; then
      echo "{\"type\":\"process\",\"agent_ip\":\"$AGENT_IP\",\"timestamp\":\"$(date -u +"%Y-%m-%dT%H:%M:%SZ")\",\"user\":\"$user\",\"pid\":$pid,\"cpu_p\":$cpu,\"mem_p\":$mem,\"command\":\"$command\"}"
    fi
  done
  sleep 5
done
EOF
sudo chmod +x /var/log/agent/process.sh
sudo nohup /var/log/agent/process.sh > /var/log/agent/process.log 2>&1 &

# ----------------------------
# Network Connections Script (every 10 seconds)
# ----------------------------
sudo tee /var/log/agent/network.sh > /dev/null << 'EOF'
#!/bin/bash
export AGENT_IP=$(hostname -I | awk '{print $1}')
while true; do
  ss -tunap | while read line; do
    if echo "$line" | grep -q ESTAB; then
      proto=$(echo $line | awk '{print $1}')
      local=$(echo $line | awk '{print $5}')
      remote=$(echo $line | awk '{print $6}')
      process=$(echo $line | grep -o 'users:((.*))' | cut -d'"' -f2)
      echo "{\"type\":\"network_connection\",\"agent_ip\":\"$AGENT_IP\",\"timestamp\":\"$(date -u +"%Y-%m-%dT%H:%M:%SZ")\",\"protocol\":\"$proto\",\"local_address\":\"$local\",\"remote_address\":\"$remote\",\"process\":\"$process\",\"state\":\"established\"}"
    fi
  done

  ss -tulpn | grep LISTEN | while read line; do
    proto=$(echo $line | awk '{print $1}')
    local=$(echo $line | awk '{print $5}')
    process=$(echo $line | grep -o 'users:((.*))' | cut -d'"' -f2)
    echo "{\"type\":\"listening_port\",\"agent_ip\":\"$AGENT_IP\",\"timestamp\":\"$(date -u +"%Y-%m-%dT%H:%M:%SZ")\",\"protocol\":\"$proto\",\"local_address\":\"$local\",\"process\":\"$process\"}"
  done
  sleep 10
done
EOF
sudo chmod +x /var/log/agent/network.sh
sudo nohup /var/log/agent/network.sh > /var/log/agent/network.log 2>&1 &

# ----------------------------
# Authentication Log Monitor (real-time - unchanged)
# ----------------------------
sudo tee /var/log/agent/auth.sh > /dev/null << 'EOF'
#!/bin/bash
export AGENT_IP=$(hostname -I | awk '{print $1}')
tail -f /var/log/secure | while read line; do
  if echo "$line" | grep -q "Failed password"; then
    user=$(echo "$line" | grep -oP 'for \K[^ ]+')
    ip=$(echo "$line" | grep -oP 'from \K[^ ]+')
    port=$(echo "$line" | grep -oP 'port \K[0-9]+')
    echo "{\"type\":\"auth_failure\",\"agent_ip\":\"$AGENT_IP\",\"timestamp\":\"$(date -u +"%Y-%m-%dT%H:%M:%SZ")\",\"user\":\"$user\",\"source_ip\":\"$ip\",\"port\":$port}"
  elif echo "$line" | grep -q "Accepted password"; then
    user=$(echo "$line" | grep -oP 'for \K[^ ]+')
    ip=$(echo "$line" | grep -oP 'from \K[^ ]+')
    echo "{\"type\":\"auth_success\",\"agent_ip\":\"$AGENT_IP\",\"timestamp\":\"$(date -u +"%Y-%m-%dT%H:%M:%SZ")\",\"user\":\"$user\",\"source_ip\":\"$ip\"}"
  elif echo "$line" | grep -q "sudo:"; then
    user=$(echo "$line" | grep -oP 'sudo: \K[^ ]+')
    command=$(echo "$line" | grep -oP 'COMMAND=\K.*')
    echo "{\"type\":\"sudo_command\",\"agent_ip\":\"$AGENT_IP\",\"timestamp\":\"$(date -u +"%Y-%m-%dT%H:%M:%SZ")\",\"user\":\"$user\",\"command\":\"$command\"}"
  fi
done
EOF
sudo chmod +x /var/log/agent/auth.sh
sudo nohup /var/log/agent/auth.sh > /var/log/agent/auth.log 2>&1 &

# ----------------------------
# Disk Usage Monitoring (every 30 seconds)
# ----------------------------
sudo tee /var/log/agent/disk.sh > /dev/null << 'EOF'
#!/bin/bash
export AGENT_IP=$(hostname -I | awk '{print $1}')
while true; do
  df -h | grep ^/dev | while read line; do
    filesystem=$(echo $line | awk '{print $1}')
    size=$(echo $line | awk '{print $2}')
    used=$(echo $line | awk '{print $3}')
    avail=$(echo $line | awk '{print $4}')
    use_percent=$(echo $line | awk '{print $5}' | sed 's/%//')
    mount=$(echo $line | awk '{print $6}')
    echo "{\"type\":\"disk_usage\",\"agent_ip\":\"$AGENT_IP\",\"timestamp\":\"$(date -u +"%Y-%m-%dT%H:%M:%SZ")\",\"filesystem\":\"$filesystem\",\"size\":\"$size\",\"used\":\"$used\",\"available\":\"$avail\",\"use_percent\":$use_percent,\"mount\":\"$mount\"}"
  done
  sleep 30
done
EOF
sudo chmod +x /var/log/agent/disk.sh
sudo nohup /var/log/agent/disk.sh > /var/log/agent/disk.log 2>&1 &

# ----------------------------
# Memory Monitoring (every 10 seconds)
# ----------------------------
sudo tee /var/log/agent/memory.sh > /dev/null << 'EOF'
#!/bin/bash
export AGENT_IP=$(hostname -I | awk '{print $1}')
while true; do
  mem_total=$(grep MemTotal /proc/meminfo | awk '{print $2}')
  mem_free=$(grep MemFree /proc/meminfo | awk '{print $2}')
  mem_available=$(grep MemAvailable /proc/meminfo | awk '{print $2}')
  mem_used=$((mem_total - mem_available))
  mem_used_percent=$((mem_used * 100 / mem_total))
  echo "{\"type\":\"memory_detail\",\"agent_ip\":\"$AGENT_IP\",\"timestamp\":\"$(date -u +"%Y-%m-%dT%H:%M:%SZ")\",\"mem_total_kb\":$mem_total,\"mem_free_kb\":$mem_free,\"mem_available_kb\":$mem_available,\"mem_used_kb\":$mem_used,\"mem_used_percent\":$mem_used_percent}"
  sleep 10
done
EOF
sudo chmod +x /var/log/agent/memory.sh
sudo nohup /var/log/agent/memory.sh > /var/log/agent/memory.log 2>&1 &

# ----------------------------
# Fluent Bit Configuration - TUNED FOR HIGHER VOLUME
# ----------------------------
sudo tee /etc/fluent-bit/parsers.conf > /dev/null << 'EOF'
[PARSER]
    Name syslog
    Format regex
    Regex ^(?<time>[^ ]+ {1,2}[^ ]+ [^ ]+) (?<host>[^ ]+) (?<message>.*)$
    Time_Key time
    Time_Format %b %d %H:%M:%S

[PARSER]
    Name json
    Format json
    Time_Key timestamp
    Time_Format %Y-%m-%dT%H:%M:%S
EOF

sudo tee /etc/fluent-bit/fluent-bit.conf > /dev/null << EOF
[SERVICE]
    Flush        1
    Log_Level    info
    Parsers_File /etc/fluent-bit/parsers.conf

# System logs
[INPUT]
    Name   tail
    Path   /var/log/syslog
    Tag    syslog
    Parser syslog
    Buffer_Chunk_Size 32k
    Buffer_Max_Size 256k

[INPUT]
    Name   tail
    Path   /var/log/secure
    Tag    auth
    Parser syslog
    Buffer_Chunk_Size 32k
    Buffer_Max_Size 256k

# Built-in metrics - FASTER COLLECTION
[INPUT]
    Name cpu
    Tag cpu
    Interval_Sec 5

[INPUT]
    Name mem
    Tag mem
    Interval_Sec 5

[INPUT]
    Name disk
    Tag disk
    Interval_Sec 15

[INPUT]
    Name netif
    Tag net
    Interval_Sec 15
    Interface *

# Custom scripts - AGGRESSIVE READING
[INPUT]
    Name tail
    Path /var/log/agent/*.log
    Tag agent
    Parser json
    Path_Key file
    Refresh_Interval 1
    Buffer_Chunk_Size 64k
    Buffer_Max_Size 512k
    DB /var/log/agent.db
    Skip_Long_Lines On

[FILTER]
    Name record_modifier
    Match *
    Record agent_ip ${AGENT_IP}
    Record hostname $(hostname)

[OUTPUT]
    Name forward
    Match *
    Host $HOST
    Port 24224
    Retry_Limit False
EOF

# ----------------------------
# Ensure log files exist
# ----------------------------
sudo touch /var/log/agent/{process,network,auth,disk,memory}.log
sudo chmod 666 /var/log/agent/*.log

# ----------------------------
# Kill old processes and restart Fluent Bit
# ----------------------------
sudo pkill -f "/var/log/agent/.*\.sh" 2>/dev/null || true
sudo systemctl restart fluent-bit || sudo /opt/fluent-bit/bin/fluent-bit -c /etc/fluent-bit/fluent-bit.conf &

# ----------------------------
# Register Agent
# ----------------------------
source /etc/os-release
curl -s -X POST "http://$HOST:3000/agent-register" \
     -H "Content-Type: application/json" \
     -d "{ \"hostname\": \"$(hostname)\", \"os\": \"$NAME\", \"version\": \"$VERSION\", \"arch\": \"$(uname -m)\", \"agent_ip\": \"$AGENT_IP\" }"

echo "✅ Enhanced security agent installed and running (HIGH VOLUME MODE)"
echo "📊 Collecting: CPU, Memory, Disk, Network, Processes, Auth logs, Sudo commands"
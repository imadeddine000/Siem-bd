#!/bin/bash

podman start elasticsearch
sleep 10
echo "starting elastic search"

podman start kafka
echo "starting kafka"

sleep 10

podman start kibana
echo "starting kibana"

sleep 10

# Run Python script and save PID
nohup python3 /root/siem/consumer.py > python_output.log 2>&1 &
echo $! > /tmp/python_script.pid
echo "Python script started in background with nohup (PID: $!)"

# Run Fluent Bit and save PID
nohup /opt/fluent-bit/bin/fluent-bit -c /root/siem/receiver.conf > fluent_output.log 2>&1 &
echo $! > /tmp/fluent_bit.pid
echo "Fluent Bit is running (PID: $!)"

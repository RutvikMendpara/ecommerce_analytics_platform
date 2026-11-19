#!/bin/bash
# Starts Kafka Connect, then registers the connectors and restarts them if they fail
# (e.g. Debezium starting before the simulator has created the tables).
set -u

/docker-entrypoint.sh start &
CONNECT_PID=$!

until curl -sf localhost:8083/connectors > /dev/null; do sleep 3; done

for name in postgres-source s3-sink; do
  if [ "$name" = "s3-sink" ] && [ -z "${LAKE_BUCKET:-}" ]; then
    echo "LAKE_BUCKET not set, skipping s3-sink"
    continue
  fi
  curl -sf -X PUT -H "Content-Type: application/json" \
    --data @/kafka/connectors/$name.json localhost:8083/connectors/$name/config > /dev/null \
    && echo "registered $name"
done

while kill -0 $CONNECT_PID 2> /dev/null; do
  sleep 30
  curl -sf -X POST "localhost:8083/connectors/postgres-source/restart?includeTasks=true&onlyFailed=true" > /dev/null
  curl -sf -X POST "localhost:8083/connectors/s3-sink/restart?includeTasks=true&onlyFailed=true" > /dev/null
done

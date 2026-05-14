#!/usr/bin/env bash
# Simulates a warehouse batch-uploading shipment records to SQS.
# Usage: ./scripts/warehouse-simulator.sh --messages 1000 --queue <SQS_URL>

set -euo pipefail

MESSAGES=100
QUEUE_URL=""
BATCH_SIZE=10
REGION="us-east-1"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --messages) MESSAGES="$2"; shift 2 ;;
    --queue)    QUEUE_URL="$2"; shift 2 ;;
    --region)   REGION="$2";   shift 2 ;;
    *) echo "Unknown arg: $1"; exit 1 ;;
  esac
done

if [[ -z "$QUEUE_URL" ]]; then
  echo "Error: --queue <SQS_URL> is required"
  exit 1
fi

echo "Warehouse Simulator"
echo "==================="
echo "Queue:    $QUEUE_URL"
echo "Messages: $MESSAGES"
echo ""

python3 - <<PYEOF
import json, random, subprocess, sys

queue_url = "$QUEUE_URL"
region = "$REGION"
total = $MESSAGES
batch_size = $BATCH_SIZE
sent = 0
batch_num = 0

def random_tracking():
    return "TRK" + str(random.randint(1000000, 9999999))

while sent < total:
    entries = []
    for i in range(min(batch_size, total - sent)):
        msg_id = sent + i + 1
        body = json.dumps({
            "shipment_id": f"SHIP-{msg_id:06d}",
            "tracking": random_tracking(),
            "weight_kg": round(random.uniform(0.5, 50.0), 2),
            "destination": f"Warehouse-{random.randint(1, 20)}",
        })
        entries.append({"Id": f"msg{msg_id}", "MessageBody": body})

    result = subprocess.run([
        "aws", "sqs", "send-message-batch",
        "--queue-url", queue_url,
        "--entries", json.dumps(entries),
        "--region", region,
        "--output", "text"
    ], capture_output=True, text=True)

    if result.returncode != 0:
        print(f"  ERROR on batch {batch_num + 1}: {result.stderr[:100]}", file=sys.stderr)
    else:
        batch_num += 1
        sent += len(entries)
        print(f"  Batch {batch_num}: sent {len(entries)} messages (total: {sent}/{total})")

print(f"\nDone. {sent} shipment records uploaded to SQS.")
print("\nWatch KEDA react:")
print("  watch -n 5 \"kubectl get pods -n logiflow && kubectl get scaledobject -n logiflow\"")
PYEOF

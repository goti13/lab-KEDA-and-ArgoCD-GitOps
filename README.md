# KEDA + ArgoCD: GitOps Autoscaling with Real Alerts

> **Lab Series:** Kubernetes Production Patterns on AWS  
> **Difficulty:** Advanced  
> **Time:** ~3 hours  
> **Prerequisites:** EKS cluster, kubectl, AWS CLI v2, Helm 3, jq, Git, GitHub account

---

## Overview

> *"The queue is growing. Nobody is awake. Who saves the day?"*

You're an engineer at **LogiFlow**, a logistics company. Every night, warehouse partners batch-upload thousands of shipment records into an SQS queue. A single Kubernetes worker pod reads the queue and writes to the database.

Last Tuesday at 2 AM, a warehouse uploaded 50,000 records. The queue grew for hours. By 6 AM, customers were calling. The backlog took until noon to clear.

This lab fixes that — permanently.

### What You'll Build

A production-grade GitOps pipeline where:
- **KEDA** scales workers from 0 to N based on real SQS queue depth (not CPU)
- **ArgoCD** enforces that every config change goes through Git — no more `kubectl apply` from laptops
- **SNS alerts** notify on-call engineers the moment scaling happens

### What You'll Learn

| Concept | Why It Matters |
|---|---|
| KEDA vs HPA | CPU is the wrong signal for queue workers |
| Scale-to-zero | Pay only when there's work to do |
| GitOps workflow | Git is the single source of truth |
| IRSA for KEDA | Secure AWS auth without hardcoded credentials |
| SNS alerting | Humans find out before customers do |

---

## Architecture

```
┌─────────────┐   uploads messages   ┌──────────────────┐
│  Warehouse  │ ──────────────────►  │  AWS SQS Queue   │
│  Simulator  │                      │  (shipments)     │
└─────────────┘                      └────────┬─────────┘
                                              │ queue depth metric
                                              ▼
                                      ┌───────────────┐
                                      │     KEDA      │
                                      │  ScaledObject │
                                      └──────┬────────┘
                                             │ drives replica count
                                             ▼
                                  ┌─────────────────────┐
                                  │  Worker Deployment  │
                                  │  (0 → N pods)       │
                                  └──────────┬──────────┘
                               ┌─────────────┼─────────────┐
                               ▼             ▼             ▼
                            Worker 1     Worker 2     Worker N

                                   when scaling happens:
                                             │
                                             ▼
                               ┌─────────────────────────┐
                               │  Event Exporter         │
                               │  (watches k8s events)   │
                               └────────────┬────────────┘
                                            │
                                            ▼
                               ┌─────────────────────────┐
                               │  SNS Notifier pod       │
                               │  (HTTP → SNS publish)   │
                               └────────────┬────────────┘
                                            │
                          ┌─────────────────┴─────────────────┐
                          ▼                                   ▼
                       Email                               SMS
                    (your inbox)                       (your phone)
```

**GitOps flow — the only path to production:**

```
  Your laptop        GitHub             ArgoCD            EKS cluster
       │                │                 │                    │
       ├── git push ──► │                 │                    │
       │                ├── webhook ────► │                    │
       │                │                 ├── sync ──────────► │
       │                │                 │   (kubectl apply)   │
```

You never `kubectl apply` directly. Git is the only path to production.

---

## Part 1 — Why KEDA Instead of HPA

### The Fundamental Mismatch

In the HPA lab, HPA scaled on CPU. That works for APIs: more requests → more CPU → more pods.

But the LogiFlow worker is different:

```
Pick up a message from SQS
  ↓
Read from the database        ← waiting (network I/O)
  ↓
Transform the data            ← milliseconds of actual work
  ↓
Write to database             ← waiting (network I/O)
  ↓
Delete the message from SQS
  ↓
Repeat
```

Almost all of that is waiting. The pod sits at 3–5% CPU regardless of queue depth.

**HPA sees 3% CPU and thinks: all good.**  
**The queue has 50,000 messages. Customers are waiting.**

CPU is the wrong signal. Queue depth is the right one.

### How KEDA Fixes This

KEDA lets you configure a `ScaledObject` that says: *"for every 10 messages in the queue, I want 1 worker pod."*

| Queue Depth | Worker Pods |
|---|---|
| 0 | 0 (scale to zero — saves money) |
| 50 | 5 |
| 200 | 10 (capped at `maxReplicaCount`) |

KEDA creates and manages an HPA under the hood — it just feeds it a custom metric (queue depth) instead of CPU.

### Scale-to-Zero: A Superpower HPA Doesn't Have

HPA has a hard minimum of 1 pod. KEDA can go to 0.

For LogiFlow's overnight batch:
- 10 PM – 2 AM: 0 pods running (zero cost)
- 2 AM: warehouse uploads 50,000 records
- 2:01 AM: KEDA detects queue spike, scales to 10 workers
- 4 AM: queue empty, workers scale back to 0

You pay only for workers when there's actually work to do.

---

## Part 2 — GitOps Repository Setup

### Create a GitHub Repository

Create a new **public** repository on GitHub named `logiflow-gitops`, then clone it:

```bash
git clone https://github.com/<YOUR_USERNAME>/logiflow-gitops.git
cd logiflow-gitops
```

Create the directory layout:

```bash
mkdir -p apps/worker infra/alerting scripts
```

Expected structure:

```
logiflow-gitops/
├── apps/
│   └── worker/
│       ├── deployment.yaml
│       ├── service-account.yaml
│       └── keda-scaledobject.yaml
├── infra/
│   └── alerting/
│       ├── event-exporter.yaml
│       └── sns-notifier.yaml
└── scripts/
    └── warehouse-simulator.sh
```

### Install ArgoCD

```bash
kubectl create namespace argocd

kubectl apply -n argocd \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

kubectl rollout status deployment/argocd-server -n argocd
```

Get the initial admin password:

```bash
kubectl get secret argocd-initial-admin-secret -n argocd \
  -o jsonpath="{.data.password}" | base64 -d
echo ""
```

Expose the UI — **keep this terminal open throughout the lab:**

```bash
kubectl port-forward svc/argocd-server -n argocd 8080:443
```

Open `https://localhost:8080`. Username: `admin`. Password: from above. Expect a certificate warning — click through it.

### Install the ArgoCD CLI

```bash
# macOS
brew install argocd

# Linux
curl -sSL -o /usr/local/bin/argocd \
  https://github.com/argoproj/argo-cd/releases/latest/download/argocd-linux-amd64
chmod +x /usr/local/bin/argocd
```

Log in (requires the port-forward to be running):

```bash
argocd login localhost:8080 \
  --username admin \
  --insecure \
  --password $(kubectl get secret argocd-initial-admin-secret \
    -n argocd -o jsonpath="{.data.password}" | base64 -d)
```

---

## Part 3 — AWS Infrastructure

### Set Environment Variables

```bash
export CLUSTER_NAME=$(kubectl config current-context | awk -F'[:/]' '{print $NF}')
export AWS_DEFAULT_REGION="us-east-1"
export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

echo "Cluster:  $CLUSTER_NAME"
echo "Region:   $AWS_DEFAULT_REGION"
echo "Account:  $ACCOUNT_ID"
```

> **Keep this terminal open.** All subsequent commands depend on these variables.

### Create the SQS Queue

> **Note:** Append your name to all resource names to avoid conflicts with other students sharing the same AWS account.

```bash
export YOUR_NAME="gerald"   # change this to your name

aws sqs create-queue \
  --queue-name "logiflow-shipments-${YOUR_NAME}" \
  --attributes '{"VisibilityTimeout":"60"}' \
  --region us-east-1

export QUEUE_URL=$(aws sqs get-queue-url \
  --queue-name "logiflow-shipments-${YOUR_NAME}" \
  --region us-east-1 \
  --query QueueUrl \
  --output text)

echo "Queue URL: $QUEUE_URL"
```

### Create the SNS Topic

```bash
export TOPIC_ARN=$(aws sns create-topic \
  --name "logiflow-scaling-alerts-${YOUR_NAME}" \
  --region us-east-1 \
  --query TopicArn \
  --output text)

echo "Topic ARN: $TOPIC_ARN"
```

### Subscribe Your Email

```bash
export MY_EMAIL="you@example.com"   # use your real email

aws sns subscribe \
  --topic-arn "$TOPIC_ARN" \
  --protocol email \
  --notification-endpoint "$MY_EMAIL" \
  --region us-east-1
```

> **Go check your inbox now** and click "Confirm subscription" in the AWS email. Check spam if it doesn't arrive within 30 seconds. SNS will not deliver alerts until this is confirmed.

**Optional — subscribe your phone:**

```bash
export MY_PHONE="+1XXXXXXXXXX"   # E.164 format, e.g. +4915123456789

aws sns subscribe \
  --topic-arn "$TOPIC_ARN" \
  --protocol sms \
  --notification-endpoint "$MY_PHONE" \
  --region us-east-1
```

### Create the IAM Role for Worker Pods

Pods need AWS credentials to read SQS and publish to SNS. We use **IRSA** (IAM Roles for Service Accounts) — no hardcoded credentials, no Kubernetes Secrets.

**Get the cluster OIDC URL:**

```bash
export OIDC_URL=$(aws eks describe-cluster \
  --name "$CLUSTER_NAME" \
  --region us-east-1 \
  --query "cluster.identity.oidc.issuer" \
  --output text | sed 's|https://||')

echo "OIDC: $OIDC_URL"
```

**Create the IAM policy:**

> **Important:** The policy resource ARN must exactly match your queue name including the name suffix.

```bash
cat > /tmp/logiflow-policy.json << EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "sqs:ReceiveMessage",
        "sqs:DeleteMessage",
        "sqs:GetQueueAttributes",
        "sqs:GetQueueUrl"
      ],
      "Resource": "arn:aws:sqs:us-east-1:${ACCOUNT_ID}:logiflow-shipments-${YOUR_NAME}"
    },
    {
      "Effect": "Allow",
      "Action": ["sns:Publish"],
      "Resource": "${TOPIC_ARN}"
    }
  ]
}
EOF

aws iam create-policy \
  --policy-name "LogiFlowWorkerPolicy-${YOUR_NAME}" \
  --policy-document file:///tmp/logiflow-policy.json
```

**Create the IAM role with OIDC trust:**

```bash
cat > /tmp/logiflow-trust.json << EOF
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {
      "Federated": "arn:aws:iam::${ACCOUNT_ID}:oidc-provider/${OIDC_URL}"
    },
    "Action": "sts:AssumeRoleWithWebIdentity",
    "Condition": {
      "StringEquals": {
        "${OIDC_URL}:aud": "sts.amazonaws.com"
      },
      "StringLike": {
        "${OIDC_URL}:sub": "system:serviceaccount:logiflow:*"
      }
    }
  }]
}
EOF

aws iam create-role \
  --role-name "LogiFlowWorkerRole-${YOUR_NAME}" \
  --assume-role-policy-document file:///tmp/logiflow-trust.json

aws iam attach-role-policy \
  --role-name "LogiFlowWorkerRole-${YOUR_NAME}" \
  --policy-arn "arn:aws:iam::${ACCOUNT_ID}:policy/LogiFlowWorkerPolicy-${YOUR_NAME}"

export WORKER_ROLE_ARN=$(aws iam get-role \
  --role-name "LogiFlowWorkerRole-${YOUR_NAME}" \
  --query "Role.Arn" \
  --output text)

echo "Worker Role ARN: $WORKER_ROLE_ARN"
```

---

## Part 4 — Install KEDA

```bash
helm repo add kedacore https://kedacore.github.io/charts
helm repo update

helm upgrade --install keda kedacore/keda \
  --namespace keda \
  --create-namespace \
  --wait
```

Verify:

```bash
kubectl get pods -n keda
```

Expected: three pods running — `keda-operator`, `keda-operator-metrics-apiserver`, and `keda-admission-webhooks`.

```bash
kubectl get crd | grep keda
```

Expected: `scaledobjects.keda.sh` and `triggerauthentications.keda.sh` in the list.

### Grant KEDA Access to SQS via IRSA

KEDA's operator pod needs `sqs:GetQueueAttributes` to read queue depth. Annotate its service account with the worker role:

```bash
kubectl annotate serviceaccount keda-operator -n keda \
  "eks.amazonaws.com/role-arn=${WORKER_ROLE_ARN}" \
  --overwrite
```

> **Note:** The annotation takes effect when the pod restarts. Only restart the operator if nodes have capacity for a new pod — if nodes are full, use the node role fallback in the Troubleshooting section instead.

---

## Part 5 — Create Manifest Files

You are inside your cloned `logiflow-gitops` repository. Create every file from scratch.

### apps/worker/service-account.yaml

A service account gives the worker pod an AWS identity via IRSA — no hardcoded credentials.

```bash
cat > apps/worker/service-account.yaml << 'EOF'
apiVersion: v1
kind: ServiceAccount
metadata:
  name: worker
  namespace: logiflow
  annotations:
    eks.amazonaws.com/role-arn: "REPLACE_WITH_WORKER_ROLE_ARN"
EOF
```

### apps/worker/deployment.yaml

```bash
cat > apps/worker/deployment.yaml << 'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: worker
  namespace: logiflow
  labels:
    app: worker
    version: "1.0.0"
spec:
  replicas: 0
  selector:
    matchLabels:
      app: worker
  template:
    metadata:
      labels:
        app: worker
    spec:
      serviceAccountName: worker
      terminationGracePeriodSeconds: 60
      containers:
        - name: worker
          image: amazon/aws-cli:latest
          command:
            - /bin/bash
            - -c
            - |
              echo "Worker started. Consuming from queue: $SQS_QUEUE_URL"
              while true; do
                OUTPUT=$(aws sqs receive-message \
                  --queue-url "$SQS_QUEUE_URL" \
                  --max-number-of-messages 10 \
                  --wait-time-seconds 20 \
                  --region us-east-1 \
                  --query "Messages[*].[Body,ReceiptHandle]" \
                  --output text 2>/dev/null)
                if [ -n "$OUTPUT" ]; then
                  COUNT=$(echo "$OUTPUT" | wc -l | tr -d ' ')
                  echo "Processing $COUNT messages"
                  while IFS=$'\t' read -r BODY RECEIPT; do
                    echo "  Processed: ${BODY:0:80}"
                    aws sqs delete-message \
                      --queue-url "$SQS_QUEUE_URL" \
                      --receipt-handle "$RECEIPT" \
                      --region us-east-1 > /dev/null 2>&1
                  done <<< "$OUTPUT"
                else
                  echo "Queue empty, waiting..."
                fi
              done
          env:
            - name: SQS_QUEUE_URL
              valueFrom:
                configMapKeyRef:
                  name: worker-config
                  key: sqs_queue_url
          resources:
            requests:
              cpu: "100m"
              memory: "128Mi"
            limits:
              cpu: "500m"
              memory: "256Mi"
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: worker-config
  namespace: logiflow
data:
  sqs_queue_url: "REPLACE_WITH_QUEUE_URL"
  aws_region: "us-east-1"
EOF
```

### apps/worker/keda-scaledobject.yaml

The `ScaledObject` tells KEDA what to watch and when to scale. The `TriggerAuthentication` wires it to the pod's IRSA identity.

```bash
cat > apps/worker/keda-scaledobject.yaml << 'EOF'
apiVersion: keda.sh/v1alpha1
kind: TriggerAuthentication
metadata:
  name: worker-sqs-auth
  namespace: logiflow
spec:
  podIdentity:
    provider: aws
---
apiVersion: keda.sh/v1alpha1
kind: ScaledObject
metadata:
  name: worker
  namespace: logiflow
spec:
  scaleTargetRef:
    name: worker
  minReplicaCount: 0
  maxReplicaCount: 10
  cooldownPeriod: 300
  pollingInterval: 15
  triggers:
    - type: aws-sqs-queue
      authenticationRef:
        name: worker-sqs-auth
      metadata:
        queueURL: "REPLACE_WITH_QUEUE_URL"
        awsRegion: "us-east-1"
        awsAccountID: "REPLACE_WITH_ACCOUNT_ID"
        queueLength: "10"
        scaleOnInFlight: "true"
EOF
```

Key fields to understand:

| Field | Purpose |
|---|---|
| `minReplicaCount: 0` | Scale-to-zero — valid for KEDA, impossible with HPA |
| `maxReplicaCount: 10` | Hard pod ceiling regardless of queue depth |
| `queueLength: "10"` | 1 pod per 10 messages — `ceil(depth/10)` = replica count |
| `cooldownPeriod: 300` | Wait 5 minutes before scaling down after queue drains |
| `pollingInterval: 15` | Check queue depth every 15 seconds |

### infra/alerting/event-exporter.yaml

Watches the Kubernetes event stream for scaling events and forwards them to the SNS notifier via HTTP webhook.

```bash
cat > infra/alerting/event-exporter.yaml << 'EOF'
apiVersion: v1
kind: ServiceAccount
metadata:
  name: event-exporter
  namespace: logiflow
  annotations:
    eks.amazonaws.com/role-arn: "REPLACE_WITH_WORKER_ROLE_ARN"
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: event-exporter
rules:
  - apiGroups: [""]
    resources: ["events", "namespaces", "nodes", "pods", "services", "replicationcontrollers"]
    verbs: ["get", "list", "watch"]
  - apiGroups: ["apps"]
    resources: ["deployments", "replicasets", "statefulsets", "daemonsets"]
    verbs: ["get", "list", "watch"]
  - apiGroups: ["autoscaling"]
    resources: ["horizontalpodautoscalers"]
    verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: event-exporter
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: event-exporter
subjects:
  - kind: ServiceAccount
    name: event-exporter
    namespace: logiflow
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: event-exporter-config
  namespace: logiflow
data:
  config.yaml: |
    logLevel: info
    logFormat: json
    route:
      routes:
        - match:
            - receiver: "sns-alerts"
              reason: "SuccessfulRescale|FailedScale|ScalingReplicaSet"
              namespace: "logiflow"
    receivers:
      - name: "sns-alerts"
        webhook:
          endpoint: "http://sns-notifier.logiflow.svc.cluster.local:8080/notify"
          headers:
            Content-Type: "application/json"
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: event-exporter
  namespace: logiflow
  labels:
    app: event-exporter
spec:
  replicas: 1
  selector:
    matchLabels:
      app: event-exporter
  template:
    metadata:
      labels:
        app: event-exporter
    spec:
      serviceAccountName: event-exporter
      containers:
        - name: event-exporter
          image: ghcr.io/resmoio/kubernetes-event-exporter:latest
          args:
            - -conf=/data/config.yaml
          resources:
            requests:
              cpu: "50m"
              memory: "64Mi"
            limits:
              cpu: "100m"
              memory: "128Mi"
          volumeMounts:
            - name: config
              mountPath: /data
      volumes:
        - name: config
          configMap:
            name: event-exporter-config
EOF
```

### infra/alerting/sns-notifier.yaml

A lightweight Python HTTP server that receives webhook events from the event exporter and publishes them to SNS.

```bash
cat > infra/alerting/sns-notifier.yaml << 'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: sns-notifier-config
  namespace: logiflow
data:
  sns_topic_arn: "REPLACE_WITH_TOPIC_ARN"
  aws_region: "us-east-1"
  cluster_name: "logiflow-eks"
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: sns-notifier
  namespace: logiflow
  labels:
    app: sns-notifier
spec:
  replicas: 1
  selector:
    matchLabels:
      app: sns-notifier
  template:
    metadata:
      labels:
        app: sns-notifier
    spec:
      serviceAccountName: event-exporter
      initContainers:
        - name: install-boto3
          image: python:3.11-slim
          command: ["pip", "install", "boto3", "--target=/deps", "--quiet"]
          volumeMounts:
            - name: deps
              mountPath: /deps
      containers:
        - name: notifier
          image: python:3.11-slim
          command:
            - python3
            - -c
            - |
              import sys
              sys.path.insert(0, "/deps")
              import json, os, boto3
              from http.server import HTTPServer, BaseHTTPRequestHandler

              TOPIC_ARN = os.environ["SNS_TOPIC_ARN"]
              REGION    = os.environ.get("AWS_REGION", "us-east-1")
              CLUSTER   = os.environ.get("CLUSTER_NAME", "unknown")

              class NotifyHandler(BaseHTTPRequestHandler):
                  def log_message(self, format, *args):
                      print(f"[sns-notifier] {format % args}", flush=True)

                  def do_POST(self):
                      if self.path != "/notify":
                          self.send_response(404); self.end_headers(); return
                      length = int(self.headers.get("Content-Length", 0))
                      body   = json.loads(self.rfile.read(length))
                      reason    = body.get("reason", "unknown")
                      ns        = body.get("involvedObject", {}).get("namespace", "?")
                      name      = body.get("involvedObject", {}).get("name", "?")
                      kind      = body.get("involvedObject", {}).get("kind", "?")
                      message   = body.get("message", "")
                      timestamp = body.get("lastTimestamp", "")
                      subject   = f"[LogiFlow Alert] {reason} — {kind}/{name}"
                      body_text = (
                          f"Scaling event detected in your EKS cluster.\n\n"
                          f"Cluster:   {CLUSTER}\n"
                          f"Namespace: {ns}\n"
                          f"Resource:  {kind}/{name}\n"
                          f"Reason:    {reason}\n"
                          f"Message:   {message}\n"
                          f"Time:      {timestamp}\n\n"
                          f"Check the cluster: kubectl get pods -n {ns}"
                      )
                      try:
                          sns = boto3.client("sns", region_name=REGION)
                          sns.publish(TopicArn=TOPIC_ARN, Subject=subject, Message=body_text)
                          print(f"Alert sent: {subject}", flush=True)
                          self.send_response(200)
                      except Exception as e:
                          print(f"SNS error: {e}", flush=True)
                          self.send_response(500)
                      self.end_headers()

                  def do_GET(self):
                      if self.path == "/health":
                          self.send_response(200); self.end_headers()
                          self.wfile.write(b'{"status":"ok"}')
                      else:
                          self.send_response(404); self.end_headers()

              print("SNS notifier listening on :8080", flush=True)
              HTTPServer(("0.0.0.0", 8080), NotifyHandler).serve_forever()
          env:
            - name: SNS_TOPIC_ARN
              valueFrom:
                configMapKeyRef:
                  name: sns-notifier-config
                  key: sns_topic_arn
            - name: AWS_REGION
              valueFrom:
                configMapKeyRef:
                  name: sns-notifier-config
                  key: aws_region
            - name: CLUSTER_NAME
              valueFrom:
                configMapKeyRef:
                  name: sns-notifier-config
                  key: cluster_name
          ports:
            - containerPort: 8080
          resources:
            requests:
              cpu: "50m"
              memory: "64Mi"
            limits:
              cpu: "200m"
              memory: "256Mi"
          readinessProbe:
            httpGet:
              path: /health
              port: 8080
            initialDelaySeconds: 5
            periodSeconds: 10
          volumeMounts:
            - name: deps
              mountPath: /deps
      volumes:
        - name: deps
          emptyDir: {}
---
apiVersion: v1
kind: Service
metadata:
  name: sns-notifier
  namespace: logiflow
spec:
  selector:
    app: sns-notifier
  ports:
    - port: 8080
      targetPort: 8080
EOF
```

### scripts/warehouse-simulator.sh

Floods the SQS queue with fake shipment records so you can watch KEDA react in real time.

```bash
cat > scripts/warehouse-simulator.sh << 'EOF'
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
EOF
chmod +x scripts/warehouse-simulator.sh
```

---

## Part 6 — Inject Values into Manifests

Substitute all placeholder values before committing. The `sed` syntax differs between macOS and Linux.

**macOS:**

```bash
sed -i "" "s|REPLACE_WITH_WORKER_ROLE_ARN|${WORKER_ROLE_ARN}|g" apps/worker/service-account.yaml
sed -i "" "s|REPLACE_WITH_QUEUE_URL|${QUEUE_URL}|g" apps/worker/deployment.yaml
sed -i "" "s|REPLACE_WITH_QUEUE_URL|${QUEUE_URL}|g" apps/worker/keda-scaledobject.yaml
sed -i "" "s|REPLACE_WITH_ACCOUNT_ID|${ACCOUNT_ID}|g" apps/worker/keda-scaledobject.yaml
sed -i "" "s|REPLACE_WITH_TOPIC_ARN|${TOPIC_ARN}|g" infra/alerting/sns-notifier.yaml
sed -i "" "s|REPLACE_WITH_WORKER_ROLE_ARN|${WORKER_ROLE_ARN}|g" infra/alerting/event-exporter.yaml
```

**Linux:**

```bash
sed -i "s|REPLACE_WITH_WORKER_ROLE_ARN|${WORKER_ROLE_ARN}|g" apps/worker/service-account.yaml
sed -i "s|REPLACE_WITH_QUEUE_URL|${QUEUE_URL}|g" apps/worker/deployment.yaml
sed -i "s|REPLACE_WITH_QUEUE_URL|${QUEUE_URL}|g" apps/worker/keda-scaledobject.yaml
sed -i "s|REPLACE_WITH_ACCOUNT_ID|${ACCOUNT_ID}|g" apps/worker/keda-scaledobject.yaml
sed -i "s|REPLACE_WITH_TOPIC_ARN|${TOPIC_ARN}|g" infra/alerting/sns-notifier.yaml
sed -i "s|REPLACE_WITH_WORKER_ROLE_ARN|${WORKER_ROLE_ARN}|g" infra/alerting/event-exporter.yaml
```

Verify no placeholders remain:

```bash
grep -r "REPLACE_WITH" apps/ infra/
```

Should return nothing. If any remain, the corresponding variable was empty — check with `echo $WORKER_ROLE_ARN`, `echo $QUEUE_URL`, etc. before re-running the `sed` commands.

### Commit and Push — The GitOps Moment

You are not applying YAML directly to the cluster. You are pushing to Git and letting ArgoCD handle the rest.

```bash
git add apps/ infra/ scripts/
git commit -m "Configure logiflow worker with KEDA scaling and SNS alerting"
git push origin main
```

---

## Part 7 — Register Apps in ArgoCD

Tell ArgoCD to watch the repository and keep the cluster in sync.

```bash
export GITHUB_USERNAME="goti13"   # your GitHub username

kubectl apply -f - << EOF
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: logiflow-worker
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/${GITHUB_USERNAME}/logiflow-gitops.git
    targetRevision: main
    path: apps/worker
  destination:
    server: https://kubernetes.default.svc
    namespace: logiflow
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
EOF
```

Trigger the first sync and wait for it to go healthy:

```bash
argocd app sync logiflow-worker
argocd app wait logiflow-worker --health
```

Check pods — you should see zero. This is KEDA scale-to-zero working correctly:

```bash
kubectl get pods -n logiflow
```

### Deploy the Alerting Stack

```bash
kubectl apply -f - << EOF
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: logiflow-alerting
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/${GITHUB_USERNAME}/logiflow-gitops.git
    targetRevision: main
    path: infra/alerting
  destination:
    server: https://kubernetes.default.svc
    namespace: logiflow
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
EOF
```

Verify both apps are healthy:

```bash
argocd app list
```

---

## Part 8 — The Warehouse Simulation

Everything is wired up. Time to see it work.

### Send 1,000 Shipment Records

```bash
./scripts/warehouse-simulator.sh --messages 1000 --queue "$QUEUE_URL"
```

### Watch the Queue Depth (Terminal 1)

```bash
watch -n 5 "aws sqs get-queue-attributes \
  --queue-url '$QUEUE_URL' \
  --attribute-names ApproximateNumberOfMessages \
  --region us-east-1 \
  --query 'Attributes.ApproximateNumberOfMessages' \
  --output text"
```

### Watch KEDA React (Terminal 2)

```bash
watch -n 5 "kubectl get pods -n logiflow && echo '---' && kubectl get scaledobject -n logiflow"
```

### Expected Timeline

| Time | Event |
|---|---|
| 0s | Queue has 1,000 messages |
| ~15s | KEDA polls SQS, detects queue depth |
| ~20–30s | Worker pods start `ContainerCreating` |
| ~45s | Workers `Running`, consuming messages |
| ~5 min | Queue drains to 0 |
| ~10 min | Workers scale back to 0 pods |

### Check Your Inbox

Within 1–2 minutes of scale-up you should receive:

```
Subject: [LogiFlow Alert] SuccessfulRescale — HorizontalPodAutoscaler/worker

Scaling event detected in your EKS cluster.

Cluster:   logiflow-eks
Namespace: logiflow
Resource:  HorizontalPodAutoscaler/worker
Reason:    SuccessfulRescale
Message:   New size: 10; reason: external metric...
Time:      2026-05-14 02:14:33 UTC

Check the cluster: kubectl get pods -n logiflow
```

If no alert arrives within 3 minutes, check the logs:

```bash
kubectl logs -n logiflow -l app=event-exporter --tail=30
kubectl logs -n logiflow -l app=sns-notifier --tail=30
```

### Watch ArgoCD Self-Heal

Simulate a panicked teammate doing an emergency `kubectl scale` at 3 AM:

```bash
kubectl scale deployment worker -n logiflow --replicas=5
```

Watch:

```bash
kubectl get deployment worker -n logiflow -w
```

Within ~3 minutes, ArgoCD detects the drift and reverts the cluster back to what Git says. The manual change disappears.

**This is the core GitOps guarantee: Git always wins.**

---

## Part 9 — Make a Change the GitOps Way

Increase max workers from 10 to 15 by pushing a Git commit — the correct way.

**macOS:**

```bash
sed -i "" "s/maxReplicaCount: 10/maxReplicaCount: 15/" \
  apps/worker/keda-scaledobject.yaml
```

**Linux:**

```bash
sed -i "s/maxReplicaCount: 10/maxReplicaCount: 15/" \
  apps/worker/keda-scaledobject.yaml
```

Commit and push:

```bash
git add apps/worker/keda-scaledobject.yaml
git commit -m "Increase max workers to 15 for peak season"
git push origin main
```

Sync and verify:

```bash
argocd app sync logiflow-worker
kubectl describe scaledobject worker -n logiflow | grep -i "max replica"
```

Expected: `Max Replica Count: 15`

That's the full GitOps lifecycle: **code review → merge → ArgoCD syncs → cluster updated — no manual `kubectl` anywhere.**

---

## Part 10 — Cleanup

Run in order. Do not skip steps.

```bash
# 1. Remove ArgoCD apps (cascades and deletes all deployed resources)
argocd app delete logiflow-worker --cascade
argocd app delete logiflow-alerting --cascade

# 2. Remove KEDA
helm uninstall keda -n keda
kubectl delete namespace keda

# 3. Remove ArgoCD
kubectl delete namespace argocd

# 4. Delete SQS queue
aws sqs delete-queue \
  --queue-url "$QUEUE_URL" \
  --region us-east-1

# 5. Delete SNS topic
aws sns delete-topic \
  --topic-arn "$TOPIC_ARN" \
  --region us-east-1

# 6. Detach and delete IAM resources
aws iam detach-role-policy \
  --role-name "LogiFlowWorkerRole-${YOUR_NAME}" \
  --policy-arn "arn:aws:iam::${ACCOUNT_ID}:policy/LogiFlowWorkerPolicy-${YOUR_NAME}"

aws iam delete-role \
  --role-name "LogiFlowWorkerRole-${YOUR_NAME}"

aws iam delete-policy \
  --policy-arn "arn:aws:iam::${ACCOUNT_ID}:policy/LogiFlowWorkerPolicy-${YOUR_NAME}"
```

---

## Knowledge Check

Answer from memory before reading the answers.

**1.** KEDA scales workers to 0 when the queue is empty — great for cost, but what's the downside? What's the term for this problem and how would you mitigate it?

**2.** You push a change to `keda-scaledobject.yaml` but ArgoCD shows `OutOfSync` for 15 minutes without auto-syncing. List three things you'd check.

**3.** A teammate manually applies a hotfix with `kubectl apply` at 3 AM. ArgoCD reverts it 3 minutes later. Is ArgoCD misbehaving? What should the engineer have done instead?

**4.** KEDA's `queueLength` is 10. The queue has 47 messages. How many worker pods will KEDA create?

**5.** The event exporter stopped sending SNS alerts. What's the first place you'd look and why?

<details>
<summary>Answers — stop and write yours first</summary>

**1.** The **cold start problem**. When KEDA scales from 0 to N, pods take 30–60 seconds to start. During that window the queue keeps growing and nothing is consuming it. Mitigation: set `minReplicaCount: 1` to keep one warm pod always running, or add a **Cron scaler** that pre-scales to 2 workers a few minutes before expected batch uploads.

**2.** (a) ArgoCD can't reach GitHub — check network and repo access token. (b) The YAML has a syntax error — `argocd app diff logiflow-worker` will surface it. (c) `syncPolicy.automated` was accidentally disabled — check the Application with `kubectl get application logiflow-worker -n argocd -o yaml`.

**3.** ArgoCD is working correctly — that's GitOps self-healing doing its job. The engineer should have pushed to a branch, opened a PR, merged it, and let ArgoCD deploy it. For true emergencies, most teams allow pushing directly to main and triggering `argocd app sync` immediately.

**4.** `ceil(47 / 10)` = `ceil(4.7)` = **5 pods**

**5.** The event exporter pod logs first — `kubectl logs -l app=event-exporter -n logiflow`. It shows whether scaling events are being detected and whether the HTTP call to the SNS notifier is succeeding. SNS notifier logs come second to check whether SNS is rejecting the publish.

</details>

---

## Troubleshooting Reference

| Symptom | Likely Cause | Fix |
|---|---|---|
| `ScaledObject` READY: False | KEDA can't authenticate to SQS | Attach SQS policy to node role, or fix IRSA annotation on `keda-operator` SA |
| `AccessDenied` on `sqs:GetQueueAttributes` | Policy ARN points to `logiflow-shipments` but queue is `logiflow-shipments-gerald` | Update policy resource ARN to include the name suffix |
| `argocd app sync` — `authentication required` | Wrong `repoURL` in Application manifest | Patch: `kubectl patch application logiflow-worker -n argocd --type merge -p '{"spec":{"source":{"repoURL":"https://github.com/goti13/logiflow-gitops.git"}}}'` |
| `argocd` CLI — `connection refused :8080` | Port-forward not running | Run `kubectl port-forward svc/argocd-server -n argocd 8080:443` in a separate terminal |
| `sed` error on macOS — `command a expects \` | macOS `sed` requires `-i ""` not `-i` | Use `sed -i "" "s/.../.../g"` — the empty string argument is required |
| `aws sns subscribe` — Invalid parameter: Topic Name | `$TOPIC_ARN` contains multiple values (newlines from `grep`) | Set the ARN explicitly: `export TOPIC_ARN="arn:aws:sns:us-east-1:ACCOUNT:topic-name"` |
| `aws sqs delete-queue` — requires `--queue-url` | Wrong flag used | Use `--queue-url "$QUEUE_URL"` — the `--queue-name` flag does not exist for delete |
| KEDA operator pod stuck `Pending` after annotation | Nodes full — pod density limit (no IP slots) | Attach `LogiFlowWorkerPolicy` directly to the node instance role as a fallback |
| No SNS alert received | Subscription not confirmed | Check inbox and spam for the AWS confirmation email and click the link |
| `argocd app sync` hangs then fails | `--watch` flag doesn't exist | Use `argocd app sync logiflow-worker` then `argocd app wait logiflow-worker --health` separately |

---

## Key Parameters Reference

```yaml
# ScaledObject
minReplicaCount: 0       # KEDA-only — HPA minimum is always 1
maxReplicaCount: 10      # Hard pod ceiling regardless of queue depth
pollingInterval: 15      # Check queue every N seconds
cooldownPeriod: 300      # Wait N seconds before scaling down after queue empties
queueLength: "10"        # Target messages per pod: ceil(depth / queueLength) = replicas
scaleOnInFlight: "true"  # Count in-flight (invisible) messages too, not just visible ones
```

---

## Lab File Structure

```
logiflow-gitops/
├── README.md
├── apps/
│   └── worker/
│       ├── deployment.yaml          # Worker pod + ConfigMap with queue URL
│       ├── keda-scaledobject.yaml   # TriggerAuthentication + ScaledObject
│       └── service-account.yaml     # IRSA-annotated service account
├── infra/
│   └── alerting/
│       ├── event-exporter.yaml      # Watches k8s events, webhooks to notifier
│       └── sns-notifier.yaml        # HTTP server that publishes to SNS
└── scripts/
    └── warehouse-simulator.sh       # Batch-uploads fake shipments to SQS
```

---

*Part of the Kubernetes Production Patterns on AWS lab series.*  
*Author: Gerald Oti · [github.com/goti13](https://github.com/goti13) · [linkedin.com/in/gerald-oti](https://www.linkedin.com/in/gerald-oti/) · [geraldoti.com](https://geraldoti.com)*
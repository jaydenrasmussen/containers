# Deployment Guide

How to deploy any proxy in this folder on Amazon ECS (Fargate), bare EC2, and Amazon EKS. Each proxy's own README contains the platform-specific env vars and ready-to-use manifests for that proxy — this guide covers the shared infrastructure patterns: ECR, IAM, networking, and platform setup.

---

## Contents

- [Prerequisites](#prerequisites)
- [Building and Pushing to Amazon ECR](#building-and-pushing-to-amazon-ecr)
- [ECS (Fargate)](#ecs-fargate)
- [EC2](#ec2)
- [EKS](#eks)

---

## Prerequisites

- **AWS CLI** configured with credentials that have ECR, ECS/EC2/EKS, SSM, and CloudWatch permissions
- **Docker** installed locally for building and tagging images
- An **ECR repository** created per proxy image
- The target **VPC, subnets, and security groups** already exist

---

## Building and Pushing to Amazon ECR

All three platforms pull the container image from Amazon ECR. Build and push once; the same image is used across ECS, EC2, and EKS.

Replace `<ACCOUNT_ID>`, `<REGION>`, `<PROXY_DIR>` (e.g. `mysql`), and `<PROXY_NAME>` (e.g. `mysql-proxy`) throughout this guide.

```sh
# Authenticate Docker to ECR
aws ecr get-login-password --region <REGION> | \
  docker login --username AWS --password-stdin \
  <ACCOUNT_ID>.dkr.ecr.<REGION>.amazonaws.com

# Create the ECR repository (one-time per proxy)
aws ecr create-repository \
  --repository-name <PROXY_NAME> \
  --region <REGION>

# Build, tag, and push
docker build -t <PROXY_NAME> ./<PROXY_DIR>

docker tag <PROXY_NAME>:latest \
  <ACCOUNT_ID>.dkr.ecr.<REGION>.amazonaws.com/<PROXY_NAME>:latest

docker push \
  <ACCOUNT_ID>.dkr.ecr.<REGION>.amazonaws.com/<PROXY_NAME>:latest
```

---

## ECS (Fargate)

### IAM roles

Two IAM roles are required:

| Role | Required policies | Notes |
|---|---|---|
| **Task execution role** | `AmazonECSTaskExecutionRolePolicy` | Used by ECS to pull the image from ECR and write logs to CloudWatch. If using SSM Parameter Store for `UPSTREAM_HOST`, also add `ssm:GetParameters` on the relevant parameter path. |
| **Task role** | None required | The proxy containers make no AWS API calls. You can omit this or attach an empty role. |

### Store sensitive values in SSM Parameter Store

Avoid putting upstream hostnames as plaintext in the task definition. Store them in SSM Parameter Store instead:

```sh
aws ssm put-parameter \
  --name /proxies/<PROXY_NAME>/upstream-host \
  --value "<UPSTREAM_HOSTNAME>" \
  --type SecureString \
  --region <REGION>
```

Add the following inline policy to the task **execution** role so ECS can read it at launch:

```json
{
  "Effect": "Allow",
  "Action": ["ssm:GetParameters"],
  "Resource": "arn:aws:ssm:<REGION>:<ACCOUNT_ID>:parameter/proxies/*"
}
```

### Task definition

Fargate requires `networkMode: awsvpc`. Each task gets its own elastic network interface (ENI) with a private IP in your VPC. The task's security group controls what can reach the proxy.

Save the following as `task-definition.json` and substitute all `<PLACEHOLDER>` values:

```json
{
  "family": "<PROXY_NAME>",
  "networkMode": "awsvpc",
  "requiresCompatibilities": ["FARGATE"],
  "cpu": "256",
  "memory": "512",
  "executionRoleArn": "arn:aws:iam::<ACCOUNT_ID>:role/ecsTaskExecutionRole",
  "containerDefinitions": [
    {
      "name": "<PROXY_NAME>",
      "image": "<ACCOUNT_ID>.dkr.ecr.<REGION>.amazonaws.com/<PROXY_NAME>:latest",
      "essential": true,
      "portMappings": [
        {
          "containerPort": <LISTEN_PORT>,
          "protocol": "tcp"
        }
      ],
      "environment": [
        { "name": "LISTEN_PORT",      "value": "<LISTEN_PORT>" },
        { "name": "UPSTREAM_PORT",    "value": "<UPSTREAM_PORT>" },
        { "name": "RESOLVER_ADDRESS", "value": "169.254.169.253" }
      ],
      "secrets": [
        {
          "name": "UPSTREAM_HOST",
          "valueFrom": "arn:aws:ssm:<REGION>:<ACCOUNT_ID>:parameter/proxies/<PROXY_NAME>/upstream-host"
        }
      ],
      "logConfiguration": {
        "logDriver": "awslogs",
        "options": {
          "awslogs-group": "/ecs/<PROXY_NAME>",
          "awslogs-region": "<REGION>",
          "awslogs-stream-prefix": "ecs"
        }
      }
    }
  ]
}
```

> The `api-weighted-proxy` has additional environment variables (`OLD_API_HOST`, `OLD_API_PORT`, `OLD_API_WEIGHT`, `NEW_API_HOST`, `NEW_API_PORT`, `NEW_API_WEIGHT`). See its README for the full extended `environment` and `secrets` blocks.

Create the CloudWatch log group then register the task definition:

```sh
aws logs create-log-group \
  --log-group-name /ecs/<PROXY_NAME> \
  --region <REGION>

aws ecs register-task-definition \
  --cli-input-json file://task-definition.json \
  --region <REGION>
```

### Creating the ECS service

```sh
aws ecs create-service \
  --cluster <CLUSTER_NAME> \
  --service-name <PROXY_NAME> \
  --task-definition <PROXY_NAME> \
  --desired-count 2 \
  --launch-type FARGATE \
  --network-configuration "awsvpcConfiguration={
    subnets=[<SUBNET_ID_1>,<SUBNET_ID_2>],
    securityGroups=[<PROXY_SG_ID>],
    assignPublicIp=DISABLED
  }" \
  --region <REGION>
```

### Security group rules

The proxy task's security group (`<PROXY_SG_ID>`) requires:

| Direction | Protocol | Port | Peer |
|---|---|---|---|
| Inbound | TCP | `LISTEN_PORT` | Application tier security group |
| Outbound | TCP | `UPSTREAM_PORT` | RDS / ElastiCache / DocumentDB security group |
| Outbound | TCP | 443 | `0.0.0.0/0` | ECR pulls and SSM API calls |

The managed service security group must also have an **inbound** rule allowing TCP on its port from `<PROXY_SG_ID>`.

---

## EC2

### Prerequisites

- Docker installed on the instance:
  ```sh
  # Amazon Linux 2023
  sudo yum install -y docker
  sudo systemctl enable --now docker
  ```
- An IAM instance profile with `AmazonEC2ContainerRegistryReadOnly` attached (for ECR pulls)
- The instance's security group configured with the same inbound/outbound rules described in the ECS section above

### Pull and run

```sh
# Authenticate and pull
aws ecr get-login-password --region <REGION> | \
  docker login --username AWS --password-stdin \
  <ACCOUNT_ID>.dkr.ecr.<REGION>.amazonaws.com

docker pull <ACCOUNT_ID>.dkr.ecr.<REGION>.amazonaws.com/<PROXY_NAME>:latest

# Run
docker run -d \
  --name <PROXY_NAME> \
  --restart unless-stopped \
  -p <LISTEN_PORT>:<LISTEN_PORT> \
  -e UPSTREAM_HOST=<UPSTREAM_HOSTNAME> \
  -e UPSTREAM_PORT=<UPSTREAM_PORT> \
  -e RESOLVER_ADDRESS=169.254.169.253 \
  <ACCOUNT_ID>.dkr.ecr.<REGION>.amazonaws.com/<PROXY_NAME>:latest
```

### Persisting with systemd

`--restart unless-stopped` handles Docker-level restarts but will not start the container if the host reboots before the Docker daemon is ready. A systemd unit is more reliable for long-running instances.

Create `/etc/systemd/system/<PROXY_NAME>.service`:

```ini
[Unit]
Description=<PROXY_NAME> NGINX proxy
After=docker.service
Requires=docker.service

[Service]
Restart=always
RestartSec=5s
ExecStartPre=-/usr/bin/docker stop %n
ExecStartPre=-/usr/bin/docker rm %n
ExecStart=/usr/bin/docker run \
    --name %n \
    --rm \
    -p <LISTEN_PORT>:<LISTEN_PORT> \
    -e UPSTREAM_HOST=<UPSTREAM_HOSTNAME> \
    -e UPSTREAM_PORT=<UPSTREAM_PORT> \
    -e RESOLVER_ADDRESS=169.254.169.253 \
    <ACCOUNT_ID>.dkr.ecr.<REGION>.amazonaws.com/<PROXY_NAME>:latest
ExecStop=/usr/bin/docker stop %n

[Install]
WantedBy=multi-user.target
```

Enable and start the unit:

```sh
sudo systemctl daemon-reload
sudo systemctl enable --now <PROXY_NAME>
sudo systemctl status <PROXY_NAME>
```

To update to a new image version, pull the new image and restart the unit:

```sh
docker pull <ACCOUNT_ID>.dkr.ecr.<REGION>.amazonaws.com/<PROXY_NAME>:latest
sudo systemctl restart <PROXY_NAME>
```

---

## EKS

### DNS resolver

The default `RESOLVER_ADDRESS` of `169.254.169.253` (the AWS VPC link-local DNS) works correctly from EKS pods when resolving external AWS service hostnames (RDS, ElastiCache, DocumentDB). NGINX queries the VPC DNS directly, bypassing CoreDNS — this is acceptable because these are all external hostnames, not cluster-internal service names.

If your cluster uses split-horizon DNS or a custom upstream resolver that must be consulted for AWS service names, override `RESOLVER_ADDRESS` with the CoreDNS ClusterIP instead:

```sh
kubectl get svc kube-dns -n kube-system -o jsonpath='{.spec.clusterIP}'
```

### Manifest structure

Each proxy README contains a complete all-in-one YAML manifest ready to apply. The structure used in every manifest is:

| Resource | Purpose |
|---|---|
| `ConfigMap` | Non-sensitive configuration: `LISTEN_PORT`, `UPSTREAM_PORT`, `RESOLVER_ADDRESS` |
| `Secret` | Sensitive configuration: `UPSTREAM_HOST` (and API hostnames for the weighted proxy) |
| `Deployment` | Runs 2 replicas of the proxy container; mounts env vars from the ConfigMap and Secret |
| `Service` | ClusterIP service exposing the proxy to other pods in the cluster |

The generic forms are shown below. Proxy-specific values (image name, port numbers, extra env vars) are in each proxy's own README.

**ConfigMap:**

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: <PROXY_NAME>-config
data:
  LISTEN_PORT: "<LISTEN_PORT>"
  UPSTREAM_PORT: "<UPSTREAM_PORT>"
  RESOLVER_ADDRESS: "169.254.169.253"
```

**Secret** — for production, replace the inline value with [External Secrets Operator](https://external-secrets.io/) backed by AWS Secrets Manager:

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: <PROXY_NAME>-secret
type: Opaque
stringData:
  UPSTREAM_HOST: "<UPSTREAM_HOSTNAME>"
```

**Deployment:**

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: <PROXY_NAME>
spec:
  replicas: 2
  selector:
    matchLabels:
      app: <PROXY_NAME>
  template:
    metadata:
      labels:
        app: <PROXY_NAME>
    spec:
      containers:
        - name: <PROXY_NAME>
          image: <ACCOUNT_ID>.dkr.ecr.<REGION>.amazonaws.com/<PROXY_NAME>:latest
          ports:
            - containerPort: <LISTEN_PORT>
              protocol: TCP
          envFrom:
            - configMapRef:
                name: <PROXY_NAME>-config
            - secretRef:
                name: <PROXY_NAME>-secret
          resources:
            requests:
              cpu: 50m
              memory: 64Mi
            limits:
              cpu: 200m
              memory: 128Mi
          readinessProbe:
            tcpSocket:
              port: <LISTEN_PORT>
            initialDelaySeconds: 5
            periodSeconds: 10
          livenessProbe:
            tcpSocket:
              port: <LISTEN_PORT>
            initialDelaySeconds: 10
            periodSeconds: 30
```

**Service (ClusterIP — internal cluster access):**

```yaml
apiVersion: v1
kind: Service
metadata:
  name: <PROXY_NAME>
spec:
  selector:
    app: <PROXY_NAME>
  ports:
    - port: <LISTEN_PORT>
      targetPort: <LISTEN_PORT>
      protocol: TCP
  type: ClusterIP
```

Apply and connect:

```sh
kubectl apply -f <PROXY_NAME>.yaml

# Other pods connect using the Service DNS name:
# <PROXY_NAME>.<NAMESPACE>.svc.cluster.local:<LISTEN_PORT>
```

### External access via NLB

To expose a proxy to workloads outside the cluster (e.g. EC2 instances in the same VPC connecting to a proxy running in EKS), use the [AWS Load Balancer Controller](https://kubernetes-sigs.github.io/aws-load-balancer-controller/) and change the Service type to `LoadBalancer`:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: <PROXY_NAME>
  annotations:
    service.beta.kubernetes.io/aws-load-balancer-type: external
    service.beta.kubernetes.io/aws-load-balancer-scheme: internal
    service.beta.kubernetes.io/aws-load-balancer-nlb-target-type: ip
spec:
  selector:
    app: <PROXY_NAME>
  ports:
    - port: <LISTEN_PORT>
      targetPort: <LISTEN_PORT>
      protocol: TCP
  type: LoadBalancer
```

This provisions an internal Network Load Balancer via the controller. The NLB's DNS name serves as the stable connection endpoint for clients outside the cluster. Use `internal` scheme to keep the NLB within the VPC; change to `internet-facing` only if the proxy needs to be reachable from the public internet.
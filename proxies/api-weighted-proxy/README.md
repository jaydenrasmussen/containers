# API Weighted Proxy

An NGINX HTTP reverse proxy that distributes traffic between two API backends using configurable weighted routing. All configuration is driven entirely by environment variables — no image rebuild required to adjust the traffic split.

---

## How It Works

At container startup, `entrypoint.sh` runs `envsubst` to substitute environment variables into `nginx.conf.template`, writing the resolved config to `/etc/nginx/nginx.conf`. NGINX then starts using that rendered config.

Traffic is distributed via an NGINX `upstream` block containing two servers — one for the old API and one for the new. Each server is assigned a `weight` value. NGINX routes requests proportionally: a server with weight `80` receives roughly 80% of requests while a server with weight `20` receives the remaining 20%.

```
Client → NGINX (listen :LISTEN_PORT)
              │
              ├─ weight=OLD_API_WEIGHT → OLD_API_HOST:OLD_API_PORT
              └─ weight=NEW_API_WEIGHT → NEW_API_HOST:NEW_API_PORT
```

The `envsubst` call in `entrypoint.sh` explicitly lists only the variables to substitute. This prevents NGINX's own runtime variables (e.g. `$host`, `$remote_addr`) from being accidentally replaced at startup.

---

## Files

| File | Purpose |
|---|---|
| `Dockerfile` | Builds the image from `nginx:alpine`; declares all env vars with defaults |
| `nginx.conf.template` | NGINX `http` config template with `${VAR}` placeholders |
| `entrypoint.sh` | Renders the template via `envsubst` at startup, then launches NGINX |

---

## Environment Variables

| Variable | Default | Description |
|---|---|---|
| `LISTEN_PORT` | `80` | Port the proxy listens on inside the container |
| `OLD_API_HOST` | `127.0.0.1` | Hostname or IP of the old API backend |
| `OLD_API_PORT` | `8080` | Port of the old API backend |
| `OLD_API_WEIGHT` | `50` | Routing weight for the old API |
| `NEW_API_HOST` | `127.0.0.1` | Hostname or IP of the new API backend |
| `NEW_API_PORT` | `8081` | Port of the new API backend |
| `NEW_API_WEIGHT` | `50` | Routing weight for the new API |
| `RESOLVER_ADDRESS` | `169.254.169.253` | DNS resolver NGINX uses for hostname resolution. Defaults to the AWS VPC link-local resolver. Override if running outside AWS or with a custom DNS setup. |

> **Note:** Weights are relative to each other, not strict percentages. `OLD_API_WEIGHT=3` with `NEW_API_WEIGHT=1` results in a 75% / 25% split.

---

## Build

```sh
docker build -t api-weighted-proxy .
```

---

## Run

### Default — 50 / 50 split

```sh
docker run -d \
  --name api-weighted-proxy \
  -p 80:80 \
  -e OLD_API_HOST=api.old.internal \
  -e OLD_API_PORT=80 \
  -e NEW_API_HOST=api.new.internal \
  -e NEW_API_PORT=80 \
  api-weighted-proxy
```

### Canary — 10% to the new API

```sh
docker run -d \
  --name api-weighted-proxy \
  -p 80:80 \
  -e OLD_API_HOST=api.old.internal \
  -e OLD_API_PORT=80 \
  -e OLD_API_WEIGHT=90 \
  -e NEW_API_HOST=api.new.internal \
  -e NEW_API_PORT=80 \
  -e NEW_API_WEIGHT=10 \
  api-weighted-proxy
```

### Full cutover — 100% to the new API

```sh
docker run -d \
  --name api-weighted-proxy \
  -p 80:80 \
  -e OLD_API_HOST=api.old.internal \
  -e OLD_API_PORT=80 \
  -e OLD_API_WEIGHT=0 \
  -e NEW_API_HOST=api.new.internal \
  -e NEW_API_PORT=80 \
  -e NEW_API_WEIGHT=100 \
  api-weighted-proxy
```

### Docker Compose

```yaml
services:
  api-weighted-proxy:
    build: .
    ports:
      - "80:80"
    environment:
      LISTEN_PORT: 80
      OLD_API_HOST: api.old.internal
      OLD_API_PORT: 80
      OLD_API_WEIGHT: 90
      NEW_API_HOST: api.new.internal
      NEW_API_PORT: 80
      NEW_API_WEIGHT: 10
    restart: unless-stopped
```

---

## Deployment

See [../DEPLOYING.md](../DEPLOYING.md) for full platform instructions including ECR setup, IAM roles, systemd unit files, and Security Group rules.

### ECS (Fargate)

The API proxy has additional environment variables beyond the base template in [DEPLOYING.md](../DEPLOYING.md#task-definition). Extend the `environment` and `secrets` blocks of the task definition as follows:

```json
"environment": [
  { "name": "LISTEN_PORT",      "value": "80" },
  { "name": "OLD_API_PORT",     "value": "80" },
  { "name": "OLD_API_WEIGHT",   "value": "90" },
  { "name": "NEW_API_PORT",     "value": "80" },
  { "name": "NEW_API_WEIGHT",   "value": "10" },
  { "name": "RESOLVER_ADDRESS", "value": "169.254.169.253" }
],
"secrets": [
  {
    "name": "OLD_API_HOST",
    "valueFrom": "arn:aws:ssm:<REGION>:<ACCOUNT_ID>:parameter/proxies/api-weighted-proxy/old-api-host"
  },
  {
    "name": "NEW_API_HOST",
    "valueFrom": "arn:aws:ssm:<REGION>:<ACCOUNT_ID>:parameter/proxies/api-weighted-proxy/new-api-host"
  }
]
```

Store both hostnames in SSM before deploying:

```sh
aws ssm put-parameter \
  --name /proxies/api-weighted-proxy/old-api-host \
  --value "<OLD_HOSTNAME>" \
  --type SecureString \
  --region <REGION>

aws ssm put-parameter \
  --name /proxies/api-weighted-proxy/new-api-host \
  --value "<NEW_HOSTNAME>" \
  --type SecureString \
  --region <REGION>
```

To adjust the traffic split on a running ECS service, update the task definition with the new weight values and force a new deployment:

```sh
aws ecs update-service \
  --cluster <CLUSTER> \
  --service api-weighted-proxy \
  --force-new-deployment \
  --region <REGION>
```

### EC2

Use the `docker run` commands in the [Run](#run) section above. For long-running deployments, use the systemd unit approach in [DEPLOYING.md](../DEPLOYING.md#persisting-with-systemd).

### EKS

The weights are stored in the ConfigMap so the traffic split can be updated with a patch and a rollout restart — no Secret change or image rebuild required.

```yaml
# Save as api-weighted-proxy.yaml and apply with: kubectl apply -f api-weighted-proxy.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: api-weighted-proxy-config
data:
  LISTEN_PORT: "80"
  OLD_API_PORT: "80"
  OLD_API_WEIGHT: "90"
  NEW_API_PORT: "80"
  NEW_API_WEIGHT: "10"
  RESOLVER_ADDRESS: "169.254.169.253"
---
apiVersion: v1
kind: Secret
metadata:
  name: api-weighted-proxy-secret
type: Opaque
stringData:
  OLD_API_HOST: "api.old.internal"  # Replace with your old API hostname
  NEW_API_HOST: "api.new.internal"  # Replace with your new API hostname
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: api-weighted-proxy
spec:
  replicas: 2
  selector:
    matchLabels:
      app: api-weighted-proxy
  template:
    metadata:
      labels:
        app: api-weighted-proxy
    spec:
      containers:
        - name: api-weighted-proxy
          image: <ACCOUNT_ID>.dkr.ecr.<REGION>.amazonaws.com/api-weighted-proxy:latest
          ports:
            - containerPort: 80
              protocol: TCP
          envFrom:
            - configMapRef:
                name: api-weighted-proxy-config
            - secretRef:
                name: api-weighted-proxy-secret
          resources:
            requests:
              cpu: 50m
              memory: 64Mi
            limits:
              cpu: 200m
              memory: 128Mi
          readinessProbe:
            tcpSocket:
              port: 80
            initialDelaySeconds: 5
            periodSeconds: 10
          livenessProbe:
            tcpSocket:
              port: 80
            initialDelaySeconds: 10
            periodSeconds: 30
---
apiVersion: v1
kind: Service
metadata:
  name: api-weighted-proxy
spec:
  selector:
    app: api-weighted-proxy
  ports:
    - port: 80
      targetPort: 80
      protocol: TCP
  type: ClusterIP
```

Connect from other pods using `api-weighted-proxy.<NAMESPACE>.svc.cluster.local:80`.

To adjust the traffic split on a running deployment, patch the ConfigMap and trigger a rollout:

```sh
kubectl patch configmap api-weighted-proxy-config \
  --patch '{"data": {"OLD_API_WEIGHT": "50", "NEW_API_WEIGHT": "50"}}'

kubectl rollout restart deployment/api-weighted-proxy
```

---

## Migration Workflow

Use this proxy to shift traffic incrementally from a legacy API to its replacement with zero downtime. Advance through each stage only after validating error rates and latency.

| Stage | `OLD_API_WEIGHT` | `NEW_API_WEIGHT` | Description |
|---|---|---|---|
| Baseline | `100` | `0` | All traffic on old API; proxy in place but inactive for new |
| Canary | `90` | `10` | Small slice to the new API for early validation |
| Ramp-up | `50` | `50` | Equal split for extended side-by-side observation |
| Final push | `10` | `90` | Majority on new API; old API retained as fallback |
| Cutover | `0` | `100` | Full cutover; old API can be decommissioned |

To adjust the split, update the environment variables and restart the container — no rebuild needed.

---

## Forwarded Headers

The proxy sets the following headers on every proxied request so upstream services can identify the true origin of traffic:

| Header | Value |
|---|---|
| `Host` | Original `Host` header from the client |
| `X-Real-IP` | Client IP address |
| `X-Forwarded-For` | Full client IP forwarding chain |
| `X-Forwarded-Proto` | Original request scheme (`http` or `https`) |

---

## Common Use Cases

- **API migration** — gradually shift traffic to a new API version without a hard cutover or client-side changes.
- **Blue / green deployment** — point old and new weights at blue and green environments; flip the weights to promote or roll back.
- **Canary releases** — validate a new API under a small slice of real production traffic before committing to a full rollout.
- **Shadow traffic** — temporarily set new API weight low to observe real-world behaviour without impacting the majority of users.

---

## AWS Considerations

- **Upstream DNS is resolved at startup** — unlike the TCP stream proxies in this folder, NGINX open-source resolves `upstream` block server addresses once when the config is loaded. The `resolver` directive does not change this behaviour for `upstream` blocks. If an upstream hostname changes (e.g. after a deployment or DNS update), update the env vars and restart the container to pick up the new address.
- **ELB / ALB endpoints** — if `OLD_API_HOST` or `NEW_API_HOST` point at an AWS load balancer DNS name, the resolved IP may become stale after an ELB scale event. Restart the container to force re-resolution, or use a short `proxy_connect_timeout` to fail fast and surface the issue quickly.
- **Security Groups** — the proxy container needs an outbound rule to both `OLD_API_HOST` on `OLD_API_PORT` and `NEW_API_HOST` on `NEW_API_PORT`. During migration, both rules must remain open until the cutover weight reaches `0`.
- **VPC DNS resolver** — `169.254.169.253` is the AWS link-local DNS resolver, reachable from any VPC subnet without additional routing. Override `RESOLVER_ADDRESS` if running in a non-AWS environment or behind a custom DNS server.

---

## Notes

- **Weight of `0`** — NGINX treats a server with `weight=0` as removed from the pool, making it equivalent to a full cutover without requiring a config change or rebuild.
- **HTTPS** — this proxy operates at HTTP. If upstream APIs require HTTPS, terminate TLS at a load balancer or ingress controller before traffic reaches this container, or extend `nginx.conf.template` with SSL directives.
- **Health checks** — NGINX open-source does not support active health checks in `upstream` blocks. If an upstream server is unreachable, NGINX will mark it as down after a failed attempt and retry. For proactive failure detection, consider NGINX Plus or an external health-check sidecar.
- **Logging** — NGINX error logs are written to `/var/log/nginx/error.log`. Mount this path as a volume or use a log-shipping sidecar to persist logs beyond the container lifecycle.
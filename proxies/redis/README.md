# Redis TCP Proxy

A lightweight Docker container that uses NGINX's `stream` module to create a transparent TCP proxy in front of a Redis instance. All configuration is driven by environment variables, making it suitable for use in any containerised environment.

---

## How It Works

At container startup, `entrypoint.sh` runs `envsubst` to render `nginx.conf.template` into a live `/etc/nginx/nginx.conf`, substituting the three environment variables into the NGINX `stream` block. NGINX then forwards raw TCP connections — preserving the Redis Serialization Protocol (RESP) — from the configured listen port straight through to the upstream Redis host and port.

```sh
envsubst '${LISTEN_PORT} ${UPSTREAM_HOST} ${UPSTREAM_PORT}' < /nginx.conf.template > /etc/nginx/nginx.conf
```

> **Note:** Only the variables explicitly listed in the `envsubst` call are substituted. This prevents NGINX's own `$` variables from being accidentally replaced.

Because this operates at Layer 4 (TCP), NGINX does **not** inspect or modify the Redis protocol in any way. All RESP commands, pipelining, Pub/Sub, and Lua scripts pass through transparently.

---

## Files

| File | Purpose |
|---|---|
| `Dockerfile` | Builds the image from `nginx:alpine`; sets default env var values |
| `nginx.conf.template` | NGINX `stream` config template with `${VAR}` placeholders |
| `entrypoint.sh` | Renders the template at startup via `envsubst`, then execs NGINX |

---

## Environment Variables

| Variable | Default | Description |
|---|---|---|
| `LISTEN_PORT` | `6379` | Port the proxy listens on inside the container |
| `UPSTREAM_HOST` | `127.0.0.1` | Hostname or IP address of the upstream Redis instance |
| `UPSTREAM_PORT` | `6379` | Port of the upstream Redis instance |
| `RESOLVER_ADDRESS` | `169.254.169.253` | DNS resolver used by NGINX for dynamic upstream re-resolution. Defaults to the AWS VPC link-local resolver. |

> **Note:** The default `UPSTREAM_HOST` of `127.0.0.1` is intentionally non-functional in most real deployments — always override it with the actual Redis host.

---

## Build

```sh
docker build -t redis-proxy .
```

---

## Run

### Minimal — forward local port `6379` to a remote Redis instance

```sh
docker run -d \
  -p 6379:6379 \
  -e UPSTREAM_HOST=redis.internal.example.com \
  --name redis-proxy \
  redis-proxy
```

### Custom listen port — useful when host port `6379` is already in use

```sh
docker run -d \
  -p 16379:16379 \
  -e LISTEN_PORT=16379 \
  -e UPSTREAM_HOST=redis.internal.example.com \
  -e UPSTREAM_PORT=6379 \
  --name redis-proxy \
  redis-proxy
```

### Docker Compose

```yaml
services:
  redis-proxy:
    build: .
    ports:
      - "6379:6379"
    environment:
      LISTEN_PORT: 6379
      UPSTREAM_HOST: redis.internal.example.com
      UPSTREAM_PORT: 6379
    restart: unless-stopped
```

---

## Deployment

See [../DEPLOYING.md](../DEPLOYING.md) for full platform instructions including ECR setup, IAM roles, systemd unit files, and Security Group rules.

### ECS (Fargate)

Use the [task definition template in DEPLOYING.md](../DEPLOYING.md#task-definition) with the following values:

| Placeholder | Value |
|---|---|
| `<PROXY_NAME>` | `redis-proxy` |
| `<LISTEN_PORT>` | `6379` |
| `<UPSTREAM_PORT>` | `6379` |
| `<UPSTREAM_HOSTNAME>` | ElastiCache primary endpoint, e.g. `mycluster.abc123.ng.0001.use1.cache.amazonaws.com` |

### EC2

Use the `docker run` commands in the [Run](#run) section. For long-running deployments, use the systemd unit approach in [DEPLOYING.md](../DEPLOYING.md#persisting-with-systemd).

### EKS

```yaml
# Save as redis-proxy.yaml and apply with: kubectl apply -f redis-proxy.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: redis-proxy-config
data:
  LISTEN_PORT: "6379"
  UPSTREAM_PORT: "6379"
  RESOLVER_ADDRESS: "169.254.169.253"
---
apiVersion: v1
kind: Secret
metadata:
  name: redis-proxy-secret
type: Opaque
stringData:
  UPSTREAM_HOST: "mycluster.abc123.ng.0001.use1.cache.amazonaws.com"  # Replace with your ElastiCache primary endpoint
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: redis-proxy
spec:
  replicas: 2
  selector:
    matchLabels:
      app: redis-proxy
  template:
    metadata:
      labels:
        app: redis-proxy
    spec:
      containers:
        - name: redis-proxy
          image: <ACCOUNT_ID>.dkr.ecr.<REGION>.amazonaws.com/redis-proxy:latest
          ports:
            - containerPort: 6379
              protocol: TCP
          envFrom:
            - configMapRef:
                name: redis-proxy-config
            - secretRef:
                name: redis-proxy-secret
          resources:
            requests:
              cpu: 50m
              memory: 64Mi
            limits:
              cpu: 200m
              memory: 128Mi
          readinessProbe:
            tcpSocket:
              port: 6379
            initialDelaySeconds: 5
            periodSeconds: 10
          livenessProbe:
            tcpSocket:
              port: 6379
            initialDelaySeconds: 10
            periodSeconds: 30
---
apiVersion: v1
kind: Service
metadata:
  name: redis-proxy
spec:
  selector:
    app: redis-proxy
  ports:
    - port: 6379
      targetPort: 6379
      protocol: TCP
  type: ClusterIP
```

Connect from other pods using `redis-proxy.<NAMESPACE>.svc.cluster.local:6379`.

---

## Verifying the Proxy

Once the container is running, use the Redis CLI to confirm connectivity through the proxy:

```sh
redis-cli -h 127.0.0.1 -p 6379 PING
# Expected response: PONG
```

---

## Common Use Cases

- **Network segmentation** — expose a Redis instance in a private subnet through a proxy sitting in a DMZ or shared network tier without opening direct access.
- **Port standardisation** — normalise non-standard Redis ports to the default `6379` for consuming services.
- **Migration bridging** — during a Redis instance migration, point `UPSTREAM_HOST`/`UPSTREAM_PORT` at the new instance without changing any client configuration.
- **Local development** — proxy a remote or staging Redis instance to `localhost:6379` so local services connect as if Redis were running locally.

---

## AWS / ElastiCache Considerations

- **Cluster Mode is not supported** — ElastiCache Redis in cluster mode distributes hash slots across multiple shards. After the initial connection, the Redis client receives `MOVED` and `ASK` redirects pointing directly at individual shard node endpoints, bypassing this proxy entirely. This proxy is only suitable for ElastiCache in **non-cluster mode** (single-node or a replication group accessed via its primary endpoint).
- **DNS failover** — ElastiCache replication group endpoints are DNS CNAMEs that are updated to point at the new primary during a failover or maintenance event. The `resolver` directive and variable `proxy_pass` in `nginx.conf.template` handle this by re-resolving the hostname on each new connection (within the 10-second DNS cache window) rather than at container startup only. No action is required — this is handled automatically.
- **Reader endpoint** — ElastiCache exposes a separate reader endpoint for read replicas. If your application separates reads from writes, run two instances of this proxy: one pointing `UPSTREAM_HOST` at the primary endpoint, and one pointing at the reader endpoint.
- **AUTH token** — ElastiCache can require an `AUTH` token. This is application-layer and passes through the TCP proxy transparently. Configure it on the client and the ElastiCache cluster as normal.
- **TLS in-transit** — ElastiCache supports TLS encryption in transit. Because this proxy operates at Layer 4, TLS passes through unchanged. Both the client and ElastiCache must be configured for TLS; the proxy requires no additional configuration.
- **Security Groups** — The proxy container's security group must have an outbound rule allowing TCP on `UPSTREAM_PORT` to the ElastiCache security group. The ElastiCache security group must have a corresponding inbound rule from the proxy container's security group.

---

## Notes

- **No TLS termination** — this proxy forwards raw TCP; it does not handle TLS. If your Redis instance requires TLS, place a TLS-terminating sidecar (e.g. `stunnel`) between this proxy and the upstream.
- **AUTH passthrough** — Redis `AUTH` commands pass through transparently; authentication is handled end-to-end between the client and the upstream Redis server.
- **Cluster mode** — this proxy forwards to a single upstream node. Redis Cluster clients that follow `MOVED`/`ASK` redirects will attempt to contact cluster nodes directly, which may not be routable. For cluster topologies, consider a Redis-aware proxy such as [Envoy](https://www.envoyproxy.io/) or [Twemproxy](https://github.com/twitter/twemproxy).
- **NGINX stream module** — the `nginx:alpine` base image ships with the `stream` module compiled in. No additional packages are required.
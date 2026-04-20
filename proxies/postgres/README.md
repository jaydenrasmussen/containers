# PostgreSQL TCP Proxy

A lightweight Docker container that uses NGINX's `stream` module to proxy raw TCP connections to a PostgreSQL server. All configuration is driven by environment variables — no image rebuild required when changing targets.

---

## How It Works

At container startup, `entrypoint.sh` runs `envsubst` to substitute environment variables into `nginx.conf.template`, writing the resolved config to `/etc/nginx/nginx.conf`. NGINX then starts using the `stream` block, which operates at the TCP layer — no HTTP parsing is involved. All traffic arriving on `LISTEN_PORT` is forwarded as-is to `UPSTREAM_HOST:UPSTREAM_PORT`.

```sh
# entrypoint.sh
envsubst '${LISTEN_PORT} ${UPSTREAM_HOST} ${UPSTREAM_PORT} ${RESOLVER_ADDRESS}' < /nginx.conf.template > /etc/nginx/nginx.conf
exec "$@"
```

> **Note:** `envsubst` is passed an explicit list of variable names. This prevents NGINX's own `$`-prefixed variables (e.g. `$remote_addr`) from being accidentally replaced during template rendering.

---

## Files

| File | Purpose |
|---|---|
| `Dockerfile` | Builds the image from `nginx:alpine` and sets default env var values |
| `nginx.conf.template` | NGINX `stream` config template with `${VAR}` placeholders |
| `entrypoint.sh` | Renders the template at startup then hands off to NGINX |

---

## Environment Variables

| Variable | Default | Description |
|---|---|---|
| `LISTEN_PORT` | `5432` | Port the proxy listens on inside the container |
| `UPSTREAM_HOST` | `127.0.0.1` | Hostname or IP of the upstream PostgreSQL server |
| `UPSTREAM_PORT` | `5432` | Port of the upstream PostgreSQL server |
| `RESOLVER_ADDRESS` | `169.254.169.253` | DNS resolver used for dynamic upstream hostname re-resolution. The default is the AWS VPC link-local resolver, reachable from any VPC subnet. Override when running outside AWS or with a custom DNS setup. |

> **Note:** The default `UPSTREAM_HOST` of `127.0.0.1` is intentionally non-functional in most real deployments — always override it with the actual target address.

---

## Build

```sh
docker build -t postgres-proxy .
```

---

## Run

### Minimal — proxy to a PostgreSQL host on the default port

```sh
docker run -d \
  --name postgres-proxy \
  -p 5432:5432 \
  -e UPSTREAM_HOST=my-postgres.internal \
  postgres-proxy
```

### Custom ports — listen on 15432, forward to a non-standard upstream port

```sh
docker run -d \
  --name postgres-proxy \
  -p 15432:15432 \
  -e LISTEN_PORT=15432 \
  -e UPSTREAM_HOST=my-postgres.internal \
  -e UPSTREAM_PORT=5433 \
  postgres-proxy
```

### Docker Compose

```yaml
services:
  postgres-proxy:
    build: .
    ports:
      - "5432:5432"
    environment:
      LISTEN_PORT: "5432"
      UPSTREAM_HOST: my-postgres.internal
      UPSTREAM_PORT: "5432"
    restart: unless-stopped
```

---

## Deployment

See [../DEPLOYING.md](../DEPLOYING.md) for full platform instructions covering ECR setup, IAM roles, systemd unit files, and Security Group rules. Proxy-specific values and ready-to-use manifests for this proxy are below.

### ECS (Fargate)

Use the [task definition template in DEPLOYING.md](../DEPLOYING.md#task-definition) substituting the following values:

| Placeholder | Value |
|---|---|
| `<PROXY_NAME>` | `postgres-proxy` |
| `<LISTEN_PORT>` | `5432` |
| `<UPSTREAM_PORT>` | `5432` |
| `<UPSTREAM_HOSTNAME>` | Your RDS endpoint, e.g. `mydb.cluster-abc.us-east-1.rds.amazonaws.com` |

Store `UPSTREAM_HOST` in SSM Parameter Store at `/proxies/postgres-proxy/upstream-host`.

### EC2

Use the `docker run` commands in the [Run](#run) section above. For a long-running deployment use the systemd unit approach described in [DEPLOYING.md](../DEPLOYING.md#persisting-with-systemd).

### EKS

Save the following as `postgres-proxy.yaml` and apply with `kubectl apply -f postgres-proxy.yaml`. The Deployment runs 2 replicas; the Service exposes the proxy internally on port `5432`.

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: postgres-proxy-config
data:
  LISTEN_PORT: "5432"
  UPSTREAM_PORT: "5432"
  RESOLVER_ADDRESS: "169.254.169.253"
---
apiVersion: v1
kind: Secret
metadata:
  name: postgres-proxy-secret
type: Opaque
stringData:
  UPSTREAM_HOST: "mydb.cluster-abc.us-east-1.rds.amazonaws.com"  # Replace with your RDS endpoint
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: postgres-proxy
spec:
  replicas: 2
  selector:
    matchLabels:
      app: postgres-proxy
  template:
    metadata:
      labels:
        app: postgres-proxy
    spec:
      containers:
        - name: postgres-proxy
          image: <ACCOUNT_ID>.dkr.ecr.<REGION>.amazonaws.com/postgres-proxy:latest
          ports:
            - containerPort: 5432
              protocol: TCP
          envFrom:
            - configMapRef:
                name: postgres-proxy-config
            - secretRef:
                name: postgres-proxy-secret
          resources:
            requests:
              cpu: 50m
              memory: 64Mi
            limits:
              cpu: 200m
              memory: 128Mi
          readinessProbe:
            tcpSocket:
              port: 5432
            initialDelaySeconds: 5
            periodSeconds: 10
          livenessProbe:
            tcpSocket:
              port: 5432
            initialDelaySeconds: 10
            periodSeconds: 30
---
apiVersion: v1
kind: Service
metadata:
  name: postgres-proxy
spec:
  selector:
    app: postgres-proxy
  ports:
    - port: 5432
      targetPort: 5432
      protocol: TCP
  type: ClusterIP
```

Connect from other pods using `postgres-proxy.<NAMESPACE>.svc.cluster.local:5432`.

---

## Inspecting the Rendered Config

To verify the NGINX configuration that was generated at runtime:

```sh
docker exec postgres-proxy cat /etc/nginx/nginx.conf
```

---

## Logs

NGINX error logs are written to `/var/log/nginx/error.log` at `notice` level and are accessible via:

```sh
docker logs postgres-proxy
```

Upstream connection failures and refused connections will appear here.

---

## Common Use Cases

- **Cross-network bridging** — expose a PostgreSQL instance in a private network through a container in a DMZ or shared network.
- **Port remapping** — map a non-standard upstream port to the standard `5432` so clients need no reconfiguration.
- **Environment abstraction** — use the same application config across environments by pointing `UPSTREAM_HOST` at the appropriate database per environment.
- **Local development** — proxy a remote or Kubernetes-hosted PostgreSQL instance to `localhost:5432` for local tooling.
- **Sidecar proxying** — deploy alongside an application container in a Compose stack to provide a stable `localhost` address for the database.

---

## AWS / RDS Considerations

### DNS failover (RDS Multi-AZ and Aurora)

RDS Multi-AZ and Aurora cluster endpoints are DNS CNAMEs. On failover, AWS updates the CNAME to point at the new primary instance. The `resolver` directive in `nginx.conf.template` combined with the `set $upstream` variable forces NGINX to re-resolve the hostname on every new connection (with a 10-second cache window), so the proxy automatically follows the updated CNAME without a restart.

The default `RESOLVER_ADDRESS` of `169.254.169.253` is the AWS VPC link-local DNS resolver and is reachable from any subnet. No additional configuration is needed for standard VPC deployments.

### RDS Proxy

If the deployment uses [AWS RDS Proxy](https://aws.amazon.com/rds/proxy/) in front of RDS, set `UPSTREAM_HOST` to the RDS Proxy endpoint rather than the RDS instance endpoint. RDS Proxy handles connection pooling and failover internally, making this combination particularly resilient at high concurrency.

### Connection limits

RDS PostgreSQL instances enforce a `max_connections` limit based on instance class memory (e.g. a `db.t3.micro` allows roughly 85 connections). This proxy does **no connection pooling** — every application connection becomes a direct backend connection. For high-concurrency workloads, place [PgBouncer](https://www.pgbouncer.org/) or RDS Proxy between the application and this proxy to pool connections before they reach RDS.

### IAM authentication

RDS IAM database authentication generates short-lived tokens (15-minute lifetime) that the application uses as a password. The proxy is fully transparent to this — tokens travel inside the TCP stream and are never seen by NGINX. The application is responsible for refreshing tokens before they expire.

### SSL / TLS

RDS PostgreSQL can enforce SSL via the `rds.force_ssl` parameter group setting. The proxy forwards raw TCP bytes and is transparent to TLS — the TLS handshake occurs end-to-end between the client and RDS. If SSL is enforced, ensure the client is configured with `sslmode=require` (or stricter) and has the [RDS CA certificate bundle](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/UsingWithRDS.SSL.html) in its trust store.

---

## Notes

- This proxy is **protocol-transparent** — it forwards raw TCP bytes and has no awareness of the PostgreSQL wire protocol. TLS/SSL passthrough works without any additional configuration.
- The NGINX `stream` module (`ngx_stream_module`) is included in the `nginx:alpine` base image — no extra packages are needed.
- There is no connection pooling at the proxy layer. For connection pooling, place [PgBouncer](https://www.pgbouncer.org/) in front of the upstream PostgreSQL server.
- `worker_processes auto` scales NGINX workers to the number of available CPU cores on the host.
- For production use, consider adding `proxy_connect_timeout` and `proxy_timeout` directives to the `stream` server block to bound connection and idle timeouts.
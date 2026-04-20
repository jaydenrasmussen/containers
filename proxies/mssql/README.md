# MSSQL TCP Proxy

A lightweight Docker container that uses NGINX's `stream` module to act as a transparent TCP proxy in front of a Microsoft SQL Server instance. All configuration is driven by environment variables, making it suitable for use in any containerised environment.

---

## How It Works

1. **`Dockerfile`** — Builds from `nginx:alpine`, sets default environment variables, copies in the config template and entrypoint script, and marks the entrypoint executable.
2. **`entrypoint.sh`** — At container startup, `envsubst` replaces the `${...}` placeholders in `nginx.conf.template` with the current environment variable values and writes the result to `/etc/nginx/nginx.conf`. NGINX is then started via `exec "$@"`.
3. **`nginx.conf.template`** — Defines a single `stream` server block that listens on `LISTEN_PORT` and forwards all raw TCP traffic to `UPSTREAM_HOST:UPSTREAM_PORT`.

Because the proxy operates at the TCP (Layer 4) level via the `stream` module, it is completely protocol-agnostic — it forwards the raw TDS (Tabular Data Stream) bytes that MSSQL uses without any HTTP parsing or SSL termination.

> **Note:** `envsubst` is passed an explicit list of variable names. This prevents any other `$` expressions in the config from being accidentally replaced.

---

## Files

| File | Purpose |
|---|---|
| `Dockerfile` | Builds the image from `nginx:alpine` and sets default env var values |
| `nginx.conf.template` | NGINX `stream` config template with `${VAR}` placeholders |
| `entrypoint.sh` | Resolves the template at startup then hands off to NGINX |

---

## Environment Variables

| Variable           | Default           | Description                                              |
|--------------------|-------------------|----------------------------------------------------------|
| `LISTEN_PORT`      | `1433`            | Port the NGINX proxy listens on inside the container     |
| `UPSTREAM_HOST`    | `127.0.0.1`       | Hostname or IP address of the target MSSQL server        |
| `UPSTREAM_PORT`    | `1433`            | Port of the target MSSQL server                          |
| `RESOLVER_ADDRESS` | `169.254.169.253` | DNS resolver used for dynamic upstream hostname resolution. The default is the AWS VPC link-local resolver, reachable from any VPC subnet. Override if running outside AWS or using a custom DNS setup. |

> **Note:** The defaults mirror the standard MSSQL port (`1433`). Always override `UPSTREAM_HOST` in real deployments — the default `127.0.0.1` is intentionally non-functional outside of local testing.

---

## Build

```sh
docker build -t mssql-proxy .
```

---

## Run

### Minimal — proxy to a remote MSSQL host

```sh
docker run -d \
  --name mssql-proxy \
  -p 1433:1433 \
  -e UPSTREAM_HOST=mssql.internal.example.com \
  mssql-proxy
```

Clients connect to `localhost:1433` and traffic is forwarded transparently to `mssql.internal.example.com:1433`.

### Custom ports — remap the listen port

```sh
docker run -d \
  --name mssql-proxy \
  -p 11433:11433 \
  -e LISTEN_PORT=11433 \
  -e UPSTREAM_HOST=mssql.internal.example.com \
  -e UPSTREAM_PORT=1433 \
  mssql-proxy
```

### Docker Compose

```yaml
services:
  mssql-proxy:
    build: .
    ports:
      - "1433:1433"
    environment:
      LISTEN_PORT: 1433
      UPSTREAM_HOST: mssql.internal.example.com
      UPSTREAM_PORT: 1433
    restart: unless-stopped
```

---

## Deployment

See [../DEPLOYING.md](../DEPLOYING.md) for full platform instructions including ECR setup, IAM roles, systemd unit files, and Security Group configuration.

### ECS (Fargate)

Use the [task definition template in DEPLOYING.md](../DEPLOYING.md#task-definition) substituting the following values:

| Placeholder | Value |
|---|---|
| `<PROXY_NAME>` | `mssql-proxy` |
| `<LISTEN_PORT>` | `1433` |
| `<UPSTREAM_PORT>` | `1433` |
| `<UPSTREAM_HOSTNAME>` | RDS for SQL Server endpoint, e.g. `mydb.xxxx.us-east-1.rds.amazonaws.com` |

Store the endpoint in SSM before deploying:

```sh
aws ssm put-parameter \
  --name /proxies/mssql-proxy/upstream-host \
  --value "mydb.xxxx.us-east-1.rds.amazonaws.com" \
  --type SecureString
```

### EC2

Use the `docker run` commands in the [Run](#run) section above. For long-running deployments, use the systemd unit approach in [DEPLOYING.md](../DEPLOYING.md#persisting-with-systemd), substituting `<PROXY_NAME>` with `mssql-proxy` and `<LISTEN_PORT>` with `1433`.

### EKS

Save as `mssql-proxy.yaml` and apply with `kubectl apply -f mssql-proxy.yaml`:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: mssql-proxy-config
data:
  LISTEN_PORT: "1433"
  UPSTREAM_PORT: "1433"
  RESOLVER_ADDRESS: "169.254.169.253"
---
apiVersion: v1
kind: Secret
metadata:
  name: mssql-proxy-secret
type: Opaque
stringData:
  UPSTREAM_HOST: "mydb.xxxx.us-east-1.rds.amazonaws.com"  # Replace with your RDS endpoint
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: mssql-proxy
spec:
  replicas: 2
  selector:
    matchLabels:
      app: mssql-proxy
  template:
    metadata:
      labels:
        app: mssql-proxy
    spec:
      containers:
        - name: mssql-proxy
          image: <ACCOUNT_ID>.dkr.ecr.<REGION>.amazonaws.com/mssql-proxy:latest
          ports:
            - containerPort: 1433
              protocol: TCP
          envFrom:
            - configMapRef:
                name: mssql-proxy-config
            - secretRef:
                name: mssql-proxy-secret
          resources:
            requests:
              cpu: 50m
              memory: 64Mi
            limits:
              cpu: 200m
              memory: 128Mi
          readinessProbe:
            tcpSocket:
              port: 1433
            initialDelaySeconds: 5
            periodSeconds: 10
          livenessProbe:
            tcpSocket:
              port: 1433
            initialDelaySeconds: 10
            periodSeconds: 30
---
apiVersion: v1
kind: Service
metadata:
  name: mssql-proxy
spec:
  selector:
    app: mssql-proxy
  ports:
    - port: 1433
      targetPort: 1433
      protocol: TCP
  type: ClusterIP
```

Connect from other pods using `mssql-proxy.<NAMESPACE>.svc.cluster.local:1433`.

---

## Common Use Cases

- **Network segmentation** — Expose a single proxy endpoint to an application tier while keeping the real MSSQL host on a private network segment.
- **Port mapping** — Present MSSQL on a non-standard port externally while maintaining the standard `1433` port internally (or vice versa).
- **Service abstraction** — Decouple application connection strings from the physical MSSQL host, allowing the backend to be migrated or swapped without redeploying applications — just update `UPSTREAM_HOST` and restart the proxy.
- **Local development** — Tunnel a remote, VPN-accessible MSSQL instance to `localhost:1433` inside a dev container.

---

## AWS / RDS for SQL Server Considerations

### DNS failover (RDS Multi-AZ)
RDS for SQL Server Multi-AZ uses a CNAME endpoint (e.g. `mydb.xxxx.us-east-1.rds.amazonaws.com`). On failover, AWS updates the CNAME to point at the standby instance. The proxy handles this correctly — `RESOLVER_ADDRESS` is set to the VPC DNS resolver and `proxy_pass` uses a variable, so NGINX re-resolves the hostname on every new connection rather than caching the IP at startup.

The `valid=10s` resolver cache means NGINX will detect a failover within 10 seconds of the DNS record changing. Active connections at the time of failover will be dropped and must be re-established by the application.

### TLS enforcement
RDS for SQL Server sets `rds.force_ssl=1` by default, meaning the server rejects unencrypted connections. The proxy is transparent to this — TLS is negotiated end-to-end between the client and the RDS instance. Clients must include `Encrypt=True;TrustServerCertificate=False` in their connection string and trust the [Amazon RDS CA certificate](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/UsingWithRDS.SSL.html).

### Connection limits
RDS for SQL Server has a hard connection limit based on instance class. The proxy does not pool connections — each application connection maps directly to one RDS connection. At high concurrency, consider placing [RDS Proxy](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/rds-proxy.html) between this proxy and the RDS instance. Set `UPSTREAM_HOST` to the RDS Proxy endpoint rather than the RDS instance endpoint directly.

### Named instances
RDS for SQL Server does not use named instances or the SQL Server Browser service. The instance always listens on a fixed port (`1433` by default). Set `UPSTREAM_PORT` to the port shown in the RDS console and leave named-instance resolution to the application layer.

### Security Groups
The proxy container's security group must allow:
- **Inbound** on `LISTEN_PORT` from the application tier's security group
- **Outbound** on `UPSTREAM_PORT` to the RDS instance's (or RDS Proxy's) security group

The RDS security group must explicitly allow inbound traffic on port `1433` from the proxy container's security group.

---

## Notes

- **TLS / SSL** — This proxy forwards raw TCP bytes and does not terminate or inspect TLS. If your MSSQL connection uses `Encrypt=True`, the TLS handshake happens end-to-end between the client and the upstream server; the proxy is transparent to it.
- **Named instances** — MSSQL named instances typically rely on the SQL Server Browser service (UDP `1434`) for port resolution. This proxy handles TCP only. If using a named instance, resolve the dynamic port first and set `UPSTREAM_PORT` explicitly.
- **Connection limits** — The NGINX `events.worker_connections` value is set to `1024`. For high-concurrency workloads, build a custom image with this value increased.
- **Logging** — NGINX error logs are written to `/var/log/nginx/error.log` at `notice` level. Stream access logging is not enabled by default; add an `access_log` directive to the `stream` block if needed.
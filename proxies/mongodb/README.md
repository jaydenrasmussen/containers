# MongoDB TCP Proxy

A lightweight Docker container that uses NGINX's `stream` module to proxy raw TCP connections to a MongoDB instance. All configuration is driven by environment variables — no image rebuild is required when changing targets.

---

## How It Works

At container startup, `entrypoint.sh` runs `envsubst` to render `nginx.conf.template` into `/etc/nginx/nginx.conf`, substituting the four environment variable placeholders. NGINX then launches using the `stream` block, which operates at the TCP layer (Layer 4) and forwards raw bytes without any protocol-level inspection.

```
Client → [LISTEN_PORT] → NGINX stream proxy → UPSTREAM_HOST:UPSTREAM_PORT
```

`envsubst` is passed an explicit list of variable names to substitute, which prevents NGINX's own `$variables` (e.g. `$remote_addr`) from being accidentally replaced.

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
| `LISTEN_PORT` | `27017` | Port the proxy listens on inside the container |
| `UPSTREAM_HOST` | `127.0.0.1` | Hostname or IP address of the target MongoDB instance |
| `UPSTREAM_PORT` | `27017` | Port of the target MongoDB instance |
| `RESOLVER_ADDRESS` | `169.254.169.253` | DNS resolver used by NGINX for upstream hostname resolution. The default is the AWS VPC link-local DNS resolver, reachable from any VPC subnet. Override if running outside AWS or in a custom DNS environment. |

> **Note:** The default `UPSTREAM_HOST` of `127.0.0.1` is intentionally non-functional in most deployments. Always override it with the real MongoDB host.

---

## Build

```sh
docker build -t mongodb-proxy .
```

---

## Run

### Minimal — proxy to a remote MongoDB instance

```sh
docker run -d \
  --name mongodb-proxy \
  -p 27017:27017 \
  -e UPSTREAM_HOST=mongo.internal.example.com \
  mongodb-proxy
```

### Custom ports — listen on a non-standard port, forward to the default upstream port

```sh
docker run -d \
  --name mongodb-proxy \
  -p 37017:37017 \
  -e LISTEN_PORT=37017 \
  -e UPSTREAM_HOST=mongo.internal.example.com \
  -e UPSTREAM_PORT=27017 \
  mongodb-proxy
```

### Docker Compose

```yaml
services:
  mongodb-proxy:
    build: .
    ports:
      - "27017:27017"
    environment:
      LISTEN_PORT: 27017
      UPSTREAM_HOST: mongo.internal.example.com
      UPSTREAM_PORT: 27017
      RESOLVER_ADDRESS: 169.254.169.253
    restart: unless-stopped
```

---

## Deployment

See [../DEPLOYING.md](../DEPLOYING.md) for full platform instructions including ECR setup, IAM roles, Security Group rules, and systemd unit configuration for EC2.

### ECS (Fargate)

Use the [task definition template in DEPLOYING.md](../DEPLOYING.md#task-definition) with these values:

| Placeholder | Value |
|---|---|
| `<PROXY_NAME>` | `mongodb-proxy` |
| `<LISTEN_PORT>` | `27017` |
| `<UPSTREAM_PORT>` | `27017` |
| `<UPSTREAM_HOSTNAME>` | DocumentDB cluster endpoint, e.g. `mycluster.cluster-abc.us-east-1.docdb.amazonaws.com` |

### EC2

Use the `docker run` commands in the [Run](#run) section above. For a long-running instance use the [systemd unit approach](../DEPLOYING.md#persisting-with-systemd) in DEPLOYING.md.

### EKS

Save the following as `mongodb-proxy.yaml` and apply with `kubectl apply -f mongodb-proxy.yaml`:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: mongodb-proxy-config
data:
  LISTEN_PORT: "27017"
  UPSTREAM_PORT: "27017"
  RESOLVER_ADDRESS: "169.254.169.253"
---
apiVersion: v1
kind: Secret
metadata:
  name: mongodb-proxy-secret
type: Opaque
stringData:
  UPSTREAM_HOST: "mycluster.cluster-abc.us-east-1.docdb.amazonaws.com"  # Replace with your DocumentDB cluster endpoint
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: mongodb-proxy
spec:
  replicas: 2
  selector:
    matchLabels:
      app: mongodb-proxy
  template:
    metadata:
      labels:
        app: mongodb-proxy
    spec:
      containers:
        - name: mongodb-proxy
          image: <ACCOUNT_ID>.dkr.ecr.<REGION>.amazonaws.com/mongodb-proxy:latest
          ports:
            - containerPort: 27017
              protocol: TCP
          envFrom:
            - configMapRef:
                name: mongodb-proxy-config
            - secretRef:
                name: mongodb-proxy-secret
          resources:
            requests:
              cpu: 50m
              memory: 64Mi
            limits:
              cpu: 200m
              memory: 128Mi
          readinessProbe:
            tcpSocket:
              port: 27017
            initialDelaySeconds: 5
            periodSeconds: 10
          livenessProbe:
            tcpSocket:
              port: 27017
            initialDelaySeconds: 10
            periodSeconds: 30
---
apiVersion: v1
kind: Service
metadata:
  name: mongodb-proxy
spec:
  selector:
    app: mongodb-proxy
  ports:
    - port: 27017
      targetPort: 27017
      protocol: TCP
  type: ClusterIP
```

Connect from other pods using `mongodb-proxy.<NAMESPACE>.svc.cluster.local:27017`.

> **DocumentDB connection string:** Always include `directConnection=true` and `retryWrites=false` when connecting through this proxy to DocumentDB. Without `directConnection=true` the MongoDB driver will attempt to reach individual replica set instance endpoints directly, bypassing the proxy entirely. See [AWS / DocumentDB Considerations](#aws--documentdb-considerations) for full details.

---

## Inspecting the Rendered Config

To verify the NGINX configuration generated at runtime:

```sh
docker exec mongodb-proxy cat /etc/nginx/nginx.conf
```

---

## Logs

NGINX error logs are written to stdout/stderr and are accessible via:

```sh
docker logs mongodb-proxy
```

The error log level is set to `notice` by default. Upstream connection failures and refused connections will appear here.

---

## Common Use Cases

- **Network segmentation** — expose a MongoDB instance in a private subnet through a proxy without opening direct access to the data tier.
- **Port remapping** — present MongoDB on a non-standard port externally while keeping the standard `27017` internally (or vice versa).
- **Service abstraction** — decouple application connection strings from the physical MongoDB host, allowing the backend to be swapped without redeploying applications.
- **Local development** — proxy a remote or staging MongoDB instance to `localhost:27017` so local services connect as if it were running locally.

---

## AWS / DocumentDB Considerations

Amazon DocumentDB presents a MongoDB-compatible API but has several important differences from self-hosted MongoDB that affect how this proxy should be configured.

### Replica set topology discovery
This is the most critical issue. When a MongoDB driver connects, it issues a `hello`/`isMaster` command and attempts to discover all replica set members. DocumentDB presents itself as a replica set named `rs0` and returns the individual instance endpoints (e.g. `docdb-instance-1.abc.us-east-1.docdb.amazonaws.com`) as replica set members. The driver will then attempt to connect to each instance endpoint **directly**, completely bypassing this proxy for all non-primary connections.

To prevent this, the client connection string must use `directConnection=true`:

```
mongodb://proxy-host:27017/mydb?directConnection=true&retryWrites=false
```

**Do not** use a multi-host connection string (e.g. `mongodb://host1,host2/`) when connecting through this proxy — the driver will route traffic around it.

### `retryWrites=false` is required
DocumentDB does not support MongoDB retryable writes. All client connection strings must include `retryWrites=false` or connections will be rejected with an error.

### TLS is required
DocumentDB enables in-transit encryption by default. The proxy passes TLS through transparently at the TCP layer, but clients must have the **Amazon DocumentDB CA certificate bundle** in their trust store. Download it from AWS:

```sh
wget https://truststore.pki.rds.amazonaws.com/global/global-bundle.pem
```

Then reference it in the connection string:
```
mongodb://proxy-host:27017/mydb?tls=true&tlsCAFile=/path/to/global-bundle.pem&directConnection=true&retryWrites=false
```

### DNS failover
DocumentDB uses a CNAME cluster endpoint (e.g. `mycluster.cluster-abc.us-east-1.docdb.amazonaws.com`) that is updated during failover. The `resolver` directive in `nginx.conf.template` ensures NGINX re-resolves the hostname every 10 seconds rather than caching the IP at startup. Set `UPSTREAM_HOST` to the **cluster endpoint** (not an individual instance endpoint) to benefit from this.

### Feature compatibility
DocumentDB does not implement the full MongoDB API. Notably missing or incompatible features include some aggregation pipeline operators, `$where`, `$eval`, text search indexes, and certain BSON types. Validate your application's queries against the [DocumentDB compatibility matrix](https://docs.aws.amazon.com/documentdb/latest/developerguide/mongo-apis.html) before routing production traffic through this proxy.

### Security Groups
The proxy container requires:
- **Inbound**: from the application tier on `LISTEN_PORT` (`27017` by default)
- **Outbound**: to the DocumentDB cluster security group on `UPSTREAM_PORT` (`27017` by default)

The DocumentDB cluster security group must allow inbound traffic from the proxy container's security group.

---

## Notes

- **Replica sets & sharded clusters** — Connection strings that enumerate multiple hosts (e.g. `mongodb://host1,host2,host3/`) cause the MongoDB driver to connect to each listed address directly, bypassing this proxy for secondary addresses. Point the client connection string at the proxy host only; the proxy connects to a single primary or `mongos` node.
- **TLS passthrough** — Because the proxy operates at Layer 4, TLS (including mutual TLS) passes through unchanged. Configure TLS on the MongoDB server and client as normal.
- **Authentication** — Credentials are never seen or stored by the proxy; they travel inside the TCP stream directly to the upstream server.
- **Protocol transparency** — The proxy has no awareness of the MongoDB wire protocol. It is compatible with all MongoDB-compatible servers including DocumentDB (with direct connections).
- **Logging** — Stream access logging is not enabled by default. Add a `log_format` and `access_log` directive inside the `stream {}` block of `nginx.conf.template` if connection-level logging is needed.
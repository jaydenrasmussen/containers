# MySQL TCP Proxy

A lightweight Docker container that uses NGINX's `stream` module to proxy raw TCP traffic to a MySQL server. All configuration is driven entirely by environment variables — no image rebuild required when changing targets.

---

## How It Works

At container startup, `entrypoint.sh` runs `envsubst` to substitute environment variables into `nginx.conf.template`, writing the resolved config to `/etc/nginx/nginx.conf`. NGINX then starts using the `stream` block, which operates at the TCP layer — no HTTP parsing is involved. All traffic arriving on `LISTEN_PORT` is forwarded as-is to `UPSTREAM_HOST:UPSTREAM_PORT`.

```sh
# entrypoint.sh
envsubst '${LISTEN_PORT} ${UPSTREAM_HOST} ${UPSTREAM_PORT} ${RESOLVER_ADDRESS}' \
  < /nginx.conf.template \
  > /etc/nginx/nginx.conf
exec "$@"
```

> **Note:** `envsubst` is passed an explicit list of variable names. This prevents NGINX's own `$`-prefixed variables (e.g. `$remote_addr`) from being accidentally replaced.

---

## Files

| File | Purpose |
|---|---|
| `Dockerfile` | Builds the image from `nginx:alpine` and sets default env var values |
| `nginx.conf.template` | NGINX `stream` config template with `${VAR}` placeholders |
| `entrypoint.sh` | Resolves the template at startup then hands off to NGINX |

---

## Environment Variables

| Variable | Default | Description |
|---|---|---|
| `LISTEN_PORT` | `3306` | Port the proxy listens on inside the container |
| `UPSTREAM_HOST` | `127.0.0.1` | Hostname or IP of the upstream MySQL server |
| `UPSTREAM_PORT` | `3306` | Port of the upstream MySQL server |
| `RESOLVER_ADDRESS` | `169.254.169.253` | DNS resolver used by NGINX to re-resolve the upstream hostname on each new connection. The default is the AWS VPC link-local resolver, reachable from any VPC subnet. Override if running outside AWS or with a custom DNS setup. |

> **Note:** The default `UPSTREAM_HOST` of `127.0.0.1` is intentionally non-functional in most deployments. Always override it with the real target address.

---

## Build

```sh
docker build -t mysql-proxy .
```

---

## Run

### Minimal — proxy to a MySQL host on the default port

```sh
docker run -d \
  --name mysql-proxy \
  -p 3306:3306 \
  -e UPSTREAM_HOST=my-mysql.internal \
  mysql-proxy
```

### Custom ports — listen on 13306, forward to a non-standard upstream port

```sh
docker run -d \
  --name mysql-proxy \
  -p 13306:13306 \
  -e LISTEN_PORT=13306 \
  -e UPSTREAM_HOST=my-mysql.internal \
  -e UPSTREAM_PORT=3307 \
  mysql-proxy
```

### Docker Compose

```yaml
services:
  mysql-proxy:
    build: .
    ports:
      - "3306:3306"
    environment:
      LISTEN_PORT: "3306"
      UPSTREAM_HOST: my-mysql.internal
      UPSTREAM_PORT: "3306"
    restart: unless-stopped
```

---

## Deployment

See [../DEPLOYING.md](../DEPLOYING.md) for full platform instructions including ECR setup, IAM roles, systemd unit files, and Security Group rules.

### ECS (Fargate)

Use the [task definition template in DEPLOYING.md](../DEPLOYING.md#task-definition) with the following values:

| Placeholder | Value |
|---|---|
| `<PROXY_NAME>` | `mysql-proxy` |
| `<LISTEN_PORT>` | `3306` |
| `<UPSTREAM_PORT>` | `3306` |
| `<UPSTREAM_HOSTNAME>` | Your RDS endpoint, e.g. `mydb.cluster-abc.us-east-1.rds.amazonaws.com` |

### EC2

Use the `docker run` commands in the [Run](#run) section above. For long-running instances, use the systemd unit approach described in [DEPLOYING.md](../DEPLOYING.md#persisting-with-systemd).

### EKS

Save the following as `mysql-proxy.yaml` and apply with `kubectl apply -f mysql-proxy.yaml`. Replace `<ACCOUNT_ID>` and `<REGION>` with your values.

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: mysql-proxy-config
data:
  LISTEN_PORT: "3306"
  UPSTREAM_PORT: "3306"
  RESOLVER_ADDRESS: "169.254.169.253"
---
apiVersion: v1
kind: Secret
metadata:
  name: mysql-proxy-secret
type: Opaque
stringData:
  UPSTREAM_HOST: "mydb.cluster-abc.us-east-1.rds.amazonaws.com" # Replace with your RDS endpoint
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: mysql-proxy
spec:
  replicas: 2
  selector:
    matchLabels:
      app: mysql-proxy
  template:
    metadata:
      labels:
        app: mysql-proxy
    spec:
      containers:
        - name: mysql-proxy
          image: <ACCOUNT_ID>.dkr.ecr.<REGION>.amazonaws.com/mysql-proxy:latest
          ports:
            - containerPort: 3306
              protocol: TCP
          envFrom:
            - configMapRef:
                name: mysql-proxy-config
            - secretRef:
                name: mysql-proxy-secret
          resources:
            requests:
              cpu: 50m
              memory: 64Mi
            limits:
              cpu: 200m
              memory: 128Mi
          readinessProbe:
            tcpSocket:
              port: 3306
            initialDelaySeconds: 5
            periodSeconds: 10
          livenessProbe:
            tcpSocket:
              port: 3306
            initialDelaySeconds: 10
            periodSeconds: 30
---
apiVersion: v1
kind: Service
metadata:
  name: mysql-proxy
spec:
  selector:
    app: mysql-proxy
  ports:
    - port: 3306
      targetPort: 3306
      protocol: TCP
  type: ClusterIP
```

Connect from other pods using `mysql-proxy.<NAMESPACE>.svc.cluster.local:3306`.

---

## Common Use Cases

- **Network bridging** — expose a MySQL instance on a private network through a container in a shared or DMZ network tier.
- **Port remapping** — present MySQL on a non-standard port externally while keeping the standard `3306` internally (or vice versa).
- **Service abstraction** — decouple application connection strings from the physical host; swap the backend by updating `UPSTREAM_HOST` and restarting the container.
- **Local development** — proxy a remote or staging MySQL instance to `localhost:3306` so local services connect as if the database were running locally.

---

## AWS / RDS Considerations

### DNS failover (RDS Multi-AZ and Aurora)

RDS Multi-AZ and Aurora use a DNS CNAME as their connection endpoint. On failover, AWS updates that CNAME to point at the new primary — typically within 60–120 seconds. Without the `resolver` directive and `set $upstream` variable in `nginx.conf.template`, NGINX would resolve the hostname once at startup and cache the IP indefinitely, meaning it would keep hitting the dead instance until the container was restarted.

The `resolver ${RESOLVER_ADDRESS} valid=10s` directive combined with assigning the upstream to a variable forces NGINX to re-resolve the hostname on each new connection (with a 10-second DNS cache). This means failover is transparent to the proxy within one DNS TTL window.

### RDS Proxy

If the deployment uses [AWS RDS Proxy](https://aws.amazon.com/rds/proxy/) in front of RDS, point `UPSTREAM_HOST` at the RDS Proxy endpoint rather than the RDS instance endpoint directly. RDS Proxy handles connection pooling and failover internally and presents a stable endpoint.

```sh
-e UPSTREAM_HOST=my-proxy.proxy-xxxxxxxxxxxx.us-east-1.rds.amazonaws.com
```

### Connection limits

RDS instances enforce a hard `max_connections` limit based on instance memory. This proxy adds no connection pooling — each application connection becomes a direct database connection. At high concurrency, connections can be exhausted. Mitigations:

- Use **RDS Proxy** (AWS managed, supports IAM auth and connection pooling).
- Use **ProxySQL** deployed upstream of this proxy for query-aware pooling.

### IAM authentication

RDS IAM database authentication generates short-lived tokens (15-minute lifetime) at the application layer. The proxy is transparent to this — tokens travel inside the MySQL protocol and are never seen or stored by the proxy.

### TLS

RDS can be configured to enforce SSL connections via the `require_secure_transport` parameter. The proxy is transparent to TLS since it operates at the TCP layer. Clients must have the [Amazon RDS CA bundle](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/UsingWithRDS.SSL.html) in their trust store.

### Security Groups

The proxy container requires the following rules:

| Direction | Source / Destination | Port |
|---|---|---|
| Inbound | Application tier security group | `LISTEN_PORT` |
| Outbound | RDS security group | `UPSTREAM_PORT` |

The RDS security group must allow inbound traffic from the proxy container's security group on port `3306`.

---

## Notes

- The base image is `nginx:alpine`. The `stream` module is included by default in the official NGINX Alpine image — no additional packages are required.
- This proxy is **protocol-transparent**. It does not inspect or modify MySQL traffic; TLS, authentication, and compression are all handled end-to-end between the client and the upstream server.
- Because the proxy operates at the TCP layer, it is compatible with all MySQL-compatible servers including MariaDB and Percona Server.
- For production use, consider extending `nginx.conf.template` with `proxy_connect_timeout` and `proxy_timeout` directives tuned for your environment.
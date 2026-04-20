# Docker Proxies

A collection of Dockerised NGINX proxy templates for forwarding traffic to data stores and services. Each proxy is fully configurable via environment variables — no image rebuilds required when changing targets.

---

## Overview

These templates are designed to act as lightweight, transparent intermediaries between your application layer and its backends. Use cases include:

- **Network bridging** — expose a private data store on a predictable address without changing application config.
- **Environment abstraction** — swap backing services between environments (dev/staging/prod) using only env vars.
- **Traffic migration** — shift traffic between an old and a new API gradually using weighted routing.

All proxies follow the same three-file pattern:

| File | Purpose |
|---|---|
| `Dockerfile` | Builds the image; declares all configurable env vars with defaults |
| `nginx.conf.template` | NGINX config with `${VAR}` placeholders substituted at container start |
| `entrypoint.sh` | Runs `envsubst` to compile the template into `/etc/nginx/nginx.conf`, then starts NGINX |

---

## Folder Structure

```
docker-proxies/
├── README.md                  ← You are here
├── mysql/                     ← TCP proxy → MySQL           (default port 3306)
├── postgres/                  ← TCP proxy → PostgreSQL      (default port 5432)
├── mssql/                     ← TCP proxy → SQL Server      (default port 1433)
├── mongodb/                   ← TCP proxy → MongoDB         (default port 27017)
├── redis/                     ← TCP proxy → Redis           (default port 6379)
└── api-weighted-proxy/        ← HTTP proxy with weighted routing between two API targets
```

---

## Proxy Reference

### Data Store Proxies

All data store proxies use the NGINX `stream` module for raw **TCP proxying**. This makes them protocol-agnostic — they forward bytes without inspecting or modifying the payload, so they work with any version or flavour of the target database.

| Proxy | Default Listen Port | Default Upstream Port | README |
|---|---|---|---|
| MySQL | 3306 | 3306 | [mysql/README.md](./mysql/README.md) |
| PostgreSQL | 5432 | 5432 | [postgres/README.md](./postgres/README.md) |
| MSSQL | 1433 | 1433 | [mssql/README.md](./mssql/README.md) |
| MongoDB | 27017 | 27017 | [mongodb/README.md](./mongodb/README.md) |
| Redis | 6379 | 6379 | [redis/README.md](./redis/README.md) |

**Shared environment variables for all data store proxies:**

| Variable | Default | Description |
|---|---|---|
| `LISTEN_PORT` | *(protocol default)* | Port the proxy container listens on |
| `UPSTREAM_HOST` | `127.0.0.1` | Hostname or IP of the target data store |
| `UPSTREAM_PORT` | *(protocol default)* | Port on the target data store |
| `RESOLVER_ADDRESS` | `169.254.169.253` | DNS resolver for dynamic upstream re-resolution (AWS VPC default) |

### API Weighted Proxy

An **HTTP proxy** that distributes traffic across an old and a new API endpoint using NGINX's `upstream` weight directive. Weights are read from environment variables, enabling a gradual, zero-rebuild migration from one API to another.

| Proxy | Default Listen Port | README |
|---|---|---|
| API Weighted Proxy | 80 | [api-weighted-proxy/README.md](./api-weighted-proxy/README.md) |

---

## How It Works

### 1. Template compilation at startup

Rather than baking a static config into the image, `entrypoint.sh` uses `envsubst` to compile the template each time the container starts:

```sh
envsubst '${LISTEN_PORT} ${UPSTREAM_HOST} ${UPSTREAM_PORT} ${RESOLVER_ADDRESS}' \
  < /nginx.conf.template \
  > /etc/nginx/nginx.conf
```

Only the variables explicitly listed in the `envsubst` call are substituted. All other `$` expressions in the file are left untouched, which prevents NGINX variables (e.g. `$remote_addr`) from being accidentally replaced.

### 2. TCP stream proxying (data stores)

Data store proxies use the NGINX `stream {}` block instead of `http {}`. This operates at Layer 4 (TCP), so there is no HTTP parsing overhead and no protocol restrictions — the proxy forwards raw bytes to the upstream host.

```nginx
stream {
    resolver ${RESOLVER_ADDRESS} valid=10s ipv6=off;
    resolver_timeout 5s;

    server {
        listen ${LISTEN_PORT};
        set $upstream "${UPSTREAM_HOST}:${UPSTREAM_PORT}";
        proxy_pass $upstream;
    }
}
```

Assigning the upstream to a `$variable` is what forces NGINX to go through the resolver on every new connection. Without this, NGINX resolves the hostname once at startup and caches the IP indefinitely — which breaks failover for RDS Multi-AZ, Aurora, ElastiCache, and DocumentDB, all of which update their DNS CNAME to point at the new primary during a failover event.


### 3. Weighted HTTP proxying (API proxy)

The API proxy uses an `upstream {}` block inside `http {}`. NGINX distributes requests across the two servers in proportion to their `weight` values. A weight of `90`/`10` means 90% of requests go to one server and 10% to the other.

```nginx
upstream backend {
    server ${OLD_API_HOST}:${OLD_API_PORT} weight=${OLD_API_WEIGHT};
    server ${NEW_API_HOST}:${NEW_API_PORT} weight=${NEW_API_WEIGHT};
}
```

---

## Quick Start

```sh
# 1. Choose a proxy directory
cd docker-proxies/mysql

# 2. Build the image
docker build -t my-mysql-proxy .

# 3. Run with your target's address
docker run -d \
  -p 3306:3306 \
  -e UPSTREAM_HOST=db.internal.example.com \
  -e UPSTREAM_PORT=3306 \
  my-mysql-proxy
```

Applications connecting to `localhost:3306` will now be transparently forwarded to `db.internal.example.com:3306`.

---

## Platform Deployment

Full instructions for deploying any proxy in this folder on ECS (Fargate), bare EC2, and EKS are in **[DEPLOYING.md](./DEPLOYING.md)**. That guide covers:

- Building and pushing images to Amazon ECR
- ECS task definition structure, IAM roles, SSM Parameter Store for secrets, and service creation
- EC2 pull-and-run commands and a systemd unit file for long-running instances
- EKS ConfigMap, Secret, Deployment, and ClusterIP Service manifests
- External access via an internal NLB using the AWS Load Balancer Controller

Each proxy's own README contains a `Deployment` section with platform-specific substitution values and a copy-paste-ready EKS all-in-one manifest for that proxy.

---

## Deploying on AWS

### VPC DNS resolver

All proxies default `RESOLVER_ADDRESS` to `169.254.169.253`, the AWS link-local DNS resolver reachable from any VPC subnet. This is the correct value for ECS (both EC2 and Fargate launch types). For EKS, override it with the cluster DNS service IP (typically `10.96.0.10` or the value of `--cluster-dns` in kubelet config).

### Security Groups

The proxy container needs two security group rules:

| Direction | Protocol | Port | Peer |
|---|---|---|---|
| Inbound | TCP | `LISTEN_PORT` | Application tier security group |
| Outbound | TCP | `UPSTREAM_PORT` | RDS / ElastiCache / DocumentDB security group |

The managed service security group must also allow inbound TCP on its port from the proxy container's security group.

### Service-specific considerations

| Service | Key concern |
|---|---|
| **RDS Multi-AZ / Aurora** | CNAME endpoint changes on failover — handled by the `resolver` + variable `proxy_pass` pattern above |
| **RDS** (all engines) | No connection pooling at the proxy layer; consider [RDS Proxy](https://aws.amazon.com/rds/proxy/) to avoid connection exhaustion on small instance classes |
| **RDS for SQL Server** | `rds.force_ssl=1` is set by default — clients must use `Encrypt=True` in their connection string; the proxy is transparent to TLS |
| **ElastiCache Redis** | **Cluster Mode is not supported** — clients follow `MOVED`/`ASK` redirects directly to shard endpoints, bypassing the proxy; use non-cluster mode (replication group) only — see [`redis/README.md`](./redis/README.md) |
| **DocumentDB** | Requires TLS (Amazon CA bundle) and `retryWrites=false`; use `directConnection=true` to prevent the MongoDB driver from bypassing the proxy via replica set discovery — see [`mongodb/README.md`](./mongodb/README.md) |

---

## Notes

- All images are based on `nginx:alpine` for a minimal footprint.
- The `UPSTREAM_HOST` default of `127.0.0.1` is intentionally non-functional in most real deployments — always override it with the actual target address.
- Listen port and upstream port are independent; you can remap ports freely (e.g. listen on `15432` but proxy to an upstream on `5432`).
- For production use, consider adding `proxy_timeout`, `proxy_connect_timeout`, and access log configuration to the NGINX template for your use case.
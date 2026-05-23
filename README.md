# containers

A collection of production-ready Dockerfile templates and NGINX proxy configurations — one for each major language and runtime, plus a set of zero-rebuild network proxies for common data stores and API migration scenarios.

Every template follows the same core principles:

- **Multi-stage builds** — build tools and intermediate artifacts are discarded; the final image contains only what the running application needs.
- **Layer caching** — dependency manifests are copied and resolved before source code, so a source change does not invalidate the dependency cache.
- **Non-root users** — every final image drops privileges to a dedicated, unprivileged user.
- **Minimal base images** — Alpine, slim, distroless, or scratch finals where the runtime supports it.

---

## Repository Structure

    containers/
    ├── bun/                    # Bun runtime
    ├── deno/                   # Deno runtime
    ├── dotnet/                 # .NET 8 / ASP.NET Core
    ├── golang/                 # Go (static binary to scratch)
    ├── kotlin/                 # Kotlin / JVM (Maven or Gradle)
    ├── python/
    │   ├── raw/                # pip + requirements.txt
    │   ├── pipenv/             # Pipenv
    │   └── uv/                 # uv (Astral)
    ├── rust/
    │   ├── Dockerfile          # x86_64 static binary to scratch
    │   └── Dockerfile.arm64    # ARM64 static binary to scratch
    ├── swift/                  # Swift 5.9 (static stdlib)
    ├── typescript/             # Node.js 24 native TypeScript
    └── proxies/                # NGINX proxy templates
        ├── mysql/
        ├── postgres/
        ├── mssql/
        ├── mongodb/
        ├── redis/
        ├── api-weighted-proxy/
        ├── README.md
        └── DEPLOYING.md

---

## Language Templates

### Bun

**Path:** bun/  
**Base image:** oven/bun:1  
**Exposes:** 3000

A four-stage build that separates dev and production dependency installation:

1. **base** — sets the working directory on the official Bun image.
2. **install** — installs all dependencies (including dev) into a temp directory; then installs production-only dependencies into a second temp directory. Both sets are cached independently of source code changes.
3. **prerelease** — copies dev node_modules and source code for optional testing or building steps.
4. **release** — copies only the production node_modules and application source into the clean final image, then runs as the bun user.

The .dockerignore excludes node_modules, lock files, .env files, build output, and logs from the build context.

---

### Deno

**Path:** deno/  
**Base image:** denoland/deno:distroless-2.1.4  
**Default entrypoint:** deno run -A index.ts

A minimal single-stage Dockerfile using the official Deno distroless image. The entire application directory is copied to /app and executed directly — no transpilation or build step required. A sample index.ts is included as a starting point.

---

### .NET / ASP.NET Core

**Path:** dotnet/  
**Build image:** mcr.microsoft.com/dotnet/sdk:8.0-alpine  
**Final image:** mcr.microsoft.com/dotnet/aspnet:8.0-alpine  
**Exposes:** 8080

A three-stage build optimised for layer caching:

1. **build** — copies only the .csproj and runs dotnet restore before copying source, so the package restore layer is invalidated only when dependencies change.
2. **publish** — produces the Release build with dotnet publish.
3. **final** — uses the smaller ASP.NET runtime image, runs as a dedicated dotnet user, and sets ASPNETCORE_URLS for non-root port binding.

---

### Go

**Path:** golang/  
**Build image:** golang:1.16  
**Final image:** scratch

A two-stage build that produces the smallest possible Go container:

1. **builder** — downloads modules and compiles a single static binary.
2. **Final** — copies only the binary into a completely empty scratch image. No shell, no OS, no attack surface.

---

### Kotlin / JVM

**Path:** kotlin/  
**Build image:** eclipse-temurin:17-jdk (Ubuntu-based)  
**Final image:** eclipse-temurin:17-jre  
**Exposes:** 8080

A two-stage build that supports both Maven and Gradle projects:

1. **build** — installs both maven and gradle so the same base image works for either build system. The build command is left as a documented placeholder — uncomment the line matching your build tool and ensure it emits app.jar.
2. **release** — uses the JRE-only image for a smaller footprint, runs as kotlinuser, and sets JAVA_OPTS with UseContainerSupport and MaxRAMPercentage for correct JVM memory sizing inside a container.

---

### Python

Three variants covering the most common dependency management workflows:

#### python/raw — pip + requirements.txt

**Base image:** python:3.19-slim-bookworm

A simple single-stage Dockerfile: copies source and requirements.txt, upgrades pip, installs dependencies, and runs main.py. Best for straightforward scripts and services with no build-time tooling requirements.

#### python/pipenv — Pipenv

**Base image:** python:3.19-slim-bookworm

Installs Pipenv and runs pipenv install --deploy --ignore-pipfile for a reproducible, lockfile-driven install. Source is copied into a fresh final stage and run with pipenv run python main.py.

#### python/uv — uv (Astral)

**Build image:** ghcr.io/astral-sh/uv:python3.12-bookworm-slim  
**Final image:** python:3.12-slim-bookworm  
**Exposes:** 8000

A two-stage build using [uv](https://github.com/astral-sh/uv), the fast Rust-based Python package manager:

1. **build** — copies uv.lock and pyproject.toml first, syncs dependencies without the project package (for caching), then copies source and syncs the full project. UV_COMPILE_BYTECODE=1 is set for faster container startup.
2. **release** — uses a standard Python slim image, copies the .venv from the build stage, adds it to PATH, drops to pyuser, and runs uvicorn as the entrypoint.

---

### Rust

**Path:** rust/  
**Build image:** rust:latest  
**Final image:** scratch  
**Architectures:** Dockerfile (x86_64), Dockerfile.arm64 (ARM64 / Apple Silicon / Graviton)

Both Dockerfiles follow the same pattern, targeting different musl architectures:

1. **Dependency pre-build** — creates a dummy cargo new project, copies only Cargo.toml and Cargo.lock, and builds in release mode. This caches the entire dependency compilation layer. Source-only changes reuse it.
2. **Source build** — removes the dummy main.rs, copies real source, touches src/main.rs to force a rebuild, and compiles the final binary.
3. **scratch final** — copies only /etc/passwd, /etc/group, and the statically linked binary into a completely empty image. Runs as nobody:nogroup.

The x86_64-unknown-linux-musl and aarch64-unknown-linux-musl targets produce fully static binaries with no libc dependency.

> Replace my-app with your binary name from Cargo.toml before use.

---

### Swift

**Path:** swift/  
**Build image:** swift:5.9  
**Final image:** swift:5.9-slim  
**Exposes:** 8080

A two-stage build for Swift Package Manager projects:

1. **build** — copies Package.swift and Package.resolved first for dependency caching, resolves packages, then copies source and compiles with --static-swift-stdlib -c release.
2. **release** — uses the slim Swift runtime image, runs as swiftuser, and discovers the compiled binary via a find command. The ENTRYPOINT comment documents replacing this with a direct binary invocation once the executable name is known.

---

### TypeScript (Node.js)

**Path:** typescript/  
**Base image:** node:24-bookworm-slim  
**Exposes:** 3000

A three-stage build that leverages Node.js 24 native TypeScript support via --experimental-strip-types, eliminating a separate transpilation step:

1. **base** — sets up the shared node:24-bookworm-slim foundation used by both subsequent stages.
2. **install** — copies package.json and package-lock.json, runs npm ci --omit=dev for a clean, reproducible production install.
3. **release** — copies production node_modules and .ts source, runs as the built-in node user, and executes node --experimental-strip-types index.ts directly.

The .dockerignore keeps the build context lean by excluding node_modules, .env files, build output, and logs.

---

## NGINX Proxies

**Path:** proxies/

A set of lightweight NGINX proxy containers that forward traffic to backing services. All configuration is driven by environment variables — no image rebuilds needed to change a target host, port, or traffic split.

See [proxies/README.md](./proxies/README.md) for full documentation and [proxies/DEPLOYING.md](./proxies/DEPLOYING.md) for deployment instructions on ECS (Fargate), EC2, and EKS.

### Data Store TCP Proxies

Uses the NGINX stream module for raw Layer 4 TCP proxying — protocol-agnostic and compatible with any version of the target database.

| Proxy | Default Port | Target |
|---|---|---|
| proxies/mysql/ | 3306 | MySQL / Aurora MySQL |
| proxies/postgres/ | 5432 | PostgreSQL / Aurora PostgreSQL |
| proxies/mssql/ | 1433 | SQL Server / RDS for SQL Server |
| proxies/mongodb/ | 27017 | MongoDB / DocumentDB |
| proxies/redis/ | 6379 | Redis / ElastiCache (non-cluster mode) |

**Shared environment variables:**

| Variable | Default | Description |
|---|---|---|
| LISTEN_PORT | protocol default | Port the container listens on |
| UPSTREAM_HOST | 127.0.0.1 | Target hostname or IP |
| UPSTREAM_PORT | protocol default | Port on the target |
| RESOLVER_ADDRESS | 169.254.169.253 | DNS resolver (AWS VPC link-local default) |

The RESOLVER_ADDRESS + variable proxy_pass pattern forces NGINX to re-resolve the upstream hostname on every new connection, ensuring failover works correctly for services that update their DNS CNAME during a failover event (RDS Multi-AZ, Aurora, ElastiCache, DocumentDB).

### API Weighted Proxy

**Path:** proxies/api-weighted-proxy/  
**Default Port:** 80

An HTTP reverse proxy that distributes traffic between two API backends using the NGINX upstream weight directive. Use it for blue/green deployments, canary releases, and zero-downtime API migrations.

| Variable | Default | Description |
|---|---|---|
| LISTEN_PORT | 80 | Listening port |
| OLD_API_HOST | 127.0.0.1 | Old API hostname |
| OLD_API_PORT | 8080 | Old API port |
| OLD_API_WEIGHT | 50 | Routing weight for the old API |
| NEW_API_HOST | 127.0.0.1 | New API hostname |
| NEW_API_PORT | 8081 | New API port |
| NEW_API_WEIGHT | 50 | Routing weight for the new API |

Weights are relative — 90/10 sends 90% of requests to the old API and 10% to the new. Setting a weight to 0 removes that server from the pool entirely, effecting a full cutover without a rebuild.

**Migration workflow:**

| Stage | OLD_API_WEIGHT | NEW_API_WEIGHT | Description |
|---|---|---|---|
| Baseline | 100 | 0 | All traffic on old API |
| Canary | 90 | 10 | Small slice to new API for early validation |
| Ramp-up | 50 | 50 | Equal split for side-by-side observation |
| Final push | 10 | 90 | Majority on new API; old retained as fallback |
| Cutover | 0 | 100 | Full cutover; old API can be decommissioned |

---

## Using a Template

1. Copy the relevant directory into your project.
2. Replace placeholder names (MyApp, my-app, YourExecutableName, etc.) with your actual application name.
3. Adjust the exposed port if your application listens on a different port.
4. Build and run:

        docker build -t my-app .
        docker run -p 3000:3000 my-app

Each Dockerfile is commented inline with the steps most likely to need adjustment for a real project.

# static-web

A minimal container for serving static websites. Built on [lipanski/docker-static-website](https://github.com/lipanski/docker-static-website), which uses BusyBox httpd.

## TL;DR

Copy your static files into the container. The container serves them over HTTP on port 3000.

```dockerfile
FROM ghcr.io/your-org/static-web:latest
COPY ./dist .
```

## Where Content Is Served From

The `Dockerfile` copies all files from the build context into the container's working directory using `COPY . .`. BusyBox httpd serves files directly from that directory.

To serve your site, copy your built static files into the image at build time. The container does not mount external volumes or fetch files at runtime.

## Features

- **SPA routing** — any path that does not match a real file returns `index.html`. This supports client-side routers (React Router, Vue Router, etc.).
- **MIME types** — configured for modern formats: `.mjs`, `.wasm`, `.svg`, `.webp`, `.avif`, `.woff2`, `.json`, and source maps.

## Usage

Build with your static files:

```sh
docker build -t my-site .
docker run -p 3000:3000 my-site
```

The site is available at `http://localhost:3000`.

For local development, mount a directory instead of building:

```sh
docker run -p 3000:3000 -v /path/to/your/dist:/home/static my-site
```

The container serves files from `/home/static`. Changes to files on the host are reflected immediately without a rebuild.

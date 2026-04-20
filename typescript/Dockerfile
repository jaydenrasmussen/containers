# Use Node.js 24 (Debian-based) for stability and performance
# Node 24 supports running TypeScript files directly via --experimental-strip-types
FROM node:24-bookworm-slim AS base
WORKDIR /app

# Stage 1: Install production dependencies
FROM base AS install
COPY package.json package-lock.json* ./
# Use npm ci for a clean, predictable install of production dependencies
RUN npm ci --omit=dev

# Stage 2: Final production image
FROM base AS release
ENV NODE_ENV=production

# Copy production dependencies from the install stage
COPY --from=install /app/node_modules ./node_modules

# Copy the application source code
# We copy the .ts files directly as we are avoiding a transpilation step
COPY . .

# Use the built-in non-root 'node' user for security
USER node

# Expose the application port (adjust as needed)
EXPOSE 3000

# Run the application using Node's native TypeScript support
# --experimental-strip-types allows Node to execute TS files by stripping type annotations
ENTRYPOINT ["node", "--experimental-strip-types", "index.ts"]

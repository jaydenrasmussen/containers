# Use the official uv image for the build stage
# This provides the 'uv' binary and a stable Debian-based environment
FROM ghcr.io/astral-sh/uv:python3.12-bookworm-slim AS build

# Set the working directory
WORKDIR /app

# Enable bytecode compilation for faster startup
ENV UV_COMPILE_BYTECODE=1

# Copy the lockfile and pyproject.toml to leverage Docker caching
# This ensures dependencies are only re-installed if these files change
COPY uv.lock pyproject.toml ./

# Install dependencies
# --frozen ensures the lockfile is respected
# --no-install-project skips installing the current project (just dependencies)
RUN uv sync --frozen --no-install-project --no-dev

# Copy the rest of the application source code
COPY . .

# Install the project itself
RUN uv sync --frozen --no-dev

# Stage 2: Runtime environment
# Using a slim Debian image for the final production container
FROM python:3.12-slim-bookworm AS release

# Set the working directory
WORKDIR /app

# Copy the virtual environment from the build stage
# uv creates the .venv directory by default
COPY --from=build /app/.venv /app/.venv

# Copy the application source code
COPY . .

# Place the virtual environment's bin directory on the PATH
ENV PATH="/app/.venv/bin:$PATH"

# Create a non-root user for security
RUN useradd -ms /bin/bash pyuser
USER pyuser

# Expose the default port (e.g., for FastAPI/Flask)
EXPOSE 8000

# Run the application
# Replace 'main:app' with your actual entry point
ENTRYPOINT ["python", "-m", "uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000"]

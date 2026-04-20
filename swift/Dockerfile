# Stage 1: Build the application
# Using the official Swift image (Ubuntu-based) for stability and performance
FROM swift:5.9 AS build

# Set the working directory
WORKDIR /build

# Copy Package.swift and Package.resolved first to leverage Docker caching
COPY Package.swift Package.resolved* ./

# Resolve dependencies
RUN swift package resolve

# Copy the rest of the source code
COPY . .

# Build the application in release mode
# We use static linking where possible or ensure dependencies are available
RUN swift build -c release --static-swift-stdlib

# Stage 2: Runtime environment
# Using the slim version of the official Swift image for a smaller production footprint
FROM swift:5.9-slim AS release

# Set the working directory
WORKDIR /app

# Copy the compiled binary from the build stage
# Note: Replace 'YourExecutableName' with the actual name of your executable
# In a generic base, we assume the binary is moved or found in .build/release/
COPY --from=build /build/.build/release/ /app/

# Create a non-root user for security
RUN useradd -ms /bin/bash swiftuser
USER swiftuser

# Expose the default port (common for Vapor and other Swift web frameworks)
EXPOSE 8080

# Run the application
# You should replace 'YourExecutableName' with your actual binary name
# ENTRYPOINT ["./YourExecutableName", "serve", "--hostname", "0.0.0.0", "--port", "8080"]
# Using a generic entrypoint that expects the binary name to be passed or configured
ENTRYPOINT ["/bin/bash", "-c", "find . -maxdepth 1 -executable -type f -not -name '*.so' -print -quit | xargs -I {} {}"]

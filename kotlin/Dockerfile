# Stage 1: Build the application
# Using Eclipse Temurin (Ubuntu-based) for better performance and stability compared to Alpine
FROM eclipse-temurin:17-jdk AS build
WORKDIR /app

# Install Maven and Gradle to support both build systems in the same base image
RUN apt-get update && apt-get install -y \
    maven \
    gradle \
    && rm -rf /var/lib/apt/lists/*

# Copy the project files
COPY . .

# Build logic:
# This Dockerfile is designed to be flexible. Depending on your project,
# you would typically run one of the following commands.
# We use a conditional approach or manual selection here.

# Example for Maven:
# RUN mvn clean package -DskipTests && mv target/*.jar app.jar

# Example for Gradle:
# RUN gradle build -x test && mv build/libs/*.jar app.jar

# For the sake of a functional base, we assume the build step produces a jar
# that is moved to /app/app.jar. If you are using this as a template,
# ensure your build command outputs to this location.

# Stage 2: Runtime environment
# Using the JRE version of Temurin (Ubuntu-based) for a smaller, secure production image
FROM eclipse-temurin:17-jre AS release
WORKDIR /app

# Copy the compiled jar from the build stage
# We use a wildcard to be flexible, but in production, specific paths are better
COPY --from=build /app/*.jar ./app.jar

# Create a non-root user for security (Debian/Ubuntu uses useradd)
RUN useradd -ms /bin/bash kotlinuser
USER kotlinuser

# Standard port for many Kotlin/JVM frameworks (Ktor, Spring Boot)
EXPOSE 8080

# Performance optimizations for JVM in containers
ENV JAVA_OPTS="-XX:+UseContainerSupport -XX:MaxRAMPercentage=75.0"

ENTRYPOINT ["sh", "-c", "java $JAVA_OPTS -jar app.jar"]

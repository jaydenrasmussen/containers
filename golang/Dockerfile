FROM golang:1.16 AS builder
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 GOOS=linux go build -o /app .
# Copy static binary to scratch image
FROM scratch
COPY --from=builder /app /app
CMD ["/app"]
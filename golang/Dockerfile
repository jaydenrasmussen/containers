FROM golang:1.16 as builder
WORKDIR /app
COPY . .
RUN go mod download
RUN go build -o /app .
# Copy static binary to scratch image
FROM scratch
COPY --from=builder /app /app
WORKDIR /app
CMD ["/app"]
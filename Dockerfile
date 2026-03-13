FROM golang:1.25-alpine AS builder

WORKDIR /app

COPY go.mod ./
RUN go mod download

COPY . .

RUN CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -ldflags="-s -w" -o /app/server .

FROM alpine:latest

WORKDIR /app

COPY --from=builder /app/server /app/server
COPY --from=builder /app/index.html /app/index.html
COPY --from=builder /app/style.css /app/style.css
COPY --from=builder /app/script.js /app/script.js

EXPOSE 8080

CMD ["/app/server"]
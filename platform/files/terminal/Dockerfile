FROM node:20-alpine

WORKDIR /app

# Install npm dependencies only — no app files baked in.
# server.js, index.html, wiring.md are mounted from a ConfigMap at runtime.
COPY package.json package-lock.json ./
RUN apk add --no-cache python3 make g++ && \
    npm ci --omit=dev && \
    apk del make g++

# Download kubectl for the current arch (amd64 or arm64)
RUN KUBECTL_VER=$(wget -qO- https://dl.k8s.io/release/stable.txt) && \
    ARCH=$(uname -m) && \
    [ "$ARCH" = "aarch64" ] && ARCH="arm64" || ARCH="amd64" && \
    wget -qO /usr/local/bin/kubectl \
      "https://dl.k8s.io/release/${KUBECTL_VER}/bin/linux/${ARCH}/kubectl" && \
    chmod +x /usr/local/bin/kubectl

CMD ["node", "server.js"]

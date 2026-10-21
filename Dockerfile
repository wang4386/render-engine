# ==========================================
# Build / Base Stage: Alpine Linux (x86_64)
# Minimal footprint, low memory (< 512MB limit)
#
# Fork note (wang4386): upstream render-engine shipped EasyTier
# (mesh) + Komari/MangoHub (telemetry). This fork removes both and
# replaces them with:
#   - Tailscale client, pointed at a self-hosted Headscale control
#     plane (userspace networking, because Render containers have
#     no /dev/net/tun and no CAP_NET_ADMIN)
#   - Official Nezha agent, v2 line (nezhahq/agent v2.3.5), matching a 2.x dashboard,
#     reporting to the user's own Nezha dashboard
# ==========================================
FROM alpine:3.20

LABEL maintainer="DevOps Team" \
      description="Modular Web-Box with persistent web terminal, SSH, Headscale/Tailscale mesh and Nezha telemetry on Render Free Tier"

# Explicit upstream release versions for reproducible builds
ARG TAILSCALE_VERSION="1.80.0"
ARG TTYD_VERSION="1.7.7"
ARG NEZHA_VERSION="v2.3.5"

# Set environment
ENV LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    PORT=10000

# Install runtime dependencies via Alpine apk
RUN apk update && \
    apk add --no-cache \
      bash \
      ca-certificates \
      curl \
      unzip \
      tar \
      gzip \
      openssh \
      iproute2 \
      tmux \
      vim \
      caddy \
      sing-box \
      tzdata \
      procps && \
    rm -rf /var/cache/apk/*

# Download and install Tailscale (x86_64 static binaries).
# tailscaled runs with --tun=userspace-networking (see entrypoint.sh):
# no kernel TUN device is required on Render.
RUN set -eux; \
    echo "Downloading Tailscale ${TAILSCALE_VERSION}..."; \
    TS_TGZ="tailscale_${TAILSCALE_VERSION#v}_amd64.tgz"; \
    curl -sSL "https://pkgs.tailscale.com/stable/${TS_TGZ}" -o /tmp/tailscale.tgz; \
    tar -xzf /tmp/tailscale.tgz -C /tmp; \
    cp /tmp/tailscale_*/tailscaled /usr/local/bin/tailscaled; \
    cp /tmp/tailscale_*/tailscale /usr/local/bin/tailscale; \
    chmod +x /usr/local/bin/tailscaled /usr/local/bin/tailscale; \
    rm -rf /tmp/tailscale*

# Download and install ttyd for emergency web terminal
RUN set -eux; \
    echo "Downloading ttyd ${TTYD_VERSION}..."; \
    curl -sSL -o /usr/local/bin/ttyd "https://github.com/tsl0922/ttyd/releases/download/${TTYD_VERSION}/ttyd.x86_64"; \
    chmod +x /usr/local/bin/ttyd

# Download and install official Nezha agent (v2 line).
# The agent reads its own NZ_* environment variables at runtime.
RUN set -eux; \
    echo "Downloading Nezha agent ${NEZHA_VERSION}..."; \
    curl -sSL "https://github.com/nezhahq/agent/releases/download/${NEZHA_VERSION}/nezha-agent_linux_amd64.zip" -o /tmp/nezha.zip; \
    unzip -q /tmp/nezha.zip -d /tmp/nezha; \
    cp /tmp/nezha/nezha-agent /usr/local/bin/nezha-agent; \
    chmod +x /usr/local/bin/nezha-agent; \
    rm -rf /tmp/nezha*

# Configure SSH server defaults
RUN mkdir -p /var/run/sshd /root/.ssh && \
    chmod 700 /root/.ssh

# Copy configuration files and entrypoint
COPY Caddyfile /etc/caddy/Caddyfile
COPY entrypoint.sh /usr/local/bin/entrypoint.sh

RUN chmod +x /usr/local/bin/entrypoint.sh

# Expose Render default port
EXPOSE 10000

# Working directory
WORKDIR /root

# Entrypoint
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]

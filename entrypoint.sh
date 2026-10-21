#!/usr/bin/env bash
# ==============================================================================
# Entrypoint for render-engine on Render Container
# Fork: upstream mesh -> Headscale/Tailscale (userspace), upstream telemetry -> Nezha v1 agent
# Modular Architecture: Minimal Zero-Config Base with On-Demand Extension
# Production-Hardened Edition
# ==============================================================================
set -Eeuo pipefail

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [INFO] $*"
}

warn() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [WARN] $*" >&2
}

err() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [ERROR] $*" >&2
}

generate_secure_secret() {
    head -c 32 /dev/urandom | base64 | tr -dc 'a-zA-Z0-9' | head -c 18
}

log "=========================================================="
log "Starting render-engine Container Initialization..."
log "=========================================================="

# ------------------------------------------------------------------------------
# 1. SSH Server Configuration & Credentials Setup
# ------------------------------------------------------------------------------
log "Configuring OpenSSH server..."

# Generate host keys if not present
ssh-keygen -A >/dev/null 2>&1 || true

# Prepare SSH runtime directories
mkdir -p /var/run/sshd /root/.ssh
chmod 700 /root/.ssh

# Configure sshd_config with modern OpenSSH directives
cat > /etc/ssh/sshd_config << 'EOF'
Port 22
Port 2222
ListenAddress 0.0.0.0
PermitRootLogin yes
PasswordAuthentication yes
PubkeyAuthentication yes
AuthorizedKeysFile .ssh/authorized_keys
KbdInteractiveAuthentication no
X11Forwarding no
PrintMotd no
AcceptEnv LANG LC_*
Subsystem sftp internal-sftp
ClientAliveInterval 30
ClientAliveCountMax 3
EOF

# Setup SSH password
IS_RANDOM_PASS=0
if [ -n "${SSH_PASS:-}" ]; then
    echo "root:${SSH_PASS}" | chpasswd
    log "SSH root password configured from SSH_PASS."
else
    RANDOM_PASS=$(generate_secure_secret)
    echo "root:${RANDOM_PASS}" | chpasswd
    warn "SSH_PASS not provided. Generated random root password: ${RANDOM_PASS}"
    SSH_PASS="$RANDOM_PASS"
    IS_RANDOM_PASS=1
fi

# Setup SSH Public Key if provided
if [ -n "${SSH_PUBKEY:-}" ]; then
    echo "${SSH_PUBKEY}" > /root/.ssh/authorized_keys
    chmod 600 /root/.ssh/authorized_keys
    log "SSH public key installed to /root/.ssh/authorized_keys."
fi

# Ensure root shell is bash
chsh -s /bin/bash root >/dev/null 2>&1 || true

# ------------------------------------------------------------------------------
# 2. On-Demand Feature Flags & Arguments Preparation
# ------------------------------------------------------------------------------

# Feature 1: Tailscale mesh via self-hosted Headscale
# Render containers have no /dev/net/tun and no CAP_NET_ADMIN, so
# tailscaled runs in userspace-networking mode (gVisor netstack):
# the node still gets a tailnet IP, is visible in Headscale, and
# `tailscale serve` can forward tailnet TCP to the local sshd.
# Requires HEADSCALE_URL + TS_AUTHKEY (a reusable Headscale preauth key).
if [ -n "${HEADSCALE_URL:-}" ] || [ -n "${TS_AUTHKEY:-}" ] || [ "${ENABLE_TAILSCALE:-}" = "true" ]; then
    ENABLE_TAILSCALE="true"
else
    ENABLE_TAILSCALE="false"
fi

if [ "$ENABLE_TAILSCALE" = "true" ]; then
    if [ -z "${HEADSCALE_URL:-}" ] || [ -z "${TS_AUTHKEY:-}" ]; then
        warn "ENABLE_TAILSCALE requested but HEADSCALE_URL or TS_AUTHKEY is missing; skipping Tailscale."
        ENABLE_TAILSCALE="false"
    else
        log "Tailscale mesh is ENABLED (Headscale: ${HEADSCALE_URL}, hostname: ${TS_HOSTNAME:-render-box})."
    fi
else
    log "Tailscale mesh is DISABLED (set ENABLE_TAILSCALE=true and provide HEADSCALE_URL + TS_AUTHKEY)."
fi

# Feature 2: sing-box Proxy
if [ -n "${SINGBOX_UUID:-}" ] || [ "${ENABLE_SINGBOX:-}" = "true" ]; then
    ENABLE_SINGBOX="true"
else
    ENABLE_SINGBOX="false"
fi

if [ "$ENABLE_SINGBOX" = "true" ]; then
    log "sing-box proxy is ENABLED. Preparing configuration..."
    SINGBOX_UUID="${SINGBOX_UUID:-1da2cc31-2c34-4b0b-b83c-ce3f7b8e6c2c}"
    mkdir -p /etc/sing-box
    cat > /etc/sing-box/config.json << EOF
{
  "log": {
    "level": "info",
    "timestamp": true
  },
  "inbounds": [
    {
      "type": "mixed",
      "tag": "mixed-in",
      "listen": "0.0.0.0",
      "listen_port": 10808
    },
    {
      "type": "vless",
      "tag": "vless-in",
      "listen": "127.0.0.1",
      "listen_port": 20808,
      "users": [
        {
          "uuid": "${SINGBOX_UUID}"
        }
      ],
      "transport": {
        "type": "ws",
        "path": "/vless-ws",
        "max_early_data": 2048,
        "early_data_header_name": "Sec-WebSocket-Protocol"
      }
    }
  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    }
  ],
  "route": {
    "auto_detect_interface": true
  }
}
EOF
else
    log "sing-box proxy is DISABLED (activate by defining SINGBOX_UUID or setting ENABLE_SINGBOX=true)."
fi

# Feature 3: Nezha Monitoring Agent (official nezhahq/agent, v2 line)
# The agent binary reads NZ_* environment variables itself, so the
# entrypoint only validates the two required ones and pins sane
# defaults. NZ_UUID should be a fixed value (Render generateValue in
# render.yaml) so redeploys reuse the same dashboard node instead
# of registering a duplicate on every restart (Render disks are
# ephemeral, so an auto-generated UUID would not survive).
ENABLE_NEZHA="false"
if [ -n "${NZ_SERVER:-}" ] || [ -n "${NZ_CLIENT_SECRET:-}" ] || [ "${ENABLE_NEZHA:-}" = "true" ]; then
    if [ -z "${NZ_SERVER:-}" ] || [ -z "${NZ_CLIENT_SECRET:-}" ]; then
        warn "Nezha requested but NZ_SERVER or NZ_CLIENT_SECRET is missing; skipping to prevent unauthorized telemetry routing."
    else
        ENABLE_NEZHA="true"
        export NZ_DISABLE_AUTO_UPDATE="${NZ_DISABLE_AUTO_UPDATE:-true}"
        export NZ_SKIP_CONNECTION_COUNT="${NZ_SKIP_CONNECTION_COUNT:-true}"
        export NZ_SKIP_PROCS_COUNT="${NZ_SKIP_PROCS_COUNT:-true}"
        export NZ_REPORT_DELAY="${NZ_REPORT_DELAY:-3}"
        log "Nezha agent is ENABLED (Server: ${NZ_SERVER}, TLS: ${NZ_TLS:-false})."
    fi
fi

if [ "$ENABLE_NEZHA" = "false" ]; then
    log "Nezha agent is DISABLED (provide both NZ_SERVER and NZ_CLIENT_SECRET to activate)."
fi

# Feature 4: Autonomous Inbound Keepalive Watchdog
# Render Free Tier terminates pods after 15 minutes of inbound HTTP inactivity.
# This autonomous watchdog queries the public edge URL every N seconds, generating
# valid inbound HTTP traffic to guarantee 24/7 continuous operation within the 750h/mo quota.
ENABLE_KEEPALIVE="${ENABLE_KEEPALIVE:-true}"
KEEPALIVE_INTERVAL="${KEEPALIVE_INTERVAL:-300}"
if ! [[ "$KEEPALIVE_INTERVAL" =~ ^[0-9]+$ ]] || [ "$KEEPALIVE_INTERVAL" -le 0 ]; then
    warn "Invalid or non-numeric KEEPALIVE_INTERVAL '${KEEPALIVE_INTERVAL}'; resetting to default 300s."
    KEEPALIVE_INTERVAL=300
fi
KEEPALIVE_URL="${KEEPALIVE_URL:-}"

if [ -z "$KEEPALIVE_URL" ]; then
    if [ -n "${RENDER_EXTERNAL_URL:-}" ]; then
        KEEPALIVE_URL="${RENDER_EXTERNAL_URL%/}/health"
    elif [ -n "${RENDER_EXTERNAL_HOSTNAME:-}" ]; then
        KEEPALIVE_URL="https://${RENDER_EXTERNAL_HOSTNAME}/health"
    fi
fi

# ------------------------------------------------------------------------------
# 3. Process Management & Background Services
# ------------------------------------------------------------------------------
PID_SSHD=""
PID_TAILSCALED=""
PID_TTYD=""
PID_CADDY=""
PID_NEZHA=""
PID_SINGBOX=""
PID_KEEPALIVE=""

cleanup() {
    log "Received shutdown signal. Stopping all background processes gracefully..."

    # 1. Gracefully terminate tmux server and any active web terminal child tasks
    if command -v tmux >/dev/null 2>&1; then
        tmux kill-server 2>/dev/null || true
    fi

    # 2. Terminate all active managed service daemons (including child process groups)
    local active_pids=("${PID_CADDY:-}" "${PID_TAILSCALED:-}" "${PID_SSHD:-}" "${PID_TTYD:-}" "${PID_NEZHA:-}" "${PID_SINGBOX:-}" "${PID_KEEPALIVE:-}")
    for pid in "${active_pids[@]}"; do
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            kill -TERM -- -"$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true
        fi
    done
    wait || true
    log "All processes terminated. Container exit."
    exit 0
}

trap cleanup SIGINT SIGTERM SIGHUP

# Prepare tmux configuration & persistent session wrapper for ttyd
cat > /root/.tmux.conf << 'EOF'
set -g default-terminal "xterm-256color"
set -g mouse on
set -g history-limit 50000
set -g window-size latest
setw -g aggressive-resize on
set -s escape-time 0
set -g status-style "bg=#2d3748,fg=#f7fafc"
set -g status-left "[#S] "
set -g status-right "%H:%M %d-%b"
EOF

cat > /usr/local/bin/ttyd-session << 'EOF'
#!/usr/bin/env bash
# Attach to existing tmux session 'main' or create new one with bash
exec tmux -f /root/.tmux.conf new-session -A -s main /bin/bash
EOF
chmod +x /usr/local/bin/ttyd-session

# Start SSH daemon (Core Service)
log "Starting sshd on ports 22 and 2222..."
/usr/sbin/sshd -D -e &
PID_SSHD=$!

# Start ttyd (Core Service: Web terminal with tmux session persistence & ping keepalive)
TTYD_USER="${TTYD_USER:-admin}"
TTYD_PASS="${TTYD_PASS:-$SSH_PASS}"

start_ttyd() {
    /usr/local/bin/ttyd \
        --port 7681 \
        --interface 127.0.0.1 \
        --base-path "/shell" \
        --writable \
        --ping-interval 15 \
        -t disableLeaveAlert=true \
        -t fontSize=14 \
        --credential "${TTYD_USER}:${TTYD_PASS}" \
        /usr/local/bin/ttyd-session &
}

log "Starting ttyd on 127.0.0.1:7681 (/shell) with Basic Auth and tmux persistence..."
start_ttyd
PID_TTYD=$!

# Start Caddy Reverse Proxy (Core Service)
PORT="${PORT:-10000}"
export PORT
log "Starting Caddy multiplexer on port $PORT..."
caddy run --config /etc/caddy/Caddyfile --adapter caddyfile &
PID_CADDY=$!

# Start Tailscale (Optional Extension)
# tailscaled in userspace mode, then `tailscale up` against Headscale.
# --accept-dns=false keeps Render's own DNS working. `tailscale serve`
# forwards tailnet :22 to the local sshd so the box is reachable as
# ssh root@<tailnet-ip> from any other tailnet node; a serve failure
# must not kill the container, so it is best-effort only.
start_tailscale() {
    mkdir -p /var/lib/tailscale /var/run/tailscale
    /usr/local/bin/tailscaled \
        --tun=userspace-networking \
        --socks5-server=127.0.0.1:1055 \
        --state=/var/lib/tailscale/tailscaled.state \
        --socket=/var/run/tailscale/tailscaled.sock \
        --port=41641 &
    PID_TAILSCALED=$!
    # Wait for the daemon socket, then log in (retry once: the daemon
    # can take a few seconds to become responsive on a cold container).
    local i=0
    while [ $i -lt 30 ]; do
        if /usr/local/bin/tailscale --socket=/var/run/tailscale/tailscaled.sock status >/dev/null 2>&1; then
            break
        fi
        sleep 1
        i=$((i + 1))
    done
    local up_args=(--login-server "${HEADSCALE_URL}" --authkey "${TS_AUTHKEY}" --hostname "${TS_HOSTNAME:-render-box}" --accept-dns=false)
    if [ "${TS_EPHEMERAL:-false}" = "true" ]; then
        up_args+=(--ephemeral)
    fi
    if /usr/local/bin/tailscale --socket=/var/run/tailscale/tailscaled.sock up "${up_args[@]}"; then
        log "Tailscale up OK. Tailnet IP: $(/usr/local/bin/tailscale --socket=/var/run/tailscale/tailscaled.sock ip -4 2>/dev/null || echo unknown)"
        /usr/local/bin/tailscale --socket=/var/run/tailscale/tailscaled.sock serve --bg tcp:22 tcp://127.0.0.1:22 >/dev/null 2>&1 \
            && log "Tailscale serve: tailnet :22 -> local sshd" \
            || warn "tailscale serve tcp:22 failed; Web terminal (/shell) still works, tailnet SSH may not."
    else
        warn "tailscale up failed; check HEADSCALE_URL and TS_AUTHKEY (preauth key must be reusable)."
    fi
}

if [ "$ENABLE_TAILSCALE" = "true" ] && [ -x /usr/local/bin/tailscaled ]; then
    log "Starting tailscaled (userspace networking)..."
    start_tailscale
fi

# Start sing-box (Optional Extension, log streaming)
if [ "$ENABLE_SINGBOX" = "true" ] && command -v sing-box >/dev/null 2>&1; then
    log "Starting sing-box..."
    sing-box run -c /etc/sing-box/config.json &
    PID_SINGBOX=$!
fi

# Start Nezha Agent (Optional Extension, log streaming)
if [ "$ENABLE_NEZHA" = "true" ] && [ -x /usr/local/bin/nezha-agent ]; then
    log "Starting nezha-agent..."
    /usr/local/bin/nezha-agent &
    PID_NEZHA=$!
fi

# Start Autonomous Keepalive Watchdog (Core Resilience Feature)
start_keepalive() {
    log "Starting autonomous keepalive watchdog (Target: ${KEEPALIVE_URL}, Interval: ${KEEPALIVE_INTERVAL}s)..."
    (
        # Initial grace period to allow Caddy and OpenSSH to fully initialize
        sleep 10
        while true; do
            curl -s -m 15 -A "render-engine-keepalive/1.0" "$KEEPALIVE_URL" >/dev/null 2>&1 || true
            sleep "$KEEPALIVE_INTERVAL"
        done
    ) &
    PID_KEEPALIVE=$!
}

if [ "$ENABLE_KEEPALIVE" = "true" ] && [ -n "${KEEPALIVE_URL:-}" ]; then
    start_keepalive
fi

log "=========================================================="
log "render-engine is ready!"
log "=========================================================="
if [ "$IS_RANDOM_PASS" -eq 1 ]; then
    log "Web Terminal   : https://<render-host>/shell/ (User: ${TTYD_USER}, Pass: ${RANDOM_PASS})"
else
    log "Web Terminal   : https://<render-host>/shell/ (User: ${TTYD_USER}, Pass: [CONFIGURED])"
fi
log "Health Probe   : https://<render-host>/health"
if [ "$ENABLE_KEEPALIVE" = "true" ] && [ -n "${KEEPALIVE_URL:-}" ]; then
    log "Auto Keepalive : ENABLED (Target: ${KEEPALIVE_URL}, Interval: ${KEEPALIVE_INTERVAL}s)"
else
    log "Auto Keepalive : DISABLED (Set ENABLE_KEEPALIVE=true or configure KEEPALIVE_URL)"
fi
if [ "$ENABLE_TAILSCALE" = "true" ]; then
    log "Tailscale Mesh : ENABLED (Headscale: ${HEADSCALE_URL}, Hostname: ${TS_HOSTNAME:-render-box})"
else
    log "Tailscale Mesh : DISABLED (set ENABLE_TAILSCALE=true, HEADSCALE_URL and TS_AUTHKEY to activate)"
fi
if [ "$ENABLE_SINGBOX" = "true" ]; then
    log "sing-box Proxy : ENABLED (vless-ws: /vless-ws, mixed: 10808)"
else
    log "sing-box Proxy : DISABLED (set ENABLE_SINGBOX=true or SINGBOX_UUID to activate)"
fi
if [ "$ENABLE_NEZHA" = "true" ]; then
    log "Nezha Agent    : ENABLED (Reporting to ${NZ_SERVER})"
else
    log "Nezha Agent    : DISABLED (set NZ_SERVER and NZ_CLIENT_SECRET to activate)"
fi
log "=========================================================="

# ------------------------------------------------------------------------------
# 4. Supervise Processes Loop with Crash-Loop Circuit Breaker and Success-Reset
# ------------------------------------------------------------------------------
FAIL_COUNT_CADDY=0
FAIL_COUNT_TAILSCALED=0
FAIL_COUNT_SSHD=0
FAIL_COUNT_TTYD=0
FAIL_COUNT_SINGBOX=0
FAIL_COUNT_NEZHA=0
FAIL_COUNT_KEEPALIVE=0
MAX_FAILURES=5

while true; do
    # Check Caddy (Core)
    if kill -0 "$PID_CADDY" 2>/dev/null; then
        FAIL_COUNT_CADDY=0
    else
        ((FAIL_COUNT_CADDY++)) || true
        err "Caddy process died! (Failure count: $FAIL_COUNT_CADDY/$MAX_FAILURES)"
        if [ "$FAIL_COUNT_CADDY" -ge "$MAX_FAILURES" ]; then
            err "Caddy exceeded maximum consecutive crash limit ($MAX_FAILURES). Aborting container."
            exit 1
        fi
        caddy run --config /etc/caddy/Caddyfile --adapter caddyfile &
        PID_CADDY=$!
    fi

    # Check SSHD (Core)
    if kill -0 "$PID_SSHD" 2>/dev/null; then
        FAIL_COUNT_SSHD=0
    else
        ((FAIL_COUNT_SSHD++)) || true
        err "sshd process died! (Failure count: $FAIL_COUNT_SSHD/$MAX_FAILURES)"
        if [ "$FAIL_COUNT_SSHD" -ge "$MAX_FAILURES" ]; then
            err "sshd exceeded maximum consecutive crash limit ($MAX_FAILURES). Aborting container."
            exit 1
        fi
        /usr/sbin/sshd -D -e &
        PID_SSHD=$!
    fi

    # Check ttyd (Core)
    if kill -0 "$PID_TTYD" 2>/dev/null; then
        FAIL_COUNT_TTYD=0
    else
        ((FAIL_COUNT_TTYD++)) || true
        err "ttyd process died! (Failure count: $FAIL_COUNT_TTYD/$MAX_FAILURES)"
        if [ "$FAIL_COUNT_TTYD" -ge "$MAX_FAILURES" ]; then
            err "ttyd exceeded maximum consecutive crash limit ($MAX_FAILURES). Aborting container."
            exit 1
        fi
        start_ttyd
        PID_TTYD=$!
    fi

    # Check tailscaled (Only if enabled; `tailscale up` state is kept
    # in the daemon, so a daemon restart re-runs the login helper)
    if [ "$ENABLE_TAILSCALE" = "true" ] && [ -n "$PID_TAILSCALED" ]; then
        if kill -0 "$PID_TAILSCALED" 2>/dev/null; then
            FAIL_COUNT_TAILSCALED=0
        else
            ((FAIL_COUNT_TAILSCALED++)) || true
            warn "tailscaled process died! (Failure count: $FAIL_COUNT_TAILSCALED/$MAX_FAILURES)"
            if [ "$FAIL_COUNT_TAILSCALED" -ge "$MAX_FAILURES" ]; then
                err "tailscaled exceeded maximum consecutive restart limit ($MAX_FAILURES). Stopping auto-restart."
                PID_TAILSCALED=""
            else
                start_tailscale
            fi
        fi
    fi

    # Check sing-box (Only if enabled, with circuit breaker)
    if [ "$ENABLE_SINGBOX" = "true" ] && [ -n "$PID_SINGBOX" ]; then
        if kill -0 "$PID_SINGBOX" 2>/dev/null; then
            FAIL_COUNT_SINGBOX=0
        else
            ((FAIL_COUNT_SINGBOX++)) || true
            warn "sing-box process died! (Failure count: $FAIL_COUNT_SINGBOX/$MAX_FAILURES)"
            if [ "$FAIL_COUNT_SINGBOX" -ge "$MAX_FAILURES" ]; then
                err "sing-box exceeded maximum consecutive restart limit ($MAX_FAILURES). Stopping auto-restart."
                PID_SINGBOX=""
            else
                sing-box run -c /etc/sing-box/config.json &
                PID_SINGBOX=$!
            fi
        fi
    fi

    # Check Nezha Agent (Only if enabled, with circuit breaker)
    if [ "$ENABLE_NEZHA" = "true" ] && [ -n "$PID_NEZHA" ]; then
        if kill -0 "$PID_NEZHA" 2>/dev/null; then
            FAIL_COUNT_NEZHA=0
        else
            ((FAIL_COUNT_NEZHA++)) || true
            warn "nezha-agent process died! (Failure count: $FAIL_COUNT_NEZHA/$MAX_FAILURES)"
            if [ "$FAIL_COUNT_NEZHA" -ge "$MAX_FAILURES" ]; then
                err "nezha-agent exceeded maximum consecutive restart limit ($MAX_FAILURES). Stopping auto-restart."
                PID_NEZHA=""
            else
                /usr/local/bin/nezha-agent &
                PID_NEZHA=$!
            fi
        fi
    fi

    # Check Keepalive Watchdog (Only if enabled, with circuit breaker)
    if [ "$ENABLE_KEEPALIVE" = "true" ] && [ -n "${KEEPALIVE_URL:-}" ]; then
        if [ -z "${PID_KEEPALIVE:-}" ] || ! kill -0 "$PID_KEEPALIVE" 2>/dev/null; then
            ((FAIL_COUNT_KEEPALIVE++)) || true
            warn "Keepalive worker died! (Failure count: $FAIL_COUNT_KEEPALIVE/$MAX_FAILURES)"
            if [ "$FAIL_COUNT_KEEPALIVE" -ge "$MAX_FAILURES" ]; then
                err "Keepalive worker exceeded maximum consecutive crash limit ($MAX_FAILURES). Stopping auto-restart."
                PID_KEEPALIVE=""
                ENABLE_KEEPALIVE="false"
            else
                start_keepalive
            fi
        else
            FAIL_COUNT_KEEPALIVE=0
        fi
    fi

    sleep 5
done

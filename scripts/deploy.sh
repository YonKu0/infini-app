#!/usr/bin/env bash
set -euxo pipefail

# 
# deploy.sh - Automate deployment of Docker Compose app + Prometheus on FCOS VM
#
# Usage example:
#   ./deploy.sh -i 192.168.42.10 -k ~/.ssh/infini_ops_id -d myapp -p 5050
#
# Required:
#   - VM_IP (via -i)
# Optional flags:
#   - SSH_USER (default infini-ops)
#   - SSH_KEY  (default ~/.ssh/id_rsa)
#   - APP_DIR  (default app)
#   - APP_PORT (default 5050)
#   - SSH_PORT (default 22)
# 

print_usage() {
  cat <<EOF
Usage: $0 -i VM_IP [options]

Required:
  -i VM_IP           IP address of the Fedora CoreOS VM

Options:
  -u SSH_USER        SSH username (default: infini-ops)
  -k SSH_KEY         SSH private key path (default: ~/.ssh/id_rsa)
  -d APP_DIR         Remote app directory name (default: app)
  -p APP_PORT        Application port (default: 5050)
  -P SSH_PORT        SSH port on VM (default: 22)
  -h                 Show this help message

Example:
  $0 -i 127.0.0.1 -k secrets/infini_ops_id_ed25519  -P 2222
EOF
  exit 1
}

# 
# Defaults
# 
SSH_USER="infini-ops"
SSH_KEY="${HOME}/.ssh/id_rsa"
APP_DIR="app"
APP_PORT="5050"
SSH_PORT="22"

# 
# Parse flags
# 
while getopts "i:u:k:d:p:P:h" opt; do
  case "${opt}" in
  i) VM_IP="$OPTARG" ;;    # required
  u) SSH_USER="$OPTARG" ;; # optional override
  k) SSH_KEY="$OPTARG" ;;  # optional override
  d) APP_DIR="$OPTARG" ;;  # optional override
  p) APP_PORT="$OPTARG" ;; # optional override
  P) SSH_PORT="$OPTARG" ;; # optional override
  h) print_usage ;;        # help
  *) print_usage ;;        # unknown
  esac
done

# enforce required parameter
: "${VM_IP:?ERROR: VM_IP is required. Use -h for help.}"

# 
# Logging helpers
# 
info() { echo -e " [INFO]  $*"; }
error() { echo -e " [ERROR] $*" >&2; }

# 
# Retry helper: retry <attempts> <delay> <command...>
# 
retry() {
  local attempts="$1" delay="$2"
  shift 2
  for i in $(seq 1 "$attempts"); do
    if "$@"; then
      return 0
    fi
    echo " retry $i/$attempts"
    sleep "$delay"
  done
  return 1
}

# 
# Pre-flight checks
# 
info "Verifying local prerequisites..."
for file in docker-compose.yml prometheus.yml; do
  [[ -f "$APP_DIR/$file" ]] || {
    error "$APP_DIR/$file not found"
    exit 1
  }
done

tools=(ping scp ssh curl)
for cmd in "${tools[@]}"; do
  command -v "$cmd" >/dev/null || {
    error "$cmd not installed"
    exit 1
  }
done

# 
# Check VM reachability and SSH
# 
info "Pinging VM at $VM_IP..."

if [[ "$(uname -o 2>/dev/null)" == "Msys" ]] || grep -qEi "(Microsoft|WSL)" /proc/version 2>/dev/null; then
  # Git Bash or WSL
  if ! /c/Windows/System32/ping.exe -n 3 "$VM_IP" | grep -iq "reply from"; then
    error "VM $VM_IP not reachable (Windows ping failed)"
    exit 1
  fi
else
  # Native Linux or macOS
  if ! ping -c 3 "$VM_IP" >/dev/null; then
    error "VM $VM_IP not reachable (Linux ping failed)"
    exit 1
  fi
fi

SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=5 -p "$SSH_PORT" -i "$SSH_KEY")

info "Waiting for SSH on $VM_IP:$SSH_PORT..."
retry 10 3 ssh "${SSH_OPTS[@]}" "$SSH_USER@$VM_IP" true ||
  {
    error "SSH connection to $VM_IP failed"
    exit 1
  }
info " SSH is up"

# 
# Port conflict check (ignoring Docker-owned processes)
# 
info "Checking for port conflicts on VM..."
ssh "${SSH_OPTS[@]}" "$SSH_USER@$VM_IP" bash <<'EOF'
  ss -tlnp | awk '/:5050|:9090/ && \$0 !~ /docker/ {print; exit 1}'
  echo " No external conflicts on 5050/9090"
EOF

# 
# Copy application & config to VM
# 
info "Copying application and configuration to VM..."
SCP_OPTS=(-P "$SSH_PORT" -i "$SSH_KEY")
scp "${SCP_OPTS[@]}" $APP_DIR/* \
  "$SSH_USER@$VM_IP:~/$APP_DIR"

# 
# Deploy via docker compose on VM
# 
info "Deploying stack on VM via docker compose..."
ssh "${SSH_OPTS[@]}" "$SSH_USER@$VM_IP" APP_DIR="$APP_DIR" bash <<'EOF'
  set -euxo pipefail
  cd ~/$APP_DIR
  export DOCKER_BUILDKIT=0
  export COMPOSE_DOCKER_CLI_BUILD=0
  docker compose down --remove-orphans || true
  docker compose build
  docker compose up -d
  sleep 5
  docker compose ps
EOF

# 
# Health-check /metrics endpoint
# 
info "Verifying Prometheus metrics endpoint..."
CURL_OPTS=(-s -o /dev/null -w '%{http_code}')
if retry 30 3 curl "${CURL_OPTS[@]}" "http://$VM_IP:$APP_PORT/metrics"; then
  CT=$(curl -sI "http://$VM_IP:$APP_PORT/metrics" |
    awk -F": " '/^Content-Type/ {print tolower($2)}' | tr -d '\r')
  if [[ "$CT" =~ ^text/plain ]] &&
    grep -q '^# HELP ' <<<"$(curl -s "http://$VM_IP:$APP_PORT/metrics")"; then
    info " Metrics endpoint is healthy"
    exit 0
  else
    error "Metrics format/content-type is invalid"
    exit 1
  fi
else
  error "Metrics endpoint did not return HTTP 200"
  exit 1
fi

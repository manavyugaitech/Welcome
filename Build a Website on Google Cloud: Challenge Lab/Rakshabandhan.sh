#!/usr/bin/env bash
set -Eeuo pipefail

# ==============================================================================
# Google Cloud Skills Boost: Build a Website on Google Cloud - Challenge Lab
# ==============================================================================
# 1) Build/push monolith
# 2) Create GKE regional cluster
# 3) Deploy/expose monolith
# 4) Build/push Orders + Products
# 5) Deploy/expose Orders + Products
# 6) Configure/build/push Frontend
# 7) Deploy/expose Frontend
# ==============================================================================

trap 'echo; echo "ERROR: command failed at line $LINENO"; exit 1' ERR

# --- UI Helpers ---
log()  { printf '\n\033[1;34m[+] %s\033[0m\n' "$*"; }
warn() { printf '\n\033[1;33m[!] %s\033[0m\n' "$*"; }
die()  { printf '\n\033[1;31m[x] %s\033[0m\n' "$*" >&2; exit 1; }

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

prompt_value() {
  local __var="$1"
  local __label="$2"
  local __default="${3:-}"
  local __value
  local __input="/dev/tty"

  [[ -r "$__input" ]] || __input="/dev/stdin"

  if [[ -n "$__default" ]]; then
    read -r -p "$__label [$__default]: " __value < "$__input"
    __value="${__value:-$__default}"
  else
    read -r -p "$__label: " __value < "$__input"
  fi

  [[ -n "$__value" ]] || die "$__label cannot be empty."
  printf -v "$__var" '%s' "$__value"
}

# --- Prerequisite checks ---
need_cmd gcloud
need_cmd git
need_cmd awk
need_cmd sed
need_cmd curl

ACTIVE_ACCOUNT="$(gcloud auth list --filter=status:ACTIVE --format='value(account)' 2>/dev/null | head -n1 || true)"
[[ -n "$ACTIVE_ACCOUNT" ]] || die "No active gcloud account. Run: gcloud auth login"

PROJECT_ID="${GOOGLE_CLOUD_PROJECT:-${PROJECT_ID:-}}"
if [[ -z "$PROJECT_ID" || "$PROJECT_ID" == "(unset)" ]]; then
  PROJECT_ID="$(gcloud config get-value project 2>/dev/null || true)"
fi
[[ -n "$PROJECT_ID" && "$PROJECT_ID" != "(unset)" ]] \
  || die "Could not detect project ID. Set GOOGLE_CLOUD_PROJECT or run: gcloud config set project PROJECT_ID"

gcloud config set project "$PROJECT_ID" >/dev/null

# Auto-detect configured zone when possible.
ZONE_DEFAULT="${ZONE-}"
if [[ -z "$ZONE_DEFAULT" ]]; then
  ZONE_DEFAULT="${GOOGLE_CLOUD_ZONE-}"
fi
if [[ -z "$ZONE_DEFAULT" ]]; then
  ZONE_DEFAULT="$(gcloud config get-value compute/zone 2>/dev/null || true)"
  [[ "$ZONE_DEFAULT" == "(unset)" ]] && ZONE_DEFAULT=""
fi

prompt_value ZONE "Lab zone" "$ZONE_DEFAULT"

REGION="${REGION-}"
if [[ -z "$REGION" ]]; then
  REGION="${ZONE%-*}"
fi
[[ -n "$REGION" && "$REGION" != "$ZONE" ]] || die "Could not derive region from zone '$ZONE'. Example: us-east4-a"

prompt_value MONOLITH_ID "Monolith image identifier" "${MONOLITH_ID:-}"
prompt_value CLUSTER_NAME "GKE cluster name"            "${CLUSTER_NAME:-}"
prompt_value ORDERS_ID  "Orders image identifier"   "${ORDERS_ID:-}"
prompt_value PRODUCTS_ID "Products image identifier" "${PRODUCTS_ID:-}"
prompt_value FRONTEND_ID "Frontend image identifier" "${FRONTEND_ID:-}"

MONOLITH_IMAGE="gcr.io/${PROJECT_ID}/${MONOLITH_ID}:1.0.0"
ORDERS_IMAGE="gcr.io/${PROJECT_ID}/${ORDERS_ID}:1.0.0"
PRODUCTS_IMAGE="gcr.io/${PROJECT_ID}/${PRODUCTS_ID}:1.0.0"
FRONTEND_IMAGE="gcr.io/${PROJECT_ID}/${FRONTEND_ID}:1.0.0"

log "Project:   $PROJECT_ID"
log "Zone:      $ZONE"
log "Region:    $REGION"
log "Monolith:  $MONOLITH_ID"
log "Cluster:   $CLUSTER_NAME"
log "Orders:    $ORDERS_ID"
log "Products:  $PRODUCTS_ID"
log "Frontend:  $FRONTEND_ID"

# --- Enable required APIs ---
log "Enabling required Google Cloud APIs..."
gcloud services enable \
  cloudbuild.googleapis.com \
  container.googleapis.com \
  containerregistry.googleapis.com \
  --project="$PROJECT_ID"

# --- Source repository ---
REPO_DIR="$HOME/monolith-to-microservices"

if [[ ! -d "$REPO_DIR/.git" ]]; then
  log "Cloning monolith-to-microservices repo..."
  git clone https://github.com/googlecodelabs/monolith-to-microservices.git "$REPO_DIR"
else
  log "Repo already exists: $REPO_DIR"
fi

cd "$REPO_DIR"

log "Running setup.sh..."
bash ./setup.sh

# setup.sh may install/configure nvm but non-interactive shells do not
# necessarily source ~/.bashrc automatically.
export NVM_DIR="${NVM_DIR:-$HOME/.nvm}"

if [[ -s "$NVM_DIR/nvm.sh" ]]; then
  # shellcheck disable=SC1090
  source "$NVM_DIR/nvm.sh"
fi

if ! command -v nvm >/dev/null 2>&1; then
  log "nvm not available; installing nvm..."
  curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.3/install.sh | bash

  export NVM_DIR="$HOME/.nvm"
  # shellcheck disable=SC1090
  source "$NVM_DIR/nvm.sh"
fi

command -v nvm >/dev/null 2>&1 || die "nvm installation failed."
log "Installing/using Node.js 22..."
nvm install 22
nvm use 22

log "Enabling kubectl authentication plugin..."
gcloud components install gke-gcloud-auth-plugin --quiet >/dev/null 2>&1 || true
export USE_GKE_GCLOUD_AUTH_PLUGIN=True

# --- Kubernetes Helper Functions ---
deploy_or_update() {
  local name="$1"
  local image="$2"

  if kubectl get deployment "$name" >/dev/null 2>&1; then
    log "Deployment exists; updating image: $name"
    kubectl set image "deployment/$name" "$name=$image"
  else
    log "Creating deployment: $name"
    kubectl create deployment "$name" --image="$image"
  fi

  kubectl rollout status "deployment/$name" --timeout=10m
}

expose_if_missing() {
  local name="$1"
  local target_port="$2"

  if kubectl get service "$name" >/dev/null 2>&1; then
    log "Service already exists: $name"
  else
    log "Exposing service $name on port 80 -> $target_port"
    kubectl expose deployment "$name" \
      --type=LoadBalancer \
      --port=80 \
      --target-port="$target_port"
  fi
}

wait_for_external_ip() {
  local service="$1"
  local ip=""

  printf '\n\033[1;34m[+] Waiting for external IP: %s\033[0m\n' "$service" >&2

  for _ in {1..60}; do
    ip="$(kubectl get service "$service" \
      -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"

    if [[ -n "$ip" ]]; then
      printf '%s' "$ip"
      return 0
    fi
    sleep 10
  done

  die "Timed out waiting for external IP for service '$service'."
}

# --- Task 1: Build monolith ---
log "Building monolith image..."
cd "$REPO_DIR/monolith"
gcloud builds submit \
  --project="$PROJECT_ID" \
  --tag="$MONOLITH_IMAGE" .

# --- Task 2: Create GKE cluster ---
if gcloud container clusters describe "$CLUSTER_NAME" \
    --region="$REGION" \
    --project="$PROJECT_ID" >/dev/null 2>&1; then
  log "Cluster already exists: $CLUSTER_NAME"
else
  log "Creating GKE regional cluster..."
  gcloud container clusters create "$CLUSTER_NAME" \
    --project="$PROJECT_ID" \
    --region="$REGION" \
    --node-locations="$ZONE" \
    --num-nodes=3
fi

log "Fetching cluster credentials..."
gcloud container clusters get-credentials "$CLUSTER_NAME" \
  --region="$REGION" \
  --project="$PROJECT_ID"

need_cmd kubectl

log "Waiting for cluster nodes..."
kubectl wait --for=condition=Ready nodes --all --timeout=15m

# Monolith Deployment
deploy_or_update "$MONOLITH_ID" "$MONOLITH_IMAGE"
expose_if_missing "$MONOLITH_ID" 8080
wait_for_external_ip "$MONOLITH_ID" >/dev/null

# --- Task 3: Build Orders + Products ---
log "Building Orders image..."
cd "$REPO_DIR/microservices/src/orders"
gcloud builds submit \
  --project="$PROJECT_ID" \
  --tag="$ORDERS_IMAGE" .

log "Building Products image..."
cd "$REPO_DIR/microservices/src/products"
gcloud builds submit \
  --project="$PROJECT_ID" \
  --tag="$PRODUCTS_IMAGE" .

# --- Task 4: Deploy Orders + Products ---
deploy_or_update "$ORDERS_ID" "$ORDERS_IMAGE"
expose_if_missing "$ORDERS_ID" 8081
ORDERS_EXTERNAL_IP="$(wait_for_external_ip "$ORDERS_ID")"

deploy_or_update "$PRODUCTS_ID" "$PRODUCTS_IMAGE"
expose_if_missing "$PRODUCTS_ID" 8082
PRODUCTS_EXTERNAL_IP="$(wait_for_external_ip "$PRODUCTS_ID")"

log "Orders API:   http://${ORDERS_EXTERNAL_IP}/api/orders"
log "Products API: http://${PRODUCTS_EXTERNAL_IP}/api/products"

log "Checking Orders API..."
ORDERS_JSON="$(curl -fsS "http://${ORDERS_EXTERNAL_IP}/api/orders")"
[[ -n "$ORDERS_JSON" ]] || die "Orders API returned an empty response."

log "Checking Products API..."
PRODUCTS_JSON="$(curl -fsS "http://${PRODUCTS_EXTERNAL_IP}/api/products")"
[[ -n "$PRODUCTS_JSON" ]] || die "Products API returned an empty response."

# --- Task 5: Configure + build frontend ---
log "Configuring frontend URLs..."
cd "$REPO_DIR/react-app"

cat > .env <<EOF
REACT_APP_ORDERS_URL=http://${ORDERS_EXTERNAL_IP}/api/orders
REACT_APP_PRODUCTS_URL=http://${PRODUCTS_EXTERNAL_IP}/api/products
EOF

log "Building frontend..."
npm run build

# --- Task 6: Build frontend image ---
log "Building frontend image..."
cd "$REPO_DIR/microservices/src/frontend"
gcloud builds submit \
  --project="$PROJECT_ID" \
  --tag="$FRONTEND_IMAGE" .

# --- Task 7: Deploy frontend ---
deploy_or_update "$FRONTEND_ID" "$FRONTEND_IMAGE"
expose_if_missing "$FRONTEND_ID" 8080
FRONTEND_EXTERNAL_IP="$(wait_for_external_ip "$FRONTEND_ID")"

log "Testing frontend endpoint..."
curl -fsS "http://${FRONTEND_EXTERNAL_IP}" >/dev/null

# --- Summary Output ---
echo
printf '\033[1;32m============================================================\033[0m\n'
printf '\033[1;32m Lab automation completed successfully.\033[0m\n'
printf '\033[1;32m Frontend: http://%s\033[0m\n'          "$FRONTEND_EXTERNAL_IP"
printf '\033[1;32m Orders:   http://%s/api/orders\033[0m\n' "$ORDERS_EXTERNAL_IP"
printf '\033[1;32m Products: http://%s/api/products\033[0m\n' "$PRODUCTS_EXTERNAL_IP"
printf '\033[1;32m============================================================\033[0m\n'

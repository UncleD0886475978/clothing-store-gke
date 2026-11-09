#!/usr/bin/env bash
# =============================================================================
# setup.sh — clothing-store-gke ("Threads & Co." on Google Cloud GKE)
# GCP GKE Autopilot hosting the Threads & Co. online storefront: an nginx
# storefront (page served from a ConfigMap) behind a LoadBalancer, plus the
# store's MySQL 8 database as a StatefulSet.
#
# Modes (first argument):
#   ./setup.sh cluster   Create the GKE Autopilot cluster and configure kubectl
#   ./setup.sh deploy    Deploy storefront + MySQL (namespace: threads)
#   ./setup.sh destroy   Delete the app namespace AND the cluster (asks first)
#
# Overrides (environment variables):
#   CLUSTER_NAME   Default: threads-store
#   REGION         Default: us-central1
#   GCP_PROJECT    Default: your active gcloud project (gcloud config get-value project)
#   NAMESPACE      Default: threads
#   NODE_COUNT     Default: 2  — parity with the other cloud tracks.
#   NODE_SIZE      Default: e2-medium — parity with the other tracks.
#                  NOTE: GKE Autopilot manages nodes for you, so NODE_COUNT and
#                  NODE_SIZE do NOT apply while Autopilot is used (the default).
#                  They are kept here so this script matches the EKS/AKS ones
#                  and are ready if you switch to a standard cluster.
#
# COST WARNING: GKE is NOT free-tier. Autopilot charges per pod resource
# request plus a cluster management fee (one cluster per billing account gets
# a management-fee credit, which helps, but pods still bill). A learning
# cluster left running adds up — create it, learn, then run
# ./setup.sh destroy the same day.
#
# One-liner (fresh Ubuntu/Debian VM):
#   curl -fsSL https://raw.githubusercontent.com/UncleD0886475978/clothing-store-gke/main/setup.sh | bash -s -- cluster
# =============================================================================
set -e

REPO_NAME="clothing-store-gke"
REPO="clothing-store-gke"
OWNER="UncleD0886475978"
REPO_URL="https://github.com/UncleD0886475978/${REPO_NAME}.git"
RUN_ONELINE="curl -fsSL https://raw.githubusercontent.com/${OWNER}/${REPO}/main/setup.sh | bash -s --"

CLUSTER_NAME="${CLUSTER_NAME:-threads-store}"
REGION="${REGION:-us-central1}"
GCP_PROJECT="${GCP_PROJECT:-}"
NODE_COUNT="${NODE_COUNT:-2}"
NODE_SIZE="${NODE_SIZE:-e2-medium}"
NAMESPACE="${NAMESPACE:-threads}"
MODE="${1:-}"

# ---------- pretty output ----------
if [ -t 1 ]; then
  BOLD='\033[1m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
else
  BOLD=''; GREEN=''; CYAN=''; YELLOW=''; RED=''; NC=''
fi
step() { printf "\n${BOLD}${CYAN}==>${NC} ${BOLD}%s${NC}\n" "$*"; }
info() { printf "    %s\n" "$*"; }
ok()   { printf "${GREEN}  ✓ %s${NC}\n" "$*"; }
warn() { printf "${YELLOW}  ! %s${NC}\n" "$*"; }
die()  { printf "${RED}  ✗ %s${NC}\n" "$*" >&2; exit 1; }

# ---------- platform check + base bootstrap ----------
SUDO=""
if [ "$(id -u)" -ne 0 ]; then
  if command -v sudo >/dev/null 2>&1; then
    SUDO="sudo"
  else
    echo "ERROR: this script needs root or sudo to install packages." >&2
    exit 1
  fi
fi
APT=0
if [ "$(uname -s)" = "Linux" ] && command -v apt-get >/dev/null 2>&1; then APT=1; fi
INSTALLED=""
APT_UPDATED=""
note_installed() { INSTALLED="${INSTALLED} $1"; }
apt_update_once() {
  if [ -z "${APT_UPDATED}" ]; then $SUDO apt-get update -y; APT_UPDATED=1; fi
}
apt_install() {
  apt_update_once
  DEBIAN_FRONTEND=noninteractive $SUDO apt-get install -y "$@"
}

bootstrap_base() {
  step "Platform check + base bootstrap (git, curl, ca-certificates, gnupg)"
  if [ "${APT}" -eq 1 ]; then
    BASE_PKGS=""
    command -v git >/dev/null 2>&1 || BASE_PKGS="${BASE_PKGS} git"
    command -v curl >/dev/null 2>&1 || BASE_PKGS="${BASE_PKGS} curl"
    [ -f /etc/ssl/certs/ca-certificates.crt ] || BASE_PKGS="${BASE_PKGS} ca-certificates"
    command -v gpg >/dev/null 2>&1 || BASE_PKGS="${BASE_PKGS} gnupg"
    if [ -n "${BASE_PKGS}" ]; then
      info "Installing base tools:${BASE_PKGS}"
      # shellcheck disable=SC2086
      apt_install ${BASE_PKGS}
      note_installed "${BASE_PKGS}"
    else
      ok "Base tools already present (git, curl, ca-certificates, gnupg)"
    fi
  else
    warn "Non-apt platform detected — this script can only auto-install tools on Ubuntu/Debian."
    info "On macOS/Windows/other Linux: install git, curl, kubectl and the Google Cloud CLI"
    info "manually (https://cloud.google.com/sdk/docs/install), then re-run this script."
    exit 1
  fi
}

# ---------- locate the repo (works for ./setup.sh and for curl | bash) ----------
locate_repo() {
  step "Locating the repo checkout"
  if [ -f "$0" ]; then
    SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
  else
    SCRIPT_DIR="$PWD"
  fi
  if [ -d "k8s" ] && [ -f "k8s/namespace.yaml" ]; then
    REPO_DIR="$PWD"
    info "Already inside the repo checkout: $REPO_DIR"
  elif [ -d "${SCRIPT_DIR}/k8s" ] && [ -f "${SCRIPT_DIR}/k8s/namespace.yaml" ]; then
    REPO_DIR="$SCRIPT_DIR"
    info "Using script location: $REPO_DIR"
  else
    REPO_DIR="$HOME/repos/$REPO_NAME"
    if [ -d "$REPO_DIR/.git" ]; then
      info "Existing checkout found — pulling latest..."
      git -C "$REPO_DIR" pull --ff-only || true
    else
      if ! command -v git >/dev/null 2>&1; then
        die "git not found. Install git first: https://git-scm.com/downloads"
      fi
      info "Cloning $REPO_URL into $REPO_DIR ..."
      mkdir -p "$HOME/repos"
      git clone "$REPO_URL" "$REPO_DIR"
    fi
  fi
  cd "$REPO_DIR"
  K8S_DIR="$REPO_DIR/k8s"
}

# ---------- prerequisite installers ----------
install_kubectl() {
  if command -v kubectl >/dev/null 2>&1; then info "kubectl: already present"; return 0; fi
  if [ "${APT}" -ne 1 ]; then return 1; fi
  if ! command -v sudo >/dev/null 2>&1 && [ "$(id -u)" -ne 0 ]; then return 1; fi
  info "Installing kubectl (official binary)..."
  KARCH="$(dpkg --print-architecture 2>/dev/null || uname -m)"
  case "${KARCH}" in x86_64) KARCH="amd64" ;; aarch64) KARCH="arm64" ;; esac
  KVER="$(curl -fsSL https://dl.k8s.io/release/stable.txt)"
  curl -fsSLO "https://dl.k8s.io/release/${KVER}/bin/linux/${KARCH}/kubectl"
  $SUDO install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
  rm -f kubectl
  note_installed "kubectl"
}

install_gcloud() {
  step "Bootstrapping Google Cloud CLI"
  if command -v gcloud >/dev/null 2>&1; then
    info "gcloud: already present ($(gcloud --version 2>/dev/null | head -1))"
  elif [ "${APT}" -eq 1 ]; then
    info "Installing Google Cloud CLI from the official Google Cloud apt repository..."
    # Official repo: https://cloud.google.com/sdk/docs/install#deb
    curl -fsSL https://packages.cloud.google.com/apt/doc/apt-key.gpg | $SUDO gpg --dearmor --yes -o /usr/share/keyrings/cloud.google.gpg
    echo "deb [signed-by=/usr/share/keyrings/cloud.google.gpg] https://packages.cloud.google.com/apt cloud-sdk main" | $SUDO tee /etc/apt/sources.list.d/google-cloud-sdk.list >/dev/null
    APT_UPDATED=""   # force an apt-get update so the new repo is picked up
    apt_install google-cloud-cli google-cloud-cli-gke-gcloud-auth-plugin
    note_installed "google-cloud-cli google-cloud-cli-gke-gcloud-auth-plugin"
  else
    return 1
  fi
  command -v gcloud >/dev/null 2>&1 || return 1
  ok "gcloud ready"
  # kubectl talks to GKE through the gke-gcloud-auth-plugin — make sure it exists.
  step "Checking the GKE auth plugin (kubectl <-> GKE)"
  if command -v gke-gcloud-auth-plugin >/dev/null 2>&1; then
    ok "gke-gcloud-auth-plugin present"
  elif [ "${APT}" -eq 1 ]; then
    info "Installing google-cloud-cli-gke-gcloud-auth-plugin..."
    apt_install google-cloud-cli-gke-gcloud-auth-plugin
    note_installed "google-cloud-cli-gke-gcloud-auth-plugin"
    command -v gke-gcloud-auth-plugin >/dev/null 2>&1 || die "gke-gcloud-auth-plugin still not found after install — kubectl will not be able to authenticate to GKE."
    ok "gke-gcloud-auth-plugin installed"
  else
    die "gke-gcloud-auth-plugin not found. Install it (gcloud components install gke-gcloud-auth-plugin, or the google-cloud-cli-gke-gcloud-auth-plugin apt package), then re-run."
  fi
  export USE_GKE_GCLOUD_AUTH_PLUGIN=True
}

need_kubectl() {
  step "Bootstrapping kubectl"
  MISSING_LIST=""
  install_kubectl || MISSING_LIST="${MISSING_LIST} kubectl(https://kubernetes.io/docs/tasks/tools/)"
  if [ -n "${MISSING_LIST}" ]; then
    die "could not auto-install kubectl on this platform. Missing:${MISSING_LIST} — install manually, then re-run."
  fi
  ok "kubectl: $(kubectl version --client 2>/dev/null | head -1 || echo present)"
}

check_gcloud() {
  install_gcloud || die "gcloud not found and could not be installed. Install it: https://cloud.google.com/sdk/docs/install — then run: gcloud auth login"
  step "Checking Google Cloud login"
  ACTIVE_ACCOUNT="$(gcloud auth list --filter=status:ACTIVE --format='value(account)' 2>/dev/null || true)"
  if [ -z "$ACTIVE_ACCOUNT" ]; then
    echo ""
    echo "You are not logged in to Google Cloud (no ACTIVE account in 'gcloud auth list')."
    echo "Log in first, then run this script again:"
    echo "    gcloud auth login"
    echo "    gcloud config set project YOUR_PROJECT_ID"
    exit 1
  fi
  if [ -z "$GCP_PROJECT" ]; then
    GCP_PROJECT="$(gcloud config get-value project 2>/dev/null || true)"
  fi
  [ -n "$GCP_PROJECT" ] || die "No Google Cloud project set. Run: gcloud config set project YOUR_PROJECT_ID — or set GCP_PROJECT and re-run."
  info "Logged in as: $ACTIVE_ACCOUNT"
  info "Project: $GCP_PROJECT"
}

print_summary() {
  cat <<EOF

=================== BOOTSTRAP SUMMARY ===================
Installed during this run:${INSTALLED:- (nothing — all tools were already present)}
Working copy: ${REPO_DIR}
Next time, set up from scratch on any fresh Ubuntu VM with one line:
  ${RUN_ONELINE} <cluster|deploy|destroy>
=========================================================
EOF
}

# ---------- modes ----------
do_cluster() {
  check_gcloud
  need_kubectl

  step "Enabling the Kubernetes Engine API on project '$GCP_PROJECT'"
  gcloud services enable container.googleapis.com --project "$GCP_PROJECT"

  if gcloud container clusters describe "$CLUSTER_NAME" --region "$REGION" --project "$GCP_PROJECT" >/dev/null 2>&1; then
    info "GKE cluster '$CLUSTER_NAME' already exists in $REGION — skipping creation."
  else
    step "Creating GKE Autopilot cluster '$CLUSTER_NAME' in $REGION"
    info "Autopilot manages the nodes for you (NODE_COUNT/NODE_SIZE don't apply)."
    info "This usually takes 5-10 minutes."
    gcloud container clusters create-auto "$CLUSTER_NAME" \
      --region "$REGION" \
      --project "$GCP_PROJECT"
  fi

  step "Pointing kubectl at the cluster"
  gcloud container clusters get-credentials "$CLUSTER_NAME" --region "$REGION" --project "$GCP_PROJECT"

  step "Verifying nodes"
  kubectl get nodes
  print_summary
  echo ""
  echo "Cluster is ready. Next step:"
  echo "    ./setup.sh deploy"
}

require_kube_access() {
  need_kubectl
  step "Checking kubectl can reach a cluster"
  kubectl cluster-info >/dev/null 2>&1 || die "kubectl cannot reach a cluster. Run ./setup.sh cluster first (or fix your kubeconfig)."
  kubectl get nodes
}

do_deploy() {
  require_kube_access
  step "Deploying Threads & Co. (storefront + MySQL) to namespace '$NAMESPACE'"
  kubectl apply -f "$K8S_DIR/namespace.yaml"
  if kubectl -n "$NAMESPACE" get secret mysql-secret >/dev/null 2>&1; then
    info "mysql-secret already exists — keeping it."
  elif [ -f "$K8S_DIR/mysql-secret.yaml" ]; then
    info "Applying your k8s/mysql-secret.yaml"
    kubectl apply -f "$K8S_DIR/mysql-secret.yaml"
  else
    echo "    WARNING: no mysql-secret found, so the EXAMPLE secret is being"
    echo "    applied with the demo passwords 'threads_change_me' /"
    echo "    'threads_root_change_me'."
    echo "    Fine for learning on a throwaway cluster; change it anywhere else."
    kubectl apply -f "$K8S_DIR/mysql-secret.example.yaml"
  fi
  kubectl apply -f "$K8S_DIR/mysql-schema-configmap.yaml"
  kubectl apply -f "$K8S_DIR/mysql-pvc.yaml"
  kubectl apply -f "$K8S_DIR/mysql-statefulset.yaml"
  kubectl apply -f "$K8S_DIR/mysql-service.yaml"
  kubectl apply -f "$K8S_DIR/storefront-page-configmap.yaml"
  kubectl apply -f "$K8S_DIR/web-deployment.yaml"
  kubectl apply -f "$K8S_DIR/web-service.yaml"

  step "Waiting for MySQL to be ready (Autopilot provisions capacity on first deploy)"
  kubectl -n "$NAMESPACE" rollout status statefulset/mysql --timeout=600s
  ok "MySQL is ready"
  step "Waiting for the storefront to be ready"
  kubectl -n "$NAMESPACE" rollout status deployment/storefront-web --timeout=300s
  ok "Storefront is ready"
  kubectl -n "$NAMESPACE" get pods,svc,pvc

  step "Storefront address (LoadBalancer)"
  WEB_ADDR=""
  for i in $(seq 1 30); do
    WEB_ADDR="$(kubectl -n "$NAMESPACE" get svc storefront-web -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"
    if [ -z "$WEB_ADDR" ]; then
      WEB_ADDR="$(kubectl -n "$NAMESPACE" get svc storefront-web -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)"
    fi
    [ -n "$WEB_ADDR" ] && break
    sleep 10
  done
  print_summary
  echo ""
  if [ -n "$WEB_ADDR" ]; then
    echo "Threads & Co. storefront is live:"
    echo "    http://$WEB_ADDR"
  else
    echo "The LoadBalancer address is still provisioning. Check it with:"
    echo "    kubectl -n $NAMESPACE get svc storefront-web"
  fi
  echo ""
  echo "No public IP yet? Port-forward fallback (leave it open, then browse http://localhost:8080):"
  echo "    kubectl -n $NAMESPACE port-forward svc/storefront-web 8080:80"
  echo ""
  echo "Talk to the database:"
  echo "    kubectl -n $NAMESPACE port-forward svc/mysql 3306:3306"
  echo "    mysql -h 127.0.0.1 -u threads -p threads_store   (password: your mysql-secret)"
  echo ""
  echo "When you are done learning, clean up (the cluster costs money while it exists):"
  echo "    ./setup.sh destroy"
}

do_destroy() {
  check_gcloud
  need_kubectl
  echo ""
  echo "======================================================================"
  echo "  DESTROY: this deletes the Threads & Co. app namespace AND the GKE"
  echo "  cluster '$CLUSTER_NAME' in $REGION (project $GCP_PROJECT),"
  echo "  with all data."
  echo ""
  echo "  COST NOTE: deleting is what STOPS the charges — pods and the"
  echo "  cluster management fee bill for as long as the cluster exists."
  echo "======================================================================"
  printf "Type yes to continue: "
  read -r CONFIRM
  [ "$CONFIRM" = "yes" ] || { echo "Aborted — nothing was deleted."; exit 0; }

  step "Deleting the app namespace '$NAMESPACE' (if reachable)"
  kubectl delete namespace "$NAMESPACE" --ignore-not-found --timeout=120s 2>/dev/null || info "Cluster not reachable from kubectl — continuing with cluster deletion."

  step "Deleting the GKE cluster '$CLUSTER_NAME'"
  gcloud container clusters delete "$CLUSTER_NAME" \
    --region "$REGION" \
    --project "$GCP_PROJECT" \
    --quiet
  echo ""
  echo "Destroyed. Billing for this cluster stops once deletion completes."
}

# ---------- main ----------
case "$MODE" in
  cluster|deploy|destroy) ;;
  *)
    echo "clothing-store-gke — Threads & Co. on Google Cloud GKE (Autopilot)"
    echo ""
    echo "Usage: $0 <cluster|deploy|destroy>"
    echo "  cluster  Create the GKE Autopilot cluster and configure kubectl"
    echo "  deploy   Deploy the storefront + MySQL into namespace '$NAMESPACE'"
    echo "  destroy  Delete the app and the cluster (asks for confirmation)"
    echo ""
    echo "Overrides: CLUSTER_NAME, REGION, GCP_PROJECT, NAMESPACE"
    echo "COST: GKE is not free-tier — destroy the cluster when you are done learning."
    exit 1
    ;;
esac

bootstrap_base
locate_repo

case "$MODE" in
  cluster) do_cluster ;;
  deploy)  do_deploy ;;
  destroy) do_destroy ;;
esac

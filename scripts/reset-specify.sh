#!/bin/bash
# =============================================================================
# Specify Deployment Reset Script
#
# Tears down and redeploys the Specify Kubernetes resources. Does NOT touch
# the database — use manage-db.sh for database operations.
#
# Usage:
#   ./scripts/reset-specify.sh <environment> [--nuke]
#
# Environments:
#   dev   - Local k3d cluster
#   uat   - UAT on AKS (az-aks-oim03)
#   prod  - Production on AKS (az-aks-prod01)
#
# Options:
#   --nuke    (dev only) Delete and recreate the entire k3d cluster
#
# Examples:
#   ./scripts/reset-specify.sh dev          # Quick reset (namespace only)
#   ./scripts/reset-specify.sh dev --nuke   # Full cluster recreate
#   ./scripts/reset-specify.sh uat          # Redeploy UAT pods
#   ./scripts/reset-specify.sh prod         # Redeploy prod pods
# =============================================================================

set -e

NAMESPACE="herbarium-specify"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo_info()  { echo -e "${GREEN}✓${NC} $1"; }
echo_step()  { echo -e "${BLUE}==>${NC} $1"; }
echo_warn()  { echo -e "${YELLOW}⚠${NC} $1"; }
echo_error() { echo -e "${RED}✗${NC} $1"; }

show_usage() {
    echo ""
    echo "Usage: $0 <environment> [--nuke]"
    echo ""
    echo "Environments: dev | uat | prod"
    echo ""
    echo "Options:"
    echo "  --nuke    (dev only) Delete and recreate the entire k3d cluster"
    echo ""
    echo "This resets Kubernetes resources (pods, services, etc)."
    echo "It does NOT touch the database. Use manage-db.sh for that."
    echo ""
    exit "${1:-1}"
}

# --- Parse arguments ---
ENV=""
NUKE=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        dev|uat|prod) ENV="$1"; shift ;;
        --nuke) NUKE=true; shift ;;
        --help|-h) show_usage 0 ;;
        *) echo_error "Unknown argument: $1"; show_usage ;;
    esac
done

[ -z "$ENV" ] && { echo_error "Environment required"; show_usage; }

# --- Environment config ---
case "$ENV" in
    dev)
        CONTEXT="k3d-specify-test"
        CLUSTER_NAME="specify-test"
        OVERLAY="kustomize/overlays/dev"
        ;;
    uat)
        CONTEXT="az-aks-oim03"
        OVERLAY="kustomize/overlays/uat"
        ;;
    prod)
        CONTEXT="az-aks-prod01"
        OVERLAY="kustomize/overlays/prod"
        ;;
esac

# --nuke only valid for dev
if [ "$NUKE" = true ] && [ "$ENV" != "dev" ]; then
    echo_error "--nuke is only available for dev (would destroy the cluster)"
    exit 1
fi

echo ""
echo_step "Specify Deployment Reset"
echo "  Environment: $ENV"
echo "  Context:     $CONTEXT"
[ "$NUKE" = true ] && echo "  Mode:        NUKE (full cluster recreate)"
echo ""

# --- Wait for pods helper ---
wait_for_pods() {
    local timeout=300 elapsed=0
    while [ $elapsed -lt $timeout ]; do
        local not_ready=$(kubectl get pods -n "$NAMESPACE" --no-headers 2>/dev/null | \
            grep -v "Completed" | \
            awk '{split($2, r, "/"); if (r[1] != r[2]) print $1}' | wc -l)
        local total=$(kubectl get pods -n "$NAMESPACE" --no-headers 2>/dev/null | grep -v "Completed" | wc -l)
        local ready=$((total - not_ready))

        if [ "$not_ready" -eq 0 ] && [ "$total" -gt 0 ]; then
            echo_info "All pods ready ($ready/$total)"
            return 0
        fi
        printf "\r  Pods ready: %d/%d..." $ready $total
        sleep 5
        elapsed=$((elapsed + 5))
    done
    echo ""
    echo_warn "Timeout — some pods may still be starting"
}

# =============================================================================
# DEV
# =============================================================================
if [ "$ENV" = "dev" ]; then

    if [ "$NUKE" = true ]; then
        # Full cluster nuke and recreate
        echo_step "Deleting namespace..."
        kubectl config use-context "$CONTEXT" > /dev/null 2>&1 || true
        kubectl delete namespace $NAMESPACE --ignore-not-found=true > /dev/null 2>&1 || true
        # Wait for namespace to be gone
        for i in $(seq 1 60); do
            kubectl get namespace $NAMESPACE > /dev/null 2>&1 || break
            sleep 2
        done
        echo_info "Namespace deleted"

        echo_step "Deleting k3d cluster..."
        k3d cluster delete $CLUSTER_NAME > /dev/null 2>&1 || true
        echo_info "Cluster deleted"

        echo_step "Creating fresh k3d cluster..."
        k3d cluster create $CLUSTER_NAME > /dev/null 2>&1
        echo_info "Cluster created"

        # Merge kubeconfig
        KUBECONFIG=~/.kube/config:$(k3d kubeconfig write $CLUSTER_NAME 2>/dev/null) \
            kubectl config view --flatten > ~/.kube/config.new 2>/dev/null
        mv ~/.kube/config.new ~/.kube/config
        kubectl config use-context "k3d-${CLUSTER_NAME}" > /dev/null 2>&1

        echo_step "Creating namespace..."
        kubectl create namespace $NAMESPACE > /dev/null 2>&1
        echo_info "Namespace created"

        echo_step "Applying kustomize overlay..."
        kubectl apply -k $OVERLAY > /dev/null 2>&1
        echo_info "Configuration applied"

        echo_step "Waiting for pods..."
        wait_for_pods

    else
        # Quick reset — delete namespace and redeploy
        kubectl config use-context "$CONTEXT" > /dev/null 2>&1 || {
            echo_error "Failed to switch context. Is k3d running? Try: k3d cluster start $CLUSTER_NAME"
            exit 1
        }

        echo_step "Deleting namespace (may take 1-2 min for PVC cleanup)..."
        kubectl delete namespace $NAMESPACE --ignore-not-found=true > /dev/null 2>&1 &
        DEL_PID=$!
        while kill -0 $DEL_PID 2>/dev/null; do
            printf "."
            sleep 3
        done
        echo ""
        # Wait for it to actually be gone
        for i in $(seq 1 40); do
            kubectl get namespace $NAMESPACE > /dev/null 2>&1 || break
            sleep 3
        done
        echo_info "Namespace deleted"

        echo_step "Creating namespace..."
        kubectl create namespace $NAMESPACE > /dev/null 2>&1
        echo_info "Namespace created"

        echo_step "Applying kustomize overlay..."
        kubectl apply -k $OVERLAY > /dev/null 2>&1
        echo_info "Configuration applied"

        echo_step "Waiting for pods..."
        wait_for_pods
    fi

    echo ""
    echo_info "Dev reset complete!"
    echo -e "Access: ${GREEN}http://localhost:8000/specify/${NC} (with port-forward)"
    echo ""
    echo "Start port-forward:"
    echo "  kubectl port-forward -n $NAMESPACE svc/nginx 8000:80"
    echo ""
    exit 0
fi

# =============================================================================
# UAT / PROD
# =============================================================================

# Ensure kubeconfig is merged
ACCESS_FILE=""
[ "$ENV" = "uat" ] && ACCESS_FILE="uat_access.yaml"
[ "$ENV" = "prod" ] && ACCESS_FILE="az-aks-prod01.yaml"

if [ -n "$ACCESS_FILE" ] && [ -f "$ACCESS_FILE" ]; then
    KUBECONFIG="$ACCESS_FILE":~/.kube/config kubectl config view --flatten > ~/.kube/config.new 2>/dev/null
    mv ~/.kube/config.new ~/.kube/config
fi

echo_step "Switching to context: $CONTEXT"
kubectl config use-context "$CONTEXT" > /dev/null 2>&1 || {
    echo_error "Failed to switch to context $CONTEXT"
    exit 1
}
echo_info "Context: $CONTEXT"

# Verify access
kubectl get namespace "$NAMESPACE" > /dev/null 2>&1 || {
    echo_error "Cannot access namespace $NAMESPACE"
    exit 1
}

echo -e "${RED}This will tear down and redeploy all pods in $ENV. Database is NOT affected.${NC}"
read -p "Type 'yes' to continue: " CONFIRM
[ "$CONFIRM" != "yes" ] && { echo_error "Cancelled"; exit 0; }

echo_step "Deleting resources..."
kubectl delete -k $OVERLAY -n $NAMESPACE > /dev/null 2>&1 || true
sleep 5
echo_info "Resources deleted"

echo_step "Redeploying..."
kubectl apply -k $OVERLAY > /dev/null 2>&1
echo_info "Configuration applied"

echo_step "Waiting for pods..."
wait_for_pods

echo ""
echo_info "$ENV reset complete!"
case "$ENV" in
    uat)  echo -e "Access: ${GREEN}https://specify-test.dbca.wa.gov.au/specify/${NC}" ;;
    prod) echo -e "Access: ${GREEN}https://specify.dbca.wa.gov.au/specify/${NC}" ;;
esac
echo ""

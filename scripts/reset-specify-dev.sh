#!/bin/bash

# Specify 7 Dev Reset Script
# Usage: 
#   ./reset-specify-dev.sh           # Quick reset (delete/recreate namespace only)
#   ./reset-specify-dev.sh --nuke    # Full reset (delete/recreate entire cluster)

set -e  # Exit on error

NAMESPACE="herbarium-specify"
CLUSTER_NAME="specify-test"
SQL_DUMP="kustomize/base/specify_dev_dump.sql"
OVERLAY="kustomize/overlays/dev"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo_info() {
    echo -e "${GREEN}✓${NC} $1"
}

echo_step() {
    echo -e "${BLUE}==>${NC} $1"
}

echo_warn() {
    echo -e "${YELLOW}⚠${NC} $1"
}

echo_error() {
    echo -e "${RED}✗${NC} $1"
}

# Spinner for operations
spinner() {
    local pid=$1
    local message=$2
    local spin='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
    local i=0
    
    while kill -0 $pid 2>/dev/null; do
        i=$(( (i+1) %10 ))
        printf "\r${BLUE}${spin:$i:1}${NC} $message"
        sleep 0.1
    done
    printf "\r${GREEN}✓${NC} $message\n"
}

# Check if --nuke flag is provided
NUKE_MODE=false
if [[ "$1" == "--nuke" ]]; then
    NUKE_MODE=true
    echo_step "🔥 NUKE MODE - Full cluster reset"
else
    echo_step "🔄 Quick reset mode"
fi
echo ""

echo_step "Checking kubectl context..."
CURRENT_CONTEXT=$(kubectl config current-context 2>/dev/null || echo "none")
if [[ "$CURRENT_CONTEXT" != "k3d-$CLUSTER_NAME" ]]; then
    echo_warn "Current context: $CURRENT_CONTEXT"
    if [ "$NUKE_MODE" = true ]; then
        echo_info "NUKE mode will create the cluster, continuing..."
    else
        echo ""
        read -p "Switch to k3d-$CLUSTER_NAME context? (y/n) " -n 1 -r
        echo ""
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            kubectl config use-context k3d-$CLUSTER_NAME
            echo_info "Switched to k3d-$CLUSTER_NAME"
        else
            echo_error "Cannot proceed without correct context"
            exit 1
        fi
    fi
else
    echo_info "Context: $CURRENT_CONTEXT"
fi

# Function to wait for namespace deletion
wait_for_namespace_deletion() {
    local timeout=120
    local elapsed=0
    local spin='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
    local spin_counter=0
    
    while kubectl get namespace $NAMESPACE &> /dev/null; do
        if [ $elapsed -ge $timeout ]; then
            echo ""
            echo_error "Timeout waiting for namespace deletion"
            exit 1
        fi
        
        spin_index=$((spin_counter % 10))
        printf "\r${BLUE}${spin:$spin_index:1}${NC} Waiting for namespace deletion... ${elapsed}s"
        sleep 0.1
        spin_counter=$((spin_counter + 1))
        elapsed=$(awk "BEGIN {print $spin_counter * 0.1}" | cut -d. -f1)
    done
    printf "\r${GREEN}✓${NC} Namespace deleted successfully\n"
}

# Function to wait for pods to be ready (excluding completed jobs)
wait_for_pods() {
    local timeout=300
    local elapsed=0
    local all_ready=false
    local ready_count=0
    local pod_count=0
    local spin='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
    local spin_counter=0
    
    while [ $elapsed -lt $timeout ]; do
        if [ $((spin_counter % 30)) -eq 0 ]; then
            local not_ready=$(kubectl get pods -n "$NAMESPACE" --no-headers 2>/dev/null | \
                grep -v "Completed" | \
                awk '{
                    split($2, ready, "/");
                    if (ready[1] != ready[2]) print $1
                }' | wc -l)
            
            pod_count=$(kubectl get pods -n "$NAMESPACE" --no-headers 2>/dev/null | grep -v "Completed" | wc -l)
            ready_count=$((pod_count - not_ready))
            
            if [ "$not_ready" -eq 0 ] && [ "$pod_count" -gt 0 ]; then
                printf "\r${GREEN}✓${NC} All pods are ready!\n"
                all_ready=true
                break
            fi
        fi
        
        spin_index=$((spin_counter % 10))
        printf "\r${BLUE}${spin:$spin_index:1}${NC} Pods ready: %d/%d" $ready_count $pod_count
        sleep 0.1
        spin_counter=$((spin_counter + 1))
        elapsed=$(awk "BEGIN {print $spin_counter * 0.1}" | cut -d. -f1)
    done
    
    if [ "$all_ready" = false ]; then
        echo ""
        echo_warn "Timeout reached. Some pods may still be starting."
    fi
    
    echo ""
    kubectl get pods -n "$NAMESPACE"
    return 0
}

if [ "$NUKE_MODE" = true ]; then
    echo_step "Step 1/8: Deleting namespace..."
    kubectl delete namespace $NAMESPACE --ignore-not-found=true > /dev/null 2>&1 &
    spinner $! "Deleting namespace"
    wait_for_namespace_deletion
    
    echo_step "Step 2/8: Deleting k3d cluster..."
    k3d cluster delete $CLUSTER_NAME > /dev/null 2>&1 &
    spinner $! "Deleting cluster" || echo_warn "Cluster may not exist, continuing..."
    
    echo_step "Step 3/8: Creating fresh k3d cluster..."
    k3d cluster create $CLUSTER_NAME > /dev/null 2>&1 &
    spinner $! "Creating cluster"
    
    echo_step "Step 4/8: Creating directory in k3d container..."
    docker exec k3d-${CLUSTER_NAME}-server-0 mkdir -p /tmp/specify-init
    echo_info "Directory created"
    
    echo_step "Step 5/8: Copying SQL dump to k3d container..."
    docker cp $SQL_DUMP k3d-${CLUSTER_NAME}-server-0:/tmp/specify-init/init.sql
    echo_info "SQL dump copied"
    
    echo_step "Step 6/8: Creating namespace..."
    kubectl create namespace $NAMESPACE > /dev/null 2>&1
    echo_info "Namespace created"
    
    echo_step "Step 7/8: Applying Kustomize overlay..."
    kubectl apply -k $OVERLAY > /dev/null 2>&1 &
    spinner $! "Applying configuration"
    
    echo_step "Step 8/8: Waiting for pods to be ready..."
    wait_for_pods
    
else
    echo_step "Step 1/4: Deleting namespace..."
    kubectl delete namespace $NAMESPACE --ignore-not-found=true > /dev/null 2>&1 &
    spinner $! "Deleting namespace"
    wait_for_namespace_deletion
    
    echo_step "Step 2/4: Creating namespace..."
    kubectl create namespace $NAMESPACE > /dev/null 2>&1
    echo_info "Namespace created"
    
    echo_step "Step 3/4: Applying Kustomize overlay..."
    kubectl apply -k $OVERLAY > /dev/null 2>&1 &
    spinner $! "Applying configuration"
    
    echo_step "Step 4/4: Waiting for pods to be ready..."
    wait_for_pods
fi

echo ""
echo_info "✅ Reset complete!"
echo ""

echo_step "Waiting for Specify backend to be fully initialised..."
check_specify_ready() {
    sleep 20
    for i in {1..12}; do
        if kubectl logs -n "$NAMESPACE" deployment/specify --tail=20 2>/dev/null | grep -q "Booting worker"; then
            return 0
        fi
        sleep 5
    done
    return 1
}

check_specify_ready &
spinner $! "Checking Specify backend"

if kubectl logs -n "$NAMESPACE" deployment/specify --tail=20 2>/dev/null | grep -q "Booting worker"; then
    echo_info "Specify backend is ready!"
else
    echo_warn "Could not confirm Specify backend is ready, but continuing..."
fi

echo ""

echo_step "Cleaning up any existing port-forwards on port 8000..."
(lsof -ti:8000 | xargs kill -9 2>/dev/null || true; sleep 1) &
spinner $! "Cleaning up port-forwards"

echo_step "Starting port-forward on localhost:8000..."
echo ""
echo -e "${GREEN}🚀 Specify 7 will be available at:${NC} http://localhost:8000/specify/"
echo ""
echo "Press Ctrl+C to stop the port-forward and exit"
echo ""

# Start port-forward in foreground so user can Ctrl+C to stop
kubectl port-forward -n "$NAMESPACE" svc/nginx 8000:80

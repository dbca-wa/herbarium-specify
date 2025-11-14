#!/bin/bash

# Specify 7 UAT Reset Script
# 
# This script resets the Specify 7 deployment in the Rancher UAT environment
# by deleting all resources within the namespace (not the namespace itself).
#
# Usage: 
#   ./reset-specify-uat.sh           # Reset UAT deployment
#   ./reset-specify-uat.sh --help    # Show help message
#
# Prerequisites:
#   - kubectl configured with az-aks-oim03 context
#   - VPN disconnected (VPN causes 406 errors with Rancher)
#   - .env file configured in kustomize/overlays/uat/
#
# Important: This deletes all resources including PVCs (data not tied to db or azure storage will be lost)!

set -e

NAMESPACE="herbarium-specify"
CLUSTER_CONTEXT="az-aks-oim03"
OVERLAY="kustomize/overlays/uat"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

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

show_help() {
    cat << EOF
Specify 7 UAT Reset Script

Resets the UAT deployment by deleting all resources within the namespace.
Note: Does NOT delete the namespace itself (RBAC restrictions).

Usage:
    ./reset-specify-uat.sh           Reset UAT deployment
    ./reset-specify-uat.sh --help    Show this help message

Prerequisites:
    • kubectl with az-aks-oim03 context
    • Ensure any VPN disconnected
    • .env file in kustomize/overlays/uat/

What this does:
    1. Verifies kubectl context
    2. Deletes all resources in namespace
    3. Redeploys from Kustomize overlay
    4. Waits for pods to be ready

Warning: This deletes PVCs and all data!
EOF
    exit 0
}

[[ "$1" == "--help" ]] && show_help

echo_step "🔄 UAT reset mode"
echo ""

echo_step "Step 1/6: Checking kubectl context..."
CURRENT_CONTEXT=$(kubectl config current-context)
if [[ "$CURRENT_CONTEXT" != "$CLUSTER_CONTEXT" ]]; then
    echo_error "Wrong context: $CURRENT_CONTEXT"
    echo "Switch to UAT: kubectl config use-context $CLUSTER_CONTEXT"
    exit 1
fi
echo_info "Context: $CLUSTER_CONTEXT"

echo_step "Step 2/6: Deleting resources in namespace..."
kubectl delete -k $OVERLAY -n $NAMESPACE > /dev/null 2>&1 &
spinner $! "Deleting resources" || echo_info "No resources to delete"

echo_step "Step 3/6: Waiting for resources to terminate..."
sleep 5 &
spinner $! "Waiting for termination"

echo_step "Step 4/6: Deploying fresh..."
kubectl apply -k $OVERLAY > /dev/null 2>&1 &
spinner $! "Applying configuration"

echo_step "Step 5/6: Waiting for PVCs to be bound..."
pvc_timeout=60
pvc_elapsed=0
pvc_bound=false
pvc_status="Unknown"
spin_chars='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
spin_counter=0

while [ $pvc_elapsed -lt $pvc_timeout ]; do
    # Check status every 3 seconds (30 iterations at 0.1s each)
    if [ $((spin_counter % 30)) -eq 0 ]; then
        pvc_status=$(kubectl get pvc specify-storage -n $NAMESPACE -o jsonpath='{.status.phase}' 2>/dev/null || echo "NotFound")
        
        if [ "$pvc_status" = "Bound" ]; then
            printf "\r${GREEN}✓${NC} PVC bound successfully\n"
            pvc_bound=true
            break
        fi
    fi
    
    spin_index=$((spin_counter % 10))
    printf "\r${BLUE}${spin_chars:$spin_index:1}${NC} Waiting for PVC (status: $pvc_status)... ${pvc_elapsed}s"
    sleep 0.1
    spin_counter=$((spin_counter + 1))
    pvc_elapsed=$(awk "BEGIN {print $spin_counter * 0.1}" | cut -d. -f1)
done

if [ "$pvc_bound" = false ]; then
    echo ""
    echo_warn "PVC not bound yet, but continuing..."
    kubectl get pvc -n $NAMESPACE
fi

echo_step "Step 6/6: Waiting for pods to be ready..."
pod_timeout=300
pod_elapsed=0
all_ready=false
ready_count=0
pod_count=0
spin_chars='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
spin_counter=0

while [ $pod_elapsed -lt $pod_timeout ]; do
    # Check pod status every 3 seconds (30 iterations at 0.1s each)
    if [ $((spin_counter % 30)) -eq 0 ]; then
        not_ready=$(kubectl get pods -n "$NAMESPACE" --no-headers 2>/dev/null | \
            grep -v "Completed" | \
            awk '{
                split($2, ready, "/");
                if (ready[1] != ready[2]) print $1
            }' | wc -l)
        
        pod_count=$(kubectl get pods -n "$NAMESPACE" --no-headers 2>/dev/null | grep -v "Completed" | wc -l)
        ready_count=$((pod_count - not_ready))
        
        # Check if all pods (except Completed ones) are ready
        if [ "$not_ready" -eq 0 ] && [ "$pod_count" -gt 0 ]; then
            printf "\r${GREEN}✓${NC} All pods are ready!\n"
            all_ready=true
            break
        fi
    fi
    
    spin_index=$((spin_counter % 10))
    printf "\r${BLUE}${spin_chars:$spin_index:1}${NC} Pods ready: %d/%d" $ready_count $pod_count
    sleep 0.1
    spin_counter=$((spin_counter + 1))
    pod_elapsed=$(awk "BEGIN {print $spin_counter * 0.1}" | cut -d. -f1)
done

if [ "$all_ready" = false ]; then
    echo ""
    echo_warn "Timeout reached. Some pods may still be starting."
fi

echo ""
echo_step "Deployment status:"
kubectl get pods -n $NAMESPACE
echo ""

echo_info "UAT reset complete!"
echo ""
echo -e "${GREEN}🚀 Specify 7 UAT is available at:${NC} https://specify-test.dbca.wa.gov.au/specify/"
echo ""

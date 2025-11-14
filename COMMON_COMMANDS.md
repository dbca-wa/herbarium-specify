# Common Kubectl and Kustomize Commands

Quick reference for managing Specify 7 deployments across environments.

## Context Management

```bash
# List all available contexts
kubectl config get-contexts

# Switch to dev environment (k3d local cluster)
kubectl config use-context k3d-specify-test

# Switch to UAT environment (Rancher AKS)
kubectl config use-context az-aks-oim03

# Switch to production environment (Rancher AKS)
kubectl config use-context <prod-cluster-context-name>

# Check current context
kubectl config current-context

# View current context configuration
kubectl config view --minify
```

## Deployment Commands

```bash
# Deploy to dev environment
kubectl apply -k kustomize/overlays/dev

# Deploy to UAT environment
kubectl apply -k kustomize/overlays/uat

# Deploy to production environment
kubectl apply -k kustomize/overlays/prod

# Preview what will be deployed (dry-run)
kubectl apply -k kustomize/overlays/uat --dry-run=client

# Build and view manifests without applying
kubectl kustomize kustomize/overlays/uat
```

## Viewing Resources

```bash
# List all pods in namespace
kubectl get pods -n herbarium-specify

# List all resources (pods, services, deployments, etc.)
kubectl get all -n herbarium-specify

# List persistent volume claims
kubectl get pvc -n herbarium-specify

# List ingresses
kubectl get ingress -n herbarium-specify

# Get detailed information about a pod
kubectl describe pod <pod-name> -n herbarium-specify

# Get deployment status
kubectl get deployments -n herbarium-specify
```



## Logs and Debugging

```bash
# View logs from a deployment (all replicas)
kubectl logs -n herbarium-specify deployment/specify --tail=50

# View logs from a specific pod
kubectl logs -n herbarium-specify <pod-name> --tail=100

# Follow logs in real-time
kubectl logs -n herbarium-specify deployment/specify -f

# View logs from previous container (if pod restarted)
kubectl logs -n herbarium-specify <pod-name> --previous

# View logs from all containers in a pod
kubectl logs -n herbarium-specify <pod-name> --all-containers

# View logs from specific container in a pod
kubectl logs -n herbarium-specify <pod-name> -c <container-name>

# View events in namespace (useful for troubleshooting)
kubectl get events -n herbarium-specify --sort-by='.lastTimestamp'

# Check for errors in recent events
kubectl get events -n herbarium-specify | grep -i error
```

## Exec into Pods

```bash
# Open a shell in a pod
kubectl exec -it -n herbarium-specify deployment/specify -- /bin/bash

# Run a single command in a pod
kubectl exec -n herbarium-specify deployment/specify -- env | grep DATABASE

# Open shell in specific pod (when multiple replicas exist)
kubectl exec -it -n herbarium-specify <pod-name> -- /bin/bash
```

## Restart and Rollout Management

```bash
# Restart a deployment (rolling restart, no downtime)
kubectl rollout restart deployment/specify -n herbarium-specify

# Restart all deployments in namespace
kubectl rollout restart deployment -n herbarium-specify

# Check rollout status
kubectl rollout status deployment/specify -n herbarium-specify

# View rollout history
kubectl rollout history deployment/specify -n herbarium-specify

# Rollback to previous version
kubectl rollout undo deployment/specify -n herbarium-specify

# Rollback to specific revision
kubectl rollout undo deployment/specify --to-revision=2 -n herbarium-specify
```



## Scaling

```bash
# Scale deployment to specific number of replicas
kubectl scale deployment specify -n herbarium-specify --replicas=2

# Scale back to 1 replica
kubectl scale deployment specify -n herbarium-specify --replicas=1

# Check current replica count
kubectl get deployment specify -n herbarium-specify
```

## Configuration Updates

```bash
# Update environment variables (after editing .env file)
# 1. Delete old secret
kubectl delete secret specify-secrets -n herbarium-specify

# 2. Apply changes
kubectl apply -k kustomize/overlays/uat

# 3. Restart deployments to pick up new values
kubectl rollout restart deployment/specify -n herbarium-specify
kubectl rollout restart deployment/specify-worker -n herbarium-specify

# Edit a deployment directly (not recommended, use Kustomize instead)
kubectl edit deployment specify -n herbarium-specify
```

## Resource Monitoring

```bash
# Check resource usage (CPU, memory) for pods
kubectl top pods -n herbarium-specify

# Check resource usage for nodes
kubectl top nodes

# Check resource limits and requests
kubectl describe deployment specify -n herbarium-specify | grep -A 5 "Limits\|Requests"
```

## Cleanup Commands

```bash
# Delete all resources defined in overlay (keeps namespace - REQUIRED IN UAT AND PROD DUE TO RBAC PERMISSIONS)
kubectl delete -k kustomize/overlays/uat

# Delete specific resource
kubectl delete deployment specify -n herbarium-specify

# Delete a pod (will be recreated by deployment)
kubectl delete pod <pod-name> -n herbarium-specify

# Delete a PVC (WARNING: deletes data)
kubectl delete pvc specify-storage -n herbarium-specify
```



## Port Forwarding (Dev Only)

```bash
# Forward local port to service (useful for dev environment)
kubectl port-forward -n herbarium-specify svc/nginx 8000:80

# Forward to specific pod
kubectl port-forward -n herbarium-specify <pod-name> 8000:8000

# Access application at http://localhost:8000
```

## Secrets Management

```bash
# View secret (base64 encoded)
kubectl get secret specify-secrets -n herbarium-specify -o yaml

# Decode a specific secret value
kubectl get secret specify-secrets -n herbarium-specify -o jsonpath='{.data.DATABASE_HOST}' | base64 -d

# List all secrets in namespace
kubectl get secrets -n herbarium-specify
```

## Diagnostics

```bash
# Check if pods are ready
kubectl get pods -n herbarium-specify -o wide

# Check pod resource constraints
kubectl describe pod <pod-name> -n herbarium-specify | grep -A 10 "Conditions\|Events"

# Test network connectivity between pods
kubectl exec -n herbarium-specify deployment/specify -- nc -zv redis 6379

# Check DNS resolution
kubectl exec -n herbarium-specify deployment/specify -- nslookup redis

# View pod YAML configuration
kubectl get pod <pod-name> -n herbarium-specify -o yaml

# Check for Pod Security Admission violations
kubectl get events -n herbarium-specify | grep -i "violation\|forbidden"
```

## Kustomize-Specific Commands

```bash
# Build and view final manifests
kubectl kustomize kustomize/overlays/uat

# Save built manifests to file
kubectl kustomize kustomize/overlays/uat > uat-manifests.yaml

# Validate kustomization file
kubectl kustomize kustomize/overlays/uat --enable-alpha-plugins

# Show differences between environments
diff <(kubectl kustomize kustomize/overlays/dev) <(kubectl kustomize kustomize/overlays/uat)
```



## Useful Filters and Queries

```bash
# Get pods with specific label
kubectl get pods -n herbarium-specify -l app=specify

# Get pods sorted by restart count
kubectl get pods -n herbarium-specify --sort-by='.status.containerStatuses[0].restartCount'

# Get pods with custom columns
kubectl get pods -n herbarium-specify -o custom-columns=NAME:.metadata.name,STATUS:.status.phase,RESTARTS:.status.containerStatuses[0].restartCount

# Get pod IPs
kubectl get pods -n herbarium-specify -o wide

# Get all resources with specific label
kubectl get all -n herbarium-specify -l environment=uat

# Watch resources for changes
kubectl get pods -n herbarium-specify -w
```

## Quick Troubleshooting

```bash
# Check if all pods are running
kubectl get pods -n herbarium-specify | grep -v Running

# Check for pods with restarts
kubectl get pods -n herbarium-specify | awk '$4 > 0'

# Get recent errors from all pods
kubectl logs -n herbarium-specify --all-containers --tail=50 | grep -i error

# Check ingress configuration
kubectl describe ingress specify-ingress -n herbarium-specify

# Verify service endpoints
kubectl get endpoints -n herbarium-specify

# Check PVC status
kubectl get pvc -n herbarium-specify
```

## Environment-Specific Notes

### Dev (k3d)
- Context: `k3d-specify-test`
- Access: Port-forward to localhost:8000
- Database: MariaDB in-cluster

### UAT (Rancher/AKS)
- Context: `az-aks-oim03`
- Access: https://specify-test.dbca.wa.gov.au
- Database: Azure MySQL (external)

### Production (Rancher/AKS)
- Context: `<prod-cluster-context-name>`
- Access: https://specify.dbca.wa.gov.au
- Database: Azure MySQL (external)

## Tips

- Always verify your context before running commands: `kubectl config current-context`
- Use `--dry-run=client` to preview changes before applying
- Use `-o yaml` or `-o json` to see full resource definitions
- Use `--watch` or `-w` to monitor resources in real-time
- Use `--tail=N` to limit log output
- Use `grep`, `awk`, and `jq` to filter kubectl output


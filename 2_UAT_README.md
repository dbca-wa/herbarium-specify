# Specify 7 - UAT Deployment Guide

This guide covers deploying Specify 7 to the UAT environment on Azure AKS (managed via Rancher).

**Prerequisites**: Complete the dev deployment (see [1_DEV_README.md](1_DEV_README.md)) to understand the basics.

## Key Differences from Dev

| Aspect        | Dev                | UAT                                 |
| ------------- | ------------------ | ----------------------------------- |
| **Cluster**   | k3d (local)        | Azure AKS (Rancher)                 |
| **Database**  | MariaDB in-cluster | Azure MySQL (external)              |
| **Access**    | Port-forward       | https://specify-test.dbca.wa.gov.au |
| **SSL/TLS**   | None               | External proxy handles it           |
| **Namespace** | Full control       | RBAC-restricted                     |

## Critical Warnings

### VPN Connectivity

**Disconnect VPN before any kubectl commands.** VPN interferes with Rancher authentication and causes 406 errors.

### SSL/TLS Configuration

**Never configure TLS in Kubernetes ingress.** The external proxy handles all SSL termination. Your ingress should only use HTTP (port 80).

## Cluster Access Setup

### 1. Load UAT Credentials

The `uat_access.yaml` file in the repo root should contain your cluster credentials (downloadable from rancher-uat top bar after selecting the cluster). Copy the contents and create uat_access.yaml. Merge it with your kubeconfig:

```bash
# Backup current config
cp ~/.kube/config ~/.kube/config.backup

# Merge UAT credentials
KUBECONFIG=~/.kube/config:uat_access.yaml kubectl config view --flatten > ~/.kube/config.new
mv ~/.kube/config.new ~/.kube/config

# Verify
kubectl config get-contexts
```

### 2. Switch to UAT Context

```bash
# Switch to UAT
kubectl config use-context az-aks-oim03

# Verify
kubectl config current-context
```

### 3. Test Access

```bash
# Test namespace access
kubectl get pods -n herbarium-specify
```

**Expected**: Either see pods or "No resources found" (not a permission error).

## Environment Configuration

### Create .env File

UAT uses Azure MySQL instead of in-cluster MariaDB:

```bash
# Copy template
cp kustomize/overlays/uat/.env.example kustomize/overlays/uat/.env

# Edit with your values
# - DATABASE_HOST: Azure MySQL server
# - DATABASE_NAME: specify_test
# - MASTER_NAME: Database username (use admin user for migrations)
# - MASTER_PASSWORD: Database password
# - SECRET_KEY: Generate with: python3 -c "import secrets; print(secrets.token_urlsafe(50))"
# - ASSET_SERVER_KEY: Generate with: python3 -c "import secrets; print(secrets.token_urlsafe(50))"
# - CSRF_TRUSTED_ORIGINS: https://specify-test.dbca.wa.gov.au
```

**Important**:

-   Use unique keys (different from dev)
-   Database user needs CREATE, ALTER, DROP permissions for migrations
-   Never commit actual `.env` files

## Deployment

### Deploy to UAT

```bash
# Ensure you're on UAT context
kubectl config current-context  # Should show: az-aks-oim03

# Deploy
kubectl apply -k kustomize/overlays/uat

# Monitor startup
kubectl get pods -n herbarium-specify -w
```

All pods should reach `Running` status in 2-3 minutes.

### Verify Deployment

```bash
# Check pods
kubectl get pods -n herbarium-specify

# Check ingress
kubectl get ingress -n herbarium-specify

# View logs
kubectl logs -n herbarium-specify deployment/specify --tail=50
```

Access the application at: **https://specify-test.dbca.wa.gov.au/specify/**

## Common Operations

### View Logs

```bash
kubectl logs -n herbarium-specify deployment/specify --tail=100
kubectl logs -n herbarium-specify deployment/specify -f  # Follow
```

### Restart Deployment

```bash
kubectl rollout restart deployment/specify -n herbarium-specify
```

### Update Configuration

After editing `.env`:

```bash
kubectl delete secret specify-secrets -n herbarium-specify
kubectl apply -k kustomize/overlays/uat
kubectl rollout restart deployment/specify -n herbarium-specify
```

### Reset UAT Environment

Use the reset script to clear all resources (keeps namespace):

```bash
./scripts/reset-specify-uat.sh
```

**Note**: Unlike dev, this does NOT delete the namespace (RBAC restrictions). It only deletes resources within the namespace.

## Troubleshooting

### VPN Issues

**Symptom**: 406 errors or authentication failures  
**Solution**: Disconnect VPN and retry

### Permission Errors

**Symptom**: "User cannot get resource" errors  
**Solution**: You have namespace-scoped permissions only. You cannot list cluster-wide resources (namespaces, nodes) - this is expected.

### Database Connection Errors

**Check**:

-   Credentials in `.env` file
-   Azure MySQL firewall allows AKS cluster IP range
-   Database user has CREATE, ALTER, DROP permissions (try admin user if having issues)

```bash
# View logs for database errors
kubectl logs -n herbarium-specify deployment/specify --tail=100 | grep -i database
```

### Pod Startup Issues

```bash
# Check pod status
kubectl get pods -n herbarium-specify

# Describe pod for events
kubectl describe pod <pod-name> -n herbarium-specify

# Check events
kubectl get events -n herbarium-specify --sort-by='.lastTimestamp'
```

### Kubeconfig Merge Conflicts (Multiple Clusters)

**Symptom**: `system:unauthenticated` / 403 Forbidden errors even after downloading a fresh kubeconfig from Rancher, despite the token being valid.

**Cause**: When merging kubeconfigs (`kubectl config view --flatten`), if an existing user or context entry with the same name already exists, kubectl keeps the old one and ignores the new one. This commonly happens when:
- You have multiple Rancher-managed clusters that all define a user called `rancher`
- A previous merge created user/context entries with the same names (e.g. `az-aks-oim03` as both a context and user name), and the old token has since expired

**Diagnosis** — check what user your context is actually pointing to and whether the token is stale:

```bash
# See all contexts and which user they reference
kubectl config view -o jsonpath='{range .contexts[*]}{.name}{"\t"}{.context.user}{"\n"}{end}'

# See all users
kubectl config view -o jsonpath='{range .users[*]}{.name}{"\n"}{end}'

# Quick test — bypass the merged config entirely
KUBECONFIG=uat_access.yaml kubectl get pods -n herbarium-specify
```

If the `KUBECONFIG=uat_access.yaml` command works but normal kubectl doesn't, the merge is the problem.

**Fix** — clean up stale entries and re-merge:

```bash
# 1. Before downloading a new kubeconfig from Rancher, rename the user
#    in uat_access.yaml from "rancher" to "rancher-uat" (in users and contexts)
#    to avoid collisions with other clusters

# 2. Remove any stale user entries that may have the old token
kubectl config unset users.rancher
kubectl config unset users.az-aks-oim03  # if this exists from a previous merge

# 3. Re-merge
KUBECONFIG=~/.kube/config:uat_access.yaml kubectl config view --flatten > ~/.kube/config.new
mv ~/.kube/config.new ~/.kube/config

# 4. Ensure the context points to the correct user
kubectl config set-context az-aks-oim03 --user=rancher-uat

# 5. Test
kubectl config use-context az-aks-oim03
kubectl get pods -n herbarium-specify
```

**Prevention** — always rename the user in `uat_access.yaml` to something unique (e.g. `rancher-uat`) before merging. The user name is just a local label and doesn't affect authentication.

## Architecture Notes

### Database

Unlike dev (MariaDB in-cluster), UAT uses **Azure MySQL** (external). No database pod runs in the cluster. Connection details are in your `.env` file.

### Nginx

Nginx serves static files and proxies requests to Specify. Unlike dev, it does NOT set `X-Real-IP` or `X-Forwarded-For` headers (the external proxy already sets these).

### SSL/TLS

The external proxy handles all SSL termination. Traffic flow:

```
User (HTTPS) → External Proxy (SSL termination) → Ingress (HTTP) → Nginx → Specify
```

Your ingress configuration uses HTTP only (port 80) with `tls: []`.

### Storage

Uses Azure managed-csi storage class (vs local-path in dev). PVCs are not large in UAT (2Gi/5Gi) for testing.

**Azure File Share for Asset Storage**: UAT uses a pre-provisioned Azure File Share (`specify-assets-uat`) for persistent asset storage. The connection requires a Kubernetes secret with storage account credentials. See [AZURE_FILE_SHARE_SETUP.md](AZURE_FILE_SHARE_SETUP.md) for details.

## Additional Resources

-   **Common Commands**: See [COMMON_COMMANDS.md](COMMON_COMMANDS.md)

## Quick Reference

```bash
# Switch context
kubectl config use-context az-aks-oim03

# Deploy
kubectl apply -k kustomize/overlays/uat

# Check status
kubectl get pods -n herbarium-specify

# View logs
kubectl logs -n herbarium-specify deployment/specify --tail=50

# Restart
kubectl rollout restart deployment/specify -n herbarium-specify

# Reset environment
./scripts/reset-specify-uat.sh
```

## UAT Architecture

### Traffic Flow

1. **User Request** → `https://specify-test.dbca.wa.gov.au`
2. **External Proxy** (IT-managed) → Terminates SSL, handles authentication, forwards HTTP
3. **Ingress Controller** (Azure Load Balancer) → Routes based on hostname to nginx service
4. **Nginx** → Serves static files from `/static/` OR proxies dynamic requests to Specify/Asset Server
5. **Specify** → Processes requests, connects to Azure MySQL
6. **Response** → Flows back through the chain to user

### Key Components

**External to Cluster:**

-   **External Proxy**: IT-managed, handles SSL/TLS and authentication
-   **Azure MySQL**: Managed database service (not in cluster)

**Within Cluster:**

-   **Nginx**: Serves static files, proxies dynamic requests
-   **Specify**: Main Django application (1 replica in UAT)
-   **Specify Worker**: Background task processor
-   **Redis**: Task queue for background jobs
-   **Asset Server**: Manages file attachments
-   **Report Runner**: Generates reports

**Storage:**

-   **specify-storage**: Application data (2Gi, Azure managed-csi)
-   **asset-storage**: Uploaded files (5Gi, Azure managed-csi)

## Repository Structure

### Required Files for UAT Deployment

```
herbarium-specify/
├── kustomize/
│   ├── base/                           # Base Kubernetes manifests (shared)
│   │   ├── kustomization.yaml
│   │   ├── specify-deployment.yaml
│   │   ├── nginx-deployment.yaml
│   │   ├── nginx-configmap.yaml       # Nginx config (proxies + static files)
│   │   ├── services.yaml
│   │   ├── ingress.yaml
│   │   └── ...
│   └── overlays/
│       └── uat/                        # UAT-specific configuration
│           ├── kustomization.yaml      # References base + applies patches
│           ├── .env                    # Environment variables (gitignored)
│           ├── .env.example            # Template for .env
│           ├── deployment-patch.yaml   # UAT resource limits
│           ├── ingress-patch.yaml      # UAT domain + no TLS
│           ├── pvc-patch.yaml          # UAT storage sizes
│           └── ...
├── scripts/
│   └── reset-specify-uat.sh           # UAT reset script
├── uat_access.yaml                     # UAT cluster credentials (gitignored)
├── 2_UAT_README.md                     # This file
└── COMMON_COMMANDS.md                  # kubectl reference

Gitignored (create locally):
├── kustomize/overlays/uat/.env         # Your UAT environment variables
├── kustomize/creds/uat/                # UAT credentials (optional reference)
└── uat_access.yaml                     # Your UAT kubeconfig
```

### Key Configuration Files

**kustomize/overlays/uat/.env**

-   Database connection details (Azure MySQL)
-   SECRET_KEY and ASSET_SERVER_KEY (unique per environment)
-   CSRF_TRUSTED_ORIGINS (UAT domain)
-   Debug settings (SP7_DEBUG=false)

**kustomize/overlays/uat/kustomization.yaml**

-   References base resources
-   Generates secrets from .env
-   Applies UAT-specific patches
-   Excludes MariaDB (uses Azure MySQL instead)

**kustomize/overlays/uat/ingress-patch.yaml**

-   Sets UAT domain: specify-test.dbca.wa.gov.au
-   Disables TLS (external proxy handles it)
-   Sets `tls: []` and `ssl-redirect: false`

**uat_access.yaml**

-   Contains kubeconfig for az-aks-oim03 cluster
-   Includes authentication token
-   Merge with ~/.kube/config to access UAT

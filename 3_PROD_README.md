# Specify 7 - Production Deployment Guide

This guide covers deploying Specify 7 to the production environment on Azure AKS (managed via Rancher).

**Prerequisites**: Complete the UAT deployment (see [2_UAT_README.md](2_UAT_README.md)) to understand the basics. Production follows the same patterns with higher resource limits and stricter change management.

## Key Differences from UAT

| Aspect | UAT | Production |
|--------|-----|------------|
| **Cluster** | az-aks-oim03 | aks-bcs-prod-01 |
| **Domain** | specify-test.dbca.wa.gov.au | specify.dbca.wa.gov.au |
| **Database** | specify_test | specify_prod |
| **Specify replicas** | 1 | 2 |
| **Worker replicas** | 1 | 2 |
| **Memory (specify)** | 2Gi | 4Gi |
| **Storage (specify-storage)** | 2Gi | 20Gi |
| **Asset storage** | specify-assets-uat | specify-assets-prod |
| **Debug** | configurable | SP7_DEBUG=false always |

## Critical Warnings

Same as UAT — disconnect VPN before kubectl commands, never configure TLS in ingress (external proxy handles it). See [2_UAT_README.md](2_UAT_README.md) for details.

**Additionally**: All production changes should be tested in UAT first. Have a rollback plan ready.

## Cluster Access Setup

### 1. Load Production Credentials

Download the kubeconfig from the Rancher production dashboard (top bar, select aks-bcs-prod-01 cluster). Save as `aks-bcs-prod-01.yaml` in the repo root (gitignored).

Merge into your kubeconfig:

```bash
cp ~/.kube/config ~/.kube/config.backup
KUBECONFIG=~/.kube/config:aks-bcs-prod-01.yaml kubectl config view --flatten > ~/.kube/config.new
mv ~/.kube/config.new ~/.kube/config
```

Or bypass the merge entirely:

```bash
KUBECONFIG=aks-bcs-prod-01.yaml kubectl get pods -n herbarium-specify
```

See the kubeconfig merge conflict troubleshooting in [2_UAT_README.md](2_UAT_README.md) if you hit auth issues.

### 2. Switch to Production Context

```bash
kubectl config use-context aks-bcs-prod-01
kubectl get pods -n herbarium-specify
```

## Environment Configuration

### Create .env File

```bash
cp kustomize/overlays/prod/.env.example kustomize/overlays/prod/.env
```

Fill in:
- **Database credentials**: Get from secure credential vault (Specify Master User for prod)
- **SECRET_KEY**: Generate new — `python3 -c "import secrets; print(secrets.token_urlsafe(50))"`
- **ASSET_SERVER_KEY**: Generate new — same command, different value
- **CSRF_TRUSTED_ORIGINS**: `https://specify.dbca.wa.gov.au`
- **SP7_DEBUG**: `false` (always)

Use the Master User credentials for `MASTER_NAME`/`MASTER_PASSWORD` — these need CREATE, ALTER, DROP permissions for database migrations.

### Create Azure File Secret

The asset-server uses an Azure File Share (`specify-assets-prod`) for attachments. See [AZURE_FILE_SHARE_SETUP.md](AZURE_FILE_SHARE_SETUP.md) for details.

```bash
cp kustomize/overlays/prod/azure-file-secret.yaml.example kustomize/overlays/prod/azure-file-secret.yaml
# Edit and fill in the storage account key

kubectl apply -f kustomize/overlays/prod/azure-file-secret.yaml
```

## Deployment

### Back Up First

Always back up the database before deploying or upgrading:

```bash
./scripts/backup-db.sh prod
```

Backups are saved to the Azure File Share and can be downloaded via Azure Storage Explorer.

### Deploy

```bash
# Verify context
kubectl config current-context  # Should show: aks-bcs-prod-01

# Verify namespace exists (already provisioned by cluster admin)
kubectl get namespace herbarium-specify

# If namespace is missing for any reason and you have cluster-level permissions:
# kubectl create namespace herbarium-specify
# If you don't have permissions, request it from the OIM Service Desk.

# Deploy
kubectl apply -k kustomize/overlays/prod

# Monitor startup
kubectl get pods -n herbarium-specify -w
```

All pods should reach `Running` status in 3-5 minutes. First deployment takes longer while Django runs database migrations.

### Verify

```bash
# Check pods (should see 2 specify + 2 worker replicas)
kubectl get pods -n herbarium-specify

# Check migrations ran
kubectl logs -n herbarium-specify deployment/specify --tail=50

# Check ingress
kubectl get ingress -n herbarium-specify
```

Access the application at: **https://specify.dbca.wa.gov.au/specify/**

## Common Operations

### View Logs

```bash
kubectl logs -n herbarium-specify deployment/specify --tail=100
kubectl logs -n herbarium-specify deployment/specify -f  # Follow
```

### Restart Deployments

```bash
# Restart all deployments
kubectl rollout restart deployment -n herbarium-specify

# Restart a single deployment
kubectl rollout restart deployment/specify -n herbarium-specify
```

### Update Configuration

After editing `.env`:

```bash
kubectl delete secret specify-secrets -n herbarium-specify
kubectl apply -k kustomize/overlays/prod
kubectl rollout restart deployment -n herbarium-specify
```

### Rollback

```bash
# Rollback to previous version
kubectl rollout undo deployment/specify -n herbarium-specify
kubectl rollout undo deployment/specify-worker -n herbarium-specify

# Check rollout history
kubectl rollout history deployment/specify -n herbarium-specify
```

For database rollback, restore from Azure MySQL point-in-time backup (coordinate with DBA).

## Troubleshooting

Most issues are the same as UAT — see [2_UAT_README.md](2_UAT_README.md) troubleshooting section.

### Production-Specific

**Stale content after upgrade**: Disconnect VPN and try again. VPN can route through CDN edge nodes with cached content.

**Multiple replicas**: If debugging, check logs from specific pods rather than the deployment:

```bash
kubectl get pods -n herbarium-specify -l component=web
kubectl logs -n herbarium-specify <specific-pod-name> --tail=100
```

## Architecture

Same as UAT (see [2_UAT_README.md](2_UAT_README.md)) with these differences:

- 2 replicas each for specify and specify-worker (load balanced)
- Higher resource limits
- Asset storage via Azure File Share `specify-assets-prod` (inline CSI volume)
- `specify-storage` PVC: 20Gi on `azurefile-csi`

```
User (HTTPS) → External Proxy (SSL) → Ingress (HTTP) → Nginx → Specify (x2)
                                                              → Asset Server → Azure File Share
                                                              → Workers (x2) → Redis
                                                              → Report Runner
                                                     Specify → Azure MySQL (specify_prod)
```

## Quick Reference

```bash
# Switch context
kubectl config use-context aks-bcs-prod-01

# Deploy
kubectl apply -k kustomize/overlays/prod

# Check status
kubectl get pods -n herbarium-specify

# View logs
kubectl logs -n herbarium-specify deployment/specify --tail=50

# Restart all
kubectl rollout restart deployment -n herbarium-specify

# Backup database
./scripts/backup-db.sh prod

# Rollback
kubectl rollout undo deployment/specify -n herbarium-specify
```

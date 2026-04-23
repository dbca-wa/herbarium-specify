# Azure File Share Setup

## Overview

Azure File Shares are used for persistent asset storage in Specify. The asset-server mounts the share directly using an inline CSI volume in the deployment spec, which avoids the need for cluster-scoped PersistentVolume resources.

Data is stored on Azure's side and persists independently of pod lifecycle — restarts, rescheduling, or deletion won't affect the data.

## Configuration Details

**Storage Account:** `dbcaherbariumspecify`

**File Shares:**
- `specify-assets-uat` (UAT environment)
- `specify-assets-prod` (Production environment)

## How It Works

Instead of PV/PVC, we use an inline CSI volume directly in the asset-server deployment. This:
- Requires only namespace-scoped permissions (no cluster-admin needed)
- Mounts the pre-created Azure File Share via SMB
- Data persists on Azure regardless of pod lifecycle

```
Azure File Share (specify-assets-{env})
    ↓ (SMB mount via CSI driver)
Secret (azure-file-secret) → Deployment (asset-server)
    ↓
Pod volume mount at /home/specify/attachments
```

## Secret Management

The Azure storage credentials are stored in a Kubernetes Secret named `azure-file-secret` in the namespace. This secret is created manually in Rancher or via kubectl and is NOT stored in version control.

### Creating the Secret via kubectl

```bash
kubectl apply -f kustomize/overlays/uat/azure-file-secret.yaml
```

Or create directly:

```bash
kubectl create secret generic azure-file-secret \
  --from-literal=azurestorageaccountname=dbcaherbariumspecify \
  --from-literal=azurestorageaccountkey=<STORAGE_ACCOUNT_KEY> \
  --namespace=herbarium-specify
```

### Creating the Secret in Rancher

1. Navigate to: Cluster > Storage > Secrets
2. Create Secret: `azure-file-secret`
3. Namespace: `herbarium-specify`
4. Type: Opaque
5. Add keys:
   - `azurestorageaccountname`: dbcaherbariumspecify
   - `azurestorageaccountkey`: (the access key provided by OIM)

### Secret Template

A template file is provided at `kustomize/overlays/uat/azure-file-secret.yaml.example`. Copy it, fill in the key, and the actual file is gitignored.

## UAT Environment

### Files

- `kustomize/overlays/uat/asset-server-patch.yaml` - Patches the asset-server deployment to use inline CSI volume
- `kustomize/overlays/uat/azure-file-secret.yaml` - Secret with credentials (gitignored)
- `kustomize/overlays/uat/azure-file-secret.yaml.example` - Template for the secret

### Deployment

```bash
# Ensure secret exists
kubectl get secret azure-file-secret -n herbarium-specify

# If not, create it
kubectl apply -f kustomize/overlays/uat/azure-file-secret.yaml

# Apply configuration
kubectl apply -k kustomize/overlays/uat/
```

### Verification

```bash
# Check the secret exists
kubectl get secret azure-file-secret -n herbarium-specify

# Check asset-server is running
kubectl get pods -n herbarium-specify -l component=asset-server

# Verify the mount
kubectl exec -n herbarium-specify deployment/asset-server -- df -h /home/specify/attachments

# Check mount details
kubectl exec -n herbarium-specify deployment/asset-server -- mount | grep attachments
```

## Production Environment

Production uses the same inline CSI approach with `specify-assets-prod`.

### Required Files (to be created in `kustomize/overlays/prod/`)

**1. `asset-server-patch.yaml`:**

```yaml
- op: replace
  path: /spec/template/spec/volumes/0
  value:
    name: attachments
    csi:
      driver: file.csi.azure.com
      readOnly: false
      volumeAttributes:
        secretName: azure-file-secret
        shareName: specify-assets-prod
```

**2. `azure-file-secret.yaml.example`:**

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: azure-file-secret
  namespace: herbarium-specify
type: Opaque
stringData:
  azurestorageaccountname: dbcaherbariumspecify
  azurestorageaccountkey: <STORAGE_ACCOUNT_KEY>
```

**3. Update `kustomization.yaml`** — add the asset-server patch and exclude the base PVC:

```yaml
patches:
- path: asset-server-patch.yaml
  target:
    kind: Deployment
    name: asset-server
# Exclude asset-storage PVC (using inline CSI volume instead)
- patch: |-
    $patch: delete
    apiVersion: v1
    kind: PersistentVolumeClaim
    metadata:
      name: asset-storage
```

### Production Deployment

```bash
# Create the secret
kubectl apply -f kustomize/overlays/prod/azure-file-secret.yaml

# Deploy
kubectl apply -k kustomize/overlays/prod/
```

## Troubleshooting

### Secret Not Found

If the asset-server pod fails to start with mount errors:

```bash
kubectl get secret azure-file-secret -n herbarium-specify
```

If missing, create it from the template.

### Mount Failures

```bash
# Check pod events
kubectl describe pod -l component=asset-server -n herbarium-specify

# Common issues:
# - Storage account key is incorrect
# - Azure firewall rules blocking AKS cluster
# - File share doesn't exist in storage account
```

### Verifying Data Persistence

Data lives on the Azure File Share, not in the pod. To confirm:

```bash
# Write a test file
kubectl exec -n herbarium-specify deployment/asset-server -- touch /home/specify/attachments/test-file

# Restart the pod
kubectl rollout restart deployment/asset-server -n herbarium-specify

# After restart, verify file still exists
kubectl exec -n herbarium-specify deployment/asset-server -- ls /home/specify/attachments/test-file
```

## Security Notes

- Secret files (`azure-file-secret.yaml`) are gitignored and must NEVER be committed
- Use the `.example` template for documentation
- Rotate storage account keys periodically and update the secret

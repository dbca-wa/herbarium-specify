# Azure File Share Setup

## Overview
Azure File Shares have been provisioned for Specify asset storage in both UAT and Production environments.

## Configuration Details

**Storage Account:** `dbcaherbariumspecify`

**File Shares:**
- `specify-assets-uat` (UAT environment)
- `specify-assets-prod` (Production environment)

## Secret Management

The Azure storage credentials are stored in a Kubernetes Secret in each environment's namespace. This secret is created manually in Rancher and is NOT stored in version control.

### Creating the Secret in Rancher

1. Navigate to: Cluster > Storage > Secrets
2. Create/Edit Secret: `azure-file-secret`
3. Namespace: `herbarium-specify` (or appropriate namespace)
4. Type: Opaque
5. Add keys:
   - `azurestorageaccountname`: dbcaherbariumspecify
   - `azurestorageaccountkey`: (the access key provided by OIM)

### Creating the Secret via kubectl

For local development or manual setup:

```bash
kubectl create secret generic azure-file-secret \
  --from-literal=azurestorageaccountname=dbcaherbariumspecify \
  --from-literal=azurestorageaccountkey=<STORAGE_ACCOUNT_KEY> \
  --namespace=herbarium-specify
```

Or use the template file:

```bash
# Copy and edit the template
cp kustomize/overlays/uat/azure-file-secret.yaml.example kustomize/overlays/uat/azure-file-secret.yaml
# Edit azure-file-secret.yaml and replace <STORAGE_ACCOUNT_KEY>

# Apply
kubectl apply -f kustomize/overlays/uat/azure-file-secret.yaml
```

## UAT Environment Setup

### Files

- `kustomize/overlays/uat/azure-file-pv.yaml` - PersistentVolume definition
- `kustomize/overlays/uat/azure-file-secret.yaml` - Secret (gitignored, create locally)
- `kustomize/overlays/uat/azure-file-secret.yaml.example` - Template
- `kustomize/overlays/uat/asset-storage-pvc-patch.yaml` - PVC configuration
- `kustomize/overlays/uat/kustomization.yaml` - Kustomize configuration

### Deployment

```bash
# Ensure secret exists first
kubectl get secret azure-file-secret -n herbarium-specify

# Deploy UAT configuration
kubectl apply -k kustomize/overlays/uat/
```

### Verification

```bash
# Check if the secret exists
kubectl get secret azure-file-secret -n herbarium-specify

# Check if PV is bound
kubectl get pv asset-storage-uat-pv

# Check if PVC is bound
kubectl get pvc asset-storage -n herbarium-specify

# Check if the asset-server pod can mount the volume
kubectl describe pod -l component=asset-server -n herbarium-specify
```

## Production Environment Setup

Production follows the same pattern as UAT but uses different resources.

### Required Files (to be created)

Create these files in `kustomize/overlays/prod/`:

**1. `azure-file-pv.yaml`** - PersistentVolume for production:

```yaml
apiVersion: v1
kind: PersistentVolume
metadata:
  name: asset-storage-prod-pv
spec:
  capacity:
    storage: 500Gi
  accessModes:
    - ReadWriteMany
  persistentVolumeReclaimPolicy: Retain
  storageClassName: azurefile-csi-static
  csi:
    driver: file.csi.azure.com
    readOnly: false
    volumeHandle: asset-storage-prod-unique-id
    volumeAttributes:
      storageAccount: dbcaherbariumspecify
      shareName: specify-assets-prod
    nodeStageSecretRef:
      name: azure-file-secret
      namespace: herbarium-specify
```

**2. `asset-storage-pvc-patch.yaml`** - PVC patch for production:

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: asset-storage
spec:
  storageClassName: azurefile-csi-static
  accessModes:
  - ReadWriteMany
  volumeName: asset-storage-prod-pv
  resources:
    requests:
      storage: 100Gi
```

**3. Update `kustomization.yaml`** - Add the PV resource:

```yaml
resources:
- ../../base
- azure-file-pv.yaml
```

And add the PVC patch to the patches section:

```yaml
patches:
- path: asset-storage-pvc-patch.yaml
  target:
    kind: PersistentVolumeClaim
    name: asset-storage
```

### Production Deployment

```bash
# Create the secret in production namespace
kubectl create secret generic azure-file-secret \
  --from-literal=azurestorageaccountname=dbcaherbariumspecify \
  --from-literal=azurestorageaccountkey=<STORAGE_ACCOUNT_KEY> \
  --namespace=herbarium-specify

# Deploy production configuration
kubectl apply -k kustomize/overlays/prod/
```

### Production Verification

```bash
# Check if the secret exists
kubectl get secret azure-file-secret -n herbarium-specify

# Check if PV is bound
kubectl get pv asset-storage-prod-pv

# Check if PVC is bound
kubectl get pvc asset-storage -n herbarium-specify

# Check if the asset-server pod can mount the volume
kubectl describe pod -l component=asset-server -n herbarium-specify
```

## Architecture

Static provisioning with pre-created Azure File Share:

```
Azure File Share (specify-assets-{uat|prod})
    ↓
Secret (azure-file-secret) → PersistentVolume (asset-storage-{uat|prod}-pv)
    ↓
PersistentVolumeClaim (asset-storage)
    ↓
Pod (asset-server)
```

## Troubleshooting

### Secret Not Found

If the PV fails to mount with "secret not found":

```bash
# Verify secret exists
kubectl get secret azure-file-secret -n herbarium-specify

# If missing, create it
kubectl create secret generic azure-file-secret \
  --from-literal=azurestorageaccountname=dbcaherbariumspecify \
  --from-literal=azurestorageaccountkey=<KEY> \
  --namespace=herbarium-specify
```

### PVC Not Binding

If the PVC stays in "Pending" state:

```bash
# Check PVC status
kubectl describe pvc asset-storage -n herbarium-specify

# Check PV status
kubectl get pv asset-storage-{uat|prod}-pv

# Common issues:
# - PV volumeName doesn't match in PVC
# - Storage class name mismatch
# - Access mode incompatibility
```

### Mount Failures

If pods fail to mount the volume:

```bash
# Check pod events
kubectl describe pod <pod-name> -n herbarium-specify

# Check if Azure File Share is accessible
# - Verify storage account key is correct
# - Check Azure firewall rules allow AKS cluster
# - Verify file share exists in storage account
```

## Security Notes

- The secret file (`azure-file-secret.yaml`) is gitignored and should NEVER be committed
- Use the `.example` template file for documentation
- Rotate storage account keys periodically and update the secret
- Use RBAC to restrict access to secrets in production

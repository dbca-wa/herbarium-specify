# Deployment Reset Script

Tears down and redeploys all Kubernetes resources (pods, services, ingress, etc). Does **not** touch the database.

**Script:** `scripts/reset-specify.sh`

## Usage

```bash
./scripts/reset-specify.sh <environment> [--nuke]
```

## Environments

| Environment | Context | What it does |
|-------------|---------|--------------|
| `dev` | `k3d-specify-test` | Deletes namespace, recreates, redeploys from kustomize |
| `dev --nuke` | `k3d-specify-test` | Deletes entire k3d cluster, recreates from scratch |
| `uat` | `az-aks-oim03` | Deletes and redeploys resources in namespace |
| `prod` | `az-aks-prod01` | Deletes and redeploys resources in namespace |

## When to use

- After changing kustomize manifests (deployments, configmaps, services)
- When pods are stuck or in a bad state
- After pulling new image versions
- When you want a clean slate for the Kubernetes layer without touching data

## When NOT to use

- To reset the database → use `manage-db.sh --nuke` or `manage-db.sh --load_vanilla`
- To just restart a single pod → use `kubectl rollout restart deployment/<name> -n herbarium-specify`

## What it does

### Dev (quick reset)
1. Deletes the `herbarium-specify` namespace (all resources gone)
2. Recreates the namespace
3. Applies `kustomize/overlays/dev`
4. Waits for all pods to be ready

### Dev --nuke (full cluster recreate)
1. Deletes the namespace
2. Deletes the entire k3d cluster
3. Creates a fresh k3d cluster
4. Merges kubeconfig
5. Creates namespace and applies kustomize overlay
6. Waits for pods

### UAT / Prod
1. Switches kubectl context
2. Asks for confirmation
3. Runs `kubectl delete -k` (removes all managed resources)
4. Runs `kubectl apply -k` (redeploys everything)
5. Waits for pods

## Important notes

- **Database is NOT affected.** The database lives on Azure MySQL (UAT/prod) or persists on the MariaDB PVC (dev). Redeploying pods doesn't wipe it.
- **UAT/prod requires confirmation** — you must type `yes` before it proceeds.
- **Dev --nuke loses the MariaDB PVC** — since the cluster is destroyed, the local database is gone. You'll need to run `manage-db.sh dev --nuke` or `manage-db.sh dev --load_vanilla` after to set up the DB again.

## Examples

```bash
# Quick dev reset after changing a configmap
./scripts/reset-specify.sh dev

# Full dev reset when things are really broken
./scripts/reset-specify.sh dev --nuke

# Redeploy UAT after pushing manifest changes
./scripts/reset-specify.sh uat

# Redeploy prod
./scripts/reset-specify.sh prod
```

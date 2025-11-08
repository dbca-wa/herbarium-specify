# Specify 7 - Local Development Setup (K3d)

This guide will help you run Specify 7 locally on your Mac using K3d (Kubernetes in Docker).

## Prerequisites

### Required Software

1. **Docker Desktop** (must be running)

    - Download: https://www.docker.com/products/docker-desktop
    - Verify: `docker --version`

2. **kubectl** (Kubernetes CLI)

    ```bash
    brew install kubectl
    # Verify
    kubectl version --client
    ```

3. **K3d** (K3s in Docker)
    ```bash
    brew install k3d
    # Verify
    k3d version
    ```

## Quick Start

### 1. Create K3d Cluster (First Time Only)

```bash
k3d cluster create specify-test
```

This creates a local Kubernetes cluster named `specify-test`.

### 2. Copy Database Dump to Cluster (First Time Only)

```bash
# From the kustomize directory
docker cp base/specify_dev_dump.sql k3d-specify-test-server-0:/tmp/specify-init/init.sql
```

This copies the database dump into the K3d container so MariaDB can initialize it. The dump is from specify 6 required to set up db migrations for specify 7.

### 3. Deploy Specify

```bash
# Create namespace (first time only)
kubectl create namespace herbarium-specify

# Deploy all services
kubectl apply -k overlays/dev
```

This deploys:

-   MariaDB (database)
-   Redis (task queue)
-   Asset Server (file attachments)
-   Report Runner (report generation)
-   Specify (main application)
-   Specify Worker (background tasks)
-   Nginx (web server for static files)

### 4. Wait for Pods to Start

```bash
kubectl get pods -n herbarium-specify
```

Wait until all pods show `Running` or `Completed` (1-2 minutes):

```
NAME                             READY   STATUS
asset-server-xxx                 1/1     Running
mariadb-xxx                      1/1     Running
nginx-xxx                        1/1     Running
redis-xxx                        1/1     Running
report-runner-xxx                1/1     Running
specify-xxx                      1/1     Running
specify-worker-xxx               1/1     Running
specify6-init-xxx                0/1     Completed
```

**Note**: First startup takes 2-3 minutes while Django runs database migrations. Also note, this sets specify 6 up as a job instead of a pod since it is only needed at initialisation.

### 5. Access Specify in Your Browser

```bash
kubectl port-forward -n herbarium-specify svc/nginx 8000:80
```

Then open your browser to: **http://localhost:8000/specify/**

**Login Credentials:**

-   Username: `jaridp`
-   Password: `wvq9dmj@BCY4cdy_uxd`

NOTE: These are non-sensitive testing credentials made during specify 6 workbench database creation with mariadb and are specific only to the specify_dev_dump.sql file, which has no sensitive data. A Specify 6 dump is required, unfortunately.

**Keep the terminal window open** - closing it will stop the port-forward.

## Why Port-Forward?

In Kubernetes, services run inside the cluster and aren't accessible from your Mac by default. Port-forward creates a tunnel from your Mac to the cluster:

```
Your Browser → localhost:8000 → K3d Cluster → nginx service
```

In production (UAT/Prod), we'll use an Ingress controller with a real domain (specify-test or specify dbca) name instead of port-forward.

## Why Nginx? Can't Specify serve everything?\*\*

Specify 7 runs with gunicorn (Python web server) which **does not serve static files** in production. This is standard Django practice (Note: though this could be changed, leaving as-is as the app is heavy and it may not be worth investing time to workaround their standard).

**What Nginx does here:**

1. Serves static files (CSS, JavaScript, images) to your browser
2. Proxies API requests to the Specify backend

**Without Nginx:** You'd see a blank page with 404 errors for all CSS/JS files (tested and can confirm).

**How it works:**

-   Nginx has an initContainer that copies pre-built static files from the Specify Docker image
-   No shared storage needed - works in any Kubernetes environment

## Common Commands

### Check Status

```bash
# View all pods
kubectl get pods -n herbarium-specify

# View logs for a specific service
kubectl logs -n herbarium-specify deployment/specify --tail=50
kubectl logs -n herbarium-specify deployment/nginx --tail=50

# Check if database is ready
kubectl exec -n herbarium-specify deployment/mariadb -- \
  mariadb -u root -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = 'specify_dev';"
# Should show: 235 tables
```

### Restart a Service

```bash
# Restart Specify (if it's stuck)
kubectl rollout restart deployment/specify -n herbarium-specify

# Restart Nginx
kubectl rollout restart deployment/nginx -n herbarium-specify
```

### View All Resources

```bash
kubectl get all,pvc,ingress -n herbarium-specify
```

## Stopping and Starting

### Stop Port-Forward

Press `Cmd+C` in the terminal where port-forward is running.

### Stop the Cluster (Saves Resources)

```bash
k3d cluster stop specify-test
```

This stops the cluster but keeps all data. Your database and files are preserved.

### Start the Cluster Again

```bash
k3d cluster start specify-test

# Wait a moment for pods to start, then port-forward again
kubectl port-forward -n herbarium-specify svc/nginx 8000:80
```

### Delete Everything (Clean Slate)

```bash
# Delete the deployment (keeps cluster)
kubectl delete namespace herbarium-specify

# Or delete the entire cluster
k3d cluster delete specify-test
```

**Warning**: Deleting the namespace or cluster will delete all data including the database!

## Troubleshooting

### Pods Not Starting

**Check pod status:**

```bash
kubectl get pods -n herbarium-specify
```

**If a pod shows `Pending` or `Error`:**

```bash
kubectl describe pod -n herbarium-specify <pod-name>
```

**Common issues:**

-   Docker Desktop not running
-   Not enough resources (increase Docker Desktop memory to 8GB+, mine is set to 32GB)

### 502 Bad Gateway

This usually means Specify is still starting up (running migrations), so its working but will need time.

**Check Specify logs:**

```bash
kubectl logs -n herbarium-specify deployment/specify --tail=50
```

Wait for migrations to complete (you'll see "Starting gunicorn" at the end).

### Static Files Not Loading (404 errors)

**Check Nginx logs:**

```bash
kubectl logs -n herbarium-specify deployment/nginx
```

**Check if initContainer copied files:**

```bash
kubectl logs -n herbarium-specify deployment/nginx -c copy-static-files
```

You should see files being copied.

### Database Not Initialized

**Check if SQL dump was copied:**

```bash
docker exec k3d-specify-test-server-0 ls -lh /tmp/specify-init/init.sql
```

Should show a ~23MB file.

**Check MariaDB logs:**

```bash
kubectl logs -n herbarium-specify deployment/mariadb --tail=100
```

### Port 8000 Already in Use

If you get "port already in use" error:

```bash
# Find what's using port 8000
lsof -i :8000

# Kill the process or use a different port
kubectl port-forward -n herbarium-specify svc/nginx 8001:80
# Then access: http://localhost:8001/specify/
```

## Architecture Overview

```
┌─────────────────────────────────────────────────────┐
│  Your Mac                                           │
│                                                     │
│  Browser → localhost:8000 (port-forward)            │
└─────────────────────┬───────────────────────────────┘
                      │
┌─────────────────────▼─────────────────────────────┐
│  K3d Cluster (Docker Container)                   │
│                                                   │
│  ┌─────────┐    ┌──────────┐    ┌──────────┐      │
│  │  Nginx  │───→│ Specify  │───→│ MariaDB  │      │
│  │ (port   │    │ (Django) │    │ (235     │      │
│  │  80)    │    │          │    │  tables) │      │
│  └─────────┘    └──────────┘    └──────────┘      │
│       │              │                            │
│       │              ├──→ Redis (task queue)      │
│       │              ├──→ Asset Server (files)    │
│       │              └──→ Report Runner           │
│       │                                           │
│  Serves static files (CSS/JS/images)              │
│  from initContainer copy                          │
└───────────────────────────────────────────────────┘
```

## Environment Variables

Environment variables are in `.env` (gitignored). See `.env.example` for template.

**Key variables:**

-   `DATABASE_HOST=mariadb` - Database service name
-   `MASTER_NAME=specify_admin` - Database username
-   `ASSET_SERVER_URL=http://asset-server:8080/web_asset_store.xml` - Asset server URL

**Note**: Services communicate using Kubernetes DNS (service names), not localhost.

## Next Steps

Once you've verified everything works locally:

1. UAT environment will use the same base configuration _prays_
2. Only environment-specific values change (domain, storage class, etc.)
3. Production will be similar to UAT

## Getting Help

**Check logs:**

```bash
# All pods
kubectl logs -n herbarium-specify deployment/<service-name>

# With follow (live updates)
kubectl logs -n herbarium-specify deployment/specify -f
```

**Exec into a pod:**

```bash
kubectl exec -it -n herbarium-specify deployment/specify -- /bin/sh
```

**Check service connectivity:**

```bash
kubectl exec -n herbarium-specify deployment/specify -- nc -zv mariadb 3306
kubectl exec -n herbarium-specify deployment/specify -- nc -zv redis 6379
```

# Herbarium Specify 7 - Kubernetes Deployment

This repository contains Kubernetes deployment configurations for the Herbarium Specify 7 application using Kustomize for environment-specific overlays.

## Overview

Specify 7 is a biological collections management system. This deployment supports three environments:
- **Development** (k3d local cluster)
- **UAT** (Azure AKS via Rancher)
- **TODO: Production** (Azure AKS via Rancher)

It is advised you get things running locally first to get an understanding of Kubernetes commands.


## Documentation

### Deployment Guides

- **[1_DEV_README.md](1_DEV_README.md)** - Development environment setup and deployment (k3d local cluster)
- **[2_UAT_README.md](2_UAT_README.md)** - UAT environment deployment guide (Rancher/Azure AKS)
<!-- - **[3_PROD_README.md](3_PROD_README.md)** - Production deployment guide (Rancher/Azure AKS) -->
- **[COMMON_COMMANDS.md](COMMON_COMMANDS.md)** - Quick reference for kubectl and Kustomize commands


## Quick Start

### Prerequisites

- kubectl installed and configured
- Access to appropriate Kubernetes cluster (k3d for dev, Rancher for UAT/prod)
- Environment-specific credentials configured

### Development Environment

```bash
# Switch to dev context
kubectl config use-context k3d-specify-test

# Deploy to dev
kubectl apply -k kustomize/overlays/dev

# Access via port-forward
kubectl port-forward -n herbarium-specify svc/nginx 8000:80
```

See [1_DEV_README.md](1_DEV_README.md) for detailed instructions.

### UAT Environment

```bash
# Switch to UAT context/cluster
kubectl config use-context az-aks-oim03

# Deploy to UAT
kubectl apply -k kustomize/overlays/uat
```

See [2_UAT_README.md](2_UAT_README.md) for detailed instructions.

<!-- 
### Production Environment

```bash
# Switch to production context
kubectl config use-context <prod-cluster-context>

# Deploy to production
kubectl apply -k kustomize/overlays/prod
```

See [3_PROD_README.md](3_PROD_README.md) for detailed instructions. -->



## Repository Structure

```
.
├── kustomize/
│   ├── base/                    # Base Kubernetes manifests
│   └── overlays/
│       ├── dev/                 # Development environment overlay
│       ├── uat/                 # UAT environment overlay
│       └── prod/                # Production environment overlay
├── scripts/                     # Automation scripts
│   ├── reset-specify-dev.sh    # Dev environment reset script
│   └── reset-specify-uat.sh    # UAT environment reset script
├── 1_DEV_README.md             # Development deployment guide
├── 2_UAT_README.md             # UAT deployment guide
└── COMMON_COMMANDS.md          # Command reference
```
<!-- ├── 3_PROD_README.md            # Production deployment guide -->

## Configuration Management

### Environment Variables

Each environment uses a `.env` file for configuration. These files are **gitignored** and must be created from the provided templates:

```bash
# Development
cp kustomize/overlays/dev/.env.example kustomize/overlays/dev/.env

# UAT
cp kustomize/overlays/uat/.env.example kustomize/overlays/uat/.env

# Production
cp kustomize/overlays/prod/.env.example kustomize/overlays/prod/.env
```

**Important**: Never commit `.env` files to version control. They contain sensitive credentials.

### Credentials

Credentials are stored in `kustomize/creds/` (gitignored):
- `creds/dev/` - Development credentials (for local testing)
- `creds/uat/` - UAT database and IT user credentials
- `creds/prod/` - Production database and IT user credentials

## Important Notes

### Security

- **Never commit secrets**: All `.env` files and credential files are gitignored
- **Unique keys per environment**: Each environment must use different SECRET_KEY and ASSET_SERVER_KEY values
- **Debug mode**: Must be disabled in UAT and production (`SP7_DEBUG=false`)

### UAT and Production Specifics

- **SSL/TLS**: External proxy handles SSL termination; do not configure TLS in Kubernetes ingress
- **Database**: UAT and production use Azure MySQL (external), not in-cluster MariaDB
- **Change Management**: Production deployments require approval and should follow change management procedures. Actions limited by RBAC in cluster

### Database Permissions

Azure MySQL users require the following permissions for migrations:
- CREATE
- ALTER  
- DROP
- INDEX
- REFERENCES


## Automation Scripts

### Development Reset Script

```bash
# Make executable
chmod +x ./scripts/reset-specify-dev.sh

# Quick reset (delete/recreate namespace only)
./scripts/reset-specify-dev.sh

# Full reset (delete/recreate entire k3d cluster)
./scripts/reset-specify-dev.sh --nuke
```

### UAT Reset Script

```bash
# Make executable
chmod +x ./scripts/reset-specify-uat.sh

# Reset UAT deployment (Does not delete namespace or cluster, only resoruces)
./scripts/reset-specify-uat.sh
```

**Note**: UAT reset script only deletes resources within the namespace, not the namespace itself.

## Environment Comparison

| Feature | Development | UAT | Production |
|---------|------------|-----|------------|
| **Cluster** | k3d (local) | Azure AKS | Azure AKS |
| **Database** | MariaDB (in-cluster) | Azure MySQL | Azure MySQL |
| **Access** | Port-forward (localhost:8000) | https://specify-test.dbca.wa.gov.au | https://specify.dbca.wa.gov.au |
| **Replicas** | 1 | 1 | 2 |
| **Debug Mode** | Enabled | Disabled | Disabled |
| **SSL/TLS** | None | External proxy | External proxy |
| **Change Control** | None | Informal | Formal |

## Common Operations

### View Deployment Status

```bash
# Check all pods
kubectl get pods -n herbarium-specify

# Check all resources
kubectl get all -n herbarium-specify

# View logs
kubectl logs -n herbarium-specify deployment/specify --tail=50
```

### Update Configuration

```bash
# After editing .env file:
kubectl delete secret specify-secrets -n herbarium-specify
kubectl apply -k kustomize/overlays/<env>
kubectl rollout restart deployment/specify -n herbarium-specify
```

### Restart Deployment

```bash
# Rolling restart (no downtime)
kubectl rollout restart deployment/specify -n herbarium-specify
```

See [COMMON_COMMANDS.md](COMMON_COMMANDS.md) for comprehensive command reference.

## Troubleshooting

### Common Issues

1. **VPN Connectivity** (UAT/Prod): Disconnect VPN before running kubectl commands
2. **Permission Errors**: Verify you're using the correct context and have namespace access
3. **Pod Startup Failures**: Check logs with `kubectl logs` and events with `kubectl get events`
4. **Database Connection**: Verify credentials in `.env` file and Azure MySQL firewall rules

### Getting Help

- Check environment-specific README files for detailed troubleshooting
- Review logs: `kubectl logs -n herbarium-specify deployment/specify`
- Check events: `kubectl get events -n herbarium-specify --sort-by='.lastTimestamp'`
- Verify configuration: `kubectl describe deployment specify -n herbarium-specify`

## Additional Resources

- **Specify 7 Documentation**: https://github.com/specify/specify7
- **Kubernetes Documentation**: https://kubernetes.io/docs/
- **Kustomize Documentation**: https://kustomize.io/

## Support

For deployment issues or questions:
1. Review the appropriate environment README (1_DEV_README.md, 2_UAT_README.md, or 3_PROD_README.md)
2. Check [COMMON_COMMANDS.md](COMMON_COMMANDS.md) for command reference
3. Review logs and events for error messages
4. Contact the infrastructure team for cluster or network issues
# Production Overlay Configuration

This directory contains the Kustomize overlay configuration for the **production** deployment of Herbarium Specify.

## Key Differences from UAT

### Infrastructure
- **Domain**: `specify.dbca.wa.gov.au` (vs `specify-test.dbca.wa.gov.au`)
- **Database**: `specify_prod` on production Azure MySQL server
- **Namespace**: `herbarium-specify` (same as UAT)
- **Cluster**: Production Rancher cluster (TBD - may be same or different from UAT)

### Resource Allocation
- **Specify replicas**: 2 (vs 1 in UAT) for high availability
- **Worker replicas**: 2 (vs 1 in UAT) for better task processing
- **Memory/CPU**: Higher limits for production load
- **Storage**: Larger PVCs (20Gi specify-storage, 50Gi asset-storage)

### Security
- **Unique keys**: Production uses different SECRET_KEY and ASSET_SERVER_KEY
- **Database user**: `specify_admin` (has migration permissions)
- **Debug mode**: Disabled (SP7_DEBUG=false)
- **Log level**: WARNING (reduced verbosity)

## Configuration Files

### kustomization.yaml
Main Kustomize configuration that:
- References base resources
- Generates secrets from .env file
- Applies production-specific patches
- Excludes MariaDB (using Azure MySQL)
- Sets environment label to "production"

### .env.example
Template for production environment variables. Copy to `.env` and fill in:
- Production database credentials
- Unique SECRET_KEY (generate new)
- Unique ASSET_SERVER_KEY (generate new)
- Production domain for CSRF_TRUSTED_ORIGINS

**CRITICAL**: Never commit the actual `.env` file to version control!

### deployment-patch.yaml
Production-specific deployment configuration:
- 2 replicas for high availability
- Higher resource limits (4Gi memory, 2 CPU)
- Removes MariaDB initContainer

### specify-worker-patch.yaml
Production worker configuration:
- 2 replicas for better task processing
- Higher resource limits (2Gi memory, 1 CPU)
- Removes MariaDB initContainer

### ingress-patch.yaml
Production ingress configuration:
- Domain: `specify.dbca.wa.gov.au`
- No TLS config (external proxy handles SSL)
- SSL redirect disabled (external proxy handles)

### pvc-patch.yaml
Production storage for application data:
- 20Gi storage (vs 2Gi in UAT)
- Azure managed-csi storage class
- ReadWriteOnce access mode

### asset-storage-pvc-patch.yaml
Production storage for asset files:
- 50Gi storage (vs 5Gi in UAT)
- Azure managed-csi storage class
- ReadWriteOnce access mode

## Setup Instructions

1. **Create .env file**:
   ```bash
   cp .env.example .env
   ```

2. **Generate secure keys**:
   ```bash
   # Generate SECRET_KEY
   python3 -c "import secrets; print('SECRET_KEY=' + secrets.token_urlsafe(50))"
   
   # Generate ASSET_SERVER_KEY
   python3 -c "import secrets; print('ASSET_SERVER_KEY=' + secrets.token_urlsafe(50))"
   ```

3. **Fill in database credentials**:
   - Get production database details from Azure MySQL administrator
   - Use `specify_admin` user (has CREATE, ALTER, DROP permissions for migrations)
   - Update DATABASE_HOST, DATABASE_NAME, MASTER_NAME, MASTER_PASSWORD

4. **Verify configuration**:
   ```bash
   # Build manifests to verify
   kubectl kustomize kustomize/overlays/prod
   ```

5. **Review before deployment**:
   - Verify domain is correct
   - Verify database credentials are correct
   - Verify storage sizes are appropriate
   - Verify resource limits are appropriate

## Deployment

**IMPORTANT**: Follow the production deployment guide in `3_PROD_README.md` for detailed instructions.

Quick reference:
```bash
# Switch to production cluster context
kubectl config use-context <prod-cluster-context>

# Apply production overlay
kubectl apply -k kustomize/overlays/prod

# Monitor deployment
kubectl get pods -n herbarium-specify -w
```

## Change Management

All production changes should follow the change management process:
1. Test changes in UAT first
2. Document the change and rationale
3. Get approval from stakeholders
4. Schedule maintenance window if needed
5. Have rollback plan ready
6. Deploy during maintenance window
7. Verify deployment success
8. Monitor for issues

## Rollback

If deployment fails or issues are discovered:
```bash
# Rollback to previous version
kubectl rollout undo deployment/specify -n herbarium-specify
kubectl rollout undo deployment/specify-worker -n herbarium-specify

# Or rollback to specific revision
kubectl rollout undo deployment/specify --to-revision=<N> -n herbarium-specify
```

## Security Notes

- Keep `.env` file secure - it contains production credentials
- Never commit `.env` to version control
- Rotate keys regularly (SECRET_KEY, ASSET_SERVER_KEY)
- Use strong passwords for database users
- Backup `.env` file securely before making changes
- Limit access to production cluster and credentials

## Support

For production issues:
- **Application errors**: Check pod logs, review error messages
- **Database issues**: Contact Azure MySQL administrator
- **Infrastructure issues**: Contact DevOps/IT team
- **Deployment issues**: Review deployment logs and events


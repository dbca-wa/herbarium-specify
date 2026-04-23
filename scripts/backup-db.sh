#!/bin/bash
# =============================================================================
# Specify Database Backup Script
#
# Backs up the Specify database to the Azure File Share for the given environment.
# The backup is stored on the environment's asset storage share and can be
# downloaded later via Azure Storage Explorer.
#
# Usage:
#   ./scripts/backup-db.sh [environment]
#
# Environments:
#   uat   - UAT environment (az-aks-oim03 cluster, herbarium-specify namespace)
#   prod  - Production environment (az-aks-prod01 cluster, herbarium-specify namespace)
#
# Examples:
#   ./scripts/backup-db.sh uat
#   ./scripts/backup-db.sh prod
#
# Prerequisites:
#   - kubectl configured and connected to the correct cluster
#   - azure-file-secret must exist in the namespace
#   - specify-secrets must exist in the namespace (contains DB credentials)
#
# The backup file will be saved to the Azure File Share at:
#   /specify_<dbname>_backup_<YYYYMMDD_HHMMSS>.sql
# =============================================================================

set -euo pipefail

# --- Configuration ---
NAMESPACE="herbarium-specify"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

# --- Validate arguments ---
if [ $# -lt 1 ]; then
    echo "Usage: $0 <environment>"
    echo "  environment: uat | prod"
    exit 1
fi

ENV="$1"

case "$ENV" in
    uat)
        SHARE_NAME="specify-assets-uat"
        CONTEXT="az-aks-oim03"
        ;;
    prod)
        SHARE_NAME="specify-assets-prod"
        CONTEXT="az-aks-prod01"
        ;;
    *)
        echo "Error: Unknown environment '$ENV'. Use 'uat' or 'prod'."
        exit 1
        ;;
esac

echo "=== Specify Database Backup ==="
echo "Environment: $ENV"
echo "Namespace:   $NAMESPACE"
echo "Context:     $CONTEXT"
echo "Share:       $SHARE_NAME"
echo "Timestamp:   $TIMESTAMP"
echo ""

# --- Switch context ---
echo "Switching to context: $CONTEXT"
kubectl config use-context "$CONTEXT"

# --- Get database info from secrets ---
echo "Reading database configuration from secrets..."
DB_HOST=$(kubectl get secret specify-secrets -n "$NAMESPACE" -o jsonpath='{.data.DATABASE_HOST}' | base64 -d)
DB_NAME=$(kubectl get secret specify-secrets -n "$NAMESPACE" -o jsonpath='{.data.DATABASE_NAME}' | base64 -d)
DB_PORT=$(kubectl get secret specify-secrets -n "$NAMESPACE" -o jsonpath='{.data.DATABASE_PORT}' | base64 -d 2>/dev/null || echo "3306")

BACKUP_FILE="specify_${DB_NAME}_backup_${TIMESTAMP}.sql"

echo "Database:    $DB_NAME"
echo "Host:        $DB_HOST"
echo "Backup file: $BACKUP_FILE"
echo ""

# --- Verify prerequisites ---
echo "Verifying prerequisites..."
kubectl get secret azure-file-secret -n "$NAMESPACE" > /dev/null 2>&1 || {
    echo "Error: azure-file-secret not found in namespace $NAMESPACE"
    exit 1
}
kubectl get secret specify-secrets -n "$NAMESPACE" > /dev/null 2>&1 || {
    echo "Error: specify-secrets not found in namespace $NAMESPACE"
    exit 1
}
echo "Prerequisites OK"
echo ""

# --- Run backup pod ---
echo "Starting backup..."
kubectl run db-backup-${TIMESTAMP} \
    --image=mysql:8.0 \
    --restart=Never \
    -n "$NAMESPACE" \
    --overrides="{
        \"spec\": {
            \"containers\": [{
                \"name\": \"db-backup\",
                \"image\": \"mysql:8.0\",
                \"command\": [\"bash\", \"-c\", \"echo 'Starting mysqldump...' && mysqldump --host=$DB_HOST --port=$DB_PORT --user=\$(cat /secrets/MASTER_NAME) --single-transaction --quick $DB_NAME > /backup/$BACKUP_FILE && echo 'BACKUP_COMPLETE' && ls -lh /backup/$BACKUP_FILE\"],
                \"env\": [{\"name\": \"MYSQL_PWD\", \"valueFrom\": {\"secretKeyRef\": {\"name\": \"specify-secrets\", \"key\": \"MASTER_PASSWORD\"}}}],
                \"volumeMounts\": [
                    {\"name\": \"backup-vol\", \"mountPath\": \"/backup\"},
                    {\"name\": \"secrets-vol\", \"mountPath\": \"/secrets\"}
                ]
            }],
            \"volumes\": [
                {
                    \"name\": \"backup-vol\",
                    \"csi\": {
                        \"driver\": \"file.csi.azure.com\",
                        \"readOnly\": false,
                        \"volumeAttributes\": {
                            \"secretName\": \"azure-file-secret\",
                            \"shareName\": \"$SHARE_NAME\"
                        }
                    }
                },
                {
                    \"name\": \"secrets-vol\",
                    \"secret\": {
                        \"secretName\": \"specify-secrets\"
                    }
                }
            ]
        }
    }" 2>&1

echo "Waiting for backup to complete..."
kubectl wait --for=condition=Ready=false pod/db-backup-${TIMESTAMP} -n "$NAMESPACE" --timeout=300s 2>/dev/null || true

# Wait for completion
for i in $(seq 1 60); do
    STATUS=$(kubectl get pod db-backup-${TIMESTAMP} -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
    if [ "$STATUS" = "Succeeded" ]; then
        break
    elif [ "$STATUS" = "Failed" ]; then
        echo "Error: Backup pod failed!"
        kubectl logs db-backup-${TIMESTAMP} -n "$NAMESPACE"
        kubectl delete pod db-backup-${TIMESTAMP} -n "$NAMESPACE" --ignore-not-found
        exit 1
    fi
    sleep 5
done

# --- Show logs ---
echo ""
echo "=== Backup Pod Logs ==="
kubectl logs db-backup-${TIMESTAMP} -n "$NAMESPACE"

# --- Verify backup ---
echo ""
echo "Verifying backup on Azure File Share..."
kubectl exec -n "$NAMESPACE" deployment/asset-server -- ls -lh /home/specify/attachments/$BACKUP_FILE 2>/dev/null && {
    echo ""
    echo "=== Backup Successful ==="
    echo "File: $BACKUP_FILE"
    echo "Location: Azure File Share ($SHARE_NAME)"
    echo "Download via Azure Storage Explorer or azcopy"
} || {
    echo "Warning: Could not verify backup file via asset-server"
}

# --- Cleanup ---
echo ""
echo "Cleaning up backup pod..."
kubectl delete pod db-backup-${TIMESTAMP} -n "$NAMESPACE" --ignore-not-found
echo "Done!"

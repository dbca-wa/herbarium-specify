#!/bin/bash
# =============================================================================
# Specify Database Management Script
#
# Unified tool for managing the Specify database: nuke, restore, backup, and
# save/load vanilla state. Works across dev (local k3d), UAT, and prod.
#
# Usage:
#   ./scripts/manage-db.sh <environment> <action> [options]
#
# Environments:
#   dev   - Local k3d cluster (in-cluster MariaDB)
#   uat   - UAT on AKS (Azure MySQL, file share)
#   prod  - Production on AKS (Azure MySQL, file share)
#
# Actions:
#   --nuke            Wipe DB completely (triggers Guided Setup wizard)
#   --save_vanilla    Save current DB state as vanilla.sql
#   --load_vanilla    Load vanilla.sql (reset to clean configured state)
#   --save            Create a timestamped backup
#   --load <file>     Load a specific .sql file (lists files if no name)
#   --load_last       Load the most recent backup (UAT/prod only)
#   --help            Show this help message
#
# Examples:
#   ./scripts/manage-db.sh dev --nuke
#   ./scripts/manage-db.sh dev --save_vanilla
#   ./scripts/manage-db.sh dev --load_vanilla
#   ./scripts/manage-db.sh dev --save
#   ./scripts/manage-db.sh dev --load dump.sql
#   ./scripts/manage-db.sh dev --load
#   ./scripts/manage-db.sh uat --nuke
#   ./scripts/manage-db.sh uat --load_last
# =============================================================================

set -euo pipefail

# --- Configuration ---
NAMESPACE="herbarium-specify"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
FILE_TIMESTAMP=$(date +%Y%m%d_%H%M%S)
VANILLA_FILENAME="vanilla.sql"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo_info()  { echo -e "${GREEN}✓${NC} $1"; }
echo_step()  { echo -e "${BLUE}==>${NC} $1"; }
echo_warn()  { echo -e "${YELLOW}⚠${NC} $1"; }
echo_error() { echo -e "${RED}✗${NC} $1"; }

# --- Show usage ---
show_usage() {
    echo ""
    echo "Usage: $0 <environment> <action>"
    echo ""
    echo "Environments: dev | uat | prod"
    echo ""
    echo "Actions:"
    echo "  --nuke            Wipe DB completely (Guided Setup wizard)"
    echo "  --save_vanilla    Save current DB as vanilla.sql"
    echo "  --load_vanilla    Load vanilla.sql (reset to clean state)"
    echo "  --save            Create a timestamped backup"
    echo "  --load <file>     Load a specific .sql file"
    echo "  --load            List available .sql files"
    echo "  --load_last       Load most recent backup (UAT/prod only)"
    echo "  --help            Show this message"
    echo ""
    exit "${1:-1}"
}

# --- Parse arguments ---
ENV=""
MODE=""
RESTORE_FILE=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        dev|uat|prod) ENV="$1"; shift ;;
        --nuke) MODE="nuke"; shift ;;
        --save_vanilla) MODE="save_vanilla"; shift ;;
        --load_vanilla) MODE="load_vanilla"; shift ;;
        --save) MODE="save"; shift ;;
        --load_last) MODE="load_last"; shift ;;
        --load)
            MODE="load"
            if [[ $# -gt 1 && ! "$2" =~ ^-- ]]; then
                RESTORE_FILE="$2"; shift 2
            else
                MODE="list_files"; shift
            fi
            ;;
        --help|-h) show_usage 0 ;;
        *) echo_error "Unknown argument: $1"; show_usage ;;
    esac
done

if [ -z "$ENV" ]; then
    echo_error "Environment required"
    show_usage
fi

if [ -z "$MODE" ]; then
    echo_error "Action required"
    show_usage
fi

# --- Environment config ---
case "$ENV" in
    dev)
        CONTEXT="k3d-specify-test"
        SHARE_NAME=""
        DB_TYPE="local"
        VANILLA_PATH="kustomize/base/$VANILLA_FILENAME"
        ;;
    uat)
        CONTEXT="az-aks-oim03"
        SHARE_NAME="specify-assets-uat"
        DB_TYPE="azure"
        ;;
    prod)
        CONTEXT="az-aks-prod01"
        SHARE_NAME="specify-assets-prod"
        DB_TYPE="azure"
        ;;
esac

# Validate --load_last is only for azure environments
if [ "$MODE" = "load_last" ] && [ "$DB_TYPE" = "local" ]; then
    echo_error "--load_last is only available for uat/prod (requires Azure File Share)"
    exit 1
fi

# For load_vanilla on dev, set the restore file to the local path
if [ "$MODE" = "load_vanilla" ] && [ "$DB_TYPE" = "local" ]; then
    RESTORE_FILE="$VANILLA_PATH"
fi

echo ""
echo_step "Specify Database Management"
echo "  Environment: $ENV"
echo "  Action:      $MODE"
echo "  Context:     $CONTEXT"
[ "$MODE" = "load" ] && [ -n "$RESTORE_FILE" ] && echo "  File:        $RESTORE_FILE"
echo ""

# --- Switch context ---
echo_step "Switching to context: $CONTEXT"
kubectl config use-context "$CONTEXT" > /dev/null 2>&1 || {
    echo_error "Failed to switch to context $CONTEXT"
    [ "$ENV" = "dev" ] && echo "Is your k3d cluster running? Try: k3d cluster start specify-test"
    exit 1
}
echo_info "Context: $CONTEXT"

# --- Verify namespace ---
kubectl get namespace "$NAMESPACE" > /dev/null 2>&1 || {
    echo_error "Namespace $NAMESPACE not found"
    exit 1
}

# =============================================================================
# Helper: drop all tables in database (works without DROP DATABASE privilege)
# =============================================================================
drop_all_tables_local() {
    local pod="$1" user="$2" pass="$3" db="$4"
    kubectl exec -n "$NAMESPACE" "$pod" -- \
        mysql -u "$user" -p"$pass" "$db" -e "
            SET FOREIGN_KEY_CHECKS = 0;
            SET @tables = NULL;
            SELECT GROUP_CONCAT('\`', table_name, '\`') INTO @tables
              FROM information_schema.tables
              WHERE table_schema = '$db';
            SET @tables = IFNULL(CONCAT('DROP TABLE ', @tables), 'SELECT 1');
            PREPARE stmt FROM @tables;
            EXECUTE stmt;
            DEALLOCATE PREPARE stmt;
            SET FOREIGN_KEY_CHECKS = 1;
        " 2>/dev/null
}

# =============================================================================
# DEV (local k3d with in-cluster MariaDB)
# =============================================================================
if [ "$DB_TYPE" = "local" ]; then

    # Get MariaDB pod
    MARIADB_POD=$(kubectl get pods -n "$NAMESPACE" -l app=specify,component=database \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
    if [ -z "$MARIADB_POD" ]; then
        echo_error "MariaDB pod not found. Deploy with: kubectl apply -k kustomize/overlays/dev"
        exit 1
    fi
    echo_info "MariaDB pod: $MARIADB_POD"

    # Read DB credentials
    DB_NAME=$(kubectl get secret specify-secrets -n "$NAMESPACE" -o jsonpath='{.data.DATABASE_NAME}' | base64 -d)
    DB_USER=$(kubectl get secret specify-secrets -n "$NAMESPACE" -o jsonpath='{.data.MASTER_NAME}' | base64 -d)
    DB_PASS=$(kubectl get secret specify-secrets -n "$NAMESPACE" -o jsonpath='{.data.MASTER_PASSWORD}' | base64 -d)
    echo_info "Database: $DB_NAME"

    # --- LIST FILES ---
    if [ "$MODE" = "list_files" ]; then
        echo_step "Available .sql files:"
        echo ""
        find . -name "*.sql" -not -path "./.git/*" -exec ls -lh {} \; 2>/dev/null | awk '{print "  " $NF " (" $5 ")"}'
        echo ""
        echo "Usage: $0 dev --load <path-to-file>"
        exit 0
    fi

    # --- SAVE VANILLA ---
    if [ "$MODE" = "save_vanilla" ]; then
        echo_step "Saving current database state as vanilla.sql..."
        kubectl exec -n "$NAMESPACE" "$MARIADB_POD" -- \
            mysqldump -u "$DB_USER" -p"$DB_PASS" --single-transaction "$DB_NAME" > "$VANILLA_PATH" 2>/dev/null || {
            echo_error "Failed to dump database"; exit 1
        }
        echo_info "Saved: $VANILLA_PATH ($(du -h "$VANILLA_PATH" | cut -f1))"
        echo -e "${GREEN}Running with --load_vanilla will now restore to this state.${NC}"
        echo ""
        exit 0
    fi

    # --- SAVE (backup) ---
    if [ "$MODE" = "save" ]; then
        BACKUP_FILE="/tmp/specify_${DB_NAME}_backup_${FILE_TIMESTAMP}.sql"
        echo_step "Creating backup..."
        kubectl exec -n "$NAMESPACE" "$MARIADB_POD" -- \
            mysqldump -u "$DB_USER" -p"$DB_PASS" --single-transaction "$DB_NAME" > "$BACKUP_FILE" 2>/dev/null || {
            echo_error "Backup failed"; exit 1
        }
        echo_info "Backup saved: $BACKUP_FILE ($(du -h "$BACKUP_FILE" | cut -f1))"
        echo ""
        exit 0
    fi

    # --- LOAD VANILLA ---
    if [ "$MODE" = "load_vanilla" ]; then
        if [ ! -f "$RESTORE_FILE" ]; then
            echo_error "vanilla.sql not found at: $VANILLA_PATH"
            echo "Create it first: $0 dev --nuke, complete Guided Setup, then $0 dev --save_vanilla"
            exit 1
        fi
        echo -e "${RED}This will wipe all tables and load vanilla.sql ($( du -h "$RESTORE_FILE" | cut -f1))${NC}"
        read -p "Type 'yes' to continue: " CONFIRM
        [ "$CONFIRM" != "yes" ] && { echo_error "Cancelled"; exit 0; }

        echo_step "Dropping all tables..."
        drop_all_tables_local "$MARIADB_POD" "$DB_USER" "$DB_PASS" "$DB_NAME"
        echo_info "Tables dropped"

        echo_step "Loading vanilla.sql..."
        kubectl exec -i -n "$NAMESPACE" "$MARIADB_POD" -- \
            mysql -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" < "$RESTORE_FILE" 2>/dev/null
        echo_info "Database loaded"

        echo_step "Restarting Specify..."
        kubectl rollout restart deployment/specify deployment/specify-worker -n "$NAMESPACE" > /dev/null 2>&1
        kubectl rollout status deployment/specify -n "$NAMESPACE" --timeout=120s 2>/dev/null || true
        echo_info "Done"
        echo ""
        echo -e "Access: ${GREEN}http://localhost:8000/specify/${NC}"
        exit 0
    fi

    # --- LOAD (specific file) ---
    if [ "$MODE" = "load" ]; then
        if [ ! -f "$RESTORE_FILE" ]; then
            echo_error "File not found: $RESTORE_FILE"
            echo ""
            echo "Available .sql files:"
            find . -name "*.sql" -not -path "./.git/*" -exec ls -lh {} \; 2>/dev/null | awk '{print "  " $NF " (" $5 ")"}'
            exit 1
        fi
        echo -e "${RED}This will wipe all tables and load: $(basename "$RESTORE_FILE") ($(du -h "$RESTORE_FILE" | cut -f1))${NC}"
        read -p "Type 'yes' to continue: " CONFIRM
        [ "$CONFIRM" != "yes" ] && { echo_error "Cancelled"; exit 0; }

        echo_step "Dropping all tables..."
        drop_all_tables_local "$MARIADB_POD" "$DB_USER" "$DB_PASS" "$DB_NAME"
        echo_info "Tables dropped"

        echo_step "Loading: $(basename "$RESTORE_FILE")..."
        kubectl exec -i -n "$NAMESPACE" "$MARIADB_POD" -- \
            mysql -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" < "$RESTORE_FILE" 2>/dev/null
        echo_info "Database loaded"

        echo_step "Restarting Specify..."
        kubectl rollout restart deployment/specify deployment/specify-worker -n "$NAMESPACE" > /dev/null 2>&1
        kubectl rollout status deployment/specify -n "$NAMESPACE" --timeout=120s 2>/dev/null || true
        echo_info "Done"
        echo ""
        echo -e "Access: ${GREEN}http://localhost:8000/specify/${NC}"
        exit 0
    fi

    # --- NUKE ---
    if [ "$MODE" = "nuke" ]; then
        echo -e "${RED}This will WIPE the database completely. Guided Setup wizard will appear on next access.${NC}"
        echo -e "${RED}(Takes ~5 min — cannot DROP DATABASE due to Azure MySQL permissions, so we drop all tables and re-run migrations)${NC}"
        read -p "Type 'yes' to continue: " CONFIRM
        [ "$CONFIRM" != "yes" ] && { echo_error "Cancelled"; exit 0; }

        NUKE_START=$(date +%s)

        echo_step "Dropping all tables..."
        drop_all_tables_local "$MARIADB_POD" "$DB_USER" "$DB_PASS" "$DB_NAME"
        echo_info "All tables dropped"

        echo_step "Running schema creation (base_specify_migration)..."
        kubectl exec -n "$NAMESPACE" deployment/specify -- \
            ve/bin/python manage.py base_specify_migration --database=master 2>/dev/null || true

        echo_step "Faking initial migration record..."
        kubectl exec -n "$NAMESPACE" deployment/specify -- \
            ve/bin/python manage.py base_specify_migration --use-override --database=master 2>/dev/null || true

        echo_step "Running Django migrations (creating remaining tables)..."
        kubectl exec -n "$NAMESPACE" deployment/specify -- \
            ve/bin/python manage.py migrate --database=master 2>/dev/null || true

        echo_step "Restarting for clean state..."
        kubectl rollout restart deployment/specify deployment/specify-worker -n "$NAMESPACE" > /dev/null 2>&1
        for i in $(seq 1 60); do
            kubectl logs -n "$NAMESPACE" deployment/specify --tail=3 2>/dev/null | grep -q "Booting worker" && break
            sleep 5
        done

        NUKE_END=$(date +%s)
        NUKE_TOTAL=$(( NUKE_END - NUKE_START ))
        echo_info "Done! (${NUKE_TOTAL}s total)"
        echo ""
        echo -e "Access: ${GREEN}http://localhost:8000/specify/${NC} — Guided Setup wizard will appear"
        exit 0
    fi

    echo_error "Unknown mode: $MODE"
    exit 1
fi

# =============================================================================
# UAT / PROD (Azure MySQL with Azure File Share)
# =============================================================================

# Verify prerequisites
echo_step "Verifying prerequisites..."
kubectl get secret specify-secrets -n "$NAMESPACE" > /dev/null 2>&1 || {
    echo_error "specify-secrets not found"; exit 1
}
kubectl get secret azure-file-secret -n "$NAMESPACE" > /dev/null 2>&1 || {
    echo_error "azure-file-secret not found"; exit 1
}
echo_info "Prerequisites OK"

# Read DB credentials
DB_HOST=$(kubectl get secret specify-secrets -n "$NAMESPACE" -o jsonpath='{.data.DATABASE_HOST}' | base64 -d)
DB_NAME=$(kubectl get secret specify-secrets -n "$NAMESPACE" -o jsonpath='{.data.DATABASE_NAME}' | base64 -d)
DB_PORT=$(kubectl get secret specify-secrets -n "$NAMESPACE" -o jsonpath='{.data.DATABASE_PORT}' | base64 -d 2>/dev/null || echo "3306")
echo_info "Database: $DB_NAME @ $DB_HOST"

# --- Helper: run a pod with file share access ---
run_share_pod() {
    local name="$1" command="$2" rw="${3:-true}"
    local ro_flag="false"
    [ "$rw" = "false" ] && ro_flag="true"

    kubectl run "$name" \
        --image=mysql:8.0 \
        --restart=Never \
        -n "$NAMESPACE" \
        --overrides="{
            \"spec\": {
                \"containers\": [{
                    \"name\": \"task\",
                    \"image\": \"mysql:8.0\",
                    \"command\": [\"bash\", \"-c\", \"$command\"],
                    \"env\": [{\"name\": \"MYSQL_PWD\", \"valueFrom\": {\"secretKeyRef\": {\"name\": \"specify-secrets\", \"key\": \"MASTER_PASSWORD\"}}}],
                    \"volumeMounts\": [
                        {\"name\": \"share\", \"mountPath\": \"/share\", \"readOnly\": $ro_flag},
                        {\"name\": \"secrets\", \"mountPath\": \"/secrets\"}
                    ]
                }],
                \"volumes\": [
                    {\"name\": \"share\", \"csi\": {\"driver\": \"file.csi.azure.com\", \"readOnly\": $ro_flag, \"volumeAttributes\": {\"secretName\": \"azure-file-secret\", \"shareName\": \"$SHARE_NAME\"}}},
                    {\"name\": \"secrets\", \"secret\": {\"secretName\": \"specify-secrets\"}}
                ]
            }
        }" > /dev/null 2>&1
}

wait_for_pod() {
    local name="$1" timeout="${2:-60}"
    for i in $(seq 1 $timeout); do
        STATUS=$(kubectl get pod "$name" -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || echo "Pending")
        [ "$STATUS" = "Succeeded" ] && return 0
        [ "$STATUS" = "Failed" ] && return 1
        sleep 3
    done
    return 1
}

cleanup_pod() {
    kubectl delete pod "$1" -n "$NAMESPACE" --ignore-not-found > /dev/null 2>&1
}

# --- LIST FILES ---
if [ "$MODE" = "list_files" ]; then
    echo_step "Listing .sql files on file share ($SHARE_NAME)..."
    POD="list-${TIMESTAMP}"
    run_share_pod "$POD" "ls -lh /share/*.sql 2>/dev/null || echo '  (none found)'" "false"
    wait_for_pod "$POD" 20
    echo ""
    kubectl logs "$POD" -n "$NAMESPACE" 2>/dev/null
    cleanup_pod "$POD"
    echo ""
    echo "Usage: $0 $ENV --load <filename>"
    exit 0
fi

# --- SAVE VANILLA ---
if [ "$MODE" = "save_vanilla" ]; then
    echo_step "Saving current DB as vanilla.sql on file share..."
    POD="save-vanilla-${TIMESTAMP}"
    run_share_pod "$POD" "mysqldump --host=$DB_HOST --port=$DB_PORT --user=\$(cat /secrets/MASTER_NAME) --single-transaction --quick $DB_NAME > /share/$VANILLA_FILENAME && echo DONE && ls -lh /share/$VANILLA_FILENAME"
    wait_for_pod "$POD" 60 || { echo_error "Failed"; kubectl logs "$POD" -n "$NAMESPACE" 2>/dev/null; cleanup_pod "$POD"; exit 1; }
    kubectl logs "$POD" -n "$NAMESPACE" 2>/dev/null | tail -1
    cleanup_pod "$POD"
    echo_info "vanilla.sql saved to file share"
    echo -e "${GREEN}Running with --load_vanilla will now restore to this state.${NC}"
    echo ""
    exit 0
fi

# --- SAVE (backup) ---
if [ "$MODE" = "save" ]; then
    BACKUP_FILE="specify_${DB_NAME}_backup_${FILE_TIMESTAMP}.sql"
    echo_step "Creating backup: $BACKUP_FILE"
    POD="backup-${TIMESTAMP}"
    run_share_pod "$POD" "mysqldump --host=$DB_HOST --port=$DB_PORT --user=\$(cat /secrets/MASTER_NAME) --single-transaction --quick $DB_NAME > /share/$BACKUP_FILE && echo DONE && ls -lh /share/$BACKUP_FILE"
    wait_for_pod "$POD" 60 || { echo_error "Backup failed"; kubectl logs "$POD" -n "$NAMESPACE" 2>/dev/null; cleanup_pod "$POD"; exit 1; }
    kubectl logs "$POD" -n "$NAMESPACE" 2>/dev/null | tail -1
    cleanup_pod "$POD"
    echo_info "Backup saved: $BACKUP_FILE (on $SHARE_NAME)"
    echo ""
    exit 0
fi

# --- Determine file for load modes ---
if [ "$MODE" = "load_vanilla" ]; then
    RESTORE_FILE="$VANILLA_FILENAME"
fi

if [ "$MODE" = "load_last" ]; then
    echo_step "Finding most recent backup..."
    POD="find-last-${TIMESTAMP}"
    run_share_pod "$POD" "ls -t /share/specify_*.sql 2>/dev/null | head -1 | sed 's|/share/||'" "false"
    wait_for_pod "$POD" 20
    RESTORE_FILE=$(kubectl logs "$POD" -n "$NAMESPACE" 2>/dev/null | tr -d '\n')
    cleanup_pod "$POD"
    if [ -z "$RESTORE_FILE" ]; then
        echo_error "No backup files found on file share"
        exit 1
    fi
    echo_info "Most recent: $RESTORE_FILE"
fi

# --- Verify file exists on share (for load, load_vanilla, load_last) ---
if [ "$MODE" = "load" ] || [ "$MODE" = "load_vanilla" ] || [ "$MODE" = "load_last" ]; then
    echo_step "Verifying file: $RESTORE_FILE"
    POD="verify-${TIMESTAMP}"
    run_share_pod "$POD" "[ -f /share/$RESTORE_FILE ] && echo EXISTS || echo MISSING" "false"
    wait_for_pod "$POD" 20
    RESULT=$(kubectl logs "$POD" -n "$NAMESPACE" 2>/dev/null | tr -d '\n')
    cleanup_pod "$POD"

    if [ "$RESULT" != "EXISTS" ]; then
        echo_error "File not found on share: $RESTORE_FILE"
        if [ "$MODE" = "load_vanilla" ]; then
            echo "Create it first: $0 $ENV --nuke, complete Guided Setup, then $0 $ENV --save_vanilla"
        fi
        echo ""
        echo "Available files:"
        POD="list-avail-${TIMESTAMP}"
        run_share_pod "$POD" "ls -lh /share/*.sql 2>/dev/null || echo '  (none)'" "false"
        wait_for_pod "$POD" 20
        kubectl logs "$POD" -n "$NAMESPACE" 2>/dev/null
        cleanup_pod "$POD"
        exit 1
    fi
    echo_info "File found"

    # Confirmation
    echo -e "${RED}This will wipe all tables and load: $RESTORE_FILE${NC}"
    read -p "Type 'yes' to continue: " CONFIRM
    [ "$CONFIRM" != "yes" ] && { echo_error "Cancelled"; exit 0; }

    # Drop all tables via kubectl exec (reliable, no escaping issues)
    echo_step "Dropping all tables..."
    kubectl exec -n "$NAMESPACE" deployment/specify -- python -c "
import django, os
os.environ.setdefault('DJANGO_SETTINGS_MODULE', 'specifyweb.settings')
django.setup()
from django.db import connections
cursor = connections['master'].cursor()
cursor.execute('SET FOREIGN_KEY_CHECKS = 0')
cursor.execute('SELECT table_name FROM information_schema.tables WHERE table_schema = DATABASE()')
tables = [r[0] for r in cursor.fetchall()]
if tables:
    cursor.execute('DROP TABLE ' + ', '.join(f'\`{t}\`' for t in tables))
cursor.execute('SET FOREIGN_KEY_CHECKS = 1')
print(f'Dropped {len(tables)} tables')
" 2>/dev/null
    echo_info "Tables dropped"

    # Load file
    echo_step "Loading: $RESTORE_FILE"
    POD="restore-${TIMESTAMP}"
    run_share_pod "$POD" "mysql --host=$DB_HOST --port=$DB_PORT --user=\$(cat /secrets/MASTER_NAME) $DB_NAME < /share/$RESTORE_FILE && echo DONE" "false"
    echo "  Waiting for restore..."
    wait_for_pod "$POD" 120 || { echo_error "Restore failed"; kubectl logs "$POD" -n "$NAMESPACE" 2>/dev/null; cleanup_pod "$POD"; exit 1; }
    cleanup_pod "$POD"
    echo_info "Database loaded"

    # Restart
    echo_step "Restarting Specify..."
    kubectl rollout restart deployment/specify deployment/specify-worker -n "$NAMESPACE" > /dev/null 2>&1
    kubectl rollout status deployment/specify -n "$NAMESPACE" --timeout=180s 2>/dev/null || true
    echo_info "Done"
    echo ""
    case "$ENV" in
        uat)  echo -e "Access: ${GREEN}https://specify-test.dbca.wa.gov.au/specify/${NC}" ;;
        prod) echo -e "Access: ${GREEN}https://specify.dbca.wa.gov.au/specify/${NC}" ;;
    esac
    exit 0
fi

# --- NUKE (UAT/prod) ---
if [ "$MODE" = "nuke" ]; then
    echo -e "${RED}This will WIPE the $ENV database completely. Guided Setup wizard will appear.${NC}"
    echo -e "${RED}(Takes ~5 min — cannot DROP DATABASE due to permissions, so we drop all tables and re-run migrations)${NC}"
    read -p "Type 'yes' to continue: " CONFIRM
    [ "$CONFIRM" != "yes" ] && { echo_error "Cancelled"; exit 0; }

    NUKE_START=$(date +%s)

    # Drop all tables via kubectl exec (reliable)
    echo_step "Dropping all tables..."
    kubectl exec -n "$NAMESPACE" deployment/specify -- python -c "
import django, os
os.environ.setdefault('DJANGO_SETTINGS_MODULE', 'specifyweb.settings')
django.setup()
from django.db import connections
cursor = connections['master'].cursor()
cursor.execute('SET FOREIGN_KEY_CHECKS = 0')
cursor.execute('SELECT table_name FROM information_schema.tables WHERE table_schema = DATABASE()')
tables = [r[0] for r in cursor.fetchall()]
if tables:
    cursor.execute('DROP TABLE ' + ', '.join(f'\`{t}\`' for t in tables))
cursor.execute('SET FOREIGN_KEY_CHECKS = 1')
print(f'Dropped {len(tables)} tables')
" 2>/dev/null
    echo_info "All tables dropped"

    # Run correct migration sequence
    echo_step "Running schema creation (base_specify_migration)..."
    kubectl exec -n "$NAMESPACE" deployment/specify -- \
        ve/bin/python manage.py base_specify_migration --database=master 2>/dev/null || true

    echo_step "Faking initial migration record..."
    kubectl exec -n "$NAMESPACE" deployment/specify -- \
        ve/bin/python manage.py base_specify_migration --use-override --database=master 2>/dev/null || true

    echo_step "Running Django migrations (creating remaining tables)..."
    kubectl exec -n "$NAMESPACE" deployment/specify -- \
        ve/bin/python manage.py migrate --database=master 2>/dev/null || true

    # Restart for clean state
    echo_step "Restarting for clean state..."
    kubectl rollout restart deployment/specify deployment/specify-worker -n "$NAMESPACE" > /dev/null 2>&1
    for i in $(seq 1 60); do
        kubectl logs -n "$NAMESPACE" deployment/specify --tail=3 2>/dev/null | grep -q "Booting worker" && break
        sleep 5
    done

    NUKE_END=$(date +%s)
    NUKE_TOTAL=$(( NUKE_END - NUKE_START ))
    echo_info "Done! (${NUKE_TOTAL}s total)"
    echo ""
    case "$ENV" in
        uat)  echo -e "Access: ${GREEN}https://specify-test.dbca.wa.gov.au/specify/${NC} — Guided Setup wizard" ;;
        prod) echo -e "Access: ${GREEN}https://specify.dbca.wa.gov.au/specify/${NC} — Guided Setup wizard" ;;
    esac
    exit 0
fi

echo_error "Unknown mode: $MODE"
exit 1

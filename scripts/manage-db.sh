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
    echo "  --load_last       Load most recent complete backup (UAT/prod only)"
    echo "  --check_schema    Report missing indexes, unique constraints and foreign keys (read-only)"
    echo "  --repair_schema   Create missing indexes, unique constraints and foreign keys"
    echo "                    (requires specify-worker scaled to 0 so no upload is running)"
    echo "  --help            Show this message"
    echo ""
    echo "Options:"
    echo "  --site_indexes    With --check_schema/--repair_schema, also include the"
    echo "                    site-specific WorkBench indexes"
    echo ""
    exit "${1:-1}"
}

# --- Parse arguments ---
ENV=""
MODE=""
RESTORE_FILE=""
SITE_INDEXES="0"

while [[ $# -gt 0 ]]; do
    case "$1" in
        dev|uat|prod) ENV="$1"; shift ;;
        --nuke) MODE="nuke"; shift ;;
        --save_vanilla) MODE="save_vanilla"; shift ;;
        --load_vanilla) MODE="load_vanilla"; shift ;;
        --save) MODE="save"; shift ;;
        --load_last) MODE="load_last"; shift ;;
        --check_schema) MODE="check_schema"; shift ;;
        --repair_schema) MODE="repair_schema"; shift ;;
        --site_indexes) SITE_INDEXES="1"; shift ;;
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
        CONTEXT="specify-dev"
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
        CONTEXT="aks-bcs-prod-01"
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

# --- Ensure kubeconfig is merged for UAT/prod ---
if [ "$DB_TYPE" = "azure" ]; then
    ACCESS_FILE=""
    [ "$ENV" = "uat" ] && ACCESS_FILE="az-aks-oim03.yaml"
    [ "$ENV" = "prod" ] && ACCESS_FILE="aks-bcs-prod-01.yaml"

    if [ -n "$ACCESS_FILE" ] && [ -f "$ACCESS_FILE" ]; then
        # Merge with access file taking priority (listed first)
        KUBECONFIG="$ACCESS_FILE":~/.kube/config kubectl config view --flatten > ~/.kube/config.new 2>/dev/null
        mv ~/.kube/config.new ~/.kube/config
    fi
fi

# --- Switch context ---
echo_step "Switching to context: $CONTEXT"
kubectl config use-context "$CONTEXT" > /dev/null 2>&1 || {
    echo_error "Failed to switch to context $CONTEXT"
    [ "$ENV" = "dev" ] && echo "Is your k3d cluster running? Try: k3d cluster start specify-dev"
    exit 1
}

# Verify the context actually matches what we expect
ACTIVE_CTX=$(kubectl config current-context 2>/dev/null || echo "")
if [ "$ACTIVE_CTX" != "$CONTEXT" ]; then
    echo_error "Context mismatch: expected '$CONTEXT' but got '$ACTIVE_CTX'. Aborting."
    exit 1
fi
echo_info "Context: $CONTEXT"

# --- Verify namespace ---
# Uses a namespaced call: Rancher project members usually cannot read namespaces
# at cluster scope.
kubectl get deployment specify -n "$NAMESPACE" > /dev/null 2>&1 || {
    echo_error "Deployment 'specify' not found in namespace $NAMESPACE (or no access)"
    exit 1
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCHEMA_TOOL="$SCRIPT_DIR/specify_schema_repair.py"

# =============================================================================
# Helpers: schema check / repair (shared by all environments)
# =============================================================================
# Runs scripts/specify_schema_repair.py inside the specify container.
# Usage: run_schema_tool <check|repair>
run_schema_tool() {
    local status=0 output
    output=$(kubectl exec -i -n "$NAMESPACE" deployment/specify -c specify -- \
        env SCHEMA_MODE="$1" SITE_INDEXES="$SITE_INDEXES" ve/bin/python manage.py shell \
        < "$SCHEMA_TOOL" 2>&1) || status=$?
    echo "$output" | grep -v -E "WARNING|staticfiles|System check" || true
    return $status
}

# Warns when the database is missing the indexes and constraints Specify declares.
# Specify 7.12.x cannot run its first migration on MySQL 8 and leaves the schema
# without them (https://github.com/specify/specify7/pull/8813).
verify_schema() {
    echo_step "Checking database schema..."
    local report summary
    report=$(run_schema_tool check) || true
    summary=$(echo "$report" | grep "^SCHEMA" | tail -1) || true
    if [ -z "$summary" ]; then
        echo_warn "Schema check could not run. Run '$0 $ENV --check_schema' once Specify is up."
        return 0
    fi
    if echo "$summary" | grep -q "missing=0 "; then
        echo_info "Schema complete"
        return 0
    fi
    if echo "$summary" | grep -q "SCHEMA empty"; then
        echo_info "No Specify tables yet (schema check skipped)"
        return 0
    fi
    echo_warn "$summary"
    echo_warn "The database is missing indexes/constraints, which makes WorkBench uploads very slow."
    echo_warn "Fix with: kubectl scale deployment/specify-worker -n $NAMESPACE --replicas=0"
    echo_warn "          $0 $ENV --repair_schema"
    return 1
}

if [ "$MODE" = "check_schema" ]; then
    echo_step "Checking schema (read-only)..."
    STATUS=0
    run_schema_tool check || STATUS=$?
    exit $STATUS
fi

if [ "$MODE" = "repair_schema" ]; then
    WORKERS=$(kubectl get deployment specify-worker -n "$NAMESPACE" -o jsonpath='{.spec.replicas}' 2>/dev/null)
    RUNNING=$(kubectl get pods -n "$NAMESPACE" -l app=specify,component=worker --no-headers 2>/dev/null | wc -l | tr -d ' ')
    if [ "${WORKERS:-1}" != "0" ] || [ "${RUNNING:-1}" != "0" ]; then
        echo_error "specify-worker is running (replicas=${WORKERS:-?}, pods=${RUNNING:-?})."
        echo "  Schema changes wait on, and block, any WorkBench upload in progress."
        echo "  Make sure no upload is running, then:"
        echo "    kubectl scale deployment/specify-worker -n $NAMESPACE --replicas=0"
        echo "  and re-run this command. Scale it back to 1 afterwards."
        exit 1
    fi
    echo_step "Planned changes:"
    run_schema_tool check || true
    echo ""
    echo -e "${RED}This will add the missing indexes/constraints to the $ENV database.${NC}"
    echo -e "${RED}Take a verified backup first ($0 $ENV --save).${NC}"
    read -p "Type 'yes' to continue: " CONFIRM
    [ "$CONFIRM" != "yes" ] && { echo_error "Cancelled"; exit 0; }
    STATUS=0
    run_schema_tool repair || STATUS=$?
    case $STATUS in
        0) echo_info "Schema repaired" ;;
        1) echo_warn "Repair finished, but some constraints were skipped because of existing data (see FAILED lines)" ;;
        *) echo_error "Repair stopped on a database error (see STOPPED line). Re-run it once the cause is fixed; it resumes." ;;
    esac
    echo "Scale the worker back up when ready:"
    echo "  kubectl scale deployment/specify-worker -n $NAMESPACE --replicas=1"
    exit $STATUS
fi

# =============================================================================
# Helper: drop all tables in database (works without DROP DATABASE privilege)
# =============================================================================
drop_all_tables_local() {
    local pod="$1" user="$2" pass="$3" db="$4"
    kubectl exec -n "$NAMESPACE" "$pod" -- \
        mysql -u "$user" -p"$pass" "$db" -e "
            SET FOREIGN_KEY_CHECKS = 0;
            SET SESSION group_concat_max_len = 1000000;
            SET @tables = NULL;
            SELECT GROUP_CONCAT('\`', table_name, '\`') INTO @tables
              FROM information_schema.tables
              WHERE table_schema = '$db';
            SET @tables = IFNULL(CONCAT('DROP TABLE ', @tables), 'SELECT 1');
            PREPARE stmt FROM @tables;
            EXECUTE stmt;
            DEALLOCATE PREPARE stmt;
            SET FOREIGN_KEY_CHECKS = 1;
        " 2>/dev/null || { echo_error "Failed to drop tables"; exit 1; }
}

# A complete mysqldump file ends with this footer; truncated dumps do not.
DUMP_FOOTER="-- Dump completed"

dump_is_complete() {
    tail -c 200 "$1" 2>/dev/null | grep -q -- "$DUMP_FOOTER"
}

# =============================================================================
# DEV (local k3d with in-cluster MariaDB)
# =============================================================================
if [ "$DB_TYPE" = "local" ]; then

    # Safety check: verify we're not accidentally targeting a remote cluster
    CURRENT_CTX=$(kubectl config current-context 2>/dev/null || echo "")
    if [[ "$CURRENT_CTX" == "az-aks-oim03" || "$CURRENT_CTX" == "aks-bcs-prod-01" ]]; then
        echo_error "Safety check failed: kubectl context is '$CURRENT_CTX' (a remote cluster)"
        echo_error "You're trying to run dev commands but your context points at UAT/prod. Aborting."
        exit 1
    fi

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
            mysqldump -u "$DB_USER" -p"$DB_PASS" --single-transaction --no-tablespaces "$DB_NAME" > "$VANILLA_PATH.partial" 2>/dev/null || {
            echo_error "Failed to dump database"; rm -f "$VANILLA_PATH.partial"; exit 1
        }
        dump_is_complete "$VANILLA_PATH.partial" || {
            echo_error "Dump is incomplete (no '$DUMP_FOOTER' footer); left at $VANILLA_PATH.partial"; exit 1
        }
        mv "$VANILLA_PATH.partial" "$VANILLA_PATH"
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
            mysqldump -u "$DB_USER" -p"$DB_PASS" --single-transaction --no-tablespaces "$DB_NAME" > "$BACKUP_FILE" 2>/dev/null || {
            echo_error "Backup failed"; rm -f "$BACKUP_FILE"; exit 1
        }
        dump_is_complete "$BACKUP_FILE" || {
            echo_error "Backup is incomplete (no '$DUMP_FOOTER' footer): $BACKUP_FILE"; exit 1
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
        dump_is_complete "$RESTORE_FILE" || {
            echo_error "$RESTORE_FILE is incomplete (no '$DUMP_FOOTER' footer); refusing to load it"; exit 1
        }
        echo -e "${RED}This will wipe all tables and load vanilla.sql ($( du -h "$RESTORE_FILE" | cut -f1))${NC}"
        read -p "Type 'yes' to continue: " CONFIRM
        [ "$CONFIRM" != "yes" ] && { echo_error "Cancelled"; exit 0; }

        echo_step "Dropping all tables..."
        drop_all_tables_local "$MARIADB_POD" "$DB_USER" "$DB_PASS" "$DB_NAME"
        echo_info "Tables dropped"

        echo_step "Loading vanilla.sql..."
        kubectl exec -i -n "$NAMESPACE" "$MARIADB_POD" -- \
            mysql -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" < "$RESTORE_FILE" 2>/dev/null || {
            echo_error "Load failed; the database is incomplete"; exit 1
        }
        echo_info "Database loaded"

        echo_step "Restarting Specify..."
        kubectl rollout restart deployment/specify deployment/specify-worker -n "$NAMESPACE" > /dev/null 2>&1
        kubectl rollout status deployment/specify -n "$NAMESPACE" --timeout=120s 2>/dev/null || true
        echo_info "Done"
        verify_schema || true
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
        dump_is_complete "$RESTORE_FILE" || {
            echo_error "$RESTORE_FILE is incomplete (no '$DUMP_FOOTER' footer); refusing to load it"; exit 1
        }
        echo -e "${RED}This will wipe all tables and load: $(basename "$RESTORE_FILE") ($(du -h "$RESTORE_FILE" | cut -f1))${NC}"
        read -p "Type 'yes' to continue: " CONFIRM
        [ "$CONFIRM" != "yes" ] && { echo_error "Cancelled"; exit 0; }

        echo_step "Dropping all tables..."
        drop_all_tables_local "$MARIADB_POD" "$DB_USER" "$DB_PASS" "$DB_NAME"
        echo_info "Tables dropped"

        echo_step "Loading: $(basename "$RESTORE_FILE")..."
        kubectl exec -i -n "$NAMESPACE" "$MARIADB_POD" -- \
            mysql -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" < "$RESTORE_FILE" 2>/dev/null || {
            echo_error "Load failed; the database is incomplete"; exit 1
        }
        echo_info "Database loaded"

        echo_step "Restarting Specify..."
        kubectl rollout restart deployment/specify deployment/specify-worker -n "$NAMESPACE" > /dev/null 2>&1
        kubectl rollout status deployment/specify -n "$NAMESPACE" --timeout=120s 2>/dev/null || true
        echo_info "Done"
        verify_schema || true
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

        echo_step "Running Django migrations (creating all tables from scratch)..."
        MIGRATE_LOG="/tmp/specify-migrate-${TIMESTAMP}.log"
        MIGRATE_STATUS=0
        kubectl exec -n "$NAMESPACE" deployment/specify -c specify -- \
            ve/bin/python manage.py migrate --database=master > "$MIGRATE_LOG" 2>&1 || MIGRATE_STATUS=$?
        grep -E "Applying|Operations|Running" "$MIGRATE_LOG" | tail -5 || true
        if [ $MIGRATE_STATUS -ne 0 ]; then
            echo_error "Migrations failed (exit $MIGRATE_STATUS). Full log: $MIGRATE_LOG"
            grep -E "Error|error" "$MIGRATE_LOG" | grep -v WARNING | tail -3 || true
            exit 1
        fi
        echo_info "Migrations complete"
        verify_schema || true

        # No restart needed — migrations ran in the existing pod.
        sleep 3

        # Verify setup_tool works
        echo_step "Verifying Guided Setup endpoint..."
        for i in $(seq 1 12); do
            RESULT=$(kubectl exec -n "$NAMESPACE" deployment/specify -- python -c "
import urllib.request
try:
    r = urllib.request.urlopen('http://localhost:8000/setup_tool/setup_progress/')
    print('OK')
except:
    print('WAIT')
" 2>/dev/null)
            [ "$RESULT" = "OK" ] && break
            sleep 5
        done

        NUKE_END=$(date +%s)
        NUKE_TOTAL=$(( NUKE_END - NUKE_START ))
        if [ "$RESULT" = "OK" ]; then
            echo_info "Done! Guided Setup ready (${NUKE_TOTAL}s total)"
        else
            echo_warn "Done (${NUKE_TOTAL}s) but setup endpoint not responding yet — wait a moment and refresh"
        fi
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
        }" > /dev/null 2>&1 || {
        echo_error "Could not start task pod $name (check permissions to create pods in $NAMESPACE)"
        exit 1
    }
}

# Waits for a task pod to finish. Returns 0 if it succeeded, 1 if it failed and
# 2 if it is still running after <timeout_seconds>.
wait_for_pod() {
    local name="$1" timeout="${2:-60}" waited=0
    while [ $waited -lt "$timeout" ]; do
        STATUS=$(kubectl get pod "$name" -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || echo "Pending")
        [ "$STATUS" = "Succeeded" ] && return 0
        [ "$STATUS" = "Failed" ] && return 1
        sleep 5
        waited=$((waited + 5))
        [ $((waited % 60)) -eq 0 ] && echo "  ... still running ($((waited / 60)) min)"
    done
    return 2
}

cleanup_pod() {
    kubectl delete pod "$1" -n "$NAMESPACE" --ignore-not-found > /dev/null 2>&1
}

# Waits for a long-running dump/restore pod. A pod that is still running is never
# deleted: deleting it would leave a truncated dump or a half-loaded database.
wait_for_task_pod() {
    local name="$1" timeout="$2" what="$3" rc=0
    wait_for_pod "$name" "$timeout" || rc=$?
    if [ $rc -eq 2 ]; then
        echo_error "$what is still running after $((timeout / 60)) minutes. The pod has been left running."
        echo "  Follow it with:  kubectl logs -f $name -n $NAMESPACE"
        echo "  Remove it after it finishes:  kubectl delete pod $name -n $NAMESPACE"
        exit 1
    fi
    if [ $rc -ne 0 ]; then
        echo_error "$what failed:"
        kubectl logs "$name" -n "$NAMESPACE" 2>/dev/null | tail -5
        cleanup_pod "$name"
        exit 1
    fi
}

# Drops every table through the specify container (Azure MySQL does not allow
# DROP DATABASE) and checks that nothing is left.
drop_all_tables_azure() {
    echo_step "Dropping all tables..."
    local output summary
    output=$(kubectl exec -n "$NAMESPACE" deployment/specify -c specify -- python -c "
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
cursor.execute('SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = DATABASE()')
print(f'DROPPED {len(tables)} REMAINING {cursor.fetchone()[0]}')
" 2>&1) || true
    summary=$(echo "$output" | grep "^DROPPED" | tail -1) || true
    if [ -z "$summary" ] || ! echo "$summary" | grep -q "REMAINING 0$"; then
        echo_error "Dropping tables failed:"
        echo "$output" | grep -v WARNING | tail -5
        exit 1
    fi
    echo_info "Tables dropped ($(echo "$summary" | awk '{print $2}'))"
}

# Long-running task timeouts (seconds)
DUMP_TIMEOUT=7200
RESTORE_TIMEOUT=7200

# Shell snippet (run in a share pod) that succeeds only if the dump has the footer.
footer_check() {
    echo "tail -c 200 /share/$1 | grep -q 'Dump completed'"
}

# --- LIST FILES ---
if [ "$MODE" = "list_files" ]; then
    echo_step "Listing .sql files on file share ($SHARE_NAME)..."
    POD="list-${TIMESTAMP}"
    run_share_pod "$POD" "ls -lh /share/*.sql 2>/dev/null || echo '  (none found)'" "false"
    wait_for_pod "$POD" 120 || true
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
    PARTIAL="$VANILLA_FILENAME.partial"
    run_share_pod "$POD" "mysqldump --host=$DB_HOST --port=$DB_PORT --user=\$(cat /secrets/MASTER_NAME) --single-transaction --quick --no-tablespaces $DB_NAME > /share/$PARTIAL && $(footer_check "$PARTIAL") && mv /share/$PARTIAL /share/$VANILLA_FILENAME && echo DONE && ls -lh /share/$VANILLA_FILENAME"
    wait_for_task_pod "$POD" "$DUMP_TIMEOUT" "Dump"
    kubectl logs "$POD" -n "$NAMESPACE" 2>/dev/null | tail -1
    cleanup_pod "$POD"
    echo_info "vanilla.sql saved to file share (verified complete)"
    echo -e "${GREEN}Running with --load_vanilla will now restore to this state.${NC}"
    echo ""
    exit 0
fi

# --- SAVE (backup) ---
if [ "$MODE" = "save" ]; then
    BACKUP_FILE="specify_${DB_NAME}_backup_${FILE_TIMESTAMP}.sql"
    echo_step "Creating backup: $BACKUP_FILE"
    POD="backup-${TIMESTAMP}"
    PARTIAL="$BACKUP_FILE.partial"
    run_share_pod "$POD" "mysqldump --host=$DB_HOST --port=$DB_PORT --user=\$(cat /secrets/MASTER_NAME) --single-transaction --quick --no-tablespaces $DB_NAME > /share/$PARTIAL && $(footer_check "$PARTIAL") && mv /share/$PARTIAL /share/$BACKUP_FILE && echo DONE && ls -lh /share/$BACKUP_FILE"
    echo "  Waiting for dump (large databases take several minutes)..."
    wait_for_task_pod "$POD" "$DUMP_TIMEOUT" "Backup"
    kubectl logs "$POD" -n "$NAMESPACE" 2>/dev/null | tail -1
    cleanup_pod "$POD"
    echo_info "Backup saved: $BACKUP_FILE (on $SHARE_NAME, verified complete)"
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
    # Newest backup that has the mysqldump footer (truncated dumps are skipped)
    run_share_pod "$POD" "for f in \$(ls -t /share/specify_*.sql 2>/dev/null); do tail -c 200 \$f | grep -q 'Dump completed' && { basename \$f; break; }; done" "false"
    wait_for_pod "$POD" 120 || true
    RESTORE_FILE=$(kubectl logs "$POD" -n "$NAMESPACE" 2>/dev/null | tr -d '\n')
    cleanup_pod "$POD"
    if [ -z "$RESTORE_FILE" ]; then
        echo_error "No complete backup files found on file share"
        exit 1
    fi
    echo_info "Most recent: $RESTORE_FILE"
fi

# --- Verify file exists on share (for load, load_vanilla, load_last) ---
if [ "$MODE" = "load" ] || [ "$MODE" = "load_vanilla" ] || [ "$MODE" = "load_last" ]; then
    echo_step "Verifying file: $RESTORE_FILE"
    POD="verify-${TIMESTAMP}"
    run_share_pod "$POD" "if [ ! -f /share/$RESTORE_FILE ]; then echo MISSING; elif $(footer_check "$RESTORE_FILE"); then echo EXISTS; else echo INCOMPLETE; fi" "false"
    wait_for_pod "$POD" 120 || true
    RESULT=$(kubectl logs "$POD" -n "$NAMESPACE" 2>/dev/null | tr -d '\n')
    cleanup_pod "$POD"

    if [ "$RESULT" = "INCOMPLETE" ]; then
        echo_error "$RESTORE_FILE is truncated (no '$DUMP_FOOTER' footer); refusing to load it"
        exit 1
    fi
    if [ "$RESULT" != "EXISTS" ]; then
        echo_error "File not found on share: $RESTORE_FILE"
        if [ "$MODE" = "load_vanilla" ]; then
            echo "Create it first: $0 $ENV --nuke, complete Guided Setup, then $0 $ENV --save_vanilla"
        fi
        echo ""
        echo "Available files:"
        POD="list-avail-${TIMESTAMP}"
        run_share_pod "$POD" "ls -lh /share/*.sql 2>/dev/null || echo '  (none)'" "false"
        wait_for_pod "$POD" 120 || true
        kubectl logs "$POD" -n "$NAMESPACE" 2>/dev/null
        cleanup_pod "$POD"
        exit 1
    fi
    echo_info "File found"

    # Confirmation
    echo -e "${RED}This will wipe all tables and load: $RESTORE_FILE${NC}"
    read -p "Type 'yes' to continue: " CONFIRM
    [ "$CONFIRM" != "yes" ] && { echo_error "Cancelled"; exit 0; }

    drop_all_tables_azure

    # Load file
    echo_step "Loading: $RESTORE_FILE"
    POD="restore-${TIMESTAMP}"
    run_share_pod "$POD" "mysql --host=$DB_HOST --port=$DB_PORT --user=\$(cat /secrets/MASTER_NAME) $DB_NAME < /share/$RESTORE_FILE && echo DONE" "false"
    echo "  Waiting for restore (large databases take several minutes)..."
    wait_for_task_pod "$POD" "$RESTORE_TIMEOUT" "Restore"
    cleanup_pod "$POD"
    echo_info "Database loaded"

    # Restart
    echo_step "Restarting Specify..."
    kubectl rollout restart deployment/specify deployment/specify-worker -n "$NAMESPACE" > /dev/null 2>&1
    kubectl rollout status deployment/specify -n "$NAMESPACE" --timeout=600s 2>/dev/null || true
    echo_info "Done"
    verify_schema || true
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
    echo -e "${RED}(Takes ~3-5 min — drops all tables and runs Django migrations from scratch)${NC}"
    read -p "Type 'yes' to continue: " CONFIRM
    [ "$CONFIRM" != "yes" ] && { echo_error "Cancelled"; exit 0; }

    NUKE_START=$(date +%s)

    drop_all_tables_azure

    echo_step "Running Django migrations (creating all tables from scratch)..."
    MIGRATE_LOG="/tmp/specify-migrate-${ENV}-${TIMESTAMP}.log"
    MIGRATE_STATUS=0
    kubectl exec -n "$NAMESPACE" deployment/specify -c specify -- \
        ve/bin/python manage.py migrate --database=master > "$MIGRATE_LOG" 2>&1 || MIGRATE_STATUS=$?
    grep -E "Applying|Operations|Running" "$MIGRATE_LOG" | tail -5 || true
    if [ $MIGRATE_STATUS -ne 0 ]; then
        echo_error "Migrations failed (exit $MIGRATE_STATUS). Full log: $MIGRATE_LOG"
        grep -E "Error|error" "$MIGRATE_LOG" | grep -v WARNING | tail -3 || true
        if grep -q "1071" "$MIGRATE_LOG"; then
            echo ""
            echo_warn "This is the Specify 7.12 / MySQL 8 index-length bug (https://github.com/specify/specify7/pull/8813)."
            echo_warn "Until the deployed image includes the fix, complete the setup with:"
            echo "    1. kubectl rollout restart deployment/specify -n $NAMESPACE  (finishes the remaining migrations)"
            echo "    2. kubectl scale deployment/specify-worker -n $NAMESPACE --replicas=0"
            echo "    3. $0 $ENV --repair_schema  (adds the missing indexes and constraints)"
            echo "    4. kubectl scale deployment/specify-worker -n $NAMESPACE --replicas=1"
        fi
        exit 1
    fi
    echo_info "Migrations complete"
    verify_schema || true

    # Verify setup_tool works
    sleep 3
    echo_step "Verifying Guided Setup endpoint..."
    for i in $(seq 1 12); do
        RESULT=$(kubectl exec -n "$NAMESPACE" deployment/specify -- python -c "
import urllib.request
try:
    r = urllib.request.urlopen('http://localhost:8000/setup_tool/setup_progress/')
    print('OK')
except:
    print('WAIT')
" 2>/dev/null)
        [ "$RESULT" = "OK" ] && break
        sleep 5
    done

    NUKE_END=$(date +%s)
    NUKE_TOTAL=$(( NUKE_END - NUKE_START ))
    if [ "$RESULT" = "OK" ]; then
        echo_info "Done! Guided Setup ready (${NUKE_TOTAL}s total)"
    else
        echo_warn "Done (${NUKE_TOTAL}s) but setup endpoint not responding yet — wait a moment and refresh"
    fi
    echo ""
    case "$ENV" in
        uat)  echo -e "Access: ${GREEN}https://specify-test.dbca.wa.gov.au/specify/${NC} — Guided Setup wizard" ;;
        prod) echo -e "Access: ${GREEN}https://specify.dbca.wa.gov.au/specify/${NC} — Guided Setup wizard" ;;
    esac
    exit 0
fi

echo_error "Unknown mode: $MODE"
exit 1

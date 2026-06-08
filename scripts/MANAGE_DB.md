# Database Management Script

Unified tool for managing the Specify database across all environments.

**Script:** `scripts/manage-db.sh`

## Quick Reference

```bash
./scripts/manage-db.sh dev --nuke           # Empty DB → Guided Setup wizard (~5 min)
./scripts/manage-db.sh dev --save_vanilla   # Save current state as vanilla.sql
./scripts/manage-db.sh dev --load_vanilla   # Reset to vanilla.sql (~30s)
./scripts/manage-db.sh dev --save           # Timestamped backup to /tmp
./scripts/manage-db.sh dev --load           # List available .sql files
./scripts/manage-db.sh dev --load dump.sql  # Load specific file (~30s)
./scripts/manage-db.sh uat --load_last      # Load most recent backup (UAT/prod)
```

## Actions

| Action | Description |
|--------|-------------|
| `--nuke` | Drops all tables, recreates schema via migrations. Guided Setup wizard appears |
| `--save_vanilla` | Dumps current DB as `vanilla.sql` (the reset point) |
| `--load_vanilla` | Loads `vanilla.sql` — resets to clean configured state |
| `--save` | Creates a timestamped backup (`/tmp` on dev, file share on UAT/prod) |
| `--load <file>` | Loads a specific `.sql` file after dropping all tables |
| `--load` _(no file)_ | Lists available `.sql` files |
| `--load_last` | Loads the most recent `specify_*.sql` backup (UAT/prod only) |

Running with no action shows usage and available options.

## Environments

| Environment | Context | Database | Backups/Vanilla Location |
|-------------|---------|----------|--------------------------|
| `dev` | `specify-dev` | In-cluster MariaDB | `/tmp` (backups), `kustomize/base/vanilla.sql` |
| `uat` | `az-aks-oim03` | Azure MySQL | Azure File Share (`specify-assets-uat`) |
| `prod` | `aks-bcs-prod-01` | Azure MySQL | Azure File Share (`specify-assets-prod`) |

## Typical Workflow

1. **First time setup:** `./scripts/manage-db.sh uat --nuke` → Guided Setup wizard appears
2. **Configure:** Complete the wizard (institution, trees, collection, admin user)
3. **Save baseline:** `./scripts/manage-db.sh uat --save_vanilla` → saves as `vanilla.sql`
4. **Reset anytime:** `./scripts/manage-db.sh uat --load_vanilla` → back to clean state

## Why No DROP DATABASE

On UAT and prod, the database user does not have `CREATE DATABASE` or `DROP DATABASE` privileges. To keep behaviour consistent across all environments, the script drops all tables within the database using:

```sql
SET FOREIGN_KEY_CHECKS=0;
-- dynamically generates DROP TABLE for every table in the schema
SET FOREIGN_KEY_CHECKS=1;
```

This works with limited Azure MySQL permissions and behaves identically on dev.

## Why `--nuke` Takes ~5 Minutes

Because we can't DROP/CREATE the database, Specify's Docker entrypoint always sees "existing database" and incorrectly fakes the initial Django migration. The script works around this by:

1. Dropping all tables
2. Letting the entrypoint run (and mess up the state)
3. Dropping all tables again (removing the partial schema)
4. Manually running `base_specify_migration` + `migrate` correctly
5. Restarting for a clean state

The `specify.0001_initial` migration creates ~220 tables with complex foreign keys — that's what takes the time.

## The `vanilla.sql` File

The "known good starting point" — a database dump taken after completing the Guided Setup wizard. Contains:

- Institution, division, discipline, and collection config
- A single admin user account
- Default trees (storage, geography, taxon)
- No specimen data or extra user accounts

**Location:**
- Dev: `kustomize/base/vanilla.sql`
- UAT/Prod: `vanilla.sql` on the Azure File Share

## Timing

| Action | Time |
|--------|------|
| `--nuke` | ~5 minutes |
| `--load_vanilla` / `--load` | ~30 seconds |
| `--save` / `--save_vanilla` | ~15 seconds |

## Troubleshooting

**"Action required"** — you need to specify what to do (e.g. `--nuke`, `--load_vanilla`)

**"vanilla.sql not found"** — run `--nuke`, complete Guided Setup, then `--save_vanilla`

**Guided Setup shows spinner after `--nuke`** — migrations still running, wait ~5 min. Check: `kubectl logs -n herbarium-specify deployment/specify --tail=5`

**"MariaDB pod not found"** — deploy first: `kubectl apply -k kustomize/overlays/dev`

**"Failed to switch context"** — dev: `k3d cluster start specify-test` / UAT: merge kubeconfig (see `2_UAT_README.md`)

## Specify 6 Removal

Specify 6 is no longer required. Changes made:
- Removed `specify6-deployment.yaml` (init job)
- Removed `specify-storage` PVC (was for Specify 6 config files)
- Removed `/opt/Specify` volume mounts
- `SPECIFY_CONFIG_DIR` points to `/opt/specify7/config` (built into Docker image)
- Fresh databases use the Guided Setup wizard instead of Specify 6 Wizard

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
./scripts/manage-db.sh uat --load_last      # Load most recent complete backup (UAT/prod)
./scripts/manage-db.sh uat --check_schema   # Report missing indexes/constraints (read-only)
./scripts/manage-db.sh uat --repair_schema  # Add missing indexes/constraints
```

## Actions

| Action | Description |
|--------|-------------|
| `--nuke` | Drops all tables, recreates the schema via migrations. Guided Setup wizard appears |
| `--save_vanilla` | Dumps the current DB as `vanilla.sql` (the reset point) |
| `--load_vanilla` | Loads `vanilla.sql`, resetting to the clean configured state |
| `--save` | Creates a timestamped backup (`/tmp` on dev, file share on UAT/prod) |
| `--load <file>` | Loads a specific `.sql` file after dropping all tables |
| `--load` _(no file)_ | Lists available `.sql` files |
| `--load_last` | Loads the most recent complete `specify_*.sql` backup (UAT/prod only) |
| `--check_schema` | Reports indexes, unique constraints and foreign keys that Specify declares but the database lacks. Read-only |
| `--repair_schema` | Creates the missing indexes, unique constraints and foreign keys. Requires `specify-worker` to be scaled to 0 |
| `--site_indexes` | Option for `--check_schema` / `--repair_schema`: also include the site-specific WorkBench indexes |

Running with no action shows usage and available options.

## Environments

| Environment | Context | Database | Backups/Vanilla Location |
|-------------|---------|----------|--------------------------|
| `dev` | `specify-dev` | In-cluster MariaDB | `/tmp` (backups), `kustomize/base/vanilla.sql` |
| `uat` | `az-aks-oim03` | Azure MySQL | Azure File Share (`specify-assets-uat`) |
| `prod` | `aks-bcs-prod-01` | Azure MySQL | Azure File Share (`specify-assets-prod`) |

## Typical Workflow

1. **First time setup:** `./scripts/manage-db.sh uat --nuke` → Guided Setup wizard appears (see the known issue below for Azure MySQL)
2. **Configure:** Complete the wizard (institution, trees, collection, admin user)
3. **Check the schema:** `./scripts/manage-db.sh uat --check_schema` should report `missing=0`
4. **Save baseline:** `./scripts/manage-db.sh uat --save_vanilla` → saves as `vanilla.sql`
5. **Reset anytime:** `./scripts/manage-db.sh uat --load_vanilla` → back to clean state

## Backups and Restores

- Dumps are written to `<name>.partial` first and only renamed to `<name>` once the file ends with mysqldump's `-- Dump completed` footer. A `.partial` file left on the share is an incomplete dump and must not be loaded.
- Loads refuse any file without the footer, and `--load_last` picks the newest backup that has it.
- Dump and restore pods may run for up to 2 hours. If they take longer, the script stops waiting but leaves the pod running, and prints the commands to follow and remove it. Deleting a running pod would truncate the dump or leave a half-loaded database.

Backups taken before these checks were added may be truncated. Check a file with:

```bash
kubectl exec -n herbarium-specify deployment/asset-server -- \
  sh -c 'tail -c 200 /home/specify/attachments/<file>.sql | grep -c "Dump completed"'   # 1 = complete
```

## Known Issue: Specify 7.12 on MySQL 8

Specify 7.12 cannot run its first migration (`specify.0001_initial`) on MySQL 8, which UAT and prod use. It fails with error 1071 ("Specified key was too long") on the locality name index. MariaDB, used on dev, is not affected. The upstream fix is [specify/specify7#8813](https://github.com/specify/specify7/pull/8813).

If the failure is not noticed, Specify's Docker entrypoint marks the migration as applied on the next restart. The database then works but lacks most of its indexes, unique constraints and foreign keys, so WorkBench uploads and searches become very slow and get slower as the tables grow. This is what happened to UAT in May 2026.

The script now stops when migrations fail and checks the schema after `--nuke` and after every load. Until the deployed image includes the fix, finish a `--nuke` on UAT/prod with the steps it prints:

1. `kubectl rollout restart deployment/specify -n herbarium-specify` (completes the remaining migrations)
2. `kubectl scale deployment/specify-worker -n herbarium-specify --replicas=0`
3. `./scripts/manage-db.sh uat --repair_schema`
4. `kubectl scale deployment/specify-worker -n herbarium-specify --replicas=1`

`--repair_schema` runs `scripts/specify_schema_repair.py` inside the specify container. It applies the same repair as the upstream fix, and is safe to run on a healthy database (it finds nothing to do). Schema changes wait on, and block, a WorkBench upload in progress, which is why the worker must be scaled to 0 first. Take a backup with `--save` beforehand.

### Site-specific indexes

The collection object WorkBench upload plans match collecting events on `Text8`, which Specify does not index. `--site_indexes` adds `CEDisciplineText8IDX` on `collectingevent (DisciplineID, Text8(32))`. In testing on a copy of UAT data this took collection object uploads from about 10 to about 100 rows per second.

## Why No DROP DATABASE

On UAT and prod, the database user does not have `CREATE DATABASE` or `DROP DATABASE` privileges. To keep behaviour consistent across all environments, the script drops all tables within the database using:

```sql
SET FOREIGN_KEY_CHECKS=0;
-- dynamically generates DROP TABLE for every table in the schema
SET FOREIGN_KEY_CHECKS=1;
```

This works with limited Azure MySQL permissions and behaves identically on dev. The script confirms that no tables remain before loading or migrating.

## The `vanilla.sql` File

The "known good starting point": a database dump taken after completing the Guided Setup wizard. Contains:

- Institution, division, discipline, and collection config
- A single admin user account
- Default trees (storage, geography, taxon)
- No specimen data or extra user accounts

**Location:**
- Dev: `kustomize/base/vanilla.sql`
- UAT/Prod: `vanilla.sql` on the Azure File Share

The UAT `vanilla.sql` saved on 22 May 2026 has the incomplete schema described above. After loading it, run `--repair_schema`, or re-save it from a repaired database.

## Timing

| Action | Time |
|--------|------|
| `--nuke` | ~5 minutes |
| `--load_vanilla` | ~30 seconds |
| `--load` / `--save` of a full UAT database (~3 GB) | several minutes to tens of minutes |
| `--repair_schema` on a full UAT database | about 1–2 minutes of database work |

## Troubleshooting

**"Action required"**: specify what to do (e.g. `--nuke`, `--load_vanilla`)

**"vanilla.sql not found"**: run `--nuke`, complete Guided Setup, then `--save_vanilla`

**"Migrations failed ... 1071"**: the Specify 7.12 / MySQL 8 issue above; follow the printed steps

**"is truncated (no '-- Dump completed' footer)"**: the backup is incomplete; pick another file

**"specify-worker is running"** (from `--repair_schema`): make sure no upload is in progress, then scale the worker to 0

**Guided Setup shows spinner after `--nuke`**: migrations still running, wait ~5 min. Check: `kubectl logs -n herbarium-specify deployment/specify --tail=5`

**"MariaDB pod not found"**: deploy first with `kubectl apply -k kustomize/overlays/dev`

**"Failed to switch context"**: dev: `k3d cluster start specify-dev` / UAT: merge kubeconfig (see `2_UAT_README.md`)

## Specify 6 Removal

Specify 6 is no longer required. Changes made:
- Removed `specify6-deployment.yaml` (init job)
- Removed `specify-storage` PVC (was for Specify 6 config files)
- Removed `/opt/Specify` volume mounts
- `SPECIFY_CONFIG_DIR` points to `/opt/specify7/config` (built into Docker image)
- Fresh databases use the Guided Setup wizard instead of Specify 6 Wizard

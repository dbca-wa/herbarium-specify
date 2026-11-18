"""
Check or repair the Specify database schema.

Specify 7 (up to and including 7.12.x) cannot run its first migration on MySQL 8:
specify.0001_initial fails with error 1071 ("Specified key was too long") on
localityNameIDX, and the docker entrypoint then records the migration as applied.
The database is left without most of its indexes, unique constraints and foreign
keys, which makes WorkBench uploads and searches very slow. The upstream fix is
https://github.com/specify/specify7/pull/8813; this script applies the same repair
to a running instance.

Run inside the specify container through manage.py shell (see scripts/manage-db.sh
--check_schema / --repair_schema). Options are passed as environment variables:

    SCHEMA_MODE=check|repair    check only reports; repair creates what is missing
    SITE_INDEXES=1              also create the site-specific indexes listed below
"""
import json
import os
import sys
import time

from django.apps import apps
from django.db import DatabaseError, connection

MODE = os.environ.get("SCHEMA_MODE", "check")
SITE_INDEXES = os.environ.get("SITE_INDEXES") == "1"

SIGNATURE_TABLE = "locality"
SIGNATURE_INDEX = "localityNameIDX"

# Unique constraints still declared on the models but deliberately dropped by
# businessrules.0003_catnum_constraint (replaced by a configurable uniqueness rule).
DROPPED_UNIQUE_CONSTRAINTS = {("collectionobject", ("collectionid", "catalognumber"))}

# Indexes on varchar(1024+) columns need a prefix to fit InnoDB's 3072-byte key limit.
PREFIX_INDEX_SQL = {
    ("locality", "localityNameIDX"): "CREATE INDEX `localityNameIDX` ON `locality` (`LocalityName`(768))",
    ("container", "ContainerNameIDX"): "CREATE INDEX `ContainerNameIDX` ON `container` (`Name`(768))",
    ("agentidentifier", "agentidentifier_identifier_idx"):
        "CREATE INDEX `agentidentifier_identifier_idx` ON `agentidentifier` (`Identifier`(768))",
}

# Indexes that Specify does not declare but this site's WorkBench upload plans rely on.
# The collection object plans match collecting events on Text8 (a longtext field).
SITE_INDEX_SQL = {
    ("collectingevent", "CEDisciplineText8IDX"):
        "CREATE INDEX `CEDisciplineText8IDX` ON `collectingevent` (`DisciplineID`, `Text8`(32))",
}


def say(message):
    print(message, flush=True)


def constraints(table):
    with connection.cursor() as cursor:
        return connection.introspection.get_constraints(cursor, table)


def lower(columns):
    return [c.lower() for c in columns]


def has_index(existing, columns, name=None):
    if name is not None and name in existing:
        return True
    wanted = lower(columns)
    return any(
        lower(c["columns"]) == wanted
        for c in existing.values()
        if (c["index"] or c["foreign_key"]) and not (c["unique"] or c["primary_key"])
    )


def has_unique(existing, columns):
    wanted = sorted(lower(columns))
    return any(c["unique"] and sorted(lower(c["columns"])) == wanted for c in existing.values())


def has_foreign_key(existing, column):
    return any(c["foreign_key"] and lower(c["columns"]) == [column.lower()] for c in existing.values())


def planned_statements(editor):
    tables = set(connection.introspection.table_names())
    models = [
        m for m in apps.get_app_config("specify").get_models()
        if m._meta.managed and not m._meta.proxy and m._meta.db_table in tables
    ]
    indexes, uniques, foreign_keys = [], [], []
    for model in models:
        meta = model._meta
        table = meta.db_table
        existing = constraints(table)
        for field in meta.local_fields:
            if field.db_index and not field.unique and not field.remote_field and not has_index(existing, [field.column]):
                for sql in editor._field_indexes_sql(model, field):
                    indexes.append((f"index {table}({field.column})", str(sql)))
        for index in meta.indexes:
            columns = [meta.get_field(name.lstrip("-")).column for name in index.fields]
            if not has_index(existing, columns, index.name):
                sql = PREFIX_INDEX_SQL.get((table, index.name)) or str(index.create_sql(model, editor))
                indexes.append((f"index {index.name} on {table}", sql))
        for field_names in meta.unique_together:
            fields = [meta.get_field(name) for name in field_names]
            if (table, tuple(lower(f.column for f in fields))) in DROPPED_UNIQUE_CONSTRAINTS:
                continue
            if not has_unique(existing, [f.column for f in fields]):
                uniques.append((f"unique {table}{tuple(f.column for f in fields)}",
                                str(editor._create_unique_sql(model, fields))))
        for field in meta.local_fields:
            if (field.remote_field and field.db_constraint
                    and field.remote_field.model._meta.db_table in tables
                    and not has_foreign_key(existing, field.column)):
                foreign_keys.append((f"foreign key {table}.{field.column}",
                                     str(editor._create_fk_sql(model, field, "_fk_%(to_table)s_%(to_column)s"))))
    site = []
    if SITE_INDEXES:
        for (table, name), sql in SITE_INDEX_SQL.items():
            if table in tables and name not in constraints(table):
                site.append((f"site index {name} on {table}", sql))
    return indexes + uniques + foreign_keys + site


def main():
    if SIGNATURE_TABLE not in connection.introspection.table_names():
        say("SCHEMA empty: no Specify tables in this database")
        return 0
    affected = SIGNATURE_INDEX not in constraints(SIGNATURE_TABLE)
    with connection.schema_editor(atomic=False) as editor:
        plan = planned_statements(editor)
        counts = {}
        for description, _ in plan:
            kind = "foreign key" if description.startswith("foreign") else description.rsplit(" on ", 1)[0].split(" ")[0]
            kind = "site index" if description.startswith("site") else kind
            counts[kind] = counts.get(kind, 0) + 1
        say("SCHEMA affected_by_0001_failure=%s missing=%d %s" % (affected, len(plan), json.dumps(counts)))
        if MODE != "repair":
            for description, _ in plan[:15]:
                say("  missing: " + description)
            if len(plan) > 15:
                say("  ... and %d more" % (len(plan) - 15))
            return 0
        applied, failed = 0, []
        started = time.time()
        for n, (description, sql) in enumerate(plan, 1):
            t = time.time()
            try:
                editor.execute(sql)
                applied += 1
            except DatabaseError as e:
                failed.append((description, str(e)))
            if n % 25 == 0 or n == len(plan) or time.time() - t > 10:
                say("  [%d/%d] %s (%.1fs)" % (n, len(plan), description, time.time() - t))
        say("SCHEMA repair applied=%d failed=%d seconds=%.0f" % (applied, len(failed), time.time() - started))
        for description, error in failed:
            say("  FAILED " + description + ": " + error[:300])
        return 1 if failed else 0


status = main()
if status:
    sys.exit(status)

-- This file contains functions that aid in inserting data into a hypertable.

-- Creates a temporary table with the same structure as a given hypertable.
-- This can be used for bulk inserts.
-- TODO(rrk) - This is currently only used by unit tests, rewrite unit tests so
-- we can remove it.
CREATE OR REPLACE FUNCTION create_temp_copy_table(
    hypertable_name NAME,
    table_name      TEXT
)
    RETURNS TEXT LANGUAGE PLPGSQL VOLATILE AS
$BODY$
DECLARE
    root_schema NAME;
    root_table  NAME;
BEGIN
    EXECUTE format(
        $$
            SELECT h.root_schema_name, h.root_table_name
            FROM hypertable h
            WHERE h.name = %L
            LIMIT 1
        $$, hypertable_name)
    INTO root_schema, root_table;
    EXECUTE format(
        $$
            CREATE TEMP TABLE "%s" ON COMMIT DROP AS (
                SELECT * FROM %I.%I WHERE FALSE
            )
        $$, table_name, root_schema, root_table);

    RETURN table_name;
END
$BODY$;

-- Get a comma-separated list of fields in a hypertable.
CREATE OR REPLACE FUNCTION _sysinternal.get_field_list(
    hypertable_name NAME
)
    RETURNS TEXT LANGUAGE SQL STABLE AS
$BODY$
SELECT array_to_string(get_quoted_field_names(hypertable_name), ', ')
$BODY$;

-- Gets the partition ID of a given epoch and data row.
--
-- epoch - The epoch whose partition ID we want
-- copy_record - Record/row from a table
-- copy_table_name - Name of the relation to cast the record to.
CREATE OR REPLACE FUNCTION _sysinternal.get_partition_for_epoch_row(
    epoch           partition_epoch,
    copy_record     anyelement,
    copy_table_name TEXT
)
    RETURNS partition LANGUAGE PLPGSQL STABLE AS
$BODY$
DECLARE
    partition_row partition;
BEGIN
    EXECUTE format(
        $$
            SELECT  p.*
            FROM partition p
            WHERE p.epoch_id = %L AND
            %s((SELECT row.%I FROM (SELECT (%L::%s).*) as row), %L)
            BETWEEN p.keyspace_start AND p.keyspace_end
        $$,
            epoch.id, epoch.partitioning_func,
            epoch.partitioning_field,
            copy_record, copy_table_name, epoch.partitioning_mod)
    INTO STRICT partition_row;

    RETURN partition_row;
END
$BODY$;

-- Gets the value of the time field from a given row.
--
-- field_name - Name of time field/column to fetch
-- field_type - Type of the time record
-- copy_record - Record/row from a table
-- copy_table_name - Name of the relation to cast the record to
CREATE OR REPLACE FUNCTION _sysinternal.get_time_field_from_record(
    field_name      NAME,
    field_type      REGTYPE,
    copy_record     anyelement,
    copy_table_name TEXT
)
    RETURNS bigint LANGUAGE PLPGSQL STABLE AS
$BODY$
DECLARE
    t bigint;
BEGIN
    EXECUTE format(
        $$
            SELECT %s FROM (SELECT (%L::%s).*) as row LIMIT 1
        $$, _sysinternal.extract_time_sql(format('row.%I', field_name), field_type), copy_record, copy_table_name)
    INTO STRICT t;

    RETURN t;
END
$BODY$;

-- Inserts rows from a (temporary) table into correct hypertable child tables.
--
-- In typical use case, the copy_table_oid is the OID of a hypertable's main
-- table. This allows users to use normal SQL INSERT calls on the main table,
-- and a trigger that executes after the statement will call this function to
-- place the data appropriately.
--
-- hypertable_name - Name of the hypertable the data belongs to
-- copy_table_oid -- OID of the table to fetch rows from
CREATE OR REPLACE FUNCTION insert_data(
    hypertable_name NAME,
    copy_table_oid  REGCLASS
)
    RETURNS VOID LANGUAGE PLPGSQL VOLATILE AS
$BODY$
DECLARE
    crn_record            RECORD;
    distinct_table_oid    REGCLASS;
    time_point            BIGINT;
    time_field_name_point NAME;
    time_field_type_point REGTYPE;
    partition_id          INT;
    distinct_field        TEXT;
    distinct_clauses      TEXT;
    distinct_clause_idx   INT;
BEGIN
    time_point := 1;
    EXECUTE format(
        $$
            SELECT _sysinternal.get_time_field_from_record(h.time_field_name, h.time_field_type, ct, '%1$s'), h.time_field_name, h.time_field_type, p.id
            FROM ONLY %1$s ct
            LEFT JOIN hypertable h ON (h.NAME = %2$L)
            LEFT JOIN partition_epoch pe ON (
              pe.hypertable_name = %2$L AND
              (pe.start_time <= (SELECT _sysinternal.get_time_field_from_record(h.time_field_name, h.time_field_type, ct, '%1$s'))::bigint 
                OR pe.start_time IS NULL) AND
              (pe.end_time   >= (SELECT _sysinternal.get_time_field_from_record(h.time_field_name, h.time_field_type, ct, '%1$s'))::bigint 
                OR pe.end_time IS NULL)
            )
            LEFT JOIN _sysinternal.get_partition_for_epoch_row(pe, ct, '%1$s') AS p ON(true)
            LIMIT 1
        $$, copy_table_oid, hypertable_name)
    INTO STRICT time_point, time_field_name_point, time_field_type_point, partition_id;
    IF time_point IS NOT NULL AND partition_id IS NULL THEN
        RAISE EXCEPTION 'Should never happen: could not find partition for insert'
        USING ERRCODE = 'IO501';
    END IF;

    WHILE time_point IS NOT NULL LOOP
        FOR crn_record IN
        SELECT
            crn.database_name,
            crn.schema_name,
            crn.table_name,
            c.start_time,
            c.end_time,
            pr.hypertable_name,
            pr.replica_id
        FROM get_or_create_chunk(partition_id, time_point) c
        INNER JOIN chunk_replica_node crn ON (crn.chunk_id = c.id)
        INNER JOIN partition_replica pr ON (pr.id = crn.partition_replica_id)
        LOOP
            distinct_clauses := '';
            distinct_clause_idx := 0;

            SELECT *
            INTO distinct_table_oid
            FROM get_distinct_table_oid(hypertable_name, crn_record.replica_id, crn_record.database_name);

            FOR distinct_field IN
            SELECT f.name
            FROM field as f
            WHERE f.is_distinct = TRUE AND f.hypertable_name = insert_data.hypertable_name
            ORDER BY f.name
            LOOP
                distinct_clauses := distinct_clauses || ',' || format(
                    $$
                    insert_distinct_%3$s AS (
                         INSERT INTO  %1$s as distinct_table
                             SELECT DISTINCT %2$L, selected.%2$I as value
                             FROM selected
                             ORDER BY value
                             ON CONFLICT
                                 DO NOTHING
                     )
                     $$, distinct_table_oid, distinct_field, distinct_clause_idx);
                distinct_clause_idx := distinct_clause_idx + 1;
            END LOOP;

            PERFORM set_config('io.ignore_delete_in_trigger', 'true', true);
            EXECUTE format(
                $$
              WITH selected AS
              (
                  DELETE FROM ONLY %2$s
                  WHERE (%7$I >= %3$s OR %3$s IS NULL) and (%7$I <= %4$s OR %4$s IS NULL)
                  RETURNING *
              )%5$s
              INSERT INTO %1$s (%6$s) SELECT %6$s FROM selected;
          $$,
                format('%I.%I', crn_record.schema_name, crn_record.table_name) :: REGCLASS,
                copy_table_oid, 
                _sysinternal.time_literal_sql(crn_record.start_time, time_field_type_point),
                _sysinternal.time_literal_sql(crn_record.end_time, time_field_type_point),
                distinct_clauses,
                _sysinternal.get_field_list(hypertable_name),
                time_field_name_point);
        END LOOP;

        EXECUTE format(
            $$
                SELECT _sysinternal.get_time_field_from_record(h.time_field_name, h.time_field_type, ct, '%1$s'), h.time_field_name, h.time_field_type, p.id
                FROM ONLY %1$s ct
                LEFT JOIN hypertable h ON (h.NAME = %2$L)
                LEFT JOIN partition_epoch pe ON (
                  pe.hypertable_name = %2$L AND
                  (pe.start_time <= (SELECT _sysinternal.get_time_field_from_record(h.time_field_name, h.time_field_type, ct, '%1$s'))::bigint 
                    OR pe.start_time IS NULL) AND
                  (pe.end_time   >= (SELECT _sysinternal.get_time_field_from_record(h.time_field_name, h.time_field_type, ct, '%1$s'))::bigint 
                    OR pe.end_time IS NULL)
                )
                LEFT JOIN _sysinternal.get_partition_for_epoch_row(pe, ct, '%1$s') AS p ON(true)
                LIMIT 1
            $$, copy_table_oid, hypertable_name)
        INTO time_point, time_field_name_point, time_field_type_point, partition_id;

        IF time_point IS NOT NULL AND partition_id IS NULL THEN
            RAISE EXCEPTION 'Should never happen: could not find partition for insert'
            USING ERRCODE = 'IO501';
        END IF;
    END LOOP;
END
$BODY$;

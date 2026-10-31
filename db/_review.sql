-- =============================================================================
-- _review.sql  -  TEMPLATE, included once per product schema by
-- 08_mapping_quality.sql. Expects psql variable :schema. Do not run on its own.
--
-- Mapping review + data quality: everything between the AI worker's proposal and
-- sp_commit_batch.
--
--   MAPPING_REVIEW --sp_approve_mapping--> VALIDATING --> READY_TO_COMMIT
--                                                    \--> NEEDS_REVIEW
--   NEEDS_REVIEW --sp_correct_value / sp_reject_record / sp_confirm_issue--> (re-validated)
--
-- Validation uses the SAME rules commit will apply, so a READY_TO_COMMIT batch commits:
--   CONVERSION  the mapping's transform could not convert the source value   (ERROR)
--   REQUIRED    NOT NULL column without a value                               (ERROR)
--   TYPE/CHECK  value rejected by the column type or a CHECK constraint      (ERROR)
--               (found by inserting the row and rolling it back)
--   REFERENCE   parent row (e.g. supplier of an invoice) not in the database  (ERROR)
--   DUPLICATE   same business key twice in the batch                          (ERROR)
--   EXTRACTION_* from the AI worker (e.g. low OCR confidence): must be confirmed
-- original_value is kept on every issue; corrections are recorded on it.
-- =============================================================================

-- Columns a mapping may target: domain-table columns minus lineage.
CREATE FUNCTION :"schema"._domain_columns(p_entity text)
RETURNS TABLE (column_name text, data_type text, required boolean, is_key boolean, ordinal int)
LANGUAGE sql STABLE SET search_path = :"schema", public, pg_temp AS $$
    SELECT a.attname::text, format_type(a.atttypid, a.atttypmod),
           a.attnotnull AND NOT a.atthasdef,
           EXISTS (SELECT 1 FROM pg_index i WHERE i.indrelid = a.attrelid AND i.indisprimary AND a.attnum = ANY (i.indkey)),
           a.attnum::int
    FROM pg_attribute a
    WHERE a.attrelid = to_regclass(format('%I.%I', current_schema(), p_entity))
      AND a.attnum > 0 AND NOT a.attisdropped
      AND a.attname NOT IN ('batch_id', 'source_record_no')
    ORDER BY a.attnum;
$$;

-- Only real domain tables of this schema (the ones with lineage) can be targets.
CREATE FUNCTION :"schema"._is_domain_table(p_entity text) RETURNS boolean
LANGUAGE sql STABLE SET search_path = :"schema", public, pg_temp AS $$
    SELECT EXISTS (SELECT 1 FROM information_schema.columns
                   WHERE table_schema = current_schema() AND table_name = p_entity AND column_name = 'source_record_no');
$$;

-- Python strptime format (what the worker detects) -> PostgreSQL to_date/to_timestamp format.
CREATE FUNCTION :"schema"._pg_format(p_fmt text) RETURNS text
LANGUAGE sql IMMUTABLE AS $$
    SELECT replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(
           replace(p_fmt, '%%', chr(1)),
           '%Y', 'YYYY'), '%y', 'YY'), '%m', 'MM'), '%d', 'DD'), '%B', 'FMMonth'), '%b', 'Mon'),
           '%H', 'HH24'), '%M', 'MI'), '%S', 'SS'), 'T', '"T"'), chr(1), '%');
$$;

-- One value through one transform (docs_ai/02 transformation types + "constant").
-- Raises on values it can't convert; the caller turns that into a CONVERSION issue.
CREATE FUNCTION :"schema"._transform(p_value jsonb, p_t jsonb) RETURNS jsonb
LANGUAGE plpgsql STABLE SET search_path = :"schema", public, pg_temp AS $$
DECLARE
    v_type text := coalesce(p_t->>'type', 'none');
    v_txt  text;
    v_num  numeric;
    c      text;
BEGIN
    IF v_type = 'constant' THEN
        RETURN p_t->'value';
    END IF;
    IF p_value IS NULL OR jsonb_typeof(p_value) = 'null' THEN
        RETURN NULL;
    END IF;
    v_txt := btrim(CASE jsonb_typeof(p_value) WHEN 'string' THEN p_value #>> '{}' ELSE p_value::text END);
    IF v_txt = '' THEN
        RETURN NULL;
    END IF;

    CASE v_type
    WHEN 'none' THEN
        RETURN p_value;
    WHEN 'trim' THEN
        RETURN to_jsonb(v_txt);
    WHEN 'uppercase' THEN
        RETURN to_jsonb(upper(v_txt));
    WHEN 'parse_decimal', 'parse_integer' THEN
        FOR c IN SELECT jsonb_array_elements_text(coalesce(p_t->'remove_characters', '[]')) LOOP
            v_txt := replace(v_txt, c, '');
        END LOOP;
        v_txt := regexp_replace(v_txt, '[\s,$€£₹¥]', '', 'g');
        v_txt := regexp_replace(v_txt, '([0-9])[A-Za-z]{3}$', '\1');  -- trailing currency code: 100.00USD
        IF v_txt ~ '^\(.*\)$' THEN
            v_txt := '-' || btrim(v_txt, '()');                       -- accounting negative: (100.00)
        END IF;
        v_num := v_txt::numeric;
        IF v_type = 'parse_integer' THEN
            IF v_num <> trunc(v_num) THEN
                RAISE EXCEPTION 'not a whole number' USING ERRCODE = '22P02';
            END IF;
            RETURN to_jsonb(v_num::bigint);
        END IF;
        RETURN to_jsonb(v_num);
    WHEN 'parse_date' THEN
        IF p_t ? 'format' THEN
            RETURN to_jsonb(to_date(v_txt, _pg_format(p_t->>'format'))::text);
        END IF;
        RETURN to_jsonb(v_txt::date::text);
    WHEN 'parse_datetime' THEN
        IF p_t ? 'format' THEN
            RETURN to_jsonb(to_timestamp(v_txt, _pg_format(p_t->>'format')));
        END IF;
        RETURN to_jsonb(v_txt::timestamptz);
    WHEN 'parse_boolean' THEN
        IF lower(v_txt) IN (SELECT lower(x) FROM jsonb_array_elements_text(
                                coalesce(p_t->'true_values', '["true","yes","y","1"]')) x) THEN
            RETURN 'true'::jsonb;
        END IF;
        IF lower(v_txt) IN ('false', 'no', 'n', '0', 'not approved', 'rejected') THEN
            RETURN 'false'::jsonb;
        END IF;
        RAISE EXCEPTION 'not a yes/no value' USING ERRCODE = '22P02';
    ELSE
        RAISE EXCEPTION 'unknown transform %', v_type USING ERRCODE = '22023';
    END CASE;
END $$;

-- -----------------------------------------------------------------------------
-- Validation of the current normalized_fields of every live record.
-- Re-runnable: drops its own unresolved findings and recomputes them; keeps
-- extraction issues, conversion issues and everything already resolved.
-- -----------------------------------------------------------------------------
CREATE FUNCTION :"schema"._validate_batch(p_batch_id uuid) RETURNS void
LANGUAGE plpgsql SET search_path = :"schema", public, pg_temp AS $$
DECLARE
    v_entity text;
    r        record;
    col      record;
    fk       record;
    v_col    text;
    v_con    text;
    v_pk     text;
BEGIN
    DELETE FROM validation_issue
    WHERE batch_id = p_batch_id AND resolved_at IS NULL
      AND rule_code IN ('REQUIRED', 'TYPE', 'CHECK', 'REFERENCE', 'DUPLICATE');

    FOR v_entity IN SELECT DISTINCT target_entity FROM raw_record
                    WHERE batch_id = p_batch_id AND state <> 'REJECTED' AND target_entity IS NOT NULL LOOP
        -- per record: required values, then a probe insert for types and CHECKs
        FOR r IN SELECT record_no, coalesce(normalized_fields, '{}') AS nf FROM raw_record
                 WHERE batch_id = p_batch_id AND target_entity = v_entity AND state <> 'REJECTED' LOOP
            INSERT INTO validation_issue (batch_id, record_no, field, rule_code, severity, message)
            SELECT p_batch_id, r.record_no, c.column_name, 'REQUIRED', 'ERROR',
                   format('%s is required', c.column_name)
            FROM _domain_columns(v_entity) c
            WHERE c.required AND (r.nf->c.column_name IS NULL OR jsonb_typeof(r.nf->c.column_name) = 'null'
                                  OR r.nf->>c.column_name = '')
              AND NOT EXISTS (SELECT 1 FROM validation_issue i      -- already explained by a conversion failure
                              WHERE i.batch_id = p_batch_id AND i.record_no = r.record_no
                                AND i.field = c.column_name AND i.rule_code = 'CONVERSION' AND i.resolved_at IS NULL);
            IF FOUND OR EXISTS (SELECT 1 FROM validation_issue i      -- already in error: one finding is enough
                                WHERE i.batch_id = p_batch_id AND i.record_no = r.record_no
                                  AND i.rule_code = 'CONVERSION' AND i.resolved_at IS NULL) THEN
                CONTINUE;
            END IF;

            BEGIN
                EXECUTE format('INSERT INTO %1$I.%2$I SELECT p.* FROM jsonb_populate_record(NULL::%1$I.%2$I, $1) p',
                               current_schema(), v_entity)
                USING r.nf || jsonb_build_object('batch_id', p_batch_id, 'source_record_no', r.record_no);
                RAISE EXCEPTION 'probe passed' USING ERRCODE = 'RV000';     -- undo the probe row
            EXCEPTION
                WHEN SQLSTATE 'RV000' OR unique_violation THEN
                    NULL;   -- valid (an existing key will be updated at commit: newer batch wins)
                WHEN not_null_violation THEN
                    GET STACKED DIAGNOSTICS v_col = COLUMN_NAME;
                    INSERT INTO validation_issue (batch_id, record_no, field, rule_code, severity, message)
                    VALUES (p_batch_id, r.record_no, v_col, 'REQUIRED', 'ERROR', format('%s is required', v_col));
                WHEN check_violation THEN
                    GET STACKED DIAGNOSTICS v_con = CONSTRAINT_NAME;
                    INSERT INTO validation_issue (batch_id, record_no, field, rule_code, severity, message)
                    SELECT p_batch_id, r.record_no,
                           (SELECT a.attname FROM pg_attribute a WHERE a.attrelid = con.conrelid AND a.attnum = con.conkey[1]
                            AND array_length(con.conkey, 1) = 1),
                           'CHECK', 'ERROR', 'Rule not met: ' || pg_get_constraintdef(con.oid)
                    FROM pg_constraint con
                    WHERE con.conname = v_con AND con.conrelid = to_regclass(format('%I.%I', current_schema(), v_entity));
                WHEN OTHERS THEN   -- wrong type / too long for the column
                    INSERT INTO validation_issue (batch_id, record_no, field, rule_code, severity, message)
                    VALUES (p_batch_id, r.record_no, NULL, 'TYPE', 'ERROR', SQLERRM);
            END;
        END LOOP;

        -- references to parent rows (single-column FKs): the parent must already be committed
        FOR fk IN SELECT a.attname AS col, pc.relname AS parent, pa.attname AS parent_col
                  FROM pg_constraint con
                  JOIN pg_attribute a  ON a.attrelid = con.conrelid AND a.attnum = con.conkey[1]
                  JOIN pg_class pc     ON pc.oid = con.confrelid
                  JOIN pg_attribute pa ON pa.attrelid = con.confrelid AND pa.attnum = con.confkey[1]
                  WHERE con.conrelid = to_regclass(format('%I.%I', current_schema(), v_entity))
                    AND con.contype = 'f' AND array_length(con.conkey, 1) = 1
                    AND pc.relname <> 'ingestion_batch' LOOP
            EXECUTE format(
                'INSERT INTO validation_issue (batch_id, record_no, field, rule_code, severity, message, original_value)
                 SELECT r.batch_id, r.record_no, %1$L, ''REFERENCE'', ''ERROR'',
                        format(''No %2$s with %3$s "%%s" exists yet. Commit it first or correct the value.'', r.normalized_fields->>%1$L),
                        r.normalized_fields->>%1$L
                 FROM raw_record r
                 WHERE r.batch_id = $1 AND r.target_entity = $2 AND r.state <> ''REJECTED''
                   AND coalesce(r.normalized_fields->>%1$L, '''') <> ''''
                   AND NOT EXISTS (SELECT 1 FROM %4$I.%2$I p WHERE p.%3$I::text = r.normalized_fields->>%1$L)',
                fk.col, fk.parent, fk.parent_col, current_schema())
            USING p_batch_id, v_entity;
        END LOOP;

        -- the same business key twice in one batch would break the commit's upsert
        SELECT string_agg(format('r.normalized_fields->>%L', c.column_name), ', ' ORDER BY c.ordinal) INTO v_pk
        FROM _domain_columns(v_entity) c WHERE c.is_key;
        IF v_pk IS NOT NULL THEN
            EXECUTE format(
                'INSERT INTO validation_issue (batch_id, record_no, field, rule_code, severity, message)
                 SELECT batch_id, record_no, NULL, ''DUPLICATE'', ''ERROR'',
                        format(''Same key as record %%s in this file'', first_no)
                 FROM (SELECT r.batch_id, r.record_no,
                              first_value(r.record_no) OVER w AS first_no, row_number() OVER w AS n
                       FROM raw_record r
                       WHERE r.batch_id = $1 AND r.target_entity = $2 AND r.state <> ''REJECTED''
                       WINDOW w AS (PARTITION BY %s ORDER BY r.record_no)) d
                 WHERE n > 1', v_pk)
            USING p_batch_id, v_entity;
        END IF;
    END LOOP;

    -- a record is ACCEPTED when nothing about it is still open
    UPDATE raw_record rr
    SET state = CASE WHEN EXISTS (SELECT 1 FROM validation_issue i
                                  WHERE i.batch_id = rr.batch_id AND i.record_no = rr.record_no AND i.resolved_at IS NULL)
                     THEN 'NEEDS_REVIEW' ELSE 'ACCEPTED' END
    WHERE rr.batch_id = p_batch_id AND rr.state <> 'REJECTED';
END $$;

-- Validate and move the batch on: READY_TO_COMMIT when every live record is ACCEPTED.
CREATE FUNCTION :"schema"._validate_and_advance(p_batch_id uuid) RETURNS jsonb
LANGUAGE plpgsql SET search_path = :"schema", public, pg_temp AS $$
DECLARE
    v_open int;
    v_counts jsonb;
BEGIN
    PERFORM sp_update_batch_status(p_batch_id, 'VALIDATING', 50::smallint, 'Validating records');
    PERFORM _validate_batch(p_batch_id);

    SELECT jsonb_build_object(
               'records', count(*),
               'accepted', count(*) FILTER (WHERE state = 'ACCEPTED'),
               'needs_review', count(*) FILTER (WHERE state = 'NEEDS_REVIEW'),
               'rejected', count(*) FILTER (WHERE state = 'REJECTED'),
               'open_issues', (SELECT count(*) FROM validation_issue WHERE batch_id = p_batch_id AND resolved_at IS NULL))
    INTO v_counts FROM raw_record WHERE batch_id = p_batch_id;
    v_open := (v_counts->>'needs_review')::int;

    IF v_open > 0 THEN
        PERFORM sp_update_batch_status(p_batch_id, 'NEEDS_REVIEW', NULL,
                                       format('%s record(s) need review', v_open));
    ELSIF (v_counts->>'accepted')::int = 0 THEN
        PERFORM sp_update_batch_status(p_batch_id, 'NEEDS_REVIEW', NULL, 'Every record was rejected');
    ELSE
        PERFORM sp_update_batch_status(p_batch_id, 'READY_TO_COMMIT', NULL,
                                       format('%s record(s) ready to commit', v_counts->>'accepted'));
    END IF;
    RETURN v_counts || jsonb_build_object('status', (SELECT status FROM ingestion_batch WHERE batch_id = p_batch_id));
END $$;

CREATE FUNCTION :"schema"._assert_permission(p_user_id uuid, p_permission text) RETURNS void
LANGUAGE plpgsql STABLE SET search_path = :"schema", public, pg_temp AS $$
DECLARE
    v_app text := (SELECT code FROM iam.app WHERE schema_name = current_schema());
BEGIN
    IF NOT iam.fn_has_permission(p_user_id, v_app, p_permission) THEN
        RAISE EXCEPTION 'Not allowed (%) in %', p_permission, v_app USING ERRCODE = '42501';
    END IF;
END $$;

-- Locks the batch and checks it is in one of the given states.
CREATE FUNCTION :"schema"._lock_batch(p_batch_id uuid, p_states text[]) RETURNS :"schema".ingestion_batch
LANGUAGE plpgsql SET search_path = :"schema", public, pg_temp AS $$
DECLARE
    v_b ingestion_batch;
BEGIN
    SELECT * INTO v_b FROM ingestion_batch WHERE batch_id = p_batch_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Batch % not found', p_batch_id USING ERRCODE = 'P0002';
    END IF;
    IF NOT v_b.status = ANY (p_states) THEN
        RAISE EXCEPTION 'Batch is %, this step needs %', v_b.status, array_to_string(p_states, ' or ')
            USING ERRCODE = '22023';
    END IF;
    RETURN v_b;
END $$;

-- =============================================================================
-- Public API (call as <schema>_app)
-- =============================================================================

-- Work lists for the Mapping review and Data quality pages.
CREATE FUNCTION :"schema".fn_review_queue(p_user_id uuid) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = :"schema", public, pg_temp AS $$
BEGIN
    PERFORM _assert_permission(p_user_id, 'dataset.view');
    RETURN jsonb_build_object(
        'mapping', coalesce((SELECT jsonb_agg(x ORDER BY x->>'uploaded_at' DESC) FROM (
            SELECT jsonb_build_object('batch_id', b.batch_id, 'batch_code', 'BATCH-' || lpad(b.batch_no::text, 6, '0'),
                       'file_name', b.file_name, 'status', b.status, 'uploaded_at', b.uploaded_at,
                       'records', (SELECT count(*) FROM raw_record r WHERE r.batch_id = b.batch_id),
                       'suggested_entity', (SELECT max(target_entity) FROM raw_record r WHERE r.batch_id = b.batch_id)) AS x
            FROM ingestion_batch b
            WHERE b.status = 'MAPPING_REVIEW'
               OR (b.status = 'NEEDS_REVIEW' AND NOT EXISTS (
                       SELECT 1 FROM mapping_version m WHERE m.batch_id = b.batch_id AND m.status = 'APPROVED'))) q), '[]'),
        'quality', coalesce((SELECT jsonb_agg(x ORDER BY x->>'uploaded_at' DESC) FROM (
            SELECT jsonb_build_object('batch_id', b.batch_id, 'batch_code', 'BATCH-' || lpad(b.batch_no::text, 6, '0'),
                       'file_name', b.file_name, 'status', b.status, 'uploaded_at', b.uploaded_at,
                       'open_issues', (SELECT count(*) FROM validation_issue i WHERE i.batch_id = b.batch_id AND i.resolved_at IS NULL),
                       'needs_review', (SELECT count(*) FROM raw_record r WHERE r.batch_id = b.batch_id AND r.state = 'NEEDS_REVIEW'),
                       'accepted', (SELECT count(*) FROM raw_record r WHERE r.batch_id = b.batch_id AND r.state = 'ACCEPTED')) AS x
            FROM ingestion_batch b
            WHERE b.status IN ('VALIDATING', 'READY_TO_COMMIT')
               OR (b.status = 'NEEDS_REVIEW' AND EXISTS (
                       SELECT 1 FROM mapping_version m WHERE m.batch_id = b.batch_id AND m.status = 'APPROVED'))) q), '[]'));
END $$;

-- Everything the mapping screen needs: latest mapping, target columns, source samples.
CREATE FUNCTION :"schema".fn_get_mapping(p_user_id uuid, p_batch_id uuid) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = :"schema", public, pg_temp AS $$
DECLARE
    v_b ingestion_batch;
BEGIN
    PERFORM _assert_permission(p_user_id, 'mapping.review');
    SELECT * INTO v_b FROM ingestion_batch WHERE batch_id = p_batch_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Batch % not found', p_batch_id USING ERRCODE = 'P0002';
    END IF;
    RETURN jsonb_build_object(
        'batch', jsonb_build_object('batch_id', v_b.batch_id, 'batch_code', 'BATCH-' || lpad(v_b.batch_no::text, 6, '0'),
                                   'file_name', v_b.file_name, 'status', v_b.status),
        'mapping', (SELECT jsonb_build_object('version', m.version, 'status', m.status, 'mappings', m.mappings,
                                              'created_at', m.created_at, 'proposed_by_ai', m.created_by IS NULL,
                                              'approved_at', m.approved_at)
                    FROM mapping_version m WHERE m.batch_id = p_batch_id ORDER BY m.version DESC LIMIT 1),
        'suggested_entity', (SELECT max(target_entity) FROM raw_record WHERE batch_id = p_batch_id),
        'entities', (SELECT jsonb_object_agg(t.table_name, (
                         SELECT jsonb_agg(jsonb_build_object('column', c.column_name, 'type', c.data_type,
                                                             'required', c.required, 'key', c.is_key) ORDER BY c.ordinal)
                         FROM _domain_columns(t.table_name) c))
                     FROM information_schema.columns t
                     WHERE t.table_schema = current_schema() AND t.column_name = 'source_record_no'),
        'fields', (SELECT coalesce(jsonb_agg(jsonb_build_object('source_field', k, 'samples', s) ORDER BY first_no), '[]')
                   FROM (SELECT k, min(r.record_no) AS first_no,
                                (SELECT coalesce(jsonb_agg(v), '[]') FROM (
                                     SELECT DISTINCT r2.raw_fields->>k AS v FROM raw_record r2
                                     WHERE r2.batch_id = p_batch_id AND coalesce(r2.raw_fields->>k, '') <> ''
                                     LIMIT 5) s5) AS s
                         FROM raw_record r, jsonb_object_keys(r.raw_fields) k
                         WHERE r.batch_id = p_batch_id AND r.record_no <= 200 AND k <> '_extra'
                         GROUP BY k) f),
        'records', (SELECT count(*) FROM raw_record WHERE batch_id = p_batch_id));
END $$;

-- Approve a mapping: version it, apply the transforms to every live record, validate.
-- p_mappings = [{source_field, target_field, transform}]; a required column the file
-- lacks can be filled with {"source_field": null, "transform": {"type":"constant","value":..}}.
CREATE FUNCTION :"schema".sp_approve_mapping(p_user_id uuid, p_batch_id uuid, p_entity text, p_mappings jsonb)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = :"schema", public, pg_temp AS $$
DECLARE
    v_app text := (SELECT code FROM iam.app WHERE schema_name = current_schema());
    v_missing text;
    v_bad text;
    v_version int;
    m jsonb;
    r record;
    v_nf jsonb;
    v_val jsonb;
BEGIN
    PERFORM _assert_permission(p_user_id, 'mapping.review');
    PERFORM _lock_batch(p_batch_id, ARRAY['MAPPING_REVIEW', 'NEEDS_REVIEW', 'READY_TO_COMMIT']);

    IF p_entity IS NULL OR NOT _is_domain_table(p_entity) THEN
        RAISE EXCEPTION 'Unknown target table "%"', p_entity USING ERRCODE = '22023';
    END IF;
    IF jsonb_typeof(p_mappings) IS DISTINCT FROM 'array' THEN
        RAISE EXCEPTION 'mappings must be a list' USING ERRCODE = '22023';
    END IF;
    -- keep only items that target something
    p_mappings := coalesce((SELECT jsonb_agg(x) FROM jsonb_array_elements(p_mappings) x
                            WHERE coalesce(x->>'target_field', '') <> ''), '[]');

    SELECT string_agg(DISTINCT x->>'target_field', ', ') INTO v_bad
    FROM jsonb_array_elements(p_mappings) x
    WHERE x->>'target_field' NOT IN (SELECT column_name FROM _domain_columns(p_entity));
    IF v_bad IS NOT NULL THEN
        RAISE EXCEPTION '% is not a field of %', v_bad, p_entity USING ERRCODE = '22023';
    END IF;
    SELECT string_agg(t, ', ') INTO v_bad FROM (
        SELECT x->>'target_field' AS t FROM jsonb_array_elements(p_mappings) x GROUP BY 1 HAVING count(*) > 1) d;
    IF v_bad IS NOT NULL THEN
        RAISE EXCEPTION 'More than one source field maps to %', v_bad USING ERRCODE = '22023';
    END IF;
    SELECT string_agg(DISTINCT coalesce(x->'transform'->>'type', 'none'), ', ') INTO v_bad
    FROM jsonb_array_elements(p_mappings) x
    WHERE coalesce(x->'transform'->>'type', 'none') NOT IN
          ('none', 'trim', 'uppercase', 'parse_decimal', 'parse_integer', 'parse_date', 'parse_datetime',
           'parse_boolean', 'constant');
    IF v_bad IS NOT NULL THEN
        RAISE EXCEPTION 'Unknown transform: %', v_bad USING ERRCODE = '22023';
    END IF;
    SELECT string_agg(c.column_name, ', ' ORDER BY c.ordinal) INTO v_missing
    FROM _domain_columns(p_entity) c
    WHERE c.required AND c.column_name NOT IN (SELECT x->>'target_field' FROM jsonb_array_elements(p_mappings) x);
    IF v_missing IS NOT NULL THEN
        RAISE EXCEPTION 'Map or give a fixed value for required field(s): %', v_missing USING ERRCODE = '22023';
    END IF;

    -- version: earlier ones are superseded, this one is APPROVED by the user
    UPDATE mapping_version SET status = 'SUPERSEDED' WHERE batch_id = p_batch_id AND status <> 'SUPERSEDED';
    SELECT coalesce(max(version), 0) + 1 INTO v_version FROM mapping_version WHERE batch_id = p_batch_id;
    INSERT INTO mapping_version (batch_id, version, mappings, status, created_by, approved_by, approved_at)
    VALUES (p_batch_id, v_version, p_mappings, 'APPROVED', p_user_id, p_user_id, now());

    -- a new mapping invalidates earlier conversions/corrections; extraction issues stay
    DELETE FROM validation_issue WHERE batch_id = p_batch_id AND rule_code NOT LIKE 'EXTRACTION%';

    FOR r IN SELECT record_no, raw_fields FROM raw_record WHERE batch_id = p_batch_id AND state <> 'REJECTED' LOOP
        v_nf := '{}';
        FOR m IN SELECT x FROM jsonb_array_elements(p_mappings) x LOOP
            BEGIN
                v_val := _transform(r.raw_fields->(m->>'source_field'), coalesce(m->'transform', '{}'));
                IF v_val IS NOT NULL THEN
                    v_nf := v_nf || jsonb_build_object(m->>'target_field', v_val);
                END IF;
            EXCEPTION WHEN OTHERS THEN
                INSERT INTO validation_issue (batch_id, record_no, field, rule_code, severity, message, original_value)
                VALUES (p_batch_id, r.record_no, m->>'target_field', 'CONVERSION', 'ERROR',
                        format('Could not convert "%s" from %s (%s)', r.raw_fields->>(m->>'source_field'),
                               m->>'source_field', SQLERRM),
                        r.raw_fields->>(m->>'source_field'));
            END;
        END LOOP;
        UPDATE raw_record SET target_entity = p_entity, normalized_fields = v_nf, state = 'PENDING'
        WHERE batch_id = p_batch_id AND record_no = r.record_no;
    END LOOP;

    PERFORM iam._audit(p_user_id, (SELECT app_id FROM iam.app WHERE code = v_app), 'MAPPING_APPROVED', 'batch',
                       p_batch_id::text, jsonb_build_object('version', v_version, 'entity', p_entity));
    RETURN _validate_and_advance(p_batch_id) || jsonb_build_object('mapping_version', v_version);
END $$;

-- Issues of a batch (open first) with the record values needed to fix them.
CREATE FUNCTION :"schema".fn_list_issues(p_user_id uuid, p_batch_id uuid) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = :"schema", public, pg_temp AS $$
DECLARE
    v_b ingestion_batch;
BEGIN
    PERFORM _assert_permission(p_user_id, 'dataset.view');
    SELECT * INTO v_b FROM ingestion_batch WHERE batch_id = p_batch_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Batch % not found', p_batch_id USING ERRCODE = 'P0002';
    END IF;
    RETURN jsonb_build_object(
        'batch', jsonb_build_object('batch_id', v_b.batch_id, 'batch_code', 'BATCH-' || lpad(v_b.batch_no::text, 6, '0'),
                                   'file_name', v_b.file_name, 'status', v_b.status, 'uploaded_by', v_b.uploaded_by),
        'counts', (SELECT jsonb_build_object(
                       'records', count(*),
                       'accepted', count(*) FILTER (WHERE state = 'ACCEPTED'),
                       'needs_review', count(*) FILTER (WHERE state = 'NEEDS_REVIEW'),
                       'rejected', count(*) FILTER (WHERE state = 'REJECTED'),
                       'pending', count(*) FILTER (WHERE state = 'PENDING'))
                   FROM raw_record WHERE batch_id = p_batch_id),
        'entity', (SELECT max(target_entity) FROM raw_record WHERE batch_id = p_batch_id),
        'columns', (SELECT coalesce(jsonb_agg(jsonb_build_object('column', c.column_name, 'type', c.data_type,
                                                                 'required', c.required) ORDER BY c.ordinal), '[]')
                    FROM _domain_columns((SELECT max(target_entity) FROM raw_record WHERE batch_id = p_batch_id)) c),
        'issues', (SELECT coalesce(jsonb_agg(jsonb_build_object(
                       'issue_id', i.issue_id, 'record_no', i.record_no, 'field', i.field, 'rule_code', i.rule_code,
                       'severity', i.severity, 'message', i.message, 'original_value', i.original_value,
                       'corrected_value', i.corrected_value, 'resolved_at', i.resolved_at,
                       'record_state', r.state, 'current_value', r.normalized_fields->i.field,
                       'source_location', r.source_location, 'raw_fields', r.raw_fields)
                   ORDER BY (i.resolved_at IS NOT NULL), i.record_no, i.issue_id), '[]')
                   FROM (SELECT * FROM validation_issue WHERE batch_id = p_batch_id
                         ORDER BY (resolved_at IS NOT NULL), record_no, issue_id LIMIT 500) i
                   LEFT JOIN raw_record r ON r.batch_id = i.batch_id AND r.record_no = i.record_no));
END $$;

-- Fix one value. The original stays on the issue; the batch is validated again.
CREATE FUNCTION :"schema".sp_correct_value(
    p_user_id uuid, p_batch_id uuid, p_record_no int, p_field text, p_value text
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = :"schema", public, pg_temp AS $$
DECLARE
    v_app text := (SELECT code FROM iam.app WHERE schema_name = current_schema());
    v_entity text;
BEGIN
    PERFORM _assert_permission(p_user_id, 'data_quality.review');
    PERFORM _lock_batch(p_batch_id, ARRAY['NEEDS_REVIEW', 'READY_TO_COMMIT']);
    SELECT target_entity INTO v_entity FROM raw_record
    WHERE batch_id = p_batch_id AND record_no = p_record_no AND state <> 'REJECTED';
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Record % not found', p_record_no USING ERRCODE = 'P0002';
    END IF;
    IF p_field NOT IN (SELECT column_name FROM _domain_columns(v_entity)) THEN
        RAISE EXCEPTION '% is not a field of %', p_field, v_entity USING ERRCODE = '22023';
    END IF;

    UPDATE raw_record
    SET normalized_fields = CASE WHEN nullif(btrim(p_value), '') IS NULL THEN normalized_fields - p_field
                                 ELSE coalesce(normalized_fields, '{}') || jsonb_build_object(p_field, btrim(p_value)) END
    WHERE batch_id = p_batch_id AND record_no = p_record_no;
    UPDATE validation_issue
    SET corrected_value = btrim(p_value), resolved_by = p_user_id, resolved_at = now()
    WHERE batch_id = p_batch_id AND record_no = p_record_no AND field = p_field AND resolved_at IS NULL;

    PERFORM iam._audit(p_user_id, (SELECT app_id FROM iam.app WHERE code = v_app), 'VALUE_CORRECTED', 'record',
                       p_batch_id || '#' || p_record_no, jsonb_build_object('field', p_field));
    RETURN _validate_and_advance(p_batch_id);
END $$;

-- Exclude a record from the commit (it is counted as rejected).
CREATE FUNCTION :"schema".sp_reject_record(p_user_id uuid, p_batch_id uuid, p_record_no int, p_reason text)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = :"schema", public, pg_temp AS $$
DECLARE
    v_app text := (SELECT code FROM iam.app WHERE schema_name = current_schema());
BEGIN
    PERFORM _assert_permission(p_user_id, 'data_quality.review');
    PERFORM _lock_batch(p_batch_id, ARRAY['NEEDS_REVIEW', 'READY_TO_COMMIT']);
    IF nullif(btrim(p_reason), '') IS NULL THEN
        RAISE EXCEPTION 'A reason is required to reject a record' USING ERRCODE = '22023';
    END IF;
    UPDATE raw_record SET state = 'REJECTED'
    WHERE batch_id = p_batch_id AND record_no = p_record_no AND state <> 'REJECTED';
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Record % not found', p_record_no USING ERRCODE = 'P0002';
    END IF;
    UPDATE validation_issue
    SET corrected_value = 'Record rejected: ' || left(btrim(p_reason), 200), resolved_by = p_user_id, resolved_at = now()
    WHERE batch_id = p_batch_id AND record_no = p_record_no AND resolved_at IS NULL;

    PERFORM iam._audit(p_user_id, (SELECT app_id FROM iam.app WHERE code = v_app), 'RECORD_REJECTED', 'record',
                       p_batch_id || '#' || p_record_no, jsonb_build_object('reason', left(p_reason, 200)));
    RETURN _validate_and_advance(p_batch_id);
END $$;

-- Confirm an extraction warning (e.g. low OCR confidence) or a conversion issue
-- whose field is optional, after checking the value.
CREATE FUNCTION :"schema".sp_confirm_issue(p_user_id uuid, p_batch_id uuid, p_issue_id bigint) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = :"schema", public, pg_temp AS $$
BEGIN
    PERFORM _assert_permission(p_user_id, 'data_quality.review');
    PERFORM _lock_batch(p_batch_id, ARRAY['NEEDS_REVIEW', 'READY_TO_COMMIT']);
    UPDATE validation_issue
    SET corrected_value = '(confirmed as is)', resolved_by = p_user_id, resolved_at = now()
    WHERE issue_id = p_issue_id AND batch_id = p_batch_id AND resolved_at IS NULL
      AND (rule_code LIKE 'EXTRACTION%' OR rule_code = 'CONVERSION');
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Only open extraction or conversion issues can be confirmed; fix the value instead'
            USING ERRCODE = '22023';
    END IF;
    RETURN _validate_and_advance(p_batch_id);
END $$;

-- Run validation again (e.g. after the missing parent rows were committed).
CREATE FUNCTION :"schema".sp_revalidate_batch(p_user_id uuid, p_batch_id uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = :"schema", public, pg_temp AS $$
BEGIN
    PERFORM _assert_permission(p_user_id, 'data_quality.review');
    PERFORM _lock_batch(p_batch_id, ARRAY['NEEDS_REVIEW', 'READY_TO_COMMIT']);
    IF NOT EXISTS (SELECT 1 FROM mapping_version WHERE batch_id = p_batch_id AND status = 'APPROVED') THEN
        RAISE EXCEPTION 'Approve the mapping first' USING ERRCODE = '22023';
    END IF;
    RETURN _validate_and_advance(p_batch_id);
END $$;

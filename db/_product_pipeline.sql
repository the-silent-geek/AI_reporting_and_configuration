-- =============================================================================
-- _product_pipeline.sql  -  TEMPLATE, included once per product schema.
-- Expects psql variable :schema (erp | aml | lending). Do not run on its own.
--
-- Batch life cycle (enforced by sp_update_batch_status):
--
--   UPLOADED -> EXTRACTING -> MAPPING_REVIEW -> VALIDATING -> READY_TO_COMMIT -> COMMITTED
--                   |               |              |               |
--                   +--> NEEDS_REVIEW <------------+               +--> VALIDATING (re-check)
--   any non-final state --> FAILED --> UPLOADED (safe retry)
--
-- Functions here use the schema's search_path, so unqualified names resolve to
-- this product's tables, and current_schema() tells them which app they are.
-- =============================================================================

\set rw_role :schema _app
\set ro_role :schema _ro

-- -----------------------------------------------------------------------------
-- ingestion_batch: one uploaded file. The original file lives on disk/object
-- storage (storage_uri); the DB keeps metadata + checksum.
-- -----------------------------------------------------------------------------
CREATE TABLE :"schema".ingestion_batch (
    batch_id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    batch_no          bigint GENERATED ALWAYS AS IDENTITY UNIQUE,   -- human id: BATCH-000001
    status            text NOT NULL DEFAULT 'UPLOADED' CHECK (status IN
                        ('UPLOADED','EXTRACTING','MAPPING_REVIEW','VALIDATING','READY_TO_COMMIT',
                         'COMMITTED','NEEDS_REVIEW','FAILED')),
    progress_pct      smallint NOT NULL DEFAULT 0 CHECK (progress_pct BETWEEN 0 AND 100),
    progress_message  text,
    file_name         text NOT NULL,
    file_type         text NOT NULL CHECK (file_type IN ('CSV','EXCEL','JSON','PDF')),
    mime_type         text,
    file_size_bytes   bigint NOT NULL CHECK (file_size_bytes > 0),
    sha256            text NOT NULL CHECK (sha256 ~ '^[0-9a-f]{64}$'),  -- duplicate-upload detection
    storage_uri       text NOT NULL,                                     -- where the original file is kept
    source_system     text,
    period_start      date,
    period_end        date,
    parser_version    text,
    error_message     text,
    -- final record accounting, frozen at commit: received = accepted + rejected
    received_count    integer,
    accepted_count    integer,
    rejected_count    integer,
    uploaded_by       uuid NOT NULL REFERENCES iam.app_user(user_id),
    uploaded_at       timestamptz NOT NULL DEFAULT now(),
    committed_by      uuid REFERENCES iam.app_user(user_id),
    committed_at      timestamptz,
    updated_at        timestamptz NOT NULL DEFAULT now(),
    CHECK (period_end IS NULL OR period_start IS NULL OR period_end >= period_start)
);
-- Same file can't be live twice; a FAILED batch may be re-uploaded.
CREATE UNIQUE INDEX ux_ingestion_batch_sha256 ON :"schema".ingestion_batch(sha256) WHERE status <> 'FAILED';
CREATE INDEX ix_ingestion_batch_uploaded ON :"schema".ingestion_batch(uploaded_at DESC);
CREATE TRIGGER trg_ingestion_batch_updated BEFORE UPDATE ON :"schema".ingestion_batch
    FOR EACH ROW EXECUTE FUNCTION iam.tg_set_updated_at();

-- -----------------------------------------------------------------------------
-- batch_event: every status/progress change. Feeds SSE and lets a reconnecting
-- browser replay what it missed (Last-Event-ID = event_id).
-- -----------------------------------------------------------------------------
CREATE TABLE :"schema".batch_event (
    event_id      bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    batch_id      uuid NOT NULL REFERENCES :"schema".ingestion_batch(batch_id) ON DELETE CASCADE,
    status        text NOT NULL,
    progress_pct  smallint NOT NULL,
    message       text,
    created_at    timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX ix_batch_event_batch ON :"schema".batch_event(batch_id, event_id);

-- -----------------------------------------------------------------------------
-- raw_record: one candidate record extracted from the file (all 4 formats use
-- this same shape - the "one adapter contract"). Bulk-loaded with COPY.
-- state is mutually exclusive, so received = accepted + rejected + pending/review.
-- -----------------------------------------------------------------------------
CREATE TABLE :"schema".raw_record (
    batch_id           uuid NOT NULL REFERENCES :"schema".ingestion_batch(batch_id) ON DELETE CASCADE,
    record_no          integer NOT NULL,
    target_entity      text,                 -- domain table it maps to, e.g. 'invoice'
    source_location    jsonb NOT NULL,       -- {"sheet":"Payables","row":12} or {"page":2,"table":1,"row":4,"bbox":[...]}
    raw_fields         jsonb NOT NULL,       -- original names + values, never modified
    normalized_fields  jsonb,                -- after approved mapping, keys = domain column names
    extraction_method  text NOT NULL CHECK (extraction_method IN ('csv','excel','json','pdf_text','ocr')),
    confidence         numeric(5,4) CHECK (confidence BETWEEN 0 AND 1),
    state              text NOT NULL DEFAULT 'PENDING'
                         CHECK (state IN ('PENDING','ACCEPTED','REJECTED','NEEDS_REVIEW')),
    PRIMARY KEY (batch_id, record_no)
);
CREATE INDEX ix_raw_record_state ON :"schema".raw_record(batch_id, state);

-- -----------------------------------------------------------------------------
-- mapping_version: AI-proposed / human-approved field mapping for a batch.
-- mappings = [{"source_field","target_field","transform","confidence","rationale"}]
-- -----------------------------------------------------------------------------
CREATE TABLE :"schema".mapping_version (
    mapping_id   bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    batch_id     uuid NOT NULL REFERENCES :"schema".ingestion_batch(batch_id) ON DELETE CASCADE,
    version      integer NOT NULL,
    mappings     jsonb NOT NULL,
    status       text NOT NULL DEFAULT 'PROPOSED' CHECK (status IN ('PROPOSED','APPROVED','SUPERSEDED')),
    created_by   uuid REFERENCES iam.app_user(user_id),   -- NULL = proposed by AI worker
    created_at   timestamptz NOT NULL DEFAULT now(),
    approved_by  uuid REFERENCES iam.app_user(user_id),
    approved_at  timestamptz,
    UNIQUE (batch_id, version)
);

-- -----------------------------------------------------------------------------
-- validation_issue: data-quality problems per record/field, with the correction
-- trail (original_value is kept forever).
-- -----------------------------------------------------------------------------
CREATE TABLE :"schema".validation_issue (
    issue_id         bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    batch_id         uuid NOT NULL,
    record_no        integer,                 -- NULL = batch-level issue (e.g. totals don't reconcile)
    field            text,
    rule_code        text NOT NULL,           -- REQUIRED, TYPE, ENUM, DUPLICATE, RECONCILIATION, ...
    severity         text NOT NULL CHECK (severity IN ('ERROR','WARNING')),
    message          text NOT NULL,
    original_value   text,
    corrected_value  text,
    resolved_by      uuid REFERENCES iam.app_user(user_id),
    resolved_at      timestamptz,
    created_at       timestamptz NOT NULL DEFAULT now(),
    FOREIGN KEY (batch_id) REFERENCES :"schema".ingestion_batch(batch_id) ON DELETE CASCADE,
    FOREIGN KEY (batch_id, record_no) REFERENCES :"schema".raw_record(batch_id, record_no) ON DELETE CASCADE
);
CREATE INDEX ix_validation_issue_batch ON :"schema".validation_issue(batch_id) WHERE resolved_at IS NULL;

-- -----------------------------------------------------------------------------
-- template_version: report/document template definitions, versioned.
-- Draft -> Submitted -> Approved -> Published; published rows are never edited.
-- -----------------------------------------------------------------------------
CREATE TABLE :"schema".template_version (
    template_code  text NOT NULL,              -- e.g. 'PAYMENT_ADVICE'
    version        integer NOT NULL,
    kind           text NOT NULL CHECK (kind IN ('REPORT','DOCUMENT')),
    name           text NOT NULL,
    root_entity    text NOT NULL,              -- e.g. 'payment'
    definition     jsonb NOT NULL,             -- sections, bindings, formatting, required fields
    status         text NOT NULL DEFAULT 'DRAFT'
                     CHECK (status IN ('DRAFT','SUBMITTED','APPROVED','PUBLISHED','REJECTED','RETIRED')),
    created_by     uuid NOT NULL REFERENCES iam.app_user(user_id),
    created_at     timestamptz NOT NULL DEFAULT now(),
    approved_by    uuid REFERENCES iam.app_user(user_id),
    published_at   timestamptz,
    PRIMARY KEY (template_code, version),
    CHECK (approved_by IS NULL OR approved_by <> created_by)    -- maker-checker
);

-- -----------------------------------------------------------------------------
-- report_run: every generated report/document, with exactly what produced it
-- (filters, period, batches, template version) so any number is reproducible.
-- -----------------------------------------------------------------------------
CREATE TABLE :"schema".report_run (
    run_id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    template_code     text NOT NULL,
    template_version  integer NOT NULL,
    filters           jsonb NOT NULL DEFAULT '{}',
    period_start      date,
    period_end        date,
    source_batch_ids  uuid[] NOT NULL DEFAULT '{}',   -- data snapshot used
    metric_version    text,
    output_uri        text,                           -- rendered PDF/CSV location
    generated_by      uuid NOT NULL REFERENCES iam.app_user(user_id),
    generated_at      timestamptz NOT NULL DEFAULT now(),
    FOREIGN KEY (template_code, template_version) REFERENCES :"schema".template_version(template_code, version)
);

-- =============================================================================
-- Functions
-- =============================================================================

-- Register an upload. Returns {"status":"CREATED"|"DUPLICATE","batch_id","batch_no"}.
-- Caller needs dataset.upload in this product.
CREATE FUNCTION :"schema".sp_create_batch(
    p_user_id uuid, p_file_name text, p_file_type text, p_file_size_bytes bigint,
    p_sha256 text, p_storage_uri text, p_mime_type text DEFAULT NULL,
    p_source_system text DEFAULT NULL, p_period_start date DEFAULT NULL, p_period_end date DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = :"schema", public, pg_temp AS $$
DECLARE
    v_app text := (SELECT code FROM iam.app WHERE schema_name = current_schema());
    v_b   ingestion_batch;
BEGIN
    IF NOT iam.fn_has_permission(p_user_id, v_app, 'dataset.upload') THEN
        RAISE EXCEPTION 'Not allowed to upload in %', v_app USING ERRCODE = '42501';
    END IF;

    -- Re-upload of a live file: hand back the existing batch instead of double-loading.
    SELECT * INTO v_b FROM ingestion_batch WHERE sha256 = lower(p_sha256) AND status <> 'FAILED';
    IF FOUND THEN
        RETURN jsonb_build_object('status', 'DUPLICATE', 'batch_id', v_b.batch_id, 'batch_no', v_b.batch_no,
                                  'batch_status', v_b.status);
    END IF;

    BEGIN
        INSERT INTO ingestion_batch (file_name, file_type, mime_type, file_size_bytes, sha256, storage_uri,
                                     source_system, period_start, period_end, uploaded_by)
        VALUES (p_file_name, upper(p_file_type), p_mime_type, p_file_size_bytes, lower(p_sha256), p_storage_uri,
                p_source_system, p_period_start, p_period_end, p_user_id)
        RETURNING * INTO v_b;
    EXCEPTION WHEN unique_violation THEN
        -- Two users uploaded the same file at the same instant; the other one won.
        SELECT * INTO v_b FROM ingestion_batch WHERE sha256 = lower(p_sha256) AND status <> 'FAILED';
        RETURN jsonb_build_object('status', 'DUPLICATE', 'batch_id', v_b.batch_id, 'batch_no', v_b.batch_no,
                                  'batch_status', v_b.status);
    END;

    INSERT INTO batch_event (batch_id, status, progress_pct, message)
    VALUES (v_b.batch_id, 'UPLOADED', 0, 'File received');
    PERFORM iam._audit(p_user_id, (SELECT app_id FROM iam.app WHERE code = v_app),
                       'BATCH_CREATED', 'batch', v_b.batch_id::text,
                       jsonb_build_object('file_name', p_file_name, 'sha256', lower(p_sha256)));

    RETURN jsonb_build_object('status', 'CREATED', 'batch_id', v_b.batch_id, 'batch_no', v_b.batch_no);
END $$;

-- Move a batch through its life cycle / report progress. Called by the backend
-- when the AI worker publishes progress on RabbitMQ. Rejects illegal jumps.
-- Same-status calls are allowed (e.g. EXTRACTING 40% -> EXTRACTING 60%).
-- Returns the new batch_event.event_id (use it as the SSE event id).
CREATE FUNCTION :"schema".sp_update_batch_status(
    p_batch_id uuid, p_status text, p_progress_pct smallint DEFAULT NULL,
    p_message text DEFAULT NULL, p_error_message text DEFAULT NULL
) RETURNS bigint
LANGUAGE plpgsql SECURITY DEFINER SET search_path = :"schema", public, pg_temp AS $$
DECLARE
    v_from text;
    v_to   text := upper(p_status);
    v_pct  smallint;
    v_event_id bigint;
BEGIN
    SELECT status INTO v_from FROM ingestion_batch WHERE batch_id = p_batch_id FOR UPDATE;
    IF v_from IS NULL THEN
        RAISE EXCEPTION 'Batch % not found', p_batch_id USING ERRCODE = 'P0002';
    END IF;

    IF v_to = 'COMMITTED' THEN
        RAISE EXCEPTION 'Use sp_commit_batch to commit' USING ERRCODE = '22023';
    END IF;
    IF v_to <> v_from AND (v_from, v_to) NOT IN (
            ('UPLOADED','EXTRACTING'),
            ('EXTRACTING','MAPPING_REVIEW'),   ('EXTRACTING','NEEDS_REVIEW'),
            ('MAPPING_REVIEW','VALIDATING'),
            ('VALIDATING','READY_TO_COMMIT'),  ('VALIDATING','NEEDS_REVIEW'),
            ('NEEDS_REVIEW','MAPPING_REVIEW'), ('NEEDS_REVIEW','VALIDATING'),
            ('READY_TO_COMMIT','VALIDATING'),
            ('FAILED','UPLOADED'))
       AND NOT (v_to = 'FAILED' AND v_from NOT IN ('COMMITTED','FAILED')) THEN
        RAISE EXCEPTION 'Illegal batch transition % -> %', v_from, v_to USING ERRCODE = '22023';
    END IF;

    -- A status change without an explicit percentage restarts the bar (or fills it when done).
    v_pct := coalesce(p_progress_pct,
                      CASE WHEN v_to = v_from THEN (SELECT progress_pct FROM ingestion_batch WHERE batch_id = p_batch_id)
                           WHEN v_to = 'READY_TO_COMMIT' THEN 100 ELSE 0 END);

    UPDATE ingestion_batch
    SET status = v_to, progress_pct = v_pct, progress_message = p_message,
        error_message = CASE WHEN v_to = 'FAILED' THEN p_error_message END
    WHERE batch_id = p_batch_id;

    INSERT INTO batch_event (batch_id, status, progress_pct, message)
    VALUES (p_batch_id, v_to, v_pct, coalesce(p_message, p_error_message))
    RETURNING event_id INTO v_event_id;
    RETURN v_event_id;
END $$;

-- Commit a validated batch into the domain tables, in one transaction.
--   * needs batch.commit
--   * maker-checker: the uploader cannot commit their own batch
--   * nothing may still be PENDING / NEEDS_REVIEW
--   * ACCEPTED rows are upserted into raw_record.target_entity by primary key
--     (business key). Update policy: the newer batch wins, lineage columns
--     batch_id/source_record_no point at the batch that last wrote the row.
-- Returns {"status":"COMMITTED","received","accepted","rejected","loaded":{entity:rows}}
CREATE FUNCTION :"schema".sp_commit_batch(p_user_id uuid, p_batch_id uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = :"schema", public, pg_temp AS $$
DECLARE
    v_app      text := (SELECT code FROM iam.app WHERE schema_name = current_schema());
    v_b        ingestion_batch;
    v_received int; v_accepted int; v_rejected int; v_open int;
    v_entity   text;
    v_pk       text;
    v_set      text;
    v_rows     int;
    v_loaded   jsonb := '{}';
BEGIN
    IF NOT iam.fn_has_permission(p_user_id, v_app, 'batch.commit') THEN
        RAISE EXCEPTION 'Not allowed to commit in %', v_app USING ERRCODE = '42501';
    END IF;

    SELECT * INTO v_b FROM ingestion_batch WHERE batch_id = p_batch_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Batch % not found', p_batch_id USING ERRCODE = 'P0002';
    END IF;
    IF v_b.status <> 'READY_TO_COMMIT' THEN
        RAISE EXCEPTION 'Batch is %, expected READY_TO_COMMIT', v_b.status USING ERRCODE = '22023';
    END IF;
    IF v_b.uploaded_by = p_user_id THEN
        RAISE EXCEPTION 'Maker-checker: the uploader cannot commit their own batch' USING ERRCODE = '42501';
    END IF;

    SELECT count(*),
           count(*) FILTER (WHERE state = 'ACCEPTED'),
           count(*) FILTER (WHERE state = 'REJECTED'),
           count(*) FILTER (WHERE state IN ('PENDING','NEEDS_REVIEW'))
    INTO v_received, v_accepted, v_rejected, v_open
    FROM raw_record WHERE batch_id = p_batch_id;

    IF v_open > 0 THEN
        RAISE EXCEPTION '% record(s) still pending or awaiting review', v_open USING ERRCODE = '22023';
    END IF;

    -- Load each target entity. Only real domain tables of THIS schema are allowed
    -- (they are the ones carrying a source_record_no lineage column).
    FOR v_entity IN
        SELECT DISTINCT target_entity FROM raw_record WHERE batch_id = p_batch_id AND state = 'ACCEPTED'
    LOOP
        IF v_entity IS NULL OR NOT EXISTS (
               SELECT 1 FROM information_schema.columns
               WHERE table_schema = current_schema() AND table_name = v_entity AND column_name = 'source_record_no') THEN
            RAISE EXCEPTION 'Invalid target entity "%" in batch', v_entity USING ERRCODE = '22023';
        END IF;

        -- primary key columns -> ON CONFLICT target
        SELECT string_agg(quote_ident(a.attname), ', ')
        INTO v_pk
        FROM pg_index i
        JOIN pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = ANY (i.indkey)
        WHERE i.indrelid = format('%I.%I', current_schema(), v_entity)::regclass AND i.indisprimary;

        -- every non-key column is overwritten by the newer batch
        SELECT string_agg(format('%1$I = EXCLUDED.%1$I', c.column_name), ', ')
        INTO v_set
        FROM information_schema.columns c
        WHERE c.table_schema = current_schema() AND c.table_name = v_entity
          AND c.column_name NOT IN (
              SELECT a.attname FROM pg_index i
              JOIN pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = ANY (i.indkey)
              WHERE i.indrelid = format('%I.%I', current_schema(), v_entity)::regclass AND i.indisprimary);

        -- jsonb_populate_record turns normalized_fields into a typed row of the
        -- target table; bad types (e.g. 'abc' as amount) abort the whole commit.
        EXECUTE format(
            'INSERT INTO %1$I.%2$I
             SELECT p.* FROM raw_record r
             CROSS JOIN LATERAL jsonb_populate_record(NULL::%1$I.%2$I,
                 r.normalized_fields || jsonb_build_object(''batch_id'', r.batch_id, ''source_record_no'', r.record_no)) p
             WHERE r.batch_id = $1 AND r.state = ''ACCEPTED'' AND r.target_entity = $2
             ON CONFLICT (%3$s) DO UPDATE SET %4$s',
            current_schema(), v_entity, v_pk, v_set)
        USING p_batch_id, v_entity;
        GET DIAGNOSTICS v_rows = ROW_COUNT;
        v_loaded := v_loaded || jsonb_build_object(v_entity, v_rows);
    END LOOP;

    UPDATE ingestion_batch
    SET status = 'COMMITTED', progress_pct = 100, progress_message = 'Committed',
        received_count = v_received, accepted_count = v_accepted, rejected_count = v_rejected,
        committed_by = p_user_id, committed_at = now()
    WHERE batch_id = p_batch_id;

    INSERT INTO batch_event (batch_id, status, progress_pct, message)
    VALUES (p_batch_id, 'COMMITTED', 100, 'Committed');
    PERFORM iam._audit(p_user_id, (SELECT app_id FROM iam.app WHERE code = v_app),
                       'BATCH_COMMITTED', 'batch', p_batch_id::text, v_loaded);

    RETURN jsonb_build_object('status', 'COMMITTED', 'received', v_received, 'accepted', v_accepted,
                              'rejected', v_rejected, 'loaded', v_loaded);
END $$;

-- One batch with live record counts. Needs dataset.view.
CREATE FUNCTION :"schema".fn_get_batch(p_user_id uuid, p_batch_id uuid) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = :"schema", public, pg_temp AS $$
DECLARE
    v_app text := (SELECT code FROM iam.app WHERE schema_name = current_schema());
    v_result jsonb;
BEGIN
    IF NOT iam.fn_has_permission(p_user_id, v_app, 'dataset.view') THEN
        RAISE EXCEPTION 'Not allowed to view datasets in %', v_app USING ERRCODE = '42501';
    END IF;

    SELECT to_jsonb(b) - 'storage_uri'
           || jsonb_build_object('batch_code', 'BATCH-' || lpad(b.batch_no::text, 6, '0'),
                                 'counts', c.counts)
    INTO v_result
    FROM ingestion_batch b
    CROSS JOIN LATERAL (
        SELECT jsonb_build_object(
                   'received',     count(*),
                   'accepted',     count(*) FILTER (WHERE state = 'ACCEPTED'),
                   'rejected',     count(*) FILTER (WHERE state = 'REJECTED'),
                   'needs_review', count(*) FILTER (WHERE state = 'NEEDS_REVIEW'),
                   'pending',      count(*) FILTER (WHERE state = 'PENDING')) AS counts
        FROM raw_record r WHERE r.batch_id = b.batch_id) c
    WHERE b.batch_id = p_batch_id;

    IF v_result IS NULL THEN
        RAISE EXCEPTION 'Batch % not found', p_batch_id USING ERRCODE = 'P0002';
    END IF;
    RETURN v_result;
END $$;

-- Paged batch list, newest first. Needs dataset.view.
CREATE FUNCTION :"schema".fn_list_batches(p_user_id uuid, p_limit int DEFAULT 50, p_offset int DEFAULT 0)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = :"schema", public, pg_temp AS $$
DECLARE
    v_app text := (SELECT code FROM iam.app WHERE schema_name = current_schema());
    v_result jsonb;
BEGIN
    IF NOT iam.fn_has_permission(p_user_id, v_app, 'dataset.view') THEN
        RAISE EXCEPTION 'Not allowed to view datasets in %', v_app USING ERRCODE = '42501';
    END IF;

    SELECT coalesce(jsonb_agg(jsonb_build_object(
               'batch_id', batch_id, 'batch_code', 'BATCH-' || lpad(batch_no::text, 6, '0'),
               'file_name', file_name, 'file_type', file_type, 'status', status,
               'progress_pct', progress_pct, 'uploaded_by', uploaded_by, 'uploaded_at', uploaded_at)
           ORDER BY uploaded_at DESC), '[]'::jsonb)
    INTO v_result
    FROM (SELECT * FROM ingestion_batch ORDER BY uploaded_at DESC
          LIMIT least(greatest(p_limit, 1), 200) OFFSET greatest(p_offset, 0)) b;
    RETURN v_result;
END $$;

-- Events after a given id, for SSE replay on reconnect. Backend checks
-- dataset.view before opening the stream, so no user parameter here.
CREATE FUNCTION :"schema".fn_get_batch_events(p_batch_id uuid, p_after_event_id bigint DEFAULT 0)
RETURNS SETOF :"schema".batch_event
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = :"schema", public, pg_temp AS $$
    SELECT * FROM batch_event
    WHERE batch_id = p_batch_id AND event_id > coalesce(p_after_event_id, 0)
    ORDER BY event_id;
$$;

-- =============================================================================
-- Grants
--   <schema>_app : SELECT everything; INSERT/UPDATE only on working tables
--                  (raw_record via COPY, mappings, issues, templates, runs).
--                  ingestion_batch / batch_event change ONLY through the functions
--                  above, so the state machine can't be bypassed.
--   <schema>_ro  : SELECT only (dashboards, reports).
-- Domain-table grants are added in 05_domain_tables.sql.
-- =============================================================================
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA :"schema" FROM PUBLIC;
GRANT USAGE ON SCHEMA :"schema" TO :"rw_role", :"ro_role";
GRANT SELECT ON ALL TABLES IN SCHEMA :"schema" TO :"rw_role", :"ro_role";
GRANT INSERT, UPDATE ON :"schema".raw_record, :"schema".mapping_version, :"schema".validation_issue,
                         :"schema".template_version, :"schema".report_run TO :"rw_role";
GRANT USAGE ON ALL SEQUENCES IN SCHEMA :"schema" TO :"rw_role";
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA :"schema" TO :"rw_role";

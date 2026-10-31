-- =============================================================================
-- _assistant.sql  -  TEMPLATE, included once per product schema by
-- 07_smart_assistance.sql. Expects psql variable :schema. Do not run on its own.
--
-- What every product's Smart Assistance needs, whatever its data tools are:
--   assistant_conversation  context kept between turns (e.g. a pending clarification)
--   assistant_tool_run      one row per data-tool call = the result_reference users see
--   assistant_audit         one row per question: intent, tool, filters, outcome
-- Product-specific data tools (fn_tool_*) live in 07_smart_assistance.sql.
-- =============================================================================

\set rw_role :schema _app

CREATE TABLE :"schema".assistant_conversation (
    conversation_id  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id          uuid NOT NULL REFERENCES iam.app_user(user_id),
    state            jsonb NOT NULL DEFAULT '{}',     -- LangGraph state carried to the next turn
    created_at       timestamptz NOT NULL DEFAULT now(),
    updated_at       timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX ix_assistant_conversation_user ON :"schema".assistant_conversation(user_id, updated_at DESC);
CREATE TRIGGER trg_assistant_conversation_updated BEFORE UPDATE ON :"schema".assistant_conversation
    FOR EACH ROW EXECUTE FUNCTION iam.tg_set_updated_at();

CREATE TABLE :"schema".assistant_tool_run (
    run_id      uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id     uuid NOT NULL REFERENCES iam.app_user(user_id),
    tool_name   text NOT NULL,
    arguments   jsonb NOT NULL,
    created_at  timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE :"schema".assistant_audit (
    audit_id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    conversation_id   uuid REFERENCES :"schema".assistant_conversation(conversation_id) ON DELETE SET NULL,
    user_id           uuid NOT NULL REFERENCES iam.app_user(user_id),
    question          text NOT NULL,
    intent            text,
    tool_name         text,
    arguments         jsonb,
    reporting_period  text,
    result_reference  uuid REFERENCES :"schema".assistant_tool_run(run_id),
    outcome           text NOT NULL CHECK (outcome IN ('ANSWERED','CLARIFICATION','REFUSED','ERROR')),
    created_at        timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX ix_assistant_audit_user ON :"schema".assistant_audit(user_id, created_at DESC);

-- -----------------------------------------------------------------------------
-- Internal: authorize a data-tool call and record it. Every fn_tool_* calls this
-- first, so a tool can't run for someone without dashboard.view plus assistant.use
-- (chat) or report.generate (reports, 09_reports_templates.sql) in this product,
-- however the backend was called. Returns the run id.
-- -----------------------------------------------------------------------------
CREATE FUNCTION :"schema"._assistant_begin(p_user_id uuid, p_tool text, p_arguments jsonb) RETURNS uuid
LANGUAGE plpgsql SET search_path = :"schema", public, pg_temp AS $$
DECLARE
    v_app text := (SELECT code FROM iam.app WHERE schema_name = current_schema());
    v_run uuid;
BEGIN
    IF NOT ((iam.fn_has_permission(p_user_id, v_app, 'assistant.use')
             OR iam.fn_has_permission(p_user_id, v_app, 'report.generate'))
            AND iam.fn_has_permission(p_user_id, v_app, 'dashboard.view')) THEN
        RAISE EXCEPTION 'Not allowed to use Smart Assistance in %', v_app USING ERRCODE = '42501';
    END IF;
    INSERT INTO assistant_tool_run (user_id, tool_name, arguments)
    VALUES (p_user_id, p_tool, p_arguments) RETURNING run_id INTO v_run;
    RETURN v_run;
END $$;

-- Internal: reject reversed or unbounded periods before any query runs.
CREATE FUNCTION :"schema"._assistant_check_period(p_start date, p_end date) RETURNS void
LANGUAGE plpgsql IMMUTABLE AS $$
BEGIN
    IF p_start IS NULL OR p_end IS NULL THEN
        RAISE EXCEPTION 'start_date and end_date are required' USING ERRCODE = '22023';
    END IF;
    IF p_end < p_start THEN
        RAISE EXCEPTION 'end_date is before start_date' USING ERRCODE = '22023';
    END IF;
    IF p_end - p_start > 3660 THEN
        RAISE EXCEPTION 'Period longer than 10 years' USING ERRCODE = '22023';
    END IF;
END $$;

-- -----------------------------------------------------------------------------
-- Conversation context. A user only ever sees their own conversations.
-- -----------------------------------------------------------------------------

-- Save the state for the next turn; NULL id starts a new conversation. Returns the id.
CREATE FUNCTION :"schema".sp_assistant_save_conversation(p_user_id uuid, p_conversation_id uuid, p_state jsonb)
RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = :"schema", public, pg_temp AS $$
DECLARE
    v_app text := (SELECT code FROM iam.app WHERE schema_name = current_schema());
    v_id uuid;
BEGIN
    IF NOT iam.fn_has_permission(p_user_id, v_app, 'assistant.use') THEN
        RAISE EXCEPTION 'Not allowed to use Smart Assistance in %', v_app USING ERRCODE = '42501';
    END IF;
    IF p_conversation_id IS NULL THEN
        INSERT INTO assistant_conversation (user_id, state) VALUES (p_user_id, coalesce(p_state, '{}'))
        RETURNING conversation_id INTO v_id;
        RETURN v_id;
    END IF;
    UPDATE assistant_conversation SET state = coalesce(p_state, '{}')
    WHERE conversation_id = p_conversation_id AND user_id = p_user_id
    RETURNING conversation_id INTO v_id;
    IF v_id IS NULL THEN
        RAISE EXCEPTION 'Conversation % not found', p_conversation_id USING ERRCODE = 'P0002';
    END IF;
    RETURN v_id;
END $$;

-- State saved by the previous turn ('{}' for a new conversation id that isn't ours).
CREATE FUNCTION :"schema".fn_assistant_get_conversation(p_user_id uuid, p_conversation_id uuid) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = :"schema", public, pg_temp AS $$
DECLARE
    v_state jsonb;
BEGIN
    SELECT state INTO v_state FROM assistant_conversation
    WHERE conversation_id = p_conversation_id AND user_id = p_user_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Conversation % not found', p_conversation_id USING ERRCODE = 'P0002';
    END IF;
    RETURN v_state;
END $$;

-- One audit row per question. result_reference must be this user's own tool run.
CREATE FUNCTION :"schema".sp_assistant_audit(
    p_user_id uuid, p_conversation_id uuid, p_question text, p_intent text, p_tool_name text,
    p_arguments jsonb, p_reporting_period text, p_result_reference uuid, p_outcome text
) RETURNS bigint
LANGUAGE plpgsql SECURITY DEFINER SET search_path = :"schema", public, pg_temp AS $$
DECLARE
    v_id bigint;
BEGIN
    IF p_result_reference IS NOT NULL AND NOT EXISTS (
           SELECT 1 FROM assistant_tool_run WHERE run_id = p_result_reference AND user_id = p_user_id) THEN
        RAISE EXCEPTION 'Unknown result reference' USING ERRCODE = '22023';
    END IF;
    INSERT INTO assistant_audit (conversation_id, user_id, question, intent, tool_name, arguments,
                                 reporting_period, result_reference, outcome)
    VALUES (p_conversation_id, p_user_id, left(p_question, 2000), p_intent, p_tool_name, p_arguments,
            p_reporting_period, p_result_reference, upper(p_outcome))
    RETURNING audit_id INTO v_id;
    RETURN v_id;
END $$;

-- Wraps a tool's numbers in the result contract the assistant explains
-- (docs_ai/02 § Tool result contract).
CREATE FUNCTION :"schema"._assistant_result(
    p_run uuid, p_period text, p_filters jsonb, p_definitions jsonb,
    p_kpis jsonb, p_chart jsonb, p_rows jsonb
) RETURNS jsonb
LANGUAGE sql STABLE AS $$
    SELECT jsonb_build_object(
        'result_reference',   p_run,
        'product',            lower((SELECT code FROM iam.app WHERE schema_name = current_schema())),
        'reporting_period',   p_period,
        'filters',            jsonb_strip_nulls(coalesce(p_filters, '{}')),
        'metric_definitions', coalesce(p_definitions, '[]'),
        'kpis',               coalesce(p_kpis, '{}'),
        'chart_data',         coalesce(p_chart, '[]'),
        'supporting_rows',    coalesce(p_rows, '[]'));
$$;

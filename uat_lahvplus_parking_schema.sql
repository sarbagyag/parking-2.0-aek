--
-- PostgreSQL database dump
--

\restrict 5HotnVPTayeJwjkbmJmvkfIdkUuuThxX5bsUXNVa6QlCZRgZebGWDuCRX7YqGTR

-- Dumped from database version 15.17
-- Dumped by pg_dump version 16.15 (Homebrew)

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Name: readyset; Type: SCHEMA; Schema: -; Owner: -
--

CREATE SCHEMA readyset;


--
-- Name: pg_trgm; Type: EXTENSION; Schema: -; Owner: -
--

CREATE EXTENSION IF NOT EXISTS pg_trgm WITH SCHEMA public;


--
-- Name: EXTENSION pg_trgm; Type: COMMENT; Schema: -; Owner: -
--

COMMENT ON EXTENSION pg_trgm IS 'text similarity measurement and index searching based on trigrams';


--
-- Name: uuid-ossp; Type: EXTENSION; Schema: -; Owner: -
--

CREATE EXTENSION IF NOT EXISTS "uuid-ossp" WITH SCHEMA public;


--
-- Name: EXTENSION "uuid-ossp"; Type: COMMENT; Schema: -; Owner: -
--

COMMENT ON EXTENSION "uuid-ossp" IS 'generate universally unique identifiers (UUIDs)';


--
-- Name: is_pre14(); Type: FUNCTION; Schema: readyset; Owner: -
--

CREATE FUNCTION readyset.is_pre14() RETURNS boolean
    LANGUAGE plpgsql
    AS $$
    DECLARE ver integer;
BEGIN
    SELECT current_setting('server_version_num') INTO ver;
    RETURN ver < 140000;
END $$;


--
-- Name: pre_alter_type(); Type: FUNCTION; Schema: readyset; Owner: -
--

CREATE FUNCTION readyset.pre_alter_type() RETURNS event_trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  -- PostgreSQL doesn't give us any information about *which* types are being
  -- modified in `ddl_command_start`, so we just put all variants for all enums
  -- in a temp table, under the assumption that (hopefully) there aren't going
  -- to be that many in practice
  CREATE TEMP TABLE pg_enum_original
  AS SELECT * FROM pg_catalog.pg_enum;
END $$;


--
-- Name: replicate_alter_table(); Type: FUNCTION; Schema: readyset; Owner: -
--

CREATE FUNCTION readyset.replicate_alter_table() RETURNS event_trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
    alter_message text;
    query text;
BEGIN
    IF coalesce(
        nullif(
            current_setting(
                'readyset.current_command_is_replica_identity',
                true
            ),
            ''
        )::boolean,
        false
    ) THEN
        RETURN;
    END IF;

    SELECT current_query() INTO query;

    SELECT
    json_build_object(
        'schema', object.schema_name,
        'data', json_build_object(
            'AlterTable',
            json_build_object(
                'name', cls.relname,
                'statement', query
            )
        )
    )
    INTO alter_message
    FROM pg_event_trigger_ddl_commands() object
    JOIN pg_class cls ON object.objid = cls.oid
    WHERE object.object_type in ('table', 'table column');

    IF readyset.is_pre14() THEN
        UPDATE readyset.ddl_replication_log SET "ddl" = alter_message;
    ELSE
        PERFORM pg_logical_emit_message(true, 'readyset', alter_message);
    END IF;
END $$;


--
-- Name: replicate_alter_type(); Type: FUNCTION; Schema: readyset; Owner: -
--

CREATE FUNCTION readyset.replicate_alter_type() RETURNS event_trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
    alter_message text;
BEGIN
    SELECT
        json_build_object(
            'schema', object.schema_name,
            'data', json_build_object('AlterType', json_build_object(
                'name', t.typname,
                'oid', t.oid::INT,
                'variants', json_agg(json_build_object(
                    'oid', e.oid::int,
                    'label', e.enumlabel
                ) ORDER BY e.enumsortorder ASC),
                'original_variants', (SELECT json_agg(json_build_object(
                    'oid', e_orig.oid::int,
                    'label', e_orig.enumlabel
                ) ORDER BY e_orig.enumsortorder ASC)
                FROM pg_enum_original e_orig
                WHERE e_orig.enumtypid = t.oid)
            ))
        )
    INTO alter_message
    FROM pg_event_trigger_ddl_commands() object
    JOIN pg_catalog.pg_type t
      ON t.oid = object.objid
    JOIN pg_catalog.pg_enum e
      ON e.enumtypid = t.oid
    GROUP BY object.objid, object.schema_name, t.oid, t.typname;

    DROP TABLE pg_enum_original;

    IF readyset.is_pre14() THEN
        UPDATE readyset.ddl_replication_log SET "ddl" = alter_message;
    ELSE
        PERFORM pg_logical_emit_message(true, 'readyset', alter_message);
    END IF;
END $$;


--
-- Name: replicate_create_table(); Type: FUNCTION; Schema: readyset; Owner: -
--

CREATE FUNCTION readyset.replicate_create_table() RETURNS event_trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
    create_message text;
    needs_replica_identity bool;
    alter_stmt record;
BEGIN
    SELECT count(*) = 0
    INTO needs_replica_identity
    FROM pg_index i
    JOIN pg_event_trigger_ddl_commands() o ON i.indrelid = o.objid
    JOIN pg_class c ON o.objid = c.oid
    WHERE i.indisprimary
    AND c.relreplident = 'd'
    AND o.object_type = 'table'
    AND o.schema_name != 'pg_temp';

    IF needs_replica_identity THEN
        -- Prevent our ALTER TABLE trigger from running on this command
        SET LOCAL readyset.current_command_is_replica_identity TO true;
        FOR alter_stmt IN
            SELECT format(
                'ALTER TABLE "%s"."%s" REPLICA IDENTITY FULL',
                object.schema_name, cls.relname
            ) AS stmt
            FROM pg_event_trigger_ddl_commands() object
            JOIN pg_class cls
            ON oid = object.objid
            -- CREATE TABLE statements can also create all other kinds of
            -- rows in pg_class, eg sequences for `SERIAL` columns or foreign
            -- key constraints. We only want to set replica identities on those
            -- rows in pg_class that're actual *tables*
            WHERE cls.relkind = 'r'
        LOOP
          EXECUTE alter_stmt.stmt;
        END LOOP;
        SET LOCAL readyset.current_command_is_replica_identity TO false;
    END IF;

    SELECT
    CASE cls.relkind
    WHEN 'r' THEN
        json_build_object(
            'schema', object.schema_name,
            'data', json_build_object('CreateTable', json_build_object(
                -- OID->json makes a string by default, so cast to bigint
                'oid', cls.oid::bigint,
                'name', cls.relname,
                'columns', (
                    SELECT json_agg(json_build_object(
                        'attnum', attr.attnum,
                        'name', attr.attname,
                        'column_type', pg_catalog.format_type(
                            attr.atttypid,
                            attr.atttypmod
                        ),
                        'not_null', attr.attnotnull
                    ) ORDER BY attr.attnum)
                    FROM pg_catalog.pg_attribute attr
                    WHERE attr.attrelid = object.objid
                    AND attr.attnum > 0
                    AND NOT attr.attisdropped
                ),
                'constraints', (
                    SELECT coalesce(
                        json_agg(json_build_object('definition', def)),
                        '[]'
                    )
                    FROM (
                        SELECT DISTINCT
                            pg_catalog.pg_get_constraintdef(con.oid, TRUE) AS def
                        FROM
                            pg_catalog.pg_class cls_index,
                            pg_catalog.pg_index idx
                        LEFT JOIN pg_catalog.pg_constraint con
                            ON con.conrelid = idx.indrelid
                            AND con.conindid = idx.indexrelid
                            AND con.contype IN ('f', 'p', 'u')
                        WHERE cls.oid = object.objid
                            AND cls.oid = idx.indrelid
                            AND idx.indexrelid = cls_index.oid
                            AND pg_catalog.pg_get_constraintdef(con.oid, TRUE)
                                IS NOT NULL
                    ) def
                )
            ))
        )
    WHEN 'p' THEN
         json_build_object(
            'schema', object.schema_name,
            'data', json_build_object('AddNonReplicatedTable', json_build_object(
                'name', cls.relname
            ))
         )
    END
    INTO create_message
    FROM pg_event_trigger_ddl_commands() object
    JOIN pg_class cls ON object.objid = cls.oid
    WHERE object.object_type = 'table'
    AND object.schema_name != 'pg_temp'
    AND cls.relkind in ('r', 'p');

    IF readyset.is_pre14() THEN
        UPDATE readyset.ddl_replication_log SET "ddl" = create_message;
    ELSE
        PERFORM pg_logical_emit_message(true, 'readyset', create_message);
    END IF;
END $$;


--
-- Name: replicate_create_type(); Type: FUNCTION; Schema: readyset; Owner: -
--

CREATE FUNCTION readyset.replicate_create_type() RETURNS event_trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
    create_message text;
BEGIN
    SELECT
        json_build_object(
            'schema', schema_name,
            'data', json_build_object('CreateType', json_build_object(
                'oid', t.oid::int,
                'array_oid', t.typarray::int,
                'name', t.typname,
                'variants', json_agg(json_build_object(
                    'oid', e.oid::int,
                    'label', e.enumlabel
                ) ORDER BY e.enumsortorder ASC)
            ))
        )
    INTO create_message
    FROM pg_event_trigger_ddl_commands() object
    JOIN pg_catalog.pg_type t
      ON t.oid = object.objid
    JOIN pg_catalog.pg_enum e
      ON e.enumtypid = t.oid
    GROUP BY object.objid, object.schema_name, t.oid, t.typname, t.typarray;

    IF readyset.is_pre14() THEN
        UPDATE readyset.ddl_replication_log SET "ddl" = create_message;
    ELSE
        PERFORM pg_logical_emit_message(true, 'readyset', create_message);
    END IF;
END $$;


--
-- Name: replicate_create_view(); Type: FUNCTION; Schema: readyset; Owner: -
--

CREATE FUNCTION readyset.replicate_create_view() RETURNS event_trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
    create_message text;
BEGIN
    SELECT
    json_build_object(
        'schema', object.schema_name,
        'data', json_build_object('CreateView', format(
            'CREATE VIEW "%s"."%s" AS %s',
            v.schemaname,
            cls.relname,
            v.definition
        ))
    )
    INTO create_message
    FROM pg_event_trigger_ddl_commands() object
    JOIN pg_catalog.pg_class cls ON object.objid = cls.oid
    JOIN pg_catalog.pg_views v
         ON object.schema_name = v.schemaname
         AND cls.relname = v.viewname
    WHERE object.object_type = 'view';

    IF readyset.is_pre14() THEN
        UPDATE readyset.ddl_replication_log SET "ddl" = create_message;
    ELSE
        PERFORM pg_logical_emit_message(true, 'readyset', create_message);
    END IF;
END $$;


--
-- Name: replicate_drop(); Type: FUNCTION; Schema: readyset; Owner: -
--

CREATE FUNCTION readyset.replicate_drop() RETURNS event_trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
    drop_message text;
BEGIN
    SELECT
    json_build_object(
        'schema', schema_name,
        'data', json_build_object('Drop', object_name)
    )
    INTO drop_message
    FROM pg_event_trigger_dropped_objects()
    WHERE object_type IN ('table', 'view', 'type')
    AND schema_name != 'pg_temp';

    IF readyset.is_pre14() THEN
        UPDATE readyset.ddl_replication_log SET "ddl" = drop_message;
    ELSE
        PERFORM pg_logical_emit_message(true, 'readyset', drop_message);
    END IF;
END $$;


SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: addresses; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.addresses (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    deleted_at timestamp with time zone,
    parking_area_id uuid,
    user_id text,
    logitude text,
    latitude text,
    model text,
    type text,
    country text,
    state text,
    city text,
    street text,
    zip_code text,
    labels text,
    tags text,
    addressa text,
    addressb text,
    partner_id uuid
);


--
-- Name: audit_logs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.audit_logs (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    deleted_at timestamp with time zone,
    title text,
    parking_area_id text,
    user_id text,
    action text,
    performed_by text,
    data text,
    details text,
    remarks text,
    is_active boolean,
    partner_id text,
    extras jsonb,
    module text
);


--
-- Name: bookings; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.bookings (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    deleted_at timestamp with time zone,
    user_id text,
    parking_area_id uuid,
    lot_id text,
    vehicle_id uuid,
    start_time timestamp with time zone,
    end_time timestamp with time zone,
    estimated_hour bigint,
    is_notify boolean,
    is_booking_active boolean,
    estimated_time text,
    payment_status text,
    payment_method text,
    status text DEFAULT 'pending'::text,
    reason text,
    rate numeric DEFAULT 0,
    amount numeric DEFAULT 0
);


--
-- Name: business_hours; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.business_hours (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    deleted_at timestamp with time zone,
    user_id uuid NOT NULL,
    hours jsonb NOT NULL
);


--
-- Name: capacities; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.capacities (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    deleted_at timestamp with time zone,
    vehicle_type text,
    parking_area_id uuid,
    quantity bigint,
    unit bigint,
    labels text,
    tags text,
    is_supported boolean,
    is_active boolean,
    vehicle_category text
);


--
-- Name: contacts; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.contacts (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    deleted_at timestamp with time zone,
    name text,
    parking_area_id uuid,
    user_id text,
    type text,
    code text,
    number text,
    username text,
    url text,
    logo text,
    is_active boolean,
    data text,
    partner_id uuid
);


--
-- Name: coupon_redemptions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.coupon_redemptions (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    deleted_at timestamp with time zone,
    coupon_id uuid NOT NULL,
    user_id text NOT NULL,
    invoice_id text NOT NULL,
    waiver_id text,
    status text NOT NULL,
    applied_at timestamp with time zone,
    unapplied_at timestamp with time zone
);


--
-- Name: coupons; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.coupons (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    deleted_at timestamp with time zone,
    partner_id text NOT NULL,
    code text NOT NULL,
    description text,
    expiry timestamp with time zone,
    usage_max bigint DEFAULT 0,
    usage_count bigint DEFAULT 0,
    is_active boolean DEFAULT true,
    apply_anywhere boolean DEFAULT false,
    discount numeric DEFAULT 0,
    max_time bigint DEFAULT 0,
    max_amount numeric DEFAULT 0,
    allow_multiple_usage boolean DEFAULT false
);


--
-- Name: feedbacks; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.feedbacks (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    deleted_at timestamp with time zone,
    title text,
    parking_area_id text,
    user_id text,
    rating bigint,
    comments text,
    is_publish boolean,
    is_active boolean
);


--
-- Name: generic_key_values; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.generic_key_values (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    deleted_at timestamp with time zone,
    type text,
    key_value jsonb
);


--
-- Name: images; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.images (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    deleted_at timestamp with time zone,
    name text,
    path text,
    url text,
    size bigint,
    vehicle_id uuid,
    user_id text,
    parking_area_id uuid,
    status text,
    remarks text,
    tags text,
    labels text,
    is_hide boolean,
    partner_id uuid
);


--
-- Name: invoices; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.invoices (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    deleted_at timestamp with time zone,
    title text,
    user_id text,
    vehicle_id uuid,
    parking_area_id uuid,
    estimated_time text,
    duration numeric,
    rate numeric,
    payment_method text,
    amount numeric,
    discount numeric,
    tax numeric,
    total numeric,
    notes text,
    status text DEFAULT 'pending'::text,
    waiver_id uuid,
    payment_notes text,
    report_notes text,
    owner_name text,
    discount_percent numeric,
    created_by text,
    serial_no bigint,
    checkout_user text,
    extras jsonb,
    scanned_image text
);


--
-- Name: live_cams; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.live_cams (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    deleted_at timestamp with time zone,
    name text,
    parking_area_id text,
    url text,
    status text,
    is_active boolean
);


--
-- Name: members; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.members (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    deleted_at timestamp with time zone,
    membership_id uuid,
    user_id text,
    joined text,
    is_active boolean DEFAULT true,
    image text,
    name text,
    countrycode text,
    phone text,
    email text,
    expiry_time timestamp with time zone DEFAULT (now() + '1 year'::interval) NOT NULL,
    vehicle_ids text,
    notes text,
    extras jsonb
);


--
-- Name: membership_parkings; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.membership_parkings (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    deleted_at timestamp with time zone,
    membership_id text,
    parking_area_id text,
    weight bigint,
    labels text,
    tags text,
    is_active boolean DEFAULT true
);


--
-- Name: memberships; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.memberships (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    deleted_at timestamp with time zone,
    name text,
    partner_id text,
    description text,
    weight bigint,
    labels text,
    tags text,
    is_active boolean DEFAULT true
);


--
-- Name: modules; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.modules (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    deleted_at timestamp with time zone,
    name text NOT NULL,
    path text NOT NULL,
    method text NOT NULL,
    description text,
    is_active boolean DEFAULT true
);


--
-- Name: notifications; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.notifications (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    deleted_at timestamp with time zone,
    title character varying(255),
    subtitle text,
    type character varying(64),
    status character varying(64),
    receiver_id character varying(64),
    receiver jsonb,
    target jsonb,
    metadata jsonb,
    sender jsonb
);


--
-- Name: parking_areas; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.parking_areas (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    deleted_at timestamp with time zone,
    name text,
    location text,
    type text,
    description text,
    capacity bigint,
    open_time text,
    close_time text,
    status text DEFAULT 'pending'::text,
    labels text,
    tags text,
    key_word text,
    company_name text,
    own_by text,
    is_active boolean,
    user_id text,
    gps_lat numeric,
    gps_long numeric,
    enabled_booking boolean,
    adv_rate numeric,
    enabled_live_cam boolean,
    contact_phone text,
    contact_email text,
    pan_number text,
    extras jsonb
);


--
-- Name: parking_suggestions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.parking_suggestions (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    deleted_at timestamp with time zone,
    type text,
    key_value jsonb
);


--
-- Name: partner_parking_areas; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.partner_parking_areas (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    deleted_at timestamp with time zone,
    partner_id text,
    parking_area_id text,
    notes text,
    scheme text,
    status text,
    effectve_date timestamp with time zone,
    percentage numeric,
    max_amount numeric,
    max_duration bigint,
    reject_reason text,
    rule_name text
);


--
-- Name: partners; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.partners (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    deleted_at timestamp with time zone,
    name text,
    premise_name text,
    user_id text,
    location text,
    email text,
    gps_lat numeric,
    gps_long numeric,
    is_active boolean,
    status text DEFAULT 'pending'::text
);


--
-- Name: permissions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.permissions (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    deleted_at timestamp with time zone,
    module_id uuid NOT NULL,
    action text NOT NULL
);


--
-- Name: rates; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.rates (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    deleted_at timestamp with time zone,
    name text,
    vehicle_type text,
    parking_area_id uuid,
    rate numeric,
    currency_unit text,
    is_active boolean,
    free_hours bigint,
    threshold bigint,
    vehicle_category text,
    is_default boolean DEFAULT false,
    priority bigint DEFAULT 0,
    pricing_unit text DEFAULT 'hour'::text,
    window_start character varying(8),
    window_end character varying(8),
    days_of_week jsonb,
    months_of_year jsonb,
    duration_min_minutes bigint,
    duration_max_minutes bigint,
    metadata jsonb,
    pricing_mode text DEFAULT ''::text,
    reset_mode boolean,
    enable_free_rate boolean,
    free_min bigint,
    enable_change_rate boolean,
    change_rate bigint
);


--
-- Name: roles; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.roles (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    deleted_at timestamp with time zone,
    role text,
    user_id text,
    partner_id text,
    parking_area_id text,
    notes text,
    username text,
    email text,
    is_default boolean DEFAULT false,
    is_active boolean DEFAULT true
);


--
-- Name: roles_permissions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.roles_permissions (
    permission_id uuid DEFAULT gen_random_uuid() NOT NULL,
    role_id uuid DEFAULT gen_random_uuid() NOT NULL
);


--
-- Name: show_cases; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.show_cases (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    deleted_at timestamp with time zone,
    user_id text,
    show_case jsonb
);


--
-- Name: transactions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.transactions (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    deleted_at timestamp with time zone,
    invoice_id text,
    amount bigint,
    status text,
    user_id text,
    gateway text,
    gateway_response jsonb,
    gateway_init_response jsonb
);


--
-- Name: user_partner_assignments; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.user_partner_assignments (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id text NOT NULL,
    partner_id text NOT NULL,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    deleted_at timestamp with time zone
);


--
-- Name: user_roles; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.user_roles (
    role_id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid DEFAULT gen_random_uuid() NOT NULL
);


--
-- Name: user_settings; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.user_settings (
    user_id text,
    language text,
    notification jsonb,
    dark_mode boolean,
    show_case jsonb
);


--
-- Name: users; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.users (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    deleted_at timestamp with time zone,
    user_id text,
    user_type text,
    username text,
    full_name text,
    phone_number text,
    email text,
    license_number text,
    is_connect boolean,
    is_active boolean,
    parking_area_id text,
    invited_by text,
    partner_id text,
    status text DEFAULT 'pending'::text,
    extras jsonb
);


--
-- Name: vehicle_timelines; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.vehicle_timelines (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    vehicle_id text NOT NULL,
    user_id text NOT NULL,
    activity_type text NOT NULL,
    occurred_at timestamp with time zone NOT NULL,
    title text,
    notes text,
    amount numeric,
    odometer text,
    quantity numeric,
    expires_at timestamp with time zone,
    attachments jsonb,
    extras jsonb
);


--
-- Name: vehicles; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.vehicles (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    deleted_at timestamp with time zone,
    name text,
    make text,
    plate_number text,
    type text,
    model text,
    color text,
    cc text,
    mfd_date text,
    engine_number text,
    fuel_type text,
    milage text,
    is_active boolean,
    user_id text,
    extras jsonb,
    vin text
);


--
-- Name: waivers; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.waivers (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    deleted_at timestamp with time zone,
    partner_id text,
    invoice_id text,
    remarks text,
    status text,
    partner_parking_area_id uuid,
    approved_by text,
    coupon_id text
);


--
-- Name: addresses addresses_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.addresses
    ADD CONSTRAINT addresses_pkey PRIMARY KEY (id);


--
-- Name: audit_logs audit_logs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.audit_logs
    ADD CONSTRAINT audit_logs_pkey PRIMARY KEY (id);


--
-- Name: bookings bookings_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.bookings
    ADD CONSTRAINT bookings_pkey PRIMARY KEY (id);


--
-- Name: business_hours business_hours_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.business_hours
    ADD CONSTRAINT business_hours_pkey PRIMARY KEY (id);


--
-- Name: capacities capacities_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.capacities
    ADD CONSTRAINT capacities_pkey PRIMARY KEY (id);


--
-- Name: contacts contacts_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.contacts
    ADD CONSTRAINT contacts_pkey PRIMARY KEY (id);


--
-- Name: coupon_redemptions coupon_redemptions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.coupon_redemptions
    ADD CONSTRAINT coupon_redemptions_pkey PRIMARY KEY (id);


--
-- Name: coupons coupons_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.coupons
    ADD CONSTRAINT coupons_pkey PRIMARY KEY (id);


--
-- Name: feedbacks feedbacks_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.feedbacks
    ADD CONSTRAINT feedbacks_pkey PRIMARY KEY (id);


--
-- Name: generic_key_values generic_key_values_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.generic_key_values
    ADD CONSTRAINT generic_key_values_pkey PRIMARY KEY (id);


--
-- Name: images images_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.images
    ADD CONSTRAINT images_pkey PRIMARY KEY (id);


--
-- Name: invoices invoices_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.invoices
    ADD CONSTRAINT invoices_pkey PRIMARY KEY (id);


--
-- Name: live_cams live_cams_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.live_cams
    ADD CONSTRAINT live_cams_pkey PRIMARY KEY (id);


--
-- Name: members members_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.members
    ADD CONSTRAINT members_pkey PRIMARY KEY (id);


--
-- Name: membership_parkings membership_parkings_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.membership_parkings
    ADD CONSTRAINT membership_parkings_pkey PRIMARY KEY (id);


--
-- Name: memberships memberships_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.memberships
    ADD CONSTRAINT memberships_pkey PRIMARY KEY (id);


--
-- Name: modules modules_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.modules
    ADD CONSTRAINT modules_pkey PRIMARY KEY (id);


--
-- Name: notifications notifications_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.notifications
    ADD CONSTRAINT notifications_pkey PRIMARY KEY (id);


--
-- Name: parking_areas parking_areas_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.parking_areas
    ADD CONSTRAINT parking_areas_pkey PRIMARY KEY (id);


--
-- Name: parking_suggestions parking_suggestions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.parking_suggestions
    ADD CONSTRAINT parking_suggestions_pkey PRIMARY KEY (id);


--
-- Name: partner_parking_areas partner_parking_areas_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.partner_parking_areas
    ADD CONSTRAINT partner_parking_areas_pkey PRIMARY KEY (id);


--
-- Name: partners partners_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.partners
    ADD CONSTRAINT partners_pkey PRIMARY KEY (id);


--
-- Name: permissions permissions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.permissions
    ADD CONSTRAINT permissions_pkey PRIMARY KEY (id);


--
-- Name: rates rates_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rates
    ADD CONSTRAINT rates_pkey PRIMARY KEY (id);


--
-- Name: roles_permissions roles_permissions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.roles_permissions
    ADD CONSTRAINT roles_permissions_pkey PRIMARY KEY (permission_id, role_id);


--
-- Name: roles roles_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.roles
    ADD CONSTRAINT roles_pkey PRIMARY KEY (id);


--
-- Name: show_cases show_cases_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.show_cases
    ADD CONSTRAINT show_cases_pkey PRIMARY KEY (id);


--
-- Name: transactions transactions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.transactions
    ADD CONSTRAINT transactions_pkey PRIMARY KEY (id);


--
-- Name: vehicles uni_vehicles_plate_number; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.vehicles
    ADD CONSTRAINT uni_vehicles_plate_number UNIQUE (plate_number);


--
-- Name: user_partner_assignments user_partner_assignments_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_partner_assignments
    ADD CONSTRAINT user_partner_assignments_pkey PRIMARY KEY (id);


--
-- Name: user_roles user_roles_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_roles
    ADD CONSTRAINT user_roles_pkey PRIMARY KEY (role_id, user_id);


--
-- Name: users users_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.users
    ADD CONSTRAINT users_pkey PRIMARY KEY (id);


--
-- Name: vehicle_timelines vehicle_timelines_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.vehicle_timelines
    ADD CONSTRAINT vehicle_timelines_pkey PRIMARY KEY (id);


--
-- Name: vehicles vehicles_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.vehicles
    ADD CONSTRAINT vehicles_pkey PRIMARY KEY (id);


--
-- Name: waivers waivers_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.waivers
    ADD CONSTRAINT waivers_pkey PRIMARY KEY (id);


--
-- Name: idx_bookings_deleted_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_bookings_deleted_at ON public.bookings USING btree (deleted_at);


--
-- Name: idx_business_hours_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_business_hours_user_id ON public.business_hours USING btree (user_id);


--
-- Name: idx_capacities_deleted_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_capacities_deleted_at ON public.capacities USING btree (deleted_at);


--
-- Name: idx_capacities_parking_area_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_capacities_parking_area_id ON public.capacities USING btree (parking_area_id);


--
-- Name: idx_coupon_partner_code; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_coupon_partner_code ON public.coupons USING btree (partner_id, code);


--
-- Name: idx_coupon_redemptions_coupon_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_coupon_redemptions_coupon_id ON public.coupon_redemptions USING btree (coupon_id);


--
-- Name: idx_coupon_redemptions_invoice_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_coupon_redemptions_invoice_id ON public.coupon_redemptions USING btree (invoice_id);


--
-- Name: idx_coupon_redemptions_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_coupon_redemptions_status ON public.coupon_redemptions USING btree (status);


--
-- Name: idx_coupon_redemptions_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_coupon_redemptions_user_id ON public.coupon_redemptions USING btree (user_id);


--
-- Name: idx_invoices_deleted_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_invoices_deleted_at ON public.invoices USING btree (deleted_at);


--
-- Name: idx_modules_name; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_modules_name ON public.modules USING btree (name);


--
-- Name: idx_parking_areas_deleted_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_parking_areas_deleted_at ON public.parking_areas USING btree (deleted_at);


--
-- Name: idx_partners_deleted_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_partners_deleted_at ON public.partners USING btree (deleted_at);


--
-- Name: idx_rates_deleted_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_rates_deleted_at ON public.rates USING btree (deleted_at);


--
-- Name: idx_rates_parking_area_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_rates_parking_area_id ON public.rates USING btree (parking_area_id);


--
-- Name: idx_upa_deleted_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_upa_deleted_at ON public.user_partner_assignments USING btree (deleted_at);


--
-- Name: idx_upa_partner_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_upa_partner_id ON public.user_partner_assignments USING btree (partner_id);


--
-- Name: idx_upa_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_upa_user_id ON public.user_partner_assignments USING btree (user_id);


--
-- Name: idx_users_deleted_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_users_deleted_at ON public.users USING btree (deleted_at);


--
-- Name: idx_users_email_unique; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_users_email_unique ON public.users USING btree (email) WHERE ((email IS NOT NULL) AND (email <> ''::text));


--
-- Name: idx_users_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_users_user_id ON public.users USING btree (user_id) WHERE ((user_id IS NOT NULL) AND (user_id <> ''::text));


--
-- Name: idx_vehicle_timelines_activity_type; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_vehicle_timelines_activity_type ON public.vehicle_timelines USING btree (activity_type);


--
-- Name: idx_vehicle_timelines_occurred_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_vehicle_timelines_occurred_at ON public.vehicle_timelines USING btree (occurred_at);


--
-- Name: idx_vehicle_timelines_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_vehicle_timelines_user_id ON public.vehicle_timelines USING btree (user_id);


--
-- Name: idx_vehicle_timelines_vehicle_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_vehicle_timelines_vehicle_id ON public.vehicle_timelines USING btree (vehicle_id);


--
-- Name: readyset_pre_alter_type; Type: EVENT TRIGGER; Schema: -; Owner: -
--

CREATE EVENT TRIGGER readyset_pre_alter_type ON ddl_command_start
         WHEN TAG IN ('ALTER TYPE')
   EXECUTE FUNCTION readyset.pre_alter_type();


--
-- Name: readyset_replicate_alter_table; Type: EVENT TRIGGER; Schema: -; Owner: -
--

CREATE EVENT TRIGGER readyset_replicate_alter_table ON ddl_command_end
         WHEN TAG IN ('ALTER TABLE')
   EXECUTE FUNCTION readyset.replicate_alter_table();


--
-- Name: readyset_replicate_alter_type; Type: EVENT TRIGGER; Schema: -; Owner: -
--

CREATE EVENT TRIGGER readyset_replicate_alter_type ON ddl_command_end
         WHEN TAG IN ('ALTER TYPE')
   EXECUTE FUNCTION readyset.replicate_alter_type();


--
-- Name: readyset_replicate_create_table; Type: EVENT TRIGGER; Schema: -; Owner: -
--

CREATE EVENT TRIGGER readyset_replicate_create_table ON ddl_command_end
         WHEN TAG IN ('CREATE TABLE')
   EXECUTE FUNCTION readyset.replicate_create_table();


--
-- Name: readyset_replicate_create_type; Type: EVENT TRIGGER; Schema: -; Owner: -
--

CREATE EVENT TRIGGER readyset_replicate_create_type ON ddl_command_end
         WHEN TAG IN ('CREATE TYPE')
   EXECUTE FUNCTION readyset.replicate_create_type();


--
-- Name: readyset_replicate_create_view; Type: EVENT TRIGGER; Schema: -; Owner: -
--

CREATE EVENT TRIGGER readyset_replicate_create_view ON ddl_command_end
         WHEN TAG IN ('CREATE VIEW')
   EXECUTE FUNCTION readyset.replicate_create_view();


--
-- Name: readyset_replicate_drop; Type: EVENT TRIGGER; Schema: -; Owner: -
--

CREATE EVENT TRIGGER readyset_replicate_drop ON sql_drop
         WHEN TAG IN ('DROP TABLE', 'DROP VIEW', 'DROP TYPE')
   EXECUTE FUNCTION readyset.replicate_drop();


--
-- PostgreSQL database dump complete
--

\unrestrict 5HotnVPTayeJwjkbmJmvkfIdkUuuThxX5bsUXNVa6QlCZRgZebGWDuCRX7YqGTR


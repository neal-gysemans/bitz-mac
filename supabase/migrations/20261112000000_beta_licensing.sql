-- ============================================================================
-- Migration: 20261112000000_beta_licensing.sql
-- Description: Temporary Supabase Backend & Key Lifecycle for Bitz Public Beta
-- Issue: #146 (refs #144, #146)
-- Invariants: Strict RLS, SECURITY DEFINER functions with search_path hardening,
--             2-device hardware cap, customer email collection & export view.
-- ============================================================================

-- Enable required extensions
CREATE EXTENSION IF NOT EXISTS "pgcrypto";

-- ----------------------------------------------------------------------------
-- 1. Table: licenses
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.licenses (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    license_key TEXT UNIQUE NOT NULL,
    license_type TEXT NOT NULL DEFAULT 'beta' CHECK (license_type IN ('beta', 'lifetime', 'subscription')),
    status TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'expired', 'revoked')),
    max_devices INT NOT NULL DEFAULT 2 CHECK (max_devices > 0),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    expires_at TIMESTAMPTZ,
    customer_email TEXT CHECK (customer_email IS NULL OR customer_email ~* '^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$'),
    email_updated_at TIMESTAMPTZ
);

COMMENT ON TABLE public.licenses IS 'Bitz license registry. Stores Beta and commercial license keys, status, and linked user emails.';

-- Partial index for fast cron expiration sweeps
CREATE INDEX IF NOT EXISTS idx_licenses_active_expiring 
    ON public.licenses (expires_at) 
    WHERE status = 'active' AND expires_at IS NOT NULL;

-- Partial index for customer email lookups and post-beta export
CREATE INDEX IF NOT EXISTS idx_licenses_customer_email 
    ON public.licenses (customer_email) 
    WHERE customer_email IS NOT NULL;

-- ----------------------------------------------------------------------------
-- 2. Table: license_activations
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.license_activations (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    license_id UUID NOT NULL REFERENCES public.licenses(id) ON DELETE CASCADE,
    device_id TEXT NOT NULL,
    device_name TEXT,
    activated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    last_validated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT uq_license_activations_license_device UNIQUE (license_id, device_id)
);

COMMENT ON TABLE public.license_activations IS 'Hardware device activations bound to a license. device_id is a salted SHA-256 hash of the Mac IOPlatformUUID.';

-- Foreign key & hardware lookup indexes
CREATE INDEX IF NOT EXISTS idx_license_activations_license_id 
    ON public.license_activations(license_id);

CREATE INDEX IF NOT EXISTS idx_license_activations_device_id 
    ON public.license_activations(device_id);

-- ----------------------------------------------------------------------------
-- 3. Row Level Security (RLS) & Role Privileges
-- ----------------------------------------------------------------------------
ALTER TABLE public.licenses ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.license_activations ENABLE ROW LEVEL SECURITY;

-- Block direct API queries; all client operations execute via secure SECURITY DEFINER RPCs
REVOKE ALL ON TABLE public.licenses FROM anon, authenticated;
REVOKE ALL ON TABLE public.license_activations FROM anon, authenticated;

-- ----------------------------------------------------------------------------
-- 4. Helper Function: Generate Beta Key
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.generate_beta_key()
RETURNS TEXT
LANGUAGE sql
AS $$
    SELECT 'BTZ-BETA-' || UPPER(SUBSTRING(REPLACE(gen_random_uuid()::text, '-', '') FROM 1 FOR 4)) || '-' || UPPER(SUBSTRING(REPLACE(gen_random_uuid()::text, '-', '') FROM 5 FOR 4));
$$;

-- ----------------------------------------------------------------------------
-- 5. RPC: activate_beta_license
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.activate_beta_license(
    p_device_id TEXT,
    p_device_name TEXT,
    p_customer_email TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_clean_email TEXT;
    v_existing_activation RECORD;
    v_license RECORD;
    v_device_count INT;
    v_new_key TEXT;
    v_sunset_date TIMESTAMPTZ;
BEGIN
    IF p_device_id IS NULL OR TRIM(p_device_id) = '' THEN
        RETURN jsonb_build_object('valid', false, 'error', 'missing_device_id');
    END IF;

    -- Normalize email if provided
    IF p_customer_email IS NOT NULL AND TRIM(p_customer_email) <> '' THEN
        v_clean_email := LOWER(TRIM(p_customer_email));
        IF v_clean_email !~* '^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$' THEN
            RETURN jsonb_build_object('valid', false, 'error', 'invalid_email_format');
        END IF;
    ELSE
        v_clean_email := NULL;
    END IF;

    -- 1. Check if this device is ALREADY activated under an active Beta license
    SELECT a.*, l.license_key, l.status, l.expires_at, l.customer_email
    INTO v_existing_activation
    FROM public.license_activations a
    JOIN public.licenses l ON l.id = a.license_id
    WHERE a.device_id = p_device_id AND l.license_type = 'beta' AND l.status = 'active'
    ORDER BY a.activated_at DESC
    LIMIT 1;

    IF FOUND THEN
        -- Update last validation heartbeat
        UPDATE public.license_activations 
        SET last_validated_at = NOW(),
            device_name = COALESCE(NULLIF(TRIM(p_device_name), ''), device_name)
        WHERE id = v_existing_activation.id;

        -- Update customer email if provided and not yet attached
        IF v_clean_email IS NOT NULL AND (v_existing_activation.customer_email IS NULL OR v_existing_activation.customer_email <> v_clean_email) THEN
            UPDATE public.licenses 
            SET customer_email = v_clean_email,
                email_updated_at = NOW()
            WHERE id = v_existing_activation.license_id;
        END IF;

        RETURN jsonb_build_object(
            'valid', true,
            'tier', 'pro',
            'license_key', v_existing_activation.license_key,
            'status', v_existing_activation.status,
            'expires_at', v_existing_activation.expires_at,
            'customer_email', COALESCE(v_clean_email, v_existing_activation.customer_email)
        );
    END IF;

    -- 2. Check global seat cap (max 5,000 Beta keys to prevent abuse)
    IF (SELECT COUNT(*) FROM public.licenses WHERE license_type = 'beta') >= 5000 THEN
        RETURN jsonb_build_object('valid', false, 'error', 'beta_capacity_reached');
    END IF;

    -- 3. Provision a new Beta license (default 90-day validity window)
    v_new_key := public.generate_beta_key();
    v_sunset_date := NOW() + INTERVAL '90 days';

    INSERT INTO public.licenses (
        license_key,
        license_type,
        status,
        max_devices,
        expires_at,
        customer_email,
        email_updated_at
    ) VALUES (
        v_new_key,
        'beta',
        'active',
        2,
        v_sunset_date,
        v_clean_email,
        CASE WHEN v_clean_email IS NOT NULL THEN NOW() ELSE NULL END
    ) RETURNING * INTO v_license;

    -- 4. Bind the calling Mac to this new license
    INSERT INTO public.license_activations (
        license_id,
        device_id,
        device_name
    ) VALUES (
        v_license.id,
        p_device_id,
        COALESCE(NULLIF(TRIM(p_device_name), ''), 'Mac')
    );

    RETURN jsonb_build_object(
        'valid', true,
        'tier', 'pro',
        'license_key', v_license.license_key,
        'status', v_license.status,
        'expires_at', v_license.expires_at,
        'customer_email', v_license.customer_email
    );
END;
$$;

-- ----------------------------------------------------------------------------
-- 6. RPC: validate_license
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.validate_license(
    p_license_key TEXT,
    p_device_id TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_license RECORD;
    v_activation RECORD;
    v_device_count INT;
BEGIN
    IF p_license_key IS NULL OR p_device_id IS NULL THEN
        RETURN jsonb_build_object('valid', false, 'error', 'missing_parameters');
    END IF;

    -- 1. Lookup license
    SELECT * INTO v_license FROM public.licenses WHERE license_key = UPPER(TRIM(p_license_key));
    IF NOT FOUND THEN
        RETURN jsonb_build_object('valid', false, 'error', 'license_not_found');
    END IF;

    -- 2. Check if expired or revoked
    IF v_license.status != 'active' THEN
        RETURN jsonb_build_object('valid', false, 'error', 'license_' || v_license.status, 'status', v_license.status);
    END IF;

    IF v_license.expires_at IS NOT NULL AND v_license.expires_at < NOW() THEN
        UPDATE public.licenses SET status = 'expired' WHERE id = v_license.id;
        RETURN jsonb_build_object('valid', false, 'error', 'license_expired', 'status', 'expired');
    END IF;

    -- 3. Check device activation
    SELECT * INTO v_activation 
    FROM public.license_activations 
    WHERE license_id = v_license.id AND device_id = p_device_id;

    IF FOUND THEN
        UPDATE public.license_activations SET last_validated_at = NOW() WHERE id = v_activation.id;
        RETURN jsonb_build_object(
            'valid', true,
            'tier', 'pro',
            'license_type', v_license.license_type,
            'status', v_license.status,
            'expires_at', v_license.expires_at,
            'customer_email', v_license.customer_email
        );
    END IF;

    -- Check device limit (max 2 Macs)
    SELECT COUNT(*) INTO v_device_count FROM public.license_activations WHERE license_id = v_license.id;
    IF v_device_count >= v_license.max_devices THEN
        RETURN jsonb_build_object(
            'valid', false,
            'error', 'activation_limit_reached',
            'message', 'This license is already active on ' || v_license.max_devices || ' Macs.'
        );
    END IF;

    -- Bind device
    INSERT INTO public.license_activations (license_id, device_id, device_name)
    VALUES (v_license.id, p_device_id, 'Mac');

    RETURN jsonb_build_object(
        'valid', true,
        'tier', 'pro',
        'license_type', v_license.license_type,
        'status', v_license.status,
        'expires_at', v_license.expires_at,
        'customer_email', v_license.customer_email
    );
END;
$$;

-- ----------------------------------------------------------------------------
-- 7. RPC: register_beta_email
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.register_beta_email(
    p_license_key TEXT,
    p_customer_email TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_clean_email TEXT;
    v_license_id UUID;
BEGIN
    IF p_license_key IS NULL OR p_customer_email IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'missing_parameters');
    END IF;

    v_clean_email := LOWER(TRIM(p_customer_email));
    IF v_clean_email !~* '^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$' THEN
        RETURN jsonb_build_object('success', false, 'error', 'invalid_email_format');
    END IF;

    SELECT id INTO v_license_id FROM public.licenses WHERE license_key = UPPER(TRIM(p_license_key));
    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'error', 'license_not_found');
    END IF;

    UPDATE public.licenses
    SET customer_email = v_clean_email,
        email_updated_at = NOW()
    WHERE id = v_license_id;

    RETURN jsonb_build_object('success', true, 'customer_email', v_clean_email);
END;
$$;

-- ----------------------------------------------------------------------------
-- 8. RPC: deactivate_license
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.deactivate_license(
    p_license_key TEXT,
    p_device_id TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_license_id UUID;
    v_deleted_count INT;
BEGIN
    IF p_license_key IS NULL OR p_device_id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'missing_parameters');
    END IF;

    SELECT id INTO v_license_id FROM public.licenses WHERE license_key = UPPER(TRIM(p_license_key));
    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'error', 'license_not_found');
    END IF;

    DELETE FROM public.license_activations 
    WHERE license_id = v_license_id AND device_id = p_device_id;
    GET DIAGNOSTICS v_deleted_count = ROW_COUNT;

    RETURN jsonb_build_object('success', true, 'deactivated', (v_deleted_count > 0));
END;
$$;

-- ----------------------------------------------------------------------------
-- 9. Grant Execute on RPCs to Public (anon, authenticated)
-- ----------------------------------------------------------------------------
GRANT EXECUTE ON FUNCTION public.activate_beta_license(TEXT, TEXT, TEXT) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.validate_license(TEXT, TEXT) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.register_beta_email(TEXT, TEXT) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.deactivate_license(TEXT, TEXT) TO anon, authenticated;

-- ----------------------------------------------------------------------------
-- 10. Post-Beta Outreach View: beta_pro_users_export
-- ----------------------------------------------------------------------------
CREATE OR REPLACE VIEW public.beta_pro_users_export 
WITH (security_invoker = false)
AS
SELECT 
    l.id,
    l.license_key,
    l.customer_email,
    l.status,
    l.created_at,
    l.expires_at,
    l.email_updated_at,
    COUNT(a.id) AS activation_count,
    MAX(a.last_validated_at) AS last_active_at
FROM public.licenses l
LEFT JOIN public.license_activations a ON a.license_id = l.id
WHERE l.license_type = 'beta'
  AND l.customer_email IS NOT NULL
GROUP BY l.id, l.license_key, l.customer_email, l.status, l.created_at, l.expires_at, l.email_updated_at
ORDER BY l.created_at ASC;

COMMENT ON VIEW public.beta_pro_users_export IS 'Export view for communicating with Beta Pro users after beta period ends (early-adopter discounts, GA announcements).';
REVOKE ALL ON public.beta_pro_users_export FROM anon, authenticated;

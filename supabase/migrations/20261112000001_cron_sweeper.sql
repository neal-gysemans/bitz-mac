-- ============================================================================
-- Migration: 20261112000001_cron_sweeper.sql
-- Description: Nightly pg_cron sweep for expired Beta licenses
-- ============================================================================

DO $$
BEGIN
    -- Check if pg_cron extension is available before scheduling
    IF EXISTS (
        SELECT 1 FROM pg_available_extensions WHERE name = 'pg_cron'
    ) THEN
        CREATE EXTENSION IF NOT EXISTS pg_cron;

        -- Unschedule existing job if present
        PERFORM cron.unschedule('daily-license-expiry-sweep')
        FROM cron.job
        WHERE jobname = 'daily-license-expiry-sweep';

        -- Schedule daily sweep at 00:00 UTC
        PERFORM cron.schedule(
            'daily-license-expiry-sweep',
            '0 0 * * *',
            $cron$
                UPDATE public.licenses
                SET status = 'expired'
                WHERE expires_at IS NOT NULL
                  AND expires_at < NOW()
                  AND status = 'active';
            $cron$
        );
    END IF;
END $$;

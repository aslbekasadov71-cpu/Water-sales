-- v3.1: dostavchi «Ishni boshlash» tugmasi bilan oddiy joylashuv yuboradi.
-- Eslatma joylashuv eskirishidan OLDIN (muddatning ~2/3 qismida) keladi, toki dostavchi buyurtmadan qolib ketmasin.
CREATE OR REPLACE FUNCTION stale_couriers(p jsonb) RETURNS jsonb LANGUAGE sql AS $$
    WITH x AS (
        UPDATE couriers SET stale_notified = TRUE
        WHERE is_online AND is_active AND NOT stale_notified
          AND (location_at IS NULL OR location_at < now() - make_interval(secs => (settings_json()->>'location_stale_min')::int * 40))
        RETURNING tg_id)
    SELECT jsonb_build_object('ids', COALESCE(jsonb_agg(tg_id), '[]')) FROM x
$$;
ALTER FUNCTION stale_couriers(jsonb) SET search_path = public, pg_temp;

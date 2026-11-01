-- v3.2: GPS kuzatuvisiz taqsimlash.
-- Dostavchi joyi uning ishidan aniqlanadi:
--   • «Ishni boshlash» -> zavod (rahbar belgilagan nuqta);
--   • qabul qilgan buyurtmasi bor bo'lsa -> o'sha buyurtma manzili (u yerga ketyapti);
--   • «Yetkazildi» -> mijozning manzili (dostavchi aynan o'sha eshik oldida).
-- Buyurtma shu nuqtaga eng yaqin bo'sh dostavchiga taklif qilinadi. Hech kim tashlab qo'yilmaydi:
-- masofa chegarasi yo'q, joyi noma'lum dostavchilar navbatning oxirida.

ALTER TABLE couriers ADD COLUMN IF NOT EXISTS loc_source TEXT;

INSERT INTO settings(key, value) VALUES ('factory_lat', ''), ('factory_lon', '') ON CONFLICT (key) DO NOTHING;

CREATE OR REPLACE FUNCTION settings_json() RETURNS jsonb LANGUAGE sql STABLE AS $$
    SELECT jsonb_build_object(
        'delivery_fee',       COALESCE(max(value) FILTER (WHERE key = 'delivery_fee'), '0')::bigint,
        'max_radius_km',      COALESCE(max(value) FILTER (WHERE key = 'max_radius_km'), '2')::float8,
        'offer_timeout_sec',  COALESCE(max(value) FILTER (WHERE key = 'offer_timeout_sec'), '180')::int,
        'location_stale_min', COALESCE(max(value) FILTER (WHERE key = 'location_stale_min'), '15')::int,
        'max_active_orders',  COALESCE(max(value) FILTER (WHERE key = 'max_active_orders'), '5')::int,
        'prices_final',       COALESCE(max(value) FILTER (WHERE key = 'prices_final'), '0') = '1',
        'support_phone',      COALESCE(max(value) FILTER (WHERE key = 'support_phone'), ''),
        'factory_lat',        NULLIF(max(value) FILTER (WHERE key = 'factory_lat'), '')::float8,
        'factory_lon',        NULLIF(max(value) FILTER (WHERE key = 'factory_lon'), '')::float8,
        'tz',                 COALESCE(max(value) FILTER (WHERE key = 'tz'), 'Asia/Tashkent'))
    FROM settings
$$;

CREATE OR REPLACE FUNCTION admin_setting_set(p jsonb) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE k text := p->>'key'; v text := trim(COALESCE(p->>'value', '')); n numeric; old text; m text[];
BEGIN
    IF k = 'factory' THEN
        -- "41.311, 69.279" yoki bo'sh (o'chirish)
        IF v = '' THEN
            UPDATE settings SET value = '' WHERE key IN ('factory_lat', 'factory_lon');
        ELSE
            m := regexp_match(v, '^(-?\d{1,2}\.\d+)\s*[, ]\s*(-?\d{1,3}\.\d+)$');
            IF m IS NULL OR abs(m[1]::float8) > 90 OR abs(m[2]::float8) > 180 THEN
                RETURN jsonb_build_object('error', 'Koordinatani "41.3111, 69.2797" ko''rinishida kiriting');
            END IF;
            INSERT INTO settings(key, value) VALUES ('factory_lat', m[1]), ('factory_lon', m[2])
            ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value;
        END IF;
        PERFORM audit((p->>'actor')::bigint, 'setting_changed', jsonb_build_object('key', k, 'new', v));
        RETURN jsonb_build_object('ok', true, 'settings', settings_json());
    END IF;
    IF k IN ('delivery_fee', 'offer_timeout_sec', 'location_stale_min', 'max_active_orders', 'max_radius_km') THEN
        IF v !~ '^\d+(\.\d+)?$' THEN RETURN jsonb_build_object('error', 'Son kiriting'); END IF;
        n := v::numeric;
        IF (k = 'delivery_fee' AND (n > 1000000 OR n <> trunc(n)))
           OR (k = 'max_radius_km' AND (n < 0.3 OR n > 30))
           OR (k = 'offer_timeout_sec' AND (n < 30 OR n > 1800 OR n <> trunc(n)))
           OR (k = 'location_stale_min' AND (n < 3 OR n > 120 OR n <> trunc(n)))
           OR (k = 'max_active_orders' AND (n < 1 OR n > 50 OR n <> trunc(n))) THEN
            RETURN jsonb_build_object('error', 'Qiymat ruxsat etilgan chegaradan tashqarida');
        END IF;
    ELSIF k = 'prices_final' THEN
        IF v NOT IN ('0', '1') THEN RETURN jsonb_build_object('error', 'Noto''g''ri qiymat'); END IF;
    ELSIF k = 'support_phone' THEN
        v := left(v, 40);
    ELSE
        RETURN jsonb_build_object('error', 'Bunday sozlama yo''q');
    END IF;
    SELECT value INTO old FROM settings WHERE key = k;
    INSERT INTO settings(key, value) VALUES (k, v) ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value;
    PERFORM audit((p->>'actor')::bigint, 'setting_changed', jsonb_build_object('key', k, 'old', old, 'new', v));
    RETURN jsonb_build_object('ok', true, 'settings', settings_json());
END $$;

-- GPS (ixtiyoriy): dostavchi o'zi joylashuv yuborsa — eng aniq manba
CREATE OR REPLACE FUNCTION courier_location(p jsonb) RETURNS jsonb LANGUAGE sql AS $$
    UPDATE couriers SET lat = (p->>'lat')::float8, lon = (p->>'lon')::float8, location_at = now(),
           loc_source = 'gps', stale_notified = FALSE,
           is_online = CASE WHEN (p->>'go_online')::boolean THEN TRUE ELSE is_online END
    WHERE tg_id = (p->>'tg_id')::bigint
    RETURNING jsonb_build_object('ok', true, 'online', is_online)
$$;

-- «Ishni boshlash»: smena boshida dostavchi zavodda (yoki 2 soat ichidagi oxirgi ma'lum joyida)
CREATE OR REPLACE FUNCTION courier_set_online(p jsonb) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE s jsonb := settings_json(); v_on boolean := (p->>'online')::boolean; c couriers%ROWTYPE;
BEGIN
    UPDATE couriers SET is_online = v_on WHERE tg_id = (p->>'tg_id')::bigint RETURNING * INTO c;
    IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'active', 0); END IF;
    IF v_on AND (s->>'factory_lat') IS NOT NULL AND (c.location_at IS NULL OR c.location_at < now() - interval '2 hours') THEN
        UPDATE couriers SET lat = (s->>'factory_lat')::float8, lon = (s->>'factory_lon')::float8,
               location_at = now(), loc_source = 'factory'
        WHERE tg_id = c.tg_id;
    END IF;
    RETURN jsonb_build_object('ok', true, 'active', (SELECT count(*) FROM orders WHERE courier_id = c.tg_id AND status = 'accepted'));
END $$;

-- «Yetkazildi» -> dostavchi mijoz manzilida
CREATE OR REPLACE FUNCTION trg_courier_at_delivery() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.status = 'delivered' AND OLD.status IS DISTINCT FROM 'delivered' AND NEW.courier_id IS NOT NULL THEN
        UPDATE couriers SET lat = NEW.lat, lon = NEW.lon, location_at = now(), loc_source = 'delivery'
        WHERE tg_id = NEW.courier_id AND NOT (loc_source = 'gps' AND location_at > now() - interval '5 minutes');
    END IF;
    RETURN NEW;
END $$;
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'courier_at_delivery') THEN
        CREATE TRIGGER courier_at_delivery AFTER UPDATE OF status ON orders
            FOR EACH ROW EXECUTE FUNCTION trg_courier_at_delivery();
    END IF;
END $$;

-- Eskirgan joylashuv eslatmalari endi kerak emas
CREATE OR REPLACE FUNCTION stale_couriers(p jsonb) RETURNS jsonb LANGUAGE sql AS $$
    SELECT jsonb_build_object('ids', '[]'::jsonb)
$$;

CREATE OR REPLACE FUNCTION dispatch_order(p jsonb) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
    v_id bigint := (p->>'order_id')::bigint;
    o orders%ROWTYPE;
    s jsonb := settings_json();
    v_expired jsonb;
    v_best bigint; v_dist float8; v_offer bigint;
BEGIN
    SELECT * INTO o FROM orders WHERE id = v_id FOR UPDATE;
    IF NOT FOUND OR o.status NOT IN ('new', 'offered', 'unassigned') THEN
        RETURN jsonb_build_object('action', 'none');
    END IF;
    IF o.status = 'offered' THEN
        IF o.offer_expires_at > now() THEN RETURN jsonb_build_object('action', 'none'); END IF;
        WITH x AS (UPDATE order_offers SET result = 'expired', responded_at = now()
                   WHERE order_id = v_id AND result = 'pending' RETURNING courier_id, message_id)
        SELECT jsonb_agg(jsonb_build_object('courier_id', courier_id, 'message_id', message_id)) INTO v_expired FROM x;
    END IF;
    SELECT cand.tg_id, cand.d INTO v_best, v_dist
    FROM (
        SELECT c.tg_id, act.n,
               CASE WHEN pt.lat IS NULL THEN NULL ELSE haversine_km(o.lat, o.lon, pt.lat, pt.lon) END AS d
        FROM couriers c
        JOIN users u ON u.tg_id = c.tg_id
        CROSS JOIN LATERAL (SELECT count(*) AS n FROM orders x WHERE x.courier_id = c.tg_id AND x.status = 'accepted') act
        LEFT JOIN LATERAL (SELECT x.lat, x.lon FROM orders x WHERE x.courier_id = c.tg_id AND x.status = 'accepted'
                           ORDER BY x.accepted_at DESC NULLS LAST, x.id DESC LIMIT 1) cur ON TRUE
        CROSS JOIN LATERAL (SELECT
            CASE WHEN c.loc_source = 'gps' AND c.location_at > now() - interval '5 minutes' THEN c.lat ELSE COALESCE(cur.lat, c.lat) END AS lat,
            CASE WHEN c.loc_source = 'gps' AND c.location_at > now() - interval '5 minutes' THEN c.lon ELSE COALESCE(cur.lon, c.lon) END AS lon) pt
        WHERE c.is_active AND c.is_online AND u.role = 'courier' AND NOT u.is_blocked
          AND NOT EXISTS (SELECT 1 FROM order_offers f WHERE f.order_id = v_id AND f.courier_id = c.tg_id)
          AND act.n < (s->>'max_active_orders')::int
    ) cand
    ORDER BY cand.d ASC NULLS LAST, cand.n ASC, cand.tg_id
    LIMIT 1;
    IF v_best IS NOT NULL THEN
        UPDATE orders SET status = 'offered', offered_to = v_best,
               offer_expires_at = now() + make_interval(secs => (s->>'offer_timeout_sec')::int)
        WHERE id = v_id;
        INSERT INTO order_offers(order_id, courier_id, distance_km) VALUES (v_id, v_best, v_dist)
        RETURNING id INTO v_offer;
        RETURN jsonb_build_object('action', 'offer', 'courier_id', v_best, 'distance_km', v_dist,
            'offer_id', v_offer, 'timeout_sec', (s->>'offer_timeout_sec')::int,
            'expired', v_expired, 'order', order_json(v_id));
    END IF;
    UPDATE orders SET status = 'unassigned', offered_to = NULL, offer_expires_at = NULL, admin_notified = TRUE
    WHERE id = v_id;
    RETURN jsonb_build_object('action', 'unassigned', 'notify_admin', NOT o.admin_notified,
        'radius_km', (s->>'max_radius_km')::float8, 'expired', v_expired, 'order', order_json(v_id));
END $$;

CREATE OR REPLACE FUNCTION order_json(p_id bigint) RETURNS jsonb LANGUAGE sql STABLE AS $$
    SELECT jsonb_build_object(
        'id', o.id, 'status', o.status, 'phone', o.phone, 'lat', o.lat, 'lon', o.lon,
        'address', o.address_note, 'time', o.delivery_time, 'payment', o.payment_method,
        'price_type', o.price_type, 'items_total', o.items_total, 'delivery_fee', o.delivery_fee, 'total', o.total,
        'paid_amount', o.paid_amount, 'debt_amount', o.debt_amount,
        'created_at', o.created_at, 'accepted_at', o.accepted_at, 'delivered_at', o.delivered_at,
        'client_id', o.client_id, 'courier_id', o.courier_id, 'offered_to', o.offered_to,
        'cancel_reason', o.cancel_reason,
        'items', (SELECT COALESCE(jsonb_agg(jsonb_build_object('volume_l', i.volume_l, 'title', i.title,
                    'qty', i.qty, 'unit_price', i.unit_price, 'returnable', i.returnable) ORDER BY i.volume_l), '[]')
                  FROM order_items i WHERE i.order_id = o.id),
        'client', (SELECT jsonb_build_object('name', u.full_name, 'phone', u.phone, 'type', u.customer_type,
                    'business', u.business_name) FROM users u WHERE u.tg_id = o.client_id),
        'courier', (SELECT jsonb_build_object('name', u.full_name, 'phone', u.phone) FROM users u WHERE u.tg_id = o.courier_id),
        'courier_loc', (SELECT jsonb_build_object('lat', c.lat, 'lon', c.lon, 'at', c.location_at)
                        FROM couriers c WHERE c.tg_id = o.courier_id AND o.status = 'accepted' AND c.lat IS NOT NULL
                          AND c.loc_source = 'gps' AND c.location_at > now() - interval '5 minutes'),
        'offers', (SELECT COALESCE(jsonb_agg(jsonb_build_object('name', u.full_name, 'result', f.result,
                    'distance_km', f.distance_km) ORDER BY f.id), '[]')
                   FROM order_offers f JOIN users u ON u.tg_id = f.courier_id WHERE f.order_id = o.id),
        'notes', (SELECT COALESCE(jsonb_agg(jsonb_build_object('kind', n.kind, 'volume_l', n.volume_l, 'qty', n.qty,
                    'text', n.text, 'at', n.created_at) ORDER BY n.id), '[]')
                  FROM order_notes n WHERE n.order_id = o.id))
    FROM orders o WHERE o.id = p_id
$$;

CREATE OR REPLACE FUNCTION admin_staff_list(p jsonb) RETURNS jsonb LANGUAGE sql STABLE AS $$
    SELECT jsonb_build_object('staff', COALESCE(jsonb_agg(jsonb_build_object(
        'id', s.id, 'login', s.login, 'full_name', s.full_name, 'phone', s.phone, 'role', s.role,
        'tg_id', s.tg_id, 'is_active', s.is_active, 'last_login_at', s.last_login_at,
        'online', COALESCE(c.is_online, false),
        'location_at', c.location_at, 'lat', c.lat, 'lon', c.lon,
        'active', (SELECT count(*) FROM orders o WHERE o.courier_id = s.tg_id AND o.status = 'accepted'),
        'today', (SELECT count(*) FROM orders o WHERE o.courier_id = s.tg_id AND o.status = 'delivered' AND o.delivered_at >= period_start(1)),
        'cash', (SELECT COALESCE(SUM(COALESCE(paid_amount, total)), 0) FROM orders o WHERE o.courier_id = s.tg_id
                 AND o.status = 'delivered' AND o.delivered_at >= period_start(1))
    ) ORDER BY s.role DESC, s.full_name), '[]'))
    FROM staff s LEFT JOIN couriers c ON c.tg_id = s.tg_id
$$;

CREATE OR REPLACE FUNCTION admin_overview(p jsonb) RETURNS jsonb LANGUAGE sql STABLE AS $$
    SELECT jsonb_build_object(
        'orders', (SELECT COALESCE(jsonb_agg(order_json(id) ORDER BY id DESC), '[]') FROM (
                     SELECT id FROM orders WHERE status IN ('new', 'offered', 'unassigned', 'accepted')
                     UNION SELECT id FROM (SELECT id FROM orders WHERE status IN ('delivered', 'cancelled')
                                           ORDER BY id DESC LIMIT 40) d) x),
        'couriers', (SELECT COALESCE(jsonb_agg(jsonb_build_object(
                        'tg_id', u.tg_id, 'name', COALESCE((SELECT st.full_name FROM staff st WHERE st.tg_id = u.tg_id), u.full_name), 'phone', u.phone, 'username', u.username,
                        'is_active', c.is_active, 'is_online', c.is_online, 'lat', c.lat, 'lon', c.lon,
                        'location_at', c.location_at,
                        'fresh', COALESCE(c.is_online, false), 'loc_source', c.loc_source,
                        'active', (SELECT count(*) FROM orders o WHERE o.courier_id = c.tg_id AND o.status = 'accepted'),
                        'today', (SELECT count(*) FROM orders o WHERE o.courier_id = c.tg_id AND o.status = 'delivered'
                                  AND o.delivered_at >= period_start(1)),
                        'cash', (SELECT COALESCE(SUM(COALESCE(paid_amount, total)), 0) FROM orders o WHERE o.courier_id = c.tg_id
                                 AND o.status = 'delivered' AND o.delivered_at >= period_start(1))
                     ) ORDER BY u.full_name), '[]')
                     FROM couriers c JOIN users u ON u.tg_id = c.tg_id WHERE u.role = 'courier'),
        'products', (SELECT COALESCE(jsonb_agg(to_jsonb(pr) ORDER BY pr.sort_order, pr.id), '[]') FROM products pr),
        'settings', settings_json())
$$;

CREATE OR REPLACE FUNCTION staff_me(p jsonb) RETURNS jsonb LANGUAGE sql STABLE AS $$
    SELECT jsonb_build_object('id', s.id, 'login', s.login, 'full_name', s.full_name, 'phone', s.phone, 'role', s.role,
                              'online', COALESCE(c.is_online, false))
    FROM staff s LEFT JOIN couriers c ON c.tg_id = s.tg_id
    WHERE s.tg_id = (p->>'tg_id')::bigint AND s.is_active
$$;

DO $$
DECLARE f record;
BEGIN
    FOR f IN SELECT p.oid::regprocedure AS sig FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
             WHERE n.nspname = 'public' AND p.prokind = 'f' LOOP
        EXECUTE format('ALTER FUNCTION %s SET search_path = public, pg_temp', f.sig);
    END LOOP;
END $$;

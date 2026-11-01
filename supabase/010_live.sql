-- v6: dostavchining Telegram jonli joylashuvi qaytadi (Yandex uslubidagi kuzatish)
-- GPS «yangi» hisoblanadigan oyna 5 -> 15 daqiqa (jonli joylashuv turg'un turganda kam yangilanadi)

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
        'courier', (SELECT jsonb_build_object('name', COALESCE(st.full_name, u.full_name), 'phone', COALESCE(st.phone, u.phone))
                    FROM users u LEFT JOIN staff st ON st.tg_id = u.tg_id WHERE u.tg_id = o.courier_id),
        'client_confirm', o.client_confirm, 'client_rating', o.client_rating, 'dispute_note', o.dispute_note,
        'dispute_resolved', o.dispute_resolved_at IS NOT NULL,
        'courier_loc', (SELECT jsonb_build_object('lat', c.lat, 'lon', c.lon, 'at', c.location_at)
                        FROM couriers c WHERE c.tg_id = o.courier_id AND o.status = 'accepted' AND c.lat IS NOT NULL
                          AND c.loc_source = 'gps' AND c.location_at > now() - interval '15 minutes'),
        'offers', (SELECT COALESCE(jsonb_agg(jsonb_build_object('name', COALESCE((SELECT st.full_name FROM staff st WHERE st.tg_id = u.tg_id), u.full_name), 'result', f.result,
                    'distance_km', f.distance_km) ORDER BY f.id), '[]')
                   FROM order_offers f JOIN users u ON u.tg_id = f.courier_id WHERE f.order_id = o.id),
        'notes', (SELECT COALESCE(jsonb_agg(jsonb_build_object('kind', n.kind, 'volume_l', n.volume_l, 'qty', n.qty,
                    'text', n.text, 'at', n.created_at) ORDER BY n.id), '[]')
                  FROM order_notes n WHERE n.order_id = o.id))
    FROM orders o WHERE o.id = p_id
$$;
ALTER FUNCTION order_json(bigint) SET search_path = public, pg_temp;

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
            CASE WHEN c.loc_source = 'gps' AND c.location_at > now() - interval '15 minutes' THEN c.lat ELSE COALESCE(cur.lat, c.lat) END AS lat,
            CASE WHEN c.loc_source = 'gps' AND c.location_at > now() - interval '15 minutes' THEN c.lon ELSE COALESCE(cur.lon, c.lon) END AS lon) pt
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
ALTER FUNCTION dispatch_order(jsonb) SET search_path = public, pg_temp;

CREATE OR REPLACE FUNCTION trg_courier_at_delivery() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.status = 'delivered' AND OLD.status IS DISTINCT FROM 'delivered' AND NEW.courier_id IS NOT NULL THEN
        UPDATE couriers SET lat = NEW.lat, lon = NEW.lon, location_at = now(), loc_source = 'delivery'
        WHERE tg_id = NEW.courier_id AND NOT (loc_source = 'gps' AND location_at > now() - interval '15 minutes');
    END IF;
    RETURN NEW;
END $$;
ALTER FUNCTION trg_courier_at_delivery() SET search_path = public, pg_temp;

CREATE OR REPLACE FUNCTION courier_set_online(p jsonb) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE s jsonb := settings_json(); v_on boolean := (p->>'online')::boolean; c couriers%ROWTYPE; v_shift shifts%ROWTYPE;
BEGIN
    UPDATE couriers SET is_online = v_on, stale_notified = CASE WHEN v_on THEN FALSE ELSE stale_notified END WHERE tg_id = (p->>'tg_id')::bigint RETURNING * INTO c;
    IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'active', 0); END IF;
    IF v_on THEN
        INSERT INTO shifts(courier_id) VALUES (c.tg_id) ON CONFLICT (courier_id) WHERE ended_at IS NULL DO NOTHING;
        IF (s->>'factory_lat') IS NOT NULL AND (c.location_at IS NULL OR c.location_at < now() - interval '2 hours') THEN
            UPDATE couriers SET lat = (s->>'factory_lat')::float8, lon = (s->>'factory_lon')::float8,
                   location_at = now(), loc_source = 'factory'
            WHERE tg_id = c.tg_id;
        END IF;
    ELSE
        UPDATE shifts SET ended_at = now() WHERE courier_id = c.tg_id AND ended_at IS NULL;
    END IF;
    SELECT * INTO v_shift FROM shifts WHERE courier_id = c.tg_id ORDER BY started_at DESC LIMIT 1;
    RETURN jsonb_build_object('ok', true,
        'active', (SELECT count(*) FROM orders WHERE courier_id = c.tg_id AND status = 'accepted'),
        'started_at', v_shift.started_at, 'ended_at', v_shift.ended_at,
        'minutes', CASE WHEN v_shift.id IS NULL THEN 0
                        ELSE round(extract(epoch FROM COALESCE(v_shift.ended_at, now()) - v_shift.started_at) / 60) END);
END $$;
ALTER FUNCTION courier_set_online(jsonb) SET search_path = public, pg_temp;

-- Ishda, smena 3 daqiqadan oshgan, lekin jonli joylashuv kelmayotgan dostavchiga bir marta eslatma
CREATE OR REPLACE FUNCTION stale_couriers(p jsonb) RETURNS jsonb LANGUAGE sql AS $$
    WITH x AS (
        UPDATE couriers c SET stale_notified = TRUE
        WHERE c.is_online AND c.is_active AND NOT c.stale_notified
          AND NOT (c.loc_source = 'gps' AND c.location_at > now() - interval '15 minutes')
          AND EXISTS (SELECT 1 FROM shifts s WHERE s.courier_id = c.tg_id AND s.ended_at IS NULL
                      AND s.started_at < now() - interval '3 minutes')
        RETURNING c.tg_id)
    SELECT jsonb_build_object('ids', COALESCE(jsonb_agg(tg_id), '[]')) FROM x
$$;
ALTER FUNCTION stale_couriers(jsonb) SET search_path = public, pg_temp;

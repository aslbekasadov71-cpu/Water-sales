-- v3.4: reyting yulduzlarsiz. Ball = 10×yetkazish + 5×mijoz tasdiqlagan − 30×e'tiroz − 3×(rad etilgan/javobsiz taklif)
CREATE OR REPLACE FUNCTION courier_ratings(p jsonb) RETURNS jsonb LANGUAGE sql STABLE AS $$
    WITH per AS (SELECT period_start(CASE WHEN (p->>'days') IN ('1', '7', '30') THEN (p->>'days')::int ELSE 30 END) AS t0),
    st AS (
        SELECT u.tg_id, COALESCE(s.full_name, u.full_name) AS name, c.is_online AS online,
            (SELECT count(*) FROM orders o, per WHERE o.courier_id = u.tg_id AND o.status = 'delivered' AND o.delivered_at >= per.t0) AS delivered,
            (SELECT count(*) FROM orders o, per WHERE o.courier_id = u.tg_id AND o.client_confirm = 'ok' AND o.delivered_at >= per.t0) AS confirmed,
            (SELECT count(*) FROM orders o, per WHERE o.courier_id = u.tg_id AND o.client_confirm = 'dispute' AND o.delivered_at >= per.t0) AS disputes,
            (SELECT count(*) FROM order_offers f, per WHERE f.courier_id = u.tg_id AND f.result IN ('declined', 'expired') AND f.offered_at >= per.t0) AS missed,
            (SELECT COALESCE(SUM(COALESCE(o.paid_amount, o.total)), 0) FROM orders o, per WHERE o.courier_id = u.tg_id AND o.status = 'delivered' AND o.delivered_at >= per.t0) AS revenue,
            (SELECT round(avg(extract(epoch FROM o.delivered_at - o.accepted_at) / 60)) FROM orders o, per
              WHERE o.courier_id = u.tg_id AND o.status = 'delivered' AND o.delivered_at >= per.t0 AND o.accepted_at IS NOT NULL) AS avg_min
        FROM users u
        JOIN couriers c ON c.tg_id = u.tg_id AND c.is_active
        JOIN staff s ON s.tg_id = u.tg_id AND s.is_active AND s.role = 'courier')
    SELECT jsonb_build_object('days', CASE WHEN (p->>'days') IN ('1', '7', '30') THEN (p->>'days')::int ELSE 30 END,
        'list', COALESCE(jsonb_agg(jsonb_build_object('tg_id', tg_id, 'name', name, 'online', online, 'delivered', delivered,
                 'confirmed', confirmed, 'disputes', disputes, 'missed', missed, 'avg_min', avg_min, 'revenue', revenue,
                 'score', 10 * delivered + 5 * confirmed - 30 * disputes - 3 * missed)
                 ORDER BY 10 * delivered + 5 * confirmed - 30 * disputes - 3 * missed DESC, delivered DESC, name), '[]'))
    FROM st
$$;
ALTER FUNCTION courier_ratings(jsonb) SET search_path = public, pg_temp;

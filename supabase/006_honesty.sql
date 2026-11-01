-- v3.3: halollik — mijoz tasdig'i, kassa (dostavchi qo'lidagi pul), reyting, "kim oldi" taxtasi.

ALTER TABLE orders ADD COLUMN IF NOT EXISTS client_confirm TEXT;
ALTER TABLE orders ADD COLUMN IF NOT EXISTS client_rating SMALLINT;
ALTER TABLE orders ADD COLUMN IF NOT EXISTS confirm_at TIMESTAMPTZ;
ALTER TABLE orders ADD COLUMN IF NOT EXISTS dispute_note TEXT;
ALTER TABLE orders ADD COLUMN IF NOT EXISTS dispute_resolved_at TIMESTAMPTZ;
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'orders_client_confirm_chk') THEN
        ALTER TABLE orders ADD CONSTRAINT orders_client_confirm_chk CHECK (client_confirm IN ('ok', 'dispute'));
        ALTER TABLE orders ADD CONSTRAINT orders_client_rating_chk CHECK (client_rating BETWEEN 1 AND 5);
    END IF;
END $$;

-- Dostavchi qo'lidagi naqd pul: yetkazishda olingan (+), rahbarga topshirilgan (−)
CREATE TABLE IF NOT EXISTS cash_ledger (
    id         BIGSERIAL PRIMARY KEY,
    courier_id BIGINT NOT NULL REFERENCES users (tg_id),
    order_id   BIGINT REFERENCES orders (id),
    delta      BIGINT NOT NULL,
    kind       TEXT NOT NULL CHECK (kind IN ('collected', 'handover', 'adjust')),
    note       TEXT,
    created_by BIGINT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_cash_courier ON cash_ledger (courier_id);
CREATE UNIQUE INDEX IF NOT EXISTS uq_cash_collected ON cash_ledger (order_id) WHERE kind = 'collected';
ALTER TABLE cash_ledger ENABLE ROW LEVEL SECURITY;

CREATE OR REPLACE FUNCTION cash_balance(p_courier bigint) RETURNS bigint LANGUAGE sql STABLE AS $$
    SELECT COALESCE(SUM(delta), 0)::bigint FROM cash_ledger WHERE courier_id = p_courier
$$;

-- Yetkazilganda olingan naqd avtomatik dostavchi kassasiga yoziladi (qo'lda o'zgartirib bo'lmaydi)
CREATE OR REPLACE FUNCTION trg_cash_on_delivery() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.status = 'delivered' AND OLD.status IS DISTINCT FROM 'delivered' AND NEW.courier_id IS NOT NULL
       AND COALESCE(NEW.paid_amount, 0) > 0 THEN
        INSERT INTO cash_ledger(courier_id, order_id, delta, kind, note, created_by)
        VALUES (NEW.courier_id, NEW.id, NEW.paid_amount, 'collected', 'Buyurtma #' || NEW.id, NEW.courier_id)
        ON CONFLICT (order_id) WHERE kind = 'collected' DO NOTHING;
    END IF;
    RETURN NEW;
END $$;
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'cash_on_delivery') THEN
        CREATE TRIGGER cash_on_delivery AFTER UPDATE OF status ON orders
            FOR EACH ROW EXECUTE FUNCTION trg_cash_on_delivery();
    END IF;
END $$;

-- Mijoz tasdig'i: "hammasi to'g'ri" yoki "muammo bor". Bir marta; "to'g'ri" dan keyin 24 soat ichida e'tiroz bildirish mumkin.
CREATE OR REPLACE FUNCTION client_confirm(p jsonb) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE o orders%ROWTYPE; v_ok boolean := (p->>'ok')::boolean;
BEGIN
    SELECT * INTO o FROM orders WHERE id = (p->>'order_id')::bigint AND client_id = (p->>'client_id')::bigint FOR UPDATE;
    IF NOT FOUND OR o.status <> 'delivered' OR o.delivered_at < now() - interval '7 days' THEN
        RETURN jsonb_build_object('ok', false, 'error', 'Bu buyurtmani endi tasdiqlab bo''lmaydi');
    END IF;
    IF o.client_confirm = 'dispute' OR (o.client_confirm = 'ok' AND (v_ok OR o.confirm_at < now() - interval '24 hours')) THEN
        RETURN jsonb_build_object('ok', false, 'error', 'Javobingiz allaqachon qabul qilingan');
    END IF;
    UPDATE orders SET client_confirm = CASE WHEN v_ok THEN 'ok' ELSE 'dispute' END, confirm_at = now(),
           dispute_note = CASE WHEN v_ok THEN NULL ELSE left(COALESCE(p->>'note', ''), 500) END
    WHERE id = o.id;
    RETURN jsonb_build_object('ok', true, 'courier_id', o.courier_id, 'order', order_json(o.id));
END $$;

CREATE OR REPLACE FUNCTION client_dispute_note(p jsonb) RETURNS jsonb LANGUAGE sql AS $$
    UPDATE orders SET dispute_note = left(p->>'note', 500)
    WHERE id = (p->>'order_id')::bigint AND client_id = (p->>'client_id')::bigint AND client_confirm = 'dispute'
      AND confirm_at > now() - interval '1 day'
    RETURNING jsonb_build_object('ok', true, 'courier_id', courier_id, 'order', order_json(id))
$$;

CREATE OR REPLACE FUNCTION client_rate(p jsonb) RETURNS jsonb LANGUAGE sql AS $$
    UPDATE orders SET client_rating = (p->>'stars')::smallint
    WHERE id = (p->>'order_id')::bigint AND client_id = (p->>'client_id')::bigint AND status = 'delivered'
      AND client_rating IS NULL AND (p->>'stars') ~ '^[1-5]$' AND delivered_at > now() - interval '7 days'
    RETURNING jsonb_build_object('ok', true, 'courier_id', courier_id, 'stars', client_rating)
$$;

-- Reyting: ball = 10×yetkazish + 5×(yulduz−3) yig'indisi − 30×e'tiroz − 3×(rad etgan yoki javob bermagan taklif)
CREATE OR REPLACE FUNCTION courier_ratings(p jsonb) RETURNS jsonb LANGUAGE sql STABLE AS $$
    WITH per AS (SELECT period_start(CASE WHEN (p->>'days') IN ('1', '7', '30') THEN (p->>'days')::int ELSE 30 END) AS t0),
    st AS (
        SELECT u.tg_id, COALESCE(s.full_name, u.full_name) AS name,
            (SELECT count(*) FROM orders o, per WHERE o.courier_id = u.tg_id AND o.status = 'delivered' AND o.delivered_at >= per.t0) AS delivered,
            (SELECT round(avg(o.client_rating)::numeric, 1) FROM orders o, per WHERE o.courier_id = u.tg_id AND o.client_rating IS NOT NULL AND o.delivered_at >= per.t0) AS stars,
            (SELECT count(*) FROM orders o, per WHERE o.courier_id = u.tg_id AND o.client_rating IS NOT NULL AND o.delivered_at >= per.t0) AS stars_n,
            (SELECT COALESCE(sum(o.client_rating - 3), 0) FROM orders o, per WHERE o.courier_id = u.tg_id AND o.client_rating IS NOT NULL AND o.delivered_at >= per.t0) AS star_pts,
            (SELECT count(*) FROM orders o, per WHERE o.courier_id = u.tg_id AND o.client_confirm = 'dispute' AND o.delivered_at >= per.t0) AS disputes,
            (SELECT count(*) FROM order_offers f, per WHERE f.courier_id = u.tg_id AND f.result IN ('declined', 'expired') AND f.offered_at >= per.t0) AS missed,
            (SELECT round(avg(extract(epoch FROM o.delivered_at - o.accepted_at) / 60)) FROM orders o, per
              WHERE o.courier_id = u.tg_id AND o.status = 'delivered' AND o.delivered_at >= per.t0 AND o.accepted_at IS NOT NULL) AS avg_min
        FROM users u
        JOIN couriers c ON c.tg_id = u.tg_id AND c.is_active
        LEFT JOIN staff s ON s.tg_id = u.tg_id
        WHERE u.role = 'courier')
    SELECT jsonb_build_object('days', CASE WHEN (p->>'days') IN ('1', '7', '30') THEN (p->>'days')::int ELSE 30 END,
        'list', COALESCE(jsonb_agg(jsonb_build_object('tg_id', tg_id, 'name', name, 'delivered', delivered, 'stars', stars,
                 'stars_n', stars_n, 'disputes', disputes, 'missed', missed, 'avg_min', avg_min,
                 'score', 10 * delivered + 5 * star_pts - 30 * disputes - 3 * missed)
                 ORDER BY 10 * delivered + 5 * star_pts - 30 * disputes - 3 * missed DESC, delivered DESC, name), '[]'))
    FROM st
$$;

-- Hozir kimda qaysi buyurtma (dostavchilar bir-birini ko'radi — ikki kishi bitta mijozga bormaydi)
CREATE OR REPLACE FUNCTION orders_board(p jsonb) RETURNS jsonb LANGUAGE sql STABLE AS $$
    SELECT jsonb_build_object(
        'taken', (SELECT COALESCE(jsonb_agg(jsonb_build_object('id', o.id, 'courier', COALESCE(s.full_name, u.full_name),
                    'courier_id', o.courier_id, 'address', o.address_note, 'accepted_at', o.accepted_at) ORDER BY o.accepted_at), '[]')
                  FROM orders o JOIN users u ON u.tg_id = o.courier_id LEFT JOIN staff s ON s.tg_id = o.courier_id
                  WHERE o.status = 'accepted'),
        'waiting', (SELECT count(*) FROM orders WHERE status IN ('new', 'offered', 'unassigned')))
$$;

CREATE OR REPLACE FUNCTION online_courier_ids(p jsonb) RETURNS jsonb LANGUAGE sql STABLE AS $$
    SELECT jsonb_build_object('ids', COALESCE(jsonb_agg(c.tg_id), '[]'))
    FROM couriers c JOIN staff s ON s.tg_id = c.tg_id AND s.is_active
    WHERE c.is_online AND c.is_active
$$;

CREATE OR REPLACE FUNCTION courier_cash(p jsonb) RETURNS jsonb LANGUAGE sql STABLE AS $$
    SELECT jsonb_build_object('balance', cash_balance((p->>'tg_id')::bigint),
        'last_handover', (SELECT max(created_at) FROM cash_ledger WHERE courier_id = (p->>'tg_id')::bigint AND kind = 'handover'))
$$;

-- Rahbar: dostavchi pul topshirdi
CREATE OR REPLACE FUNCTION admin_cash_handover(p jsonb) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE v_c bigint := (p->>'courier_id')::bigint; v_bal bigint; v_amt bigint;
BEGIN
    IF COALESCE(p->>'amount', '') !~ '^\d{1,10}$' OR (p->>'amount')::bigint <= 0 THEN
        RETURN jsonb_build_object('error', 'Summani to''g''ri kiriting');
    END IF;
    PERFORM 1 FROM couriers WHERE tg_id = v_c FOR UPDATE;
    IF NOT FOUND THEN RETURN jsonb_build_object('error', 'Dostavchi topilmadi'); END IF;
    v_bal := cash_balance(v_c);
    v_amt := (p->>'amount')::bigint;
    IF v_amt > v_bal THEN
        RETURN jsonb_build_object('error', format('Summa dostavchidagi puldan katta (%s so''m)', v_bal));
    END IF;
    INSERT INTO cash_ledger(courier_id, delta, kind, note, created_by)
    VALUES (v_c, -v_amt, 'handover', NULLIF(left(COALESCE(p->>'note', ''), 200), ''), (p->>'actor')::bigint);
    PERFORM audit((p->>'actor')::bigint, 'cash_handover', jsonb_build_object('courier', v_c, 'amount', v_amt));
    RETURN jsonb_build_object('ok', true, 'balance', cash_balance(v_c), 'amount', v_amt);
END $$;

CREATE OR REPLACE FUNCTION admin_dispute_resolve(p jsonb) RETURNS jsonb LANGUAGE plpgsql AS $$
BEGIN
    UPDATE orders SET dispute_resolved_at = now()
    WHERE id = (p->>'order_id')::bigint AND client_confirm = 'dispute' AND dispute_resolved_at IS NULL;
    IF NOT FOUND THEN RETURN jsonb_build_object('error', 'E''tiroz topilmadi'); END IF;
    PERFORM audit((p->>'actor')::bigint, 'dispute_resolved', jsonb_build_object('order', (p->>'order_id')::bigint,
                  'note', left(COALESCE(p->>'note', ''), 300)));
    RETURN jsonb_build_object('ok', true);
END $$;

-- Panel uchun qo'shimcha: kassa, reyting, hal qilinmagan e'tirozlar
CREATE OR REPLACE FUNCTION admin_extra(p jsonb) RETURNS jsonb LANGUAGE sql STABLE AS $$
    SELECT jsonb_build_object(
        'cash', (SELECT COALESCE(jsonb_object_agg(courier_id::text, bal), '{}') FROM
                   (SELECT courier_id, SUM(delta) AS bal FROM cash_ledger GROUP BY courier_id) x),
        'cash_total', (SELECT COALESCE(SUM(delta), 0) FROM cash_ledger),
        'ratings', courier_ratings(jsonb_build_object('days', 30))->'list',
        'disputes', (SELECT COALESCE(jsonb_agg(order_json(id) ORDER BY id DESC), '[]') FROM orders
                     WHERE client_confirm = 'dispute' AND dispute_resolved_at IS NULL))
$$;

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
                          AND c.loc_source = 'gps' AND c.location_at > now() - interval '5 minutes'),
        'offers', (SELECT COALESCE(jsonb_agg(jsonb_build_object('name', COALESCE((SELECT st.full_name FROM staff st WHERE st.tg_id = u.tg_id), u.full_name), 'result', f.result,
                    'distance_km', f.distance_km) ORDER BY f.id), '[]')
                   FROM order_offers f JOIN users u ON u.tg_id = f.courier_id WHERE f.order_id = o.id),
        'notes', (SELECT COALESCE(jsonb_agg(jsonb_build_object('kind', n.kind, 'volume_l', n.volume_l, 'qty', n.qty,
                    'text', n.text, 'at', n.created_at) ORDER BY n.id), '[]')
                  FROM order_notes n WHERE n.order_id = o.id))
    FROM orders o WHERE o.id = p_id
$$;

CREATE OR REPLACE FUNCTION export_all(p jsonb) RETURNS jsonb LANGUAGE sql STABLE AS $$
    SELECT jsonb_build_object(
        'version', 3, 'exported_at', now(),
        'users', (SELECT COALESCE(jsonb_agg(t), '[]') FROM users t),
        'couriers', (SELECT COALESCE(jsonb_agg(t), '[]') FROM couriers t),
        'courier_invites', (SELECT COALESCE(jsonb_agg(t), '[]') FROM courier_invites t),
        'products', (SELECT COALESCE(jsonb_agg(t), '[]') FROM products t),
        'settings', (SELECT COALESCE(jsonb_agg(t), '[]') FROM settings t),
        'orders', (SELECT COALESCE(jsonb_agg(t), '[]') FROM orders t),
        'order_items', (SELECT COALESCE(jsonb_agg(t), '[]') FROM order_items t),
        'order_offers', (SELECT COALESCE(jsonb_agg(t), '[]') FROM order_offers t),
        'bottle_ledger', (SELECT COALESCE(jsonb_agg(t), '[]') FROM bottle_ledger t),
        'audit_log', (SELECT COALESCE(jsonb_agg(t), '[]') FROM audit_log t),
        'staff', (SELECT COALESCE(jsonb_agg(t), '[]') FROM staff t),
        'debt_ledger', (SELECT COALESCE(jsonb_agg(t), '[]') FROM debt_ledger t),
        'order_notes', (SELECT COALESCE(jsonb_agg(t), '[]') FROM order_notes t),
        'cash_ledger', (SELECT COALESCE(jsonb_agg(t), '[]') FROM cash_ledger t))
$$;

CREATE OR REPLACE FUNCTION import_all(p jsonb) RETURNS jsonb LANGUAGE plpgsql AS $$
BEGIN
    IF EXISTS (SELECT 1 FROM orders) OR EXISTS (SELECT 1 FROM users) OR EXISTS (SELECT 1 FROM staff) THEN
        RAISE EXCEPTION 'Baza bo''sh emas — tiklash faqat yangi bazaga qilinadi';
    END IF;
    INSERT INTO users SELECT (jsonb_populate_record(NULL::users, '{"name_locked": false}'::jsonb || e)).*
        FROM jsonb_array_elements(p->'users') e;
    INSERT INTO couriers SELECT * FROM jsonb_populate_recordset(NULL::couriers, p->'couriers');
    INSERT INTO courier_invites SELECT * FROM jsonb_populate_recordset(NULL::courier_invites, COALESCE(p->'courier_invites', '[]'));
    INSERT INTO products SELECT (jsonb_populate_record(NULL::products, '{"sort_order": 0, "unit": "dona"}'::jsonb || e)).*
        FROM jsonb_array_elements(p->'products') e
        ON CONFLICT (id) DO UPDATE SET volume_l = EXCLUDED.volume_l, title = EXCLUDED.title, price = EXCLUDED.price,
            wholesale_price = EXCLUDED.wholesale_price, returnable = EXCLUDED.returnable, is_active = EXCLUDED.is_active,
            image_url = EXCLUDED.image_url, description = EXCLUDED.description, sort_order = EXCLUDED.sort_order, unit = EXCLUDED.unit;
    INSERT INTO settings SELECT * FROM jsonb_populate_recordset(NULL::settings, p->'settings')
        ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value;
    INSERT INTO orders SELECT * FROM jsonb_populate_recordset(NULL::orders, p->'orders');
    INSERT INTO order_items SELECT * FROM jsonb_populate_recordset(NULL::order_items, p->'order_items');
    INSERT INTO order_offers SELECT * FROM jsonb_populate_recordset(NULL::order_offers, p->'order_offers');
    INSERT INTO bottle_ledger SELECT * FROM jsonb_populate_recordset(NULL::bottle_ledger, p->'bottle_ledger');
    INSERT INTO audit_log SELECT * FROM jsonb_populate_recordset(NULL::audit_log, p->'audit_log');
    INSERT INTO staff SELECT * FROM jsonb_populate_recordset(NULL::staff, COALESCE(p->'staff', '[]'));
    INSERT INTO debt_ledger SELECT * FROM jsonb_populate_recordset(NULL::debt_ledger, COALESCE(p->'debt_ledger', '[]'));
    INSERT INTO order_notes SELECT * FROM jsonb_populate_recordset(NULL::order_notes, COALESCE(p->'order_notes', '[]'));
    INSERT INTO cash_ledger SELECT * FROM jsonb_populate_recordset(NULL::cash_ledger, COALESCE(p->'cash_ledger', '[]'));
    PERFORM setval(pg_get_serial_sequence('cash_ledger', 'id'), COALESCE((SELECT max(id) FROM cash_ledger), 1));
    PERFORM setval(pg_get_serial_sequence('products', 'id'), COALESCE((SELECT max(id) FROM products), 1));
    PERFORM setval(pg_get_serial_sequence('orders', 'id'), COALESCE((SELECT max(id) FROM orders), 1));
    PERFORM setval(pg_get_serial_sequence('order_items', 'id'), COALESCE((SELECT max(id) FROM order_items), 1));
    PERFORM setval(pg_get_serial_sequence('order_offers', 'id'), COALESCE((SELECT max(id) FROM order_offers), 1));
    PERFORM setval(pg_get_serial_sequence('bottle_ledger', 'id'), COALESCE((SELECT max(id) FROM bottle_ledger), 1));
    PERFORM setval(pg_get_serial_sequence('audit_log', 'id'), COALESCE((SELECT max(id) FROM audit_log), 1));
    PERFORM setval(pg_get_serial_sequence('staff', 'id'), COALESCE((SELECT max(id) FROM staff), 1));
    PERFORM setval(pg_get_serial_sequence('debt_ledger', 'id'), COALESCE((SELECT max(id) FROM debt_ledger), 1));
    PERFORM setval(pg_get_serial_sequence('order_notes', 'id'), COALESCE((SELECT max(id) FROM order_notes), 1));
    RETURN jsonb_build_object('ok', true, 'orders', (SELECT count(*) FROM orders));
END $$;

DO $$
DECLARE f record;
BEGIN
    FOR f IN SELECT p.oid::regprocedure AS sig FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
             WHERE n.nspname = 'public' AND p.prokind = 'f' LOOP
        EXECUTE format('ALTER FUNCTION %s SET search_path = public, pg_temp', f.sig);
    END LOOP;
END $$;

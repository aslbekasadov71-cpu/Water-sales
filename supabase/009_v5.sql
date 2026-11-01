-- v5: smenalar (ish soati), reklama bannerlari, kassa tarixi, jamoa statistikasi, mijoz profili.
-- Mijoz savatchasi yana mahsulot ID bo'yicha (rasmli katalog), buyurtma uchun ro'yxat (ism+telefon+manzil) shart.

-- ---------------------------------------------------------------- Smenalar
CREATE TABLE IF NOT EXISTS shifts (
    id         BIGSERIAL PRIMARY KEY,
    courier_id BIGINT NOT NULL REFERENCES users (tg_id),
    started_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    ended_at   TIMESTAMPTZ
);
CREATE INDEX IF NOT EXISTS idx_shifts_courier ON shifts (courier_id, started_at DESC);
CREATE UNIQUE INDEX IF NOT EXISTS uq_shift_open ON shifts (courier_id) WHERE ended_at IS NULL;
ALTER TABLE shifts ENABLE ROW LEVEL SECURITY;

-- Hozir ishda bo'lganlar uchun ochiq smena (migratsiya paytida)
INSERT INTO shifts(courier_id, started_at)
SELECT c.tg_id, now() FROM couriers c
WHERE c.is_online AND NOT EXISTS (SELECT 1 FROM shifts s WHERE s.courier_id = c.tg_id AND s.ended_at IS NULL);

-- «Ishni boshlash» / «Ishni tugatish»: smena ochiladi/yopiladi, zavod nuqtasi qo'yiladi
CREATE OR REPLACE FUNCTION courier_set_online(p jsonb) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE s jsonb := settings_json(); v_on boolean := (p->>'online')::boolean; c couriers%ROWTYPE; v_shift shifts%ROWTYPE;
BEGIN
    UPDATE couriers SET is_online = v_on WHERE tg_id = (p->>'tg_id')::bigint RETURNING * INTO c;
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

-- Davr ichida ishlangan daqiqalar (smenalar davr chegarasida kesiladi)
CREATE OR REPLACE FUNCTION worked_minutes(p_courier bigint, p_from timestamptz) RETURNS int LANGUAGE sql STABLE AS $$
    SELECT COALESCE(round(sum(extract(epoch FROM COALESCE(ended_at, now()) - GREATEST(started_at, p_from)) / 60)), 0)::int
    FROM shifts WHERE courier_id = p_courier AND COALESCE(ended_at, now()) > p_from
$$;

-- Dostavchining o'z hisobi (botdagi «Mening hisobim»)
CREATE OR REPLACE FUNCTION courier_summary(p jsonb) RETURNS jsonb LANGUAGE sql STABLE AS $$
    WITH t AS (SELECT period_start(1) AS t0, (p->>'tg_id')::bigint AS c)
    SELECT jsonb_build_object(
        'delivered', (SELECT count(*) FROM orders o, t WHERE o.courier_id = t.c AND o.status = 'delivered' AND o.delivered_at >= t.t0),
        'revenue', (SELECT COALESCE(sum(o.total), 0) FROM orders o, t WHERE o.courier_id = t.c AND o.status = 'delivered' AND o.delivered_at >= t.t0),
        'collected', (SELECT COALESCE(sum(delta), 0) FROM cash_ledger l, t WHERE l.courier_id = t.c AND l.kind = 'collected' AND l.created_at >= t.t0),
        'handed', (SELECT COALESCE(-sum(delta), 0) FROM cash_ledger l, t WHERE l.courier_id = t.c AND l.kind = 'handover' AND l.created_at >= t.t0),
        'debts', (SELECT COALESCE(sum(o.debt_amount), 0) FROM orders o, t WHERE o.courier_id = t.c AND o.status = 'delivered' AND o.delivered_at >= t.t0),
        'balance', cash_balance((p->>'tg_id')::bigint),
        'minutes', worked_minutes((p->>'tg_id')::bigint, (SELECT t0 FROM t)),
        'shift_started', (SELECT started_at FROM shifts s, t WHERE s.courier_id = t.c AND s.ended_at IS NULL),
        'active', (SELECT count(*) FROM orders o, t WHERE o.courier_id = t.c AND o.status = 'accepted'))
$$;

-- ---------------------------------------------------------------- Jamoa (rahbar uchun real ish rejimi)
CREATE OR REPLACE FUNCTION admin_team(p jsonb) RETURNS jsonb LANGUAGE sql STABLE AS $$
    WITH per AS (SELECT period_start(CASE WHEN (p->>'days') IN ('1', '7', '30') THEN (p->>'days')::int ELSE 1 END) AS t0)
    SELECT jsonb_build_object('days', CASE WHEN (p->>'days') IN ('1', '7', '30') THEN (p->>'days')::int ELSE 1 END,
      'list', COALESCE(jsonb_agg(x ORDER BY (x->>'online')::boolean DESC, (x->>'revenue')::bigint DESC, x->>'name'), '[]'))
    FROM (
      SELECT jsonb_build_object(
        'staff_id', s.id, 'tg_id', s.tg_id, 'name', s.full_name, 'phone', s.phone, 'login', s.login,
        'is_active', s.is_active, 'online', COALESCE(c.is_online, false),
        'shift_started', (SELECT started_at FROM shifts sh WHERE sh.courier_id = s.tg_id AND sh.ended_at IS NULL),
        'last_shift_end', (SELECT max(ended_at) FROM shifts sh WHERE sh.courier_id = s.tg_id),
        'minutes', worked_minutes(s.tg_id, per.t0),
        'shifts', (SELECT count(*) FROM shifts sh WHERE sh.courier_id = s.tg_id AND COALESCE(sh.ended_at, now()) > per.t0),
        'active', (SELECT count(*) FROM orders o WHERE o.courier_id = s.tg_id AND o.status = 'accepted'),
        'delivered', (SELECT count(*) FROM orders o WHERE o.courier_id = s.tg_id AND o.status = 'delivered' AND o.delivered_at >= per.t0),
        'revenue', (SELECT COALESCE(sum(o.total), 0) FROM orders o WHERE o.courier_id = s.tg_id AND o.status = 'delivered' AND o.delivered_at >= per.t0),
        'debts', (SELECT COALESCE(sum(o.debt_amount), 0) FROM orders o WHERE o.courier_id = s.tg_id AND o.status = 'delivered' AND o.delivered_at >= per.t0),
        'collected', (SELECT COALESCE(sum(l.delta), 0) FROM cash_ledger l WHERE l.courier_id = s.tg_id AND l.kind = 'collected' AND l.created_at >= per.t0),
        'handed', (SELECT COALESCE(-sum(l.delta), 0) FROM cash_ledger l WHERE l.courier_id = s.tg_id AND l.kind = 'handover' AND l.created_at >= per.t0),
        'balance', cash_balance(s.tg_id),
        'missed', (SELECT count(*) FROM order_offers f WHERE f.courier_id = s.tg_id AND f.result IN ('declined', 'expired') AND f.offered_at >= per.t0),
        'disputes', (SELECT count(*) FROM orders o WHERE o.courier_id = s.tg_id AND o.client_confirm = 'dispute' AND o.delivered_at >= per.t0),
        'confirmed', (SELECT count(*) FROM orders o WHERE o.courier_id = s.tg_id AND o.client_confirm = 'ok' AND o.delivered_at >= per.t0),
        'last_login_at', s.last_login_at) AS x
      FROM staff s CROSS JOIN per LEFT JOIN couriers c ON c.tg_id = s.tg_id
      WHERE s.role = 'courier'
    ) q
$$;

CREATE OR REPLACE FUNCTION admin_courier_detail(p jsonb) RETURNS jsonb LANGUAGE sql STABLE AS $$
    SELECT jsonb_build_object(
        'shifts', (SELECT COALESCE(jsonb_agg(jsonb_build_object('started_at', started_at, 'ended_at', ended_at,
                     'minutes', round(extract(epoch FROM COALESCE(ended_at, now()) - started_at) / 60)) ORDER BY started_at DESC), '[]')
                   FROM (SELECT * FROM shifts WHERE courier_id = (p->>'tg_id')::bigint ORDER BY started_at DESC LIMIT 20) x),
        'cash', (SELECT COALESCE(jsonb_agg(jsonb_build_object('at', created_at, 'delta', delta, 'kind', kind, 'order_id', order_id, 'note', note)
                     ORDER BY id DESC), '[]')
                 FROM (SELECT * FROM cash_ledger WHERE courier_id = (p->>'tg_id')::bigint ORDER BY id DESC LIMIT 40) x),
        'orders', (SELECT COALESCE(jsonb_agg(jsonb_build_object('id', id, 'status', status, 'total', total, 'paid', paid_amount,
                     'debt', debt_amount, 'at', COALESCE(delivered_at, accepted_at), 'address', address_note, 'confirm', client_confirm)
                     ORDER BY id DESC), '[]')
                   FROM (SELECT * FROM orders WHERE courier_id = (p->>'tg_id')::bigint ORDER BY id DESC LIMIT 20) x))
$$;

-- Kassa tarixi: kim, qachon, qancha topshirdi
CREATE OR REPLACE FUNCTION admin_cash_history(p jsonb) RETURNS jsonb LANGUAGE sql STABLE AS $$
    SELECT jsonb_build_object('list', COALESCE(jsonb_agg(jsonb_build_object('at', l.created_at, 'amount', -l.delta,
             'courier', COALESCE(s.full_name, u.full_name), 'courier_id', l.courier_id, 'note', l.note,
             'by', COALESCE(bs.full_name, bu.full_name)) ORDER BY l.id DESC), '[]'))
    FROM (SELECT * FROM cash_ledger WHERE kind = 'handover' ORDER BY id DESC LIMIT 100) l
    JOIN users u ON u.tg_id = l.courier_id LEFT JOIN staff s ON s.tg_id = l.courier_id
    LEFT JOIN users bu ON bu.tg_id = l.created_by LEFT JOIN staff bs ON bs.tg_id = l.created_by
$$;

-- ---------------------------------------------------------------- Reklama bannerlari
CREATE TABLE IF NOT EXISTS banners (
    id         SERIAL PRIMARY KEY,
    kind       TEXT NOT NULL CHECK (kind IN ('video', 'image')),
    url        TEXT NOT NULL,
    title      TEXT,
    sort_order INT NOT NULL DEFAULT 0,
    is_active  BOOLEAN NOT NULL DEFAULT TRUE,
    deleted_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
ALTER TABLE banners ENABLE ROW LEVEL SECURITY;

CREATE OR REPLACE FUNCTION admin_banners(p jsonb) RETURNS jsonb LANGUAGE sql STABLE AS $$
    SELECT jsonb_build_object('list', COALESCE(jsonb_agg(to_jsonb(b) ORDER BY b.sort_order, b.id), '[]'))
    FROM banners b WHERE b.deleted_at IS NULL
$$;

CREATE OR REPLACE FUNCTION admin_banner_create(p jsonb) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE v_id int;
BEGIN
    IF COALESCE(p->>'kind', '') NOT IN ('video', 'image') THEN RETURN jsonb_build_object('error', 'Fayl turi noto''g''ri'); END IF;
    IF COALESCE(p->>'url', '') !~ '^https://[^\s"''<>]+$' OR length(p->>'url') > 500 THEN
        RETURN jsonb_build_object('error', 'Fayl manzili noto''g''ri');
    END IF;
    IF (SELECT count(*) FROM banners WHERE deleted_at IS NULL) >= 10 THEN
        RETURN jsonb_build_object('error', 'Ko''pi bilan 10 ta banner. Avval eskisini o''chiring.');
    END IF;
    INSERT INTO banners(kind, url, title, sort_order)
    VALUES (p->>'kind', p->>'url', NULLIF(left(trim(COALESCE(p->>'title', '')), 80), ''),
            COALESCE((SELECT max(sort_order) FROM banners WHERE deleted_at IS NULL), 0) + 10)
    RETURNING id INTO v_id;
    PERFORM audit((p->>'actor')::bigint, 'banner_created', p - 'actor');
    RETURN jsonb_build_object('ok', true, 'id', v_id);
END $$;

CREATE OR REPLACE FUNCTION admin_banner_update(p jsonb) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE b banners%ROWTYPE; v_other banners%ROWTYPE;
BEGIN
    SELECT * INTO b FROM banners WHERE id = (p->>'id')::int AND deleted_at IS NULL FOR UPDATE;
    IF NOT FOUND THEN RETURN jsonb_build_object('error', 'Banner topilmadi'); END IF;
    IF p->>'op' = 'toggle' THEN
        UPDATE banners SET is_active = NOT is_active WHERE id = b.id;
    ELSIF p->>'op' = 'delete' THEN
        UPDATE banners SET deleted_at = now(), is_active = FALSE WHERE id = b.id;
    ELSIF p->>'op' IN ('up', 'down') THEN
        SELECT * INTO v_other FROM banners WHERE deleted_at IS NULL AND id <> b.id
          AND CASE WHEN p->>'op' = 'up' THEN (sort_order, id) < (b.sort_order, b.id) ELSE (sort_order, id) > (b.sort_order, b.id) END
        ORDER BY CASE WHEN p->>'op' = 'up' THEN sort_order END DESC, CASE WHEN p->>'op' = 'up' THEN id END DESC,
                 CASE WHEN p->>'op' = 'down' THEN sort_order END, CASE WHEN p->>'op' = 'down' THEN id END
        LIMIT 1 FOR UPDATE;
        IF FOUND THEN
            UPDATE banners SET sort_order = v_other.sort_order WHERE id = b.id;
            UPDATE banners SET sort_order = b.sort_order WHERE id = v_other.id;
            IF v_other.sort_order = b.sort_order THEN
                UPDATE banners SET sort_order = sort_order + CASE WHEN p->>'op' = 'up' THEN -1 ELSE 1 END WHERE id = b.id;
            END IF;
        END IF;
    ELSIF p->>'op' = 'title' THEN
        UPDATE banners SET title = NULLIF(left(trim(COALESCE(p->>'title', '')), 80), '') WHERE id = b.id;
    ELSE
        RETURN jsonb_build_object('error', 'Noma''lum amal');
    END IF;
    PERFORM audit((p->>'actor')::bigint, 'banner_' || (p->>'op'), jsonb_build_object('id', b.id));
    RETURN jsonb_build_object('ok', true);
END $$;

-- ---------------------------------------------------------------- Mijoz
CREATE OR REPLACE FUNCTION client_me(p jsonb) RETURNS jsonb LANGUAGE sql STABLE AS $$
    WITH u AS (SELECT * FROM users WHERE tg_id = (p->>'tg_id')::bigint)
    SELECT jsonb_build_object(
        'user', (SELECT jsonb_build_object('tg_id', tg_id, 'name', full_name, 'phone', phone, 'role', role,
                  'type', customer_type, 'business', business_name,
                  'registered', name_locked AND phone IS NOT NULL AND last_lat IS NOT NULL,
                  'last_lat', last_lat, 'last_lon', last_lon, 'last_address', last_address) FROM u),
        'products', (SELECT COALESCE(jsonb_agg(jsonb_build_object('id', pr.id, 'volume_l', pr.volume_l, 'title', pr.title,
                      'price', CASE WHEN (SELECT customer_type FROM u) = 'wholesale'
                                    THEN COALESCE(pr.wholesale_price, pr.price) ELSE pr.price END,
                      'retail_price', pr.price, 'returnable', pr.returnable, 'image_url', pr.image_url,
                      'description', pr.description, 'unit', pr.unit) ORDER BY pr.sort_order, pr.id), '[]')
                     FROM products pr WHERE pr.is_active),
        'settings', (SELECT jsonb_build_object('delivery_fee', s->'delivery_fee', 'prices_final', s->'prices_final',
                      'support_phone', s->'support_phone') FROM settings_json() s),
        'banners', (SELECT COALESCE(jsonb_agg(jsonb_build_object('id', b.id, 'kind', b.kind, 'url', b.url, 'title', b.title)
                      ORDER BY b.sort_order, b.id), '[]') FROM banners b WHERE b.is_active AND b.deleted_at IS NULL),
        'bottles', bottle_balance_json((p->>'tg_id')::bigint),
        'debt', debt_balance((p->>'tg_id')::bigint),
        'orders', (SELECT COALESCE(jsonb_agg(order_json(id) ORDER BY id DESC), '[]')
                   FROM (SELECT id FROM orders WHERE client_id = (p->>'tg_id')::bigint ORDER BY id DESC LIMIT 15) x))
$$;

CREATE OR REPLACE FUNCTION create_order(p jsonb) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
    v_client bigint := (p->>'client_id')::bigint;
    v_user users%ROWTYPE;
    v_existing bigint; v_id bigint;
    v_items_total bigint := 0; v_fee bigint; v_n int := 0;
    v_wholesale boolean; v_max int;
    r record;
BEGIN
    SELECT id INTO v_existing FROM orders WHERE idem_key = p->>'idem';
    IF FOUND THEN RETURN jsonb_build_object('id', v_existing, 'created', false); END IF;
    SELECT * INTO v_user FROM users WHERE tg_id = v_client;
    IF NOT FOUND OR v_user.phone IS NULL OR NOT v_user.name_locked OR v_user.is_blocked THEN
        RETURN jsonb_build_object('error', 'Avval botda ro''yxatdan o''ting (ism, telefon, manzil).');
    END IF;
    v_wholesale := v_user.customer_type = 'wholesale';
    v_max := CASE WHEN v_wholesale THEN 1000 ELSE 100 END;
    IF (SELECT count(*) FROM orders WHERE client_id = v_client
        AND status IN ('new', 'offered', 'unassigned', 'accepted')) >= (CASE WHEN v_wholesale THEN 10 ELSE 3 END) THEN
        RETURN jsonb_build_object('error', 'Sizda yakunlanmagan buyurtmalar bor. Ular yetkazilgach yangisini bering.');
    END IF;
    IF (p->>'lat') IS NULL OR (p->>'lon') IS NULL
       OR abs((p->>'lat')::float8) > 90 OR abs((p->>'lon')::float8) > 180 THEN
        RETURN jsonb_build_object('error', 'Manzil belgilanmagan.');
    END IF;
    FOR r IN SELECT pr.*, (c.value)::int AS qty,
                    CASE WHEN v_wholesale THEN COALESCE(pr.wholesale_price, pr.price) ELSE pr.price END AS eff_price
             FROM jsonb_each_text(COALESCE(p->'cart', '{}')) c
             JOIN products pr ON pr.id::text = c.key AND pr.is_active
             WHERE c.value ~ '^\d{1,4}$' AND c.value::int BETWEEN 1 AND v_max LOOP
        v_items_total := v_items_total + r.eff_price * r.qty;
        v_n := v_n + 1;
    END LOOP;
    IF v_n = 0 OR v_n <> (SELECT count(*) FROM jsonb_object_keys(COALESCE(p->'cart', '{}'))) THEN
        RETURN jsonb_build_object('error', 'Savatchada noto''g''ri mahsulot bor. Sahifani yangilab qayta urinib ko''ring.');
    END IF;
    v_fee := (settings_json()->>'delivery_fee')::bigint;
    INSERT INTO orders(idem_key, client_id, status, phone, lat, lon, address_note, delivery_time,
                       payment_method, price_type, items_total, delivery_fee, total)
    VALUES (p->>'idem', v_client, 'new', v_user.phone, (p->>'lat')::float8, (p->>'lon')::float8,
            left(COALESCE(p->>'address', ''), 300), left(COALESCE(p->>'time', ''), 100), 'cash',
            CASE WHEN v_wholesale THEN 'wholesale' ELSE 'retail' END,
            v_items_total, v_fee, v_items_total + v_fee)
    ON CONFLICT (idem_key) DO NOTHING RETURNING id INTO v_id;
    IF v_id IS NULL THEN
        RETURN jsonb_build_object('id', (SELECT id FROM orders WHERE idem_key = p->>'idem'), 'created', false);
    END IF;
    INSERT INTO order_items(order_id, product_id, volume_l, title, qty, unit_price, returnable)
    SELECT v_id, pr.id, pr.volume_l, pr.title, (c.value)::int,
           CASE WHEN v_wholesale THEN COALESCE(pr.wholesale_price, pr.price) ELSE pr.price END, pr.returnable
    FROM jsonb_each_text(p->'cart') c JOIN products pr ON pr.id::text = c.key;
    UPDATE users SET last_lat = (p->>'lat')::float8, last_lon = (p->>'lon')::float8,
                     last_address = left(COALESCE(p->>'address', ''), 300) WHERE tg_id = v_client;
    RETURN jsonb_build_object('id', v_id, 'created', true, 'order', order_json(v_id));
END $$;

-- Mijoz sozlamalari: ism-familiya va manzil (telefon faqat botda kontakt orqali)
CREATE OR REPLACE FUNCTION client_profile_update(p jsonb) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE u users%ROWTYPE;
BEGIN
    IF p ? 'name' AND (length(trim(p->>'name')) < 3 OR length(trim(p->>'name')) > 60
                       OR trim(p->>'name') !~ '^[^0-9<>@#$%^&*=+_{}\[\]|\\/~`]+\s+[^0-9<>@#$%^&*=+_{}\[\]|\\/~`]+') THEN
        RETURN jsonb_build_object('error', 'Ism va familiyani to''liq yozing');
    END IF;
    IF p ? 'lat' AND ((p->>'lat') IS NULL OR abs((p->>'lat')::float8) > 90 OR abs((p->>'lon')::float8) > 180) THEN
        RETURN jsonb_build_object('error', 'Manzil noto''g''ri');
    END IF;
    UPDATE users SET
        full_name    = CASE WHEN p ? 'name' THEN regexp_replace(trim(p->>'name'), '\s+', ' ', 'g') ELSE full_name END,
        name_locked  = name_locked OR p ? 'name',
        last_lat     = CASE WHEN p ? 'lat' THEN (p->>'lat')::float8 ELSE last_lat END,
        last_lon     = CASE WHEN p ? 'lat' THEN (p->>'lon')::float8 ELSE last_lon END,
        last_address = CASE WHEN p ? 'address' THEN left(trim(p->>'address'), 300) ELSE last_address END
    WHERE tg_id = (p->>'tg_id')::bigint RETURNING * INTO u;
    IF NOT FOUND THEN RETURN jsonb_build_object('error', 'Foydalanuvchi topilmadi'); END IF;
    RETURN jsonb_build_object('ok', true, 'name', u.full_name, 'address', u.last_address, 'lat', u.last_lat, 'lon', u.last_lon);
END $$;

-- Zaxira nusxaga yangi jadvallar
CREATE OR REPLACE FUNCTION export_all(p jsonb) RETURNS jsonb LANGUAGE sql STABLE AS $$
    SELECT jsonb_build_object(
        'version', 4, 'exported_at', now(),
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
        'cash_ledger', (SELECT COALESCE(jsonb_agg(t), '[]') FROM cash_ledger t),
        'shifts', (SELECT COALESCE(jsonb_agg(t), '[]') FROM shifts t),
        'banners', (SELECT COALESCE(jsonb_agg(t), '[]') FROM banners t))
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
    INSERT INTO shifts SELECT * FROM jsonb_populate_recordset(NULL::shifts, COALESCE(p->'shifts', '[]'));
    INSERT INTO banners SELECT * FROM jsonb_populate_recordset(NULL::banners, COALESCE(p->'banners', '[]'));
    PERFORM setval(pg_get_serial_sequence('shifts', 'id'), COALESCE((SELECT max(id) FROM shifts), 1));
    PERFORM setval(pg_get_serial_sequence('banners', 'id'), COALESCE((SELECT max(id) FROM banners), 1));
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

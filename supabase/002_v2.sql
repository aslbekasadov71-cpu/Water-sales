-- ZamZam v2: optom narx, xodimlar (login/parol), qarz daftari, yaroqsiz tara izohlari,
-- mijoz dostavchini xaritada ko'rishi. schema.sql dan keyin ishga tushiriladi. Qayta ishga tushirish xavfsiz.

ALTER TABLE products ADD COLUMN IF NOT EXISTS wholesale_price BIGINT;
ALTER TABLE users ADD COLUMN IF NOT EXISTS customer_type TEXT NOT NULL DEFAULT 'retail';
ALTER TABLE users ADD COLUMN IF NOT EXISTS business_name TEXT;
ALTER TABLE orders ADD COLUMN IF NOT EXISTS price_type TEXT NOT NULL DEFAULT 'retail';
ALTER TABLE orders ADD COLUMN IF NOT EXISTS paid_amount BIGINT;
ALTER TABLE orders ADD COLUMN IF NOT EXISTS debt_amount BIGINT NOT NULL DEFAULT 0;

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'users_customer_type_chk') THEN
        ALTER TABLE users ADD CONSTRAINT users_customer_type_chk CHECK (customer_type IN ('retail', 'wholesale'));
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'products_wholesale_price_chk') THEN
        ALTER TABLE products ADD CONSTRAINT products_wholesale_price_chk CHECK (wholesale_price IS NULL OR wholesale_price >= 0);
    END IF;
END $$;

-- Xodimlar: rahbar (owner) va dostavchilar (courier). Har biri login + parol bilan xodimlar botiga kiradi.
CREATE TABLE IF NOT EXISTS staff (
    id            SERIAL PRIMARY KEY,
    login         TEXT NOT NULL UNIQUE,
    pass_hash     TEXT NOT NULL,
    pass_salt     TEXT NOT NULL,
    full_name     TEXT NOT NULL,
    phone         TEXT,
    role          TEXT NOT NULL CHECK (role IN ('owner', 'courier')),
    tg_id         BIGINT UNIQUE,
    is_active     BOOLEAN NOT NULL DEFAULT TRUE,
    created_by    BIGINT,
    created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    last_login_at TIMESTAMPTZ
);

CREATE TABLE IF NOT EXISTS login_attempts (
    id    BIGSERIAL PRIMARY KEY,
    tg_id BIGINT NOT NULL,
    ok    BOOLEAN NOT NULL,
    at    TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_login_attempts ON login_attempts (tg_id, at DESC);

-- Qarz daftari: +N = mijoz qarz bo'ldi, -N = qarzini to'ladi
CREATE TABLE IF NOT EXISTS debt_ledger (
    id         BIGSERIAL PRIMARY KEY,
    client_id  BIGINT NOT NULL REFERENCES users (tg_id),
    order_id   BIGINT REFERENCES orders (id),
    delta      BIGINT NOT NULL CHECK (delta <> 0),
    kind       TEXT NOT NULL CHECK (kind IN ('debt', 'payment', 'adjust')),
    note       TEXT,
    created_by BIGINT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_debt_client ON debt_ledger (client_id);

-- Buyurtma izohlari (masalan: yaroqsiz tara qabul qilinmadi)
CREATE TABLE IF NOT EXISTS order_notes (
    id         BIGSERIAL PRIMARY KEY,
    order_id   BIGINT REFERENCES orders (id),
    client_id  BIGINT NOT NULL REFERENCES users (tg_id),
    kind       TEXT NOT NULL CHECK (kind IN ('defective', 'note')),
    volume_l   INT,
    qty        INT,
    text       TEXT NOT NULL,
    created_by BIGINT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_order_notes_client ON order_notes (client_id);

ALTER TABLE staff ENABLE ROW LEVEL SECURITY;
ALTER TABLE login_attempts ENABLE ROW LEVEL SECURITY;
ALTER TABLE debt_ledger ENABLE ROW LEVEL SECURITY;
ALTER TABLE order_notes ENABLE ROW LEVEL SECURITY;

-- =====================================================================
-- Yordamchilar
-- =====================================================================
CREATE OR REPLACE FUNCTION debt_balance(p_client bigint) RETURNS bigint LANGUAGE sql STABLE AS $$
    SELECT COALESCE(SUM(delta), 0)::bigint FROM debt_ledger WHERE client_id = p_client
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
        'courier', (SELECT jsonb_build_object('name', u.full_name, 'phone', u.phone) FROM users u WHERE u.tg_id = o.courier_id),
        'courier_loc', (SELECT jsonb_build_object('lat', c.lat, 'lon', c.lon, 'at', c.location_at)
                        FROM couriers c WHERE c.tg_id = o.courier_id AND o.status = 'accepted' AND c.lat IS NOT NULL),
        'offers', (SELECT COALESCE(jsonb_agg(jsonb_build_object('name', u.full_name, 'result', f.result,
                    'distance_km', f.distance_km) ORDER BY f.id), '[]')
                   FROM order_offers f JOIN users u ON u.tg_id = f.courier_id WHERE f.order_id = o.id),
        'notes', (SELECT COALESCE(jsonb_agg(jsonb_build_object('kind', n.kind, 'volume_l', n.volume_l, 'qty', n.qty,
                    'text', n.text, 'at', n.created_at) ORDER BY n.id), '[]')
                  FROM order_notes n WHERE n.order_id = o.id))
    FROM orders o WHERE o.id = p_id
$$;

-- =====================================================================
-- Mijoz
-- =====================================================================
CREATE OR REPLACE FUNCTION client_me(p jsonb) RETURNS jsonb LANGUAGE sql STABLE AS $$
    WITH u AS (SELECT * FROM users WHERE tg_id = (p->>'tg_id')::bigint)
    SELECT jsonb_build_object(
        'user', (SELECT jsonb_build_object('tg_id', tg_id, 'name', full_name, 'phone', phone, 'role', role,
                  'type', customer_type, 'business', business_name,
                  'last_lat', last_lat, 'last_lon', last_lon, 'last_address', last_address) FROM u),
        'products', (SELECT COALESCE(jsonb_agg(jsonb_build_object('volume_l', pr.volume_l, 'title', pr.title,
                      'price', CASE WHEN (SELECT customer_type FROM u) = 'wholesale'
                                    THEN COALESCE(pr.wholesale_price, pr.price) ELSE pr.price END,
                      'retail_price', pr.price, 'returnable', pr.returnable) ORDER BY pr.volume_l), '[]')
                     FROM products pr WHERE pr.is_active),
        'settings', (SELECT jsonb_build_object('delivery_fee', s->'delivery_fee', 'prices_final', s->'prices_final',
                      'support_phone', s->'support_phone') FROM settings_json() s),
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
    v_wholesale boolean;
    r record;
BEGIN
    SELECT id INTO v_existing FROM orders WHERE idem_key = p->>'idem';
    IF FOUND THEN RETURN jsonb_build_object('id', v_existing, 'created', false); END IF;
    SELECT * INTO v_user FROM users WHERE tg_id = v_client;
    IF NOT FOUND OR v_user.phone IS NULL OR v_user.is_blocked THEN
        RETURN jsonb_build_object('error', 'Avval botda telefon raqamingizni yuboring.');
    END IF;
    v_wholesale := v_user.customer_type = 'wholesale';
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
             JOIN products pr ON pr.volume_l = c.key::int AND pr.is_active
             WHERE c.value ~ '^\d{1,4}$' AND c.value::int BETWEEN 1 AND (CASE WHEN v_wholesale THEN 1000 ELSE 100 END) LOOP
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
    FROM jsonb_each_text(p->'cart') c JOIN products pr ON pr.volume_l = c.key::int;
    UPDATE users SET last_lat = (p->>'lat')::float8, last_lon = (p->>'lon')::float8,
                     last_address = left(COALESCE(p->>'address', ''), 300) WHERE tg_id = v_client;
    RETURN jsonb_build_object('id', v_id, 'created', true, 'order', order_json(v_id));
END $$;

-- =====================================================================
-- Dostavchi: yetkazish (qarz va yaroqsiz tara bilan)
-- =====================================================================
CREATE OR REPLACE FUNCTION delivery_info(p jsonb) RETURNS jsonb LANGUAGE sql STABLE AS $$
    SELECT jsonb_build_object('ok', true, 'order', order_json(o.id), 'balance', bottle_balance_json(o.client_id),
                              'debt', debt_balance(o.client_id))
    FROM orders o
    WHERE o.id = (p->>'order_id')::bigint AND o.status = 'accepted' AND o.courier_id = (p->>'courier_id')::bigint
$$;

CREATE OR REPLACE FUNCTION complete_delivery(p jsonb) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
    v_id bigint := (p->>'order_id')::bigint; v_c bigint := (p->>'courier_id')::bigint;
    o orders%ROWTYPE; r record;
    v_debt bigint; v_paid bigint; v_delta bigint;
BEGIN
    SELECT * INTO o FROM orders WHERE id = v_id AND status = 'accepted' AND courier_id = v_c FOR UPDATE;
    IF NOT FOUND THEN RETURN jsonb_build_object('ok', false); END IF;
    v_debt := GREATEST(debt_balance(o.client_id), 0);
    IF p ? 'paid' THEN
        IF (p->>'paid') !~ '^\d{1,10}$' THEN RETURN jsonb_build_object('ok', false, 'error', 'To''lov summasi noto''g''ri'); END IF;
        v_paid := (p->>'paid')::bigint;
    ELSE
        v_paid := o.total;
    END IF;
    IF v_paid > o.total + v_debt THEN
        RETURN jsonb_build_object('ok', false, 'error',
            format('To''lov juda katta: buyurtma %s, eski qarz %s so''m', o.total, v_debt));
    END IF;
    v_delta := o.total - v_paid;
    UPDATE orders SET status = 'delivered', delivered_at = now(), paid_amount = v_paid,
                      debt_amount = GREATEST(v_delta, 0) WHERE id = v_id;
    IF v_delta <> 0 THEN
        INSERT INTO debt_ledger(client_id, order_id, delta, kind, note, created_by)
        VALUES (o.client_id, v_id, v_delta, CASE WHEN v_delta > 0 THEN 'debt' ELSE 'payment' END,
                CASE WHEN v_delta > 0 THEN 'Yetkazishda to''liq to''lanmadi' ELSE 'Eski qarz to''landi' END, v_c);
    END IF;
    INSERT INTO bottle_ledger(client_id, order_id, volume_l, delta, reason, created_by)
    SELECT o.client_id, v_id, volume_l, SUM(qty), 'delivered', v_c FROM order_items
    WHERE order_id = v_id AND returnable GROUP BY volume_l;
    FOR r IN SELECT key::int AS vol, value::int AS n FROM jsonb_each_text(COALESCE(p->'returns', '{}'))
             WHERE value ~ '^\d{1,4}$' AND value::int > 0 LOOP
        INSERT INTO bottle_ledger(client_id, order_id, volume_l, delta, reason, created_by)
        VALUES (o.client_id, v_id, r.vol, -r.n, 'returned', v_c);
    END LOOP;
    FOR r IN SELECT (d->>'volume_l')::int AS vol, (d->>'qty')::int AS n, left(COALESCE(d->>'comment', ''), 300) AS txt
             FROM jsonb_array_elements(COALESCE(p->'defective', '[]')) d
             WHERE (d->>'qty') ~ '^\d{1,4}$' AND (d->>'qty')::int > 0 LOOP
        INSERT INTO order_notes(order_id, client_id, kind, volume_l, qty, text, created_by)
        VALUES (v_id, o.client_id, 'defective', r.vol, r.n,
                CASE WHEN r.txt = '' THEN 'Yaroqsiz tara qabul qilinmadi' ELSE r.txt END, v_c);
    END LOOP;
    RETURN jsonb_build_object('ok', true, 'client_id', o.client_id, 'total', o.total, 'paid', v_paid,
                              'debt', debt_balance(o.client_id), 'balance', bottle_balance_json(o.client_id));
END $$;

CREATE OR REPLACE FUNCTION courier_today(p jsonb) RETURNS jsonb LANGUAGE sql STABLE AS $$
    SELECT jsonb_build_object(
        'delivered', (SELECT count(*) FROM orders WHERE courier_id = (p->>'tg_id')::bigint AND status = 'delivered'
                      AND delivered_at >= period_start(1)),
        'cash', (SELECT COALESCE(SUM(COALESCE(paid_amount, total)), 0) FROM orders WHERE courier_id = (p->>'tg_id')::bigint
                 AND status = 'delivered' AND delivered_at >= period_start(1)),
        'debts', (SELECT COALESCE(SUM(debt_amount), 0) FROM orders WHERE courier_id = (p->>'tg_id')::bigint
                  AND status = 'delivered' AND delivered_at >= period_start(1)),
        'bottles', (SELECT COALESCE(jsonb_agg(jsonb_build_object('volume_l', volume_l, 'given', given,
                     'returned', returned) ORDER BY volume_l), '[]')
                    FROM (SELECT l.volume_l,
                                 SUM(CASE WHEN l.delta > 0 THEN l.delta ELSE 0 END)::int AS given,
                                 SUM(CASE WHEN l.delta < 0 THEN -l.delta ELSE 0 END)::int AS returned
                          FROM bottle_ledger l JOIN orders o ON o.id = l.order_id
                          WHERE o.courier_id = (p->>'tg_id')::bigint AND o.delivered_at >= period_start(1)
                            AND l.reason IN ('delivered', 'returned')
                          GROUP BY l.volume_l) b))
$$;

-- =====================================================================
-- Xodimlar: kirish (login/parol)
-- =====================================================================
CREATE OR REPLACE FUNCTION staff_me(p jsonb) RETURNS jsonb LANGUAGE sql STABLE AS $$
    SELECT jsonb_build_object('id', id, 'login', login, 'full_name', full_name, 'phone', phone, 'role', role)
    FROM staff WHERE tg_id = (p->>'tg_id')::bigint AND is_active
$$;

CREATE OR REPLACE FUNCTION staff_login_blocked(p jsonb) RETURNS jsonb LANGUAGE sql STABLE AS $$
    SELECT jsonb_build_object('blocked', count(*) >= 5)
    FROM login_attempts
    WHERE tg_id = (p->>'tg_id')::bigint AND NOT ok AND at > now() - interval '15 minutes'
      AND at > COALESCE((SELECT max(at) FROM login_attempts WHERE tg_id = (p->>'tg_id')::bigint AND ok), '-infinity')
$$;

CREATE OR REPLACE FUNCTION staff_auth_get(p jsonb) RETURNS jsonb LANGUAGE sql STABLE AS $$
    SELECT jsonb_build_object('id', id, 'pass_hash', pass_hash, 'pass_salt', pass_salt, 'is_active', is_active, 'role', role)
    FROM staff WHERE login = lower(trim(p->>'login'))
$$;

CREATE OR REPLACE FUNCTION staff_login_record(p jsonb) RETURNS jsonb LANGUAGE sql AS $$
    INSERT INTO login_attempts(tg_id, ok) VALUES ((p->>'tg_id')::bigint, (p->>'ok')::boolean)
    RETURNING jsonb_build_object('ok', true)
$$;

CREATE OR REPLACE FUNCTION staff_bind(p jsonb) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE s staff%ROWTYPE; v_tg bigint := (p->>'tg_id')::bigint;
BEGIN
    SELECT * INTO s FROM staff WHERE id = (p->>'staff_id')::int AND is_active FOR UPDATE;
    IF NOT FOUND THEN RETURN jsonb_build_object('ok', false); END IF;
    -- shu Telegram akkaunti boshqa xodimga bog'langan bo'lsa, uni ajratamiz
    UPDATE staff SET tg_id = NULL WHERE tg_id = v_tg AND id <> s.id;
    -- bu xodim boshqa telefonda kirgan bo'lsa, eski akkaunt dostavchilikdan chiqadi
    IF s.tg_id IS NOT NULL AND s.tg_id <> v_tg THEN
        UPDATE couriers SET is_active = FALSE, is_online = FALSE WHERE tg_id = s.tg_id;
        UPDATE users SET role = 'client' WHERE tg_id = s.tg_id;
    END IF;
    UPDATE staff SET tg_id = v_tg, last_login_at = now() WHERE id = s.id;
    INSERT INTO users(tg_id, full_name) VALUES (v_tg, s.full_name) ON CONFLICT (tg_id) DO NOTHING;
    IF s.role = 'courier' THEN
        UPDATE users SET role = 'courier', phone = COALESCE(phone, s.phone) WHERE tg_id = v_tg;
        INSERT INTO couriers(tg_id) VALUES (v_tg) ON CONFLICT (tg_id) DO UPDATE SET is_active = TRUE;
    END IF;
    PERFORM audit(v_tg, 'staff_login', jsonb_build_object('staff_id', s.id, 'login', s.login));
    RETURN jsonb_build_object('ok', true, 'id', s.id, 'full_name', s.full_name, 'role', s.role);
END $$;

CREATE OR REPLACE FUNCTION staff_logout(p jsonb) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE v_tg bigint := (p->>'tg_id')::bigint; v_active int;
BEGIN
    SELECT count(*) INTO v_active FROM orders WHERE courier_id = v_tg AND status = 'accepted';
    IF v_active > 0 THEN
        RETURN jsonb_build_object('ok', false, 'error', format('Sizda %s ta yetkazilmagan buyurtma bor. Avval ularni yakunlang.', v_active));
    END IF;
    UPDATE staff SET tg_id = NULL WHERE tg_id = v_tg;
    UPDATE couriers SET is_active = FALSE, is_online = FALSE WHERE tg_id = v_tg;
    UPDATE users SET role = 'client' WHERE tg_id = v_tg AND role = 'courier';
    RETURN jsonb_build_object('ok', true);
END $$;

-- =====================================================================
-- Rahbar: xodimlar
-- =====================================================================
CREATE OR REPLACE FUNCTION admin_staff_list(p jsonb) RETURNS jsonb LANGUAGE sql STABLE AS $$
    SELECT jsonb_build_object('staff', COALESCE(jsonb_agg(jsonb_build_object(
        'id', s.id, 'login', s.login, 'full_name', s.full_name, 'phone', s.phone, 'role', s.role,
        'tg_id', s.tg_id, 'is_active', s.is_active, 'last_login_at', s.last_login_at,
        'online', COALESCE(c.is_online AND c.location_at > now() - make_interval(mins => (settings_json()->>'location_stale_min')::int), false),
        'location_at', c.location_at, 'lat', c.lat, 'lon', c.lon,
        'active', (SELECT count(*) FROM orders o WHERE o.courier_id = s.tg_id AND o.status = 'accepted'),
        'today', (SELECT count(*) FROM orders o WHERE o.courier_id = s.tg_id AND o.status = 'delivered' AND o.delivered_at >= period_start(1)),
        'cash', (SELECT COALESCE(SUM(COALESCE(paid_amount, total)), 0) FROM orders o WHERE o.courier_id = s.tg_id
                 AND o.status = 'delivered' AND o.delivered_at >= period_start(1))
    ) ORDER BY s.role DESC, s.full_name), '[]'))
    FROM staff s LEFT JOIN couriers c ON c.tg_id = s.tg_id
$$;

CREATE OR REPLACE FUNCTION admin_staff_create(p jsonb) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE v_login text := lower(trim(p->>'login')); v_id int;
BEGIN
    IF v_login !~ '^[a-z0-9_.]{3,32}$' THEN
        RETURN jsonb_build_object('error', 'Login 3–32 belgi: lotin harflari, raqam, _ yoki .');
    END IF;
    IF length(trim(COALESCE(p->>'full_name', ''))) < 2 THEN RETURN jsonb_build_object('error', 'Ismni kiriting'); END IF;
    IF p->>'role' NOT IN ('owner', 'courier') THEN RETURN jsonb_build_object('error', 'Lavozim noto''g''ri'); END IF;
    IF EXISTS (SELECT 1 FROM staff WHERE login = v_login) THEN RETURN jsonb_build_object('error', 'Bu login band'); END IF;
    INSERT INTO staff(login, pass_hash, pass_salt, full_name, phone, role, created_by)
    VALUES (v_login, p->>'pass_hash', p->>'pass_salt', left(trim(p->>'full_name'), 80), left(p->>'phone', 30),
            p->>'role', (p->>'actor')::bigint)
    RETURNING id INTO v_id;
    PERFORM audit((p->>'actor')::bigint, 'staff_created', jsonb_build_object('id', v_id, 'login', v_login, 'role', p->>'role'));
    RETURN jsonb_build_object('ok', true, 'id', v_id);
END $$;

CREATE OR REPLACE FUNCTION admin_staff_update(p jsonb) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE s staff%ROWTYPE; v_active int;
BEGIN
    SELECT * INTO s FROM staff WHERE id = (p->>'id')::int FOR UPDATE;
    IF NOT FOUND THEN RETURN jsonb_build_object('error', 'Xodim topilmadi'); END IF;
    IF p->>'op' IN ('toggle', 'unbind') AND s.is_active AND s.tg_id IS NOT NULL THEN
        SELECT count(*) INTO v_active FROM orders WHERE courier_id = s.tg_id AND status = 'accepted';
        IF v_active > 0 THEN
            RETURN jsonb_build_object('error', format('Unda %s ta faol buyurtma bor. Avval ularni boshqasiga o''tkazing.', v_active));
        END IF;
    END IF;
    IF p->>'op' = 'toggle' THEN
        UPDATE staff SET is_active = NOT is_active WHERE id = s.id;
        IF s.tg_id IS NOT NULL THEN
            UPDATE couriers SET is_active = NOT s.is_active AND s.role = 'courier', is_online = FALSE WHERE tg_id = s.tg_id;
        END IF;
    ELSIF p->>'op' = 'reset' THEN
        UPDATE staff SET pass_hash = p->>'pass_hash', pass_salt = p->>'pass_salt' WHERE id = s.id;
    ELSIF p->>'op' = 'unbind' THEN
        UPDATE staff SET tg_id = NULL WHERE id = s.id;
        IF s.tg_id IS NOT NULL THEN
            UPDATE couriers SET is_active = FALSE, is_online = FALSE WHERE tg_id = s.tg_id;
            UPDATE users SET role = 'client' WHERE tg_id = s.tg_id AND role = 'courier';
        END IF;
    ELSE
        RETURN jsonb_build_object('error', 'Noma''lum amal');
    END IF;
    PERFORM audit((p->>'actor')::bigint, 'staff_' || (p->>'op'), jsonb_build_object('id', s.id, 'login', s.login));
    RETURN jsonb_build_object('ok', true, 'tg_id', s.tg_id);
END $$;

-- =====================================================================
-- Rahbar: mijozlar, qarzlar, narxlar, hisobot
-- =====================================================================
CREATE OR REPLACE FUNCTION admin_clients(p jsonb) RETURNS jsonb LANGUAGE sql STABLE AS $$
    WITH c AS (
        SELECT u.tg_id, u.full_name, u.phone, u.customer_type, u.business_name,
               debt_balance(u.tg_id) AS debt,
               (SELECT COALESCE(SUM(delta), 0) FROM bottle_ledger b WHERE b.client_id = u.tg_id)::int AS bottles,
               (SELECT count(*) FROM orders o WHERE o.client_id = u.tg_id) AS orders,
               (SELECT max(created_at) FROM orders o WHERE o.client_id = u.tg_id) AS last_order
        FROM users u
        WHERE u.phone IS NOT NULL
          AND (COALESCE(p->>'digits', '') = '' OR regexp_replace(u.phone, '\D', '', 'g') LIKE '%' || (p->>'digits'))
          AND (COALESCE(p->>'filter', 'all') = 'all'
               OR (p->>'filter' = 'wholesale' AND u.customer_type = 'wholesale')
               OR (p->>'filter' = 'debt' AND debt_balance(u.tg_id) > 0)
               OR (p->>'filter' = 'bottles' AND EXISTS (SELECT 1 FROM bottle_ledger b WHERE b.client_id = u.tg_id
                                                        GROUP BY b.client_id HAVING SUM(b.delta) > 0)))
          AND EXISTS (SELECT 1 FROM orders o WHERE o.client_id = u.tg_id
                      UNION ALL SELECT 1 FROM debt_ledger d WHERE d.client_id = u.tg_id
                      UNION ALL SELECT 1 WHERE u.customer_type = 'wholesale' OR COALESCE(p->>'digits', '') <> '')
    )
    SELECT jsonb_build_object(
        'clients', (SELECT COALESCE(jsonb_agg(to_jsonb(c) ORDER BY c.debt DESC, c.last_order DESC NULLS LAST), '[]')
                    FROM (SELECT * FROM c ORDER BY debt DESC, last_order DESC NULLS LAST LIMIT 60) c),
        'totals', jsonb_build_object(
            'debt', (SELECT COALESCE(SUM(delta), 0) FROM debt_ledger),
            'debtors', (SELECT count(*) FROM (SELECT client_id FROM debt_ledger GROUP BY client_id HAVING SUM(delta) > 0) x),
            'bottles', (SELECT COALESCE(jsonb_agg(x ORDER BY x.volume_l), '[]') FROM (
                          SELECT volume_l, SUM(delta)::int AS n FROM bottle_ledger GROUP BY volume_l) x),
            'wholesale', (SELECT count(*) FROM users WHERE customer_type = 'wholesale')))
$$;

CREATE OR REPLACE FUNCTION admin_client(p jsonb) RETURNS jsonb LANGUAGE sql STABLE AS $$
    SELECT jsonb_build_object(
        'tg_id', u.tg_id, 'name', u.full_name, 'phone', u.phone, 'type', u.customer_type, 'business', u.business_name,
        'address', u.last_address, 'created_at', u.created_at,
        'debt', debt_balance(u.tg_id), 'bottles', bottle_balance_json(u.tg_id),
        'debt_history', (SELECT COALESCE(jsonb_agg(jsonb_build_object('delta', d.delta, 'kind', d.kind, 'note', d.note,
                          'order_id', d.order_id, 'at', d.created_at) ORDER BY d.id DESC), '[]')
                         FROM (SELECT * FROM debt_ledger WHERE client_id = u.tg_id ORDER BY id DESC LIMIT 20) d),
        'notes', (SELECT COALESCE(jsonb_agg(jsonb_build_object('kind', n.kind, 'volume_l', n.volume_l, 'qty', n.qty,
                   'text', n.text, 'order_id', n.order_id, 'at', n.created_at) ORDER BY n.id DESC), '[]')
                  FROM (SELECT * FROM order_notes WHERE client_id = u.tg_id ORDER BY id DESC LIMIT 20) n),
        'orders', (SELECT COALESCE(jsonb_agg(jsonb_build_object('id', o.id, 'status', o.status, 'total', o.total,
                    'created_at', o.created_at) ORDER BY o.id DESC), '[]')
                   FROM (SELECT * FROM orders WHERE client_id = u.tg_id ORDER BY id DESC LIMIT 10) o))
    FROM users u WHERE u.tg_id = (p->>'client_id')::bigint
$$;

CREATE OR REPLACE FUNCTION admin_client_update(p jsonb) RETURNS jsonb LANGUAGE plpgsql AS $$
BEGIN
    IF p ? 'type' AND p->>'type' NOT IN ('retail', 'wholesale') THEN
        RETURN jsonb_build_object('error', 'Turi noto''g''ri');
    END IF;
    UPDATE users SET
        customer_type = COALESCE(p->>'type', customer_type),
        business_name = CASE WHEN p ? 'business' THEN NULLIF(left(trim(p->>'business'), 80), '') ELSE business_name END
    WHERE tg_id = (p->>'client_id')::bigint;
    IF NOT FOUND THEN RETURN jsonb_build_object('error', 'Mijoz topilmadi'); END IF;
    PERFORM audit((p->>'actor')::bigint, 'client_update', p - 'actor');
    RETURN jsonb_build_object('ok', true);
END $$;

CREATE OR REPLACE FUNCTION admin_debt_record(p jsonb) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE v_amount bigint; v_kind text := p->>'kind'; v_delta bigint;
BEGIN
    IF (p->>'amount') !~ '^\d{1,10}$' OR (p->>'amount')::bigint = 0 THEN
        RETURN jsonb_build_object('error', 'Summani kiriting');
    END IF;
    v_amount := (p->>'amount')::bigint;
    IF v_kind = 'payment' THEN v_delta := -v_amount;
    ELSIF v_kind = 'debt' THEN v_delta := v_amount;
    ELSE RETURN jsonb_build_object('error', 'Turi noto''g''ri');
    END IF;
    PERFORM 1 FROM users WHERE tg_id = (p->>'client_id')::bigint FOR UPDATE;
    IF NOT FOUND THEN RETURN jsonb_build_object('error', 'Mijoz topilmadi'); END IF;
    IF v_kind = 'payment' AND v_amount > debt_balance((p->>'client_id')::bigint) THEN
        RETURN jsonb_build_object('error', format('To''lov qarzdan katta. Hozirgi qarz: %s so''m', debt_balance((p->>'client_id')::bigint)));
    END IF;
    INSERT INTO debt_ledger(client_id, delta, kind, note, created_by)
    VALUES ((p->>'client_id')::bigint, v_delta, v_kind, left(COALESCE(p->>'note', ''), 200), (p->>'actor')::bigint);
    PERFORM audit((p->>'actor')::bigint, 'debt_' || v_kind, p - 'actor');
    RETURN jsonb_build_object('ok', true, 'debt', debt_balance((p->>'client_id')::bigint));
END $$;

CREATE OR REPLACE FUNCTION admin_product_update(p jsonb) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE old products%ROWTYPE; v_price bigint; v_wprice bigint;
BEGIN
    SELECT * INTO old FROM products WHERE id = (p->>'id')::int FOR UPDATE;
    IF NOT FOUND THEN RETURN jsonb_build_object('error', 'Mahsulot topilmadi'); END IF;
    IF p ? 'price' THEN
        IF (p->>'price') !~ '^\d{1,8}$' THEN RETURN jsonb_build_object('error', 'Narx noto''g''ri'); END IF;
        v_price := (p->>'price')::bigint;
        IF v_price > 10000000 THEN RETURN jsonb_build_object('error', 'Narx juda katta'); END IF;
    END IF;
    IF p ? 'wholesale_price' AND COALESCE(p->>'wholesale_price', '') <> '' THEN
        IF (p->>'wholesale_price') !~ '^\d{1,8}$' THEN RETURN jsonb_build_object('error', 'Optom narx noto''g''ri'); END IF;
        v_wprice := (p->>'wholesale_price')::bigint;
    END IF;
    UPDATE products SET
        price           = COALESCE(v_price, price),
        wholesale_price = CASE WHEN p ? 'wholesale_price' THEN v_wprice ELSE wholesale_price END,
        returnable      = COALESCE((p->>'returnable')::boolean, returnable),
        is_active       = COALESCE((p->>'is_active')::boolean, is_active)
    WHERE id = old.id;
    PERFORM audit((p->>'actor')::bigint, 'product_update',
                  jsonb_build_object('id', old.id, 'old', to_jsonb(old), 'change', p - 'actor'));
    RETURN jsonb_build_object('ok', true);
END $$;

CREATE OR REPLACE FUNCTION admin_stats(p jsonb) RETURNS jsonb LANGUAGE sql STABLE AS $$
    WITH since AS (SELECT period_start(COALESCE((p->>'days')::int, 1)) AS t)
    SELECT jsonb_build_object(
        'created',   (SELECT count(*) FROM orders, since WHERE created_at >= since.t),
        'delivered', (SELECT count(*) FROM orders, since WHERE status = 'delivered' AND delivered_at >= since.t),
        'cancelled', (SELECT count(*) FROM orders, since WHERE status = 'cancelled' AND cancelled_at >= since.t),
        'revenue',   (SELECT COALESCE(SUM(total), 0) FROM orders, since WHERE status = 'delivered' AND delivered_at >= since.t),
        'cash',      (SELECT COALESCE(SUM(COALESCE(paid_amount, total)), 0) FROM orders, since WHERE status = 'delivered' AND delivered_at >= since.t),
        'new_debt',  (SELECT COALESCE(SUM(delta), 0) FROM debt_ledger, since WHERE delta > 0 AND created_at >= since.t),
        'debt_paid', (SELECT COALESCE(-SUM(delta), 0) FROM debt_ledger, since WHERE delta < 0 AND created_at >= since.t),
        'debt_total',(SELECT COALESCE(SUM(delta), 0) FROM debt_ledger),
        'wholesale', (SELECT COALESCE(SUM(total), 0) FROM orders, since WHERE status = 'delivered' AND price_type = 'wholesale' AND delivered_at >= since.t),
        'fees',      (SELECT COALESCE(SUM(delivery_fee), 0) FROM orders, since WHERE status = 'delivered' AND delivered_at >= since.t),
        'defective', (SELECT COALESCE(SUM(qty), 0) FROM order_notes, since WHERE kind = 'defective' AND created_at >= since.t),
        'products',  (SELECT COALESCE(jsonb_agg(x ORDER BY x.volume_l), '[]') FROM (
                        SELECT i.volume_l, i.title, SUM(i.qty)::int AS qty, SUM(i.qty * i.unit_price) AS sum
                        FROM order_items i JOIN orders o ON o.id = i.order_id, since
                        WHERE o.status = 'delivered' AND o.delivered_at >= since.t
                        GROUP BY i.volume_l, i.title) x),
        'couriers',  (SELECT COALESCE(jsonb_agg(x ORDER BY x.cash DESC), '[]') FROM (
                        SELECT u.full_name AS name, count(*) AS n, SUM(COALESCE(o.paid_amount, o.total)) AS cash,
                               SUM(o.debt_amount) AS debt
                        FROM orders o JOIN users u ON u.tg_id = o.courier_id, since
                        WHERE o.status = 'delivered' AND o.delivered_at >= since.t
                        GROUP BY u.tg_id, u.full_name) x),
        'daily',     (SELECT COALESCE(jsonb_agg(x ORDER BY x.day), '[]') FROM (
                        SELECT (delivered_at AT TIME ZONE (settings_json()->>'tz'))::date AS day,
                               SUM(total) AS revenue, count(*) AS n
                        FROM orders, since WHERE status = 'delivered' AND delivered_at >= since.t
                        GROUP BY 1) x))
$$;

-- Rahbarmi? (ADMIN_IDS dan tashqari parol bilan kirgan rahbarlar)
CREATE OR REPLACE FUNCTION staff_owner_ids(p jsonb) RETURNS jsonb LANGUAGE sql STABLE AS $$
    SELECT jsonb_build_object('ids', COALESCE(jsonb_agg(tg_id), '[]'))
    FROM staff WHERE role = 'owner' AND is_active AND tg_id IS NOT NULL
$$;

CREATE OR REPLACE FUNCTION export_all(p jsonb) RETURNS jsonb LANGUAGE sql STABLE AS $$
    SELECT jsonb_build_object(
        'version', 2, 'exported_at', now(),
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
        'order_notes', (SELECT COALESCE(jsonb_agg(t), '[]') FROM order_notes t))
$$;

-- Faqat YANGI (bo'sh) bazaga tiklash uchun
CREATE OR REPLACE FUNCTION import_all(p jsonb) RETURNS jsonb LANGUAGE plpgsql AS $$
BEGIN
    IF EXISTS (SELECT 1 FROM orders) OR EXISTS (SELECT 1 FROM users) OR EXISTS (SELECT 1 FROM staff) THEN
        RAISE EXCEPTION 'Baza bo''sh emas — tiklash faqat yangi bazaga qilinadi';
    END IF;
    INSERT INTO users SELECT * FROM jsonb_populate_recordset(NULL::users, p->'users');
    INSERT INTO couriers SELECT * FROM jsonb_populate_recordset(NULL::couriers, p->'couriers');
    INSERT INTO courier_invites SELECT * FROM jsonb_populate_recordset(NULL::courier_invites, COALESCE(p->'courier_invites', '[]'));
    INSERT INTO products SELECT * FROM jsonb_populate_recordset(NULL::products, p->'products')
        ON CONFLICT (id) DO UPDATE SET volume_l = EXCLUDED.volume_l, title = EXCLUDED.title, price = EXCLUDED.price,
            wholesale_price = EXCLUDED.wholesale_price, returnable = EXCLUDED.returnable, is_active = EXCLUDED.is_active;
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

-- Barcha funksiyalarga xavfsiz search_path
DO $$
DECLARE f record;
BEGIN
    FOR f IN SELECT p.oid::regprocedure AS sig FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
             WHERE n.nspname = 'public' AND p.prokind = 'f' LOOP
        EXECUTE format('ALTER FUNCTION %s SET search_path = public, pg_temp', f.sig);
    END LOOP;
END $$;

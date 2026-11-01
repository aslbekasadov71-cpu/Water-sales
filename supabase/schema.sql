-- ZamZam suv boti: Supabase (PostgreSQL) bazasi.
-- Supabase -> SQL Editor ga to'liq joylab "Run" bosing. Qayta ishga tushirish xavfsiz.
-- Buyurtma va idish yozuvlari hech qachon o'chirilmaydi, faqat holati o'zgaradi.

CREATE TABLE IF NOT EXISTS users (
    tg_id        BIGINT PRIMARY KEY,
    full_name    TEXT NOT NULL DEFAULT '',
    username     TEXT,
    phone        TEXT,
    role         TEXT NOT NULL DEFAULT 'client' CHECK (role IN ('client', 'courier')),
    is_blocked   BOOLEAN NOT NULL DEFAULT FALSE,
    last_lat     DOUBLE PRECISION,
    last_lon     DOUBLE PRECISION,
    last_address TEXT,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS couriers (
    tg_id          BIGINT PRIMARY KEY REFERENCES users (tg_id),
    is_active      BOOLEAN NOT NULL DEFAULT TRUE,   -- admin tomonidan yoqilgan/o'chirilgan
    is_online      BOOLEAN NOT NULL DEFAULT FALSE,  -- dostavchi "ishdaman" holatida
    lat            DOUBLE PRECISION,
    lon            DOUBLE PRECISION,
    location_at    TIMESTAMPTZ,
    stale_notified BOOLEAN NOT NULL DEFAULT FALSE,
    created_at     TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS courier_invites (
    code       TEXT PRIMARY KEY,
    created_by BIGINT NOT NULL,
    used_by    BIGINT,
    used_at    TIMESTAMPTZ,
    expires_at TIMESTAMPTZ NOT NULL
);

CREATE TABLE IF NOT EXISTS products (
    id         SERIAL PRIMARY KEY,
    volume_l   INT NOT NULL UNIQUE CHECK (volume_l > 0),
    title      TEXT NOT NULL,
    price      BIGINT NOT NULL CHECK (price >= 0),
    returnable BOOLEAN NOT NULL DEFAULT TRUE,
    is_active  BOOLEAN NOT NULL DEFAULT TRUE
);

CREATE TABLE IF NOT EXISTS settings (
    key   TEXT PRIMARY KEY,
    value TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS orders (
    id               BIGSERIAL PRIMARY KEY,
    idem_key         TEXT UNIQUE,                   -- ikki marta bosilsa ham bitta buyurtma
    client_id        BIGINT NOT NULL REFERENCES users (tg_id),
    courier_id       BIGINT REFERENCES users (tg_id),
    status           TEXT NOT NULL CHECK (status IN
                     ('new', 'offered', 'unassigned', 'accepted', 'delivered', 'cancelled')),
    phone            TEXT NOT NULL,
    lat              DOUBLE PRECISION NOT NULL,
    lon              DOUBLE PRECISION NOT NULL,
    address_note     TEXT NOT NULL DEFAULT '',
    delivery_time    TEXT NOT NULL DEFAULT '',
    payment_method   TEXT NOT NULL DEFAULT 'cash',
    items_total      BIGINT NOT NULL CHECK (items_total >= 0),
    delivery_fee     BIGINT NOT NULL CHECK (delivery_fee >= 0),
    total            BIGINT NOT NULL CHECK (total >= 0),
    offered_to       BIGINT,
    offer_expires_at TIMESTAMPTZ,
    admin_notified   BOOLEAN NOT NULL DEFAULT FALSE,
    created_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
    accepted_at      TIMESTAMPTZ,
    delivered_at     TIMESTAMPTZ,
    cancelled_at     TIMESTAMPTZ,
    cancelled_by     BIGINT,
    cancel_reason    TEXT
);
CREATE INDEX IF NOT EXISTS idx_orders_status    ON orders (status);
CREATE INDEX IF NOT EXISTS idx_orders_client    ON orders (client_id, id DESC);
CREATE INDEX IF NOT EXISTS idx_orders_courier   ON orders (courier_id, status);
CREATE INDEX IF NOT EXISTS idx_orders_delivered ON orders (delivered_at) WHERE status = 'delivered';

CREATE TABLE IF NOT EXISTS order_items (
    id         BIGSERIAL PRIMARY KEY,
    order_id   BIGINT NOT NULL REFERENCES orders (id),
    product_id INT NOT NULL REFERENCES products (id),
    volume_l   INT NOT NULL,
    title      TEXT NOT NULL,
    qty        INT NOT NULL CHECK (qty > 0),
    unit_price BIGINT NOT NULL CHECK (unit_price >= 0),
    returnable BOOLEAN NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_order_items_order ON order_items (order_id);

-- Har bir dostavchiga yuborilgan taklif tarixi (kim rad etdi, kimda vaqt tugadi)
CREATE TABLE IF NOT EXISTS order_offers (
    id           BIGSERIAL PRIMARY KEY,
    order_id     BIGINT NOT NULL REFERENCES orders (id),
    courier_id   BIGINT NOT NULL REFERENCES users (tg_id),
    distance_km  DOUBLE PRECISION,
    message_id   BIGINT,
    result       TEXT NOT NULL DEFAULT 'pending' CHECK (result IN
                 ('pending', 'accepted', 'declined', 'expired', 'cancelled', 'released')),
    offered_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    responded_at TIMESTAMPTZ
);
CREATE INDEX IF NOT EXISTS idx_offers_order ON order_offers (order_id);

-- Idishlar daftari: +N = mijozga to'la idish berildi, -N = bo'sh idish qaytarildi
CREATE TABLE IF NOT EXISTS bottle_ledger (
    id         BIGSERIAL PRIMARY KEY,
    client_id  BIGINT NOT NULL REFERENCES users (tg_id),
    order_id   BIGINT REFERENCES orders (id),
    volume_l   INT NOT NULL,
    delta      INT NOT NULL CHECK (delta <> 0),
    reason     TEXT NOT NULL CHECK (reason IN ('delivered', 'returned', 'adjust')),
    note       TEXT,
    created_by BIGINT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_bottles_client ON bottle_ledger (client_id, volume_l);

-- Admin harakatlari jurnali (narx, sozlama, bekor qilish, tayinlash ...)
CREATE TABLE IF NOT EXISTS audit_log (
    id         BIGSERIAL PRIMARY KEY,
    actor_id   BIGINT,
    action     TEXT NOT NULL,
    details    JSONB,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Telegram suhbat holati (masalan, dostavchi idish sonini kiritayotgan payt)
CREATE TABLE IF NOT EXISTS sessions (
    tg_id      BIGINT PRIMARY KEY,
    data       JSONB NOT NULL,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Telegram bir xabarni ikki marta yuborsa, ikkinchisi e'tiborsiz qoldiriladi
CREATE TABLE IF NOT EXISTS processed_updates (
    update_id  BIGINT PRIMARY KEY,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Boshlang'ich sozlamalar va taxminiy narxlar (admin paneldan o'zgartiriladi)
INSERT INTO settings(key, value) VALUES
    ('delivery_fee', '0'), ('max_radius_km', '2'), ('offer_timeout_sec', '180'),
    ('location_stale_min', '15'), ('max_active_orders', '5'), ('prices_final', '0'),
    ('support_phone', ''), ('tz', 'Asia/Tashkent'), ('last_backup_day', '')
ON CONFLICT (key) DO NOTHING;

INSERT INTO products(volume_l, title, price, returnable) VALUES
    (5, '5 litr', 7000, FALSE), (10, '10 litr', 10000, FALSE), (20, '20 litr', 15000, TRUE)
ON CONFLICT (volume_l) DO NOTHING;

-- =====================================================================
-- Yordamchi funksiyalar
-- =====================================================================
CREATE OR REPLACE FUNCTION haversine_km(lat1 float8, lon1 float8, lat2 float8, lon2 float8)
RETURNS float8 LANGUAGE sql IMMUTABLE AS $$
    SELECT 2 * 6371.0088 * asin(least(1.0, sqrt(
        power(sin(radians(lat2 - lat1) / 2), 2) +
        cos(radians(lat1)) * cos(radians(lat2)) * power(sin(radians(lon2 - lon1) / 2), 2))))
$$;

CREATE OR REPLACE FUNCTION settings_json() RETURNS jsonb LANGUAGE sql STABLE AS $$
    SELECT jsonb_build_object(
        'delivery_fee',       COALESCE(max(value) FILTER (WHERE key = 'delivery_fee'), '0')::bigint,
        'max_radius_km',      COALESCE(max(value) FILTER (WHERE key = 'max_radius_km'), '2')::float8,
        'offer_timeout_sec',  COALESCE(max(value) FILTER (WHERE key = 'offer_timeout_sec'), '180')::int,
        'location_stale_min', COALESCE(max(value) FILTER (WHERE key = 'location_stale_min'), '15')::int,
        'max_active_orders',  COALESCE(max(value) FILTER (WHERE key = 'max_active_orders'), '5')::int,
        'prices_final',       COALESCE(max(value) FILTER (WHERE key = 'prices_final'), '0') = '1',
        'support_phone',      COALESCE(max(value) FILTER (WHERE key = 'support_phone'), ''),
        'tz',                 COALESCE(max(value) FILTER (WHERE key = 'tz'), 'Asia/Tashkent'))
    FROM settings
$$;

CREATE OR REPLACE FUNCTION audit(p_actor bigint, p_action text, p_details jsonb) RETURNS void
LANGUAGE sql AS $$
    INSERT INTO audit_log(actor_id, action, details) VALUES (p_actor, p_action, p_details)
$$;

CREATE OR REPLACE FUNCTION period_start(p_days int) RETURNS timestamptz LANGUAGE sql STABLE AS $$
    SELECT (date_trunc('day', now() AT TIME ZONE (settings_json()->>'tz'))
            - make_interval(days => GREATEST(p_days, 1) - 1)) AT TIME ZONE (settings_json()->>'tz')
$$;

CREATE OR REPLACE FUNCTION bottle_balance_json(p_client bigint) RETURNS jsonb LANGUAGE sql STABLE AS $$
    SELECT COALESCE(jsonb_agg(jsonb_build_object('volume_l', volume_l, 'balance', bal) ORDER BY volume_l), '[]')
    FROM (SELECT volume_l, SUM(delta)::int AS bal FROM bottle_ledger WHERE client_id = p_client
          GROUP BY volume_l HAVING SUM(delta) <> 0) b
$$;

CREATE OR REPLACE FUNCTION order_json(p_id bigint) RETURNS jsonb LANGUAGE sql STABLE AS $$
    SELECT jsonb_build_object(
        'id', o.id, 'status', o.status, 'phone', o.phone, 'lat', o.lat, 'lon', o.lon,
        'address', o.address_note, 'time', o.delivery_time, 'payment', o.payment_method,
        'items_total', o.items_total, 'delivery_fee', o.delivery_fee, 'total', o.total,
        'created_at', o.created_at, 'accepted_at', o.accepted_at, 'delivered_at', o.delivered_at,
        'client_id', o.client_id, 'courier_id', o.courier_id, 'offered_to', o.offered_to,
        'cancel_reason', o.cancel_reason,
        'items', (SELECT COALESCE(jsonb_agg(jsonb_build_object('volume_l', i.volume_l, 'title', i.title,
                    'qty', i.qty, 'unit_price', i.unit_price, 'returnable', i.returnable) ORDER BY i.volume_l), '[]')
                  FROM order_items i WHERE i.order_id = o.id),
        'client', (SELECT jsonb_build_object('name', u.full_name, 'phone', u.phone) FROM users u WHERE u.tg_id = o.client_id),
        'courier', (SELECT jsonb_build_object('name', u.full_name, 'phone', u.phone) FROM users u WHERE u.tg_id = o.courier_id),
        'offers', (SELECT COALESCE(jsonb_agg(jsonb_build_object('name', u.full_name, 'result', f.result,
                    'distance_km', f.distance_km) ORDER BY f.id), '[]')
                   FROM order_offers f JOIN users u ON u.tg_id = f.courier_id WHERE f.order_id = o.id))
    FROM orders o WHERE o.id = p_id
$$;

-- =====================================================================
-- Bot uchun funksiyalar. Hammasi bitta jsonb parametr (p) oladi va jsonb qaytaradi.
-- Har bir chaqiruv = bitta tranzaksiya.
-- =====================================================================
CREATE OR REPLACE FUNCTION claim_update(p jsonb) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE n int;
BEGIN
    INSERT INTO processed_updates(update_id) VALUES ((p->>'update_id')::bigint) ON CONFLICT DO NOTHING;
    GET DIAGNOSTICS n = ROW_COUNT;
    RETURN jsonb_build_object('fresh', n = 1);
END $$;

CREATE OR REPLACE FUNCTION upsert_user(p jsonb) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE u users%ROWTYPE;
BEGIN
    INSERT INTO users(tg_id, full_name, username)
    VALUES ((p->>'tg_id')::bigint, COALESCE(p->>'full_name', ''), p->>'username')
    ON CONFLICT (tg_id) DO UPDATE SET full_name = EXCLUDED.full_name, username = EXCLUDED.username
    WHERE (users.full_name, users.username) IS DISTINCT FROM (EXCLUDED.full_name, EXCLUDED.username);
    SELECT * INTO u FROM users WHERE tg_id = (p->>'tg_id')::bigint;
    RETURN to_jsonb(u) || jsonb_build_object('session',
        (SELECT data FROM sessions WHERE tg_id = u.tg_id AND updated_at > now() - interval '1 day'));
END $$;

CREATE OR REPLACE FUNCTION set_phone(p jsonb) RETURNS jsonb LANGUAGE sql AS $$
    UPDATE users SET phone = p->>'phone' WHERE tg_id = (p->>'tg_id')::bigint RETURNING jsonb_build_object('ok', true)
$$;

CREATE OR REPLACE FUNCTION set_session(p jsonb) RETURNS jsonb LANGUAGE plpgsql AS $$
BEGIN
    IF p->'data' IS NULL OR jsonb_typeof(p->'data') = 'null' THEN
        DELETE FROM sessions WHERE tg_id = (p->>'tg_id')::bigint;
    ELSE
        INSERT INTO sessions(tg_id, data, updated_at) VALUES ((p->>'tg_id')::bigint, p->'data', now())
        ON CONFLICT (tg_id) DO UPDATE SET data = EXCLUDED.data, updated_at = now();
    END IF;
    RETURN jsonb_build_object('ok', true);
END $$;

CREATE OR REPLACE FUNCTION join_courier(p jsonb) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE inv courier_invites%ROWTYPE; v_uid bigint := (p->>'tg_id')::bigint;
BEGIN
    SELECT * INTO inv FROM courier_invites WHERE code = p->>'code' FOR UPDATE;
    IF NOT FOUND OR inv.used_by IS NOT NULL OR inv.expires_at < now() THEN
        RETURN jsonb_build_object('ok', false);
    END IF;
    UPDATE courier_invites SET used_by = v_uid, used_at = now() WHERE code = inv.code;
    UPDATE users SET role = 'courier' WHERE tg_id = v_uid;
    INSERT INTO couriers(tg_id) VALUES (v_uid) ON CONFLICT (tg_id) DO UPDATE SET is_active = TRUE;
    PERFORM audit(inv.created_by, 'courier_joined', jsonb_build_object('courier', v_uid));
    RETURN jsonb_build_object('ok', true);
END $$;

CREATE OR REPLACE FUNCTION courier_location(p jsonb) RETURNS jsonb LANGUAGE sql AS $$
    UPDATE couriers SET lat = (p->>'lat')::float8, lon = (p->>'lon')::float8, location_at = now(),
           stale_notified = FALSE,
           is_online = CASE WHEN (p->>'go_online')::boolean THEN TRUE ELSE is_online END
    WHERE tg_id = (p->>'tg_id')::bigint
    RETURNING jsonb_build_object('ok', true, 'online', is_online)
$$;

CREATE OR REPLACE FUNCTION courier_set_online(p jsonb) RETURNS jsonb LANGUAGE sql AS $$
    WITH u AS (UPDATE couriers SET is_online = (p->>'online')::boolean WHERE tg_id = (p->>'tg_id')::bigint RETURNING tg_id)
    SELECT jsonb_build_object('active', (SELECT count(*) FROM orders WHERE courier_id = (p->>'tg_id')::bigint
                                         AND status = 'accepted'))
$$;

CREATE OR REPLACE FUNCTION client_me(p jsonb) RETURNS jsonb LANGUAGE sql STABLE AS $$
    SELECT jsonb_build_object(
        'user', (SELECT jsonb_build_object('tg_id', tg_id, 'name', full_name, 'phone', phone, 'role', role,
                  'last_lat', last_lat, 'last_lon', last_lon, 'last_address', last_address)
                 FROM users WHERE tg_id = (p->>'tg_id')::bigint),
        'products', (SELECT COALESCE(jsonb_agg(jsonb_build_object('volume_l', volume_l, 'title', title,
                      'price', price, 'returnable', returnable) ORDER BY volume_l), '[]')
                     FROM products WHERE is_active),
        'settings', (SELECT jsonb_build_object('delivery_fee', s->'delivery_fee', 'prices_final', s->'prices_final',
                      'support_phone', s->'support_phone') FROM settings_json() s),
        'bottles', bottle_balance_json((p->>'tg_id')::bigint),
        'orders', (SELECT COALESCE(jsonb_agg(order_json(id) ORDER BY id DESC), '[]')
                   FROM (SELECT id FROM orders WHERE client_id = (p->>'tg_id')::bigint ORDER BY id DESC LIMIT 15) x))
$$;

CREATE OR REPLACE FUNCTION create_order(p jsonb) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
    v_client bigint := (p->>'client_id')::bigint;
    v_user users%ROWTYPE;
    v_existing bigint; v_id bigint;
    v_items_total bigint := 0; v_fee bigint; v_n int := 0;
    r record;
BEGIN
    SELECT id INTO v_existing FROM orders WHERE idem_key = p->>'idem';
    IF FOUND THEN RETURN jsonb_build_object('id', v_existing, 'created', false); END IF;
    SELECT * INTO v_user FROM users WHERE tg_id = v_client;
    IF NOT FOUND OR v_user.phone IS NULL OR v_user.is_blocked THEN
        RETURN jsonb_build_object('error', 'Avval botda telefon raqamingizni yuboring.');
    END IF;
    IF (SELECT count(*) FROM orders WHERE client_id = v_client
        AND status IN ('new', 'offered', 'unassigned', 'accepted')) >= 3 THEN
        RETURN jsonb_build_object('error', 'Sizda yakunlanmagan buyurtmalar bor. Ular yetkazilgach yangisini bering.');
    END IF;
    IF (p->>'lat') IS NULL OR (p->>'lon') IS NULL
       OR abs((p->>'lat')::float8) > 90 OR abs((p->>'lon')::float8) > 180 THEN
        RETURN jsonb_build_object('error', 'Manzil belgilanmagan.');
    END IF;
    FOR r IN SELECT pr.*, (c.value)::int AS qty
             FROM jsonb_each_text(COALESCE(p->'cart', '{}')) c
             JOIN products pr ON pr.volume_l = c.key::int AND pr.is_active
             WHERE c.value ~ '^\d{1,3}$' AND c.value::int BETWEEN 1 AND 100 LOOP
        v_items_total := v_items_total + r.price * r.qty;
        v_n := v_n + 1;
    END LOOP;
    IF v_n = 0 OR v_n <> (SELECT count(*) FROM jsonb_object_keys(COALESCE(p->'cart', '{}'))) THEN
        RETURN jsonb_build_object('error', 'Savatchada noto''g''ri mahsulot bor. Sahifani yangilab qayta urinib ko''ring.');
    END IF;
    v_fee := (settings_json()->>'delivery_fee')::bigint;
    INSERT INTO orders(idem_key, client_id, status, phone, lat, lon, address_note, delivery_time,
                       payment_method, items_total, delivery_fee, total)
    VALUES (p->>'idem', v_client, 'new', v_user.phone, (p->>'lat')::float8, (p->>'lon')::float8,
            left(COALESCE(p->>'address', ''), 300), left(COALESCE(p->>'time', ''), 100), 'cash',
            v_items_total, v_fee, v_items_total + v_fee)
    ON CONFLICT (idem_key) DO NOTHING RETURNING id INTO v_id;
    IF v_id IS NULL THEN
        RETURN jsonb_build_object('id', (SELECT id FROM orders WHERE idem_key = p->>'idem'), 'created', false);
    END IF;
    INSERT INTO order_items(order_id, product_id, volume_l, title, qty, unit_price, returnable)
    SELECT v_id, pr.id, pr.volume_l, pr.title, (c.value)::int, pr.price, pr.returnable
    FROM jsonb_each_text(p->'cart') c JOIN products pr ON pr.volume_l = c.key::int;
    UPDATE users SET last_lat = (p->>'lat')::float8, last_lon = (p->>'lon')::float8,
                     last_address = left(COALESCE(p->>'address', ''), 300) WHERE tg_id = v_client;
    RETURN jsonb_build_object('id', v_id, 'created', true, 'order', order_json(v_id));
END $$;

-- Buyurtmani radius ichidagi eng yaqin bo'sh dostavchiga taklif qiladi
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
    SELECT c.tg_id, haversine_km(o.lat, o.lon, c.lat, c.lon) INTO v_best, v_dist
    FROM couriers c JOIN users u ON u.tg_id = c.tg_id
    WHERE c.is_active AND c.is_online AND u.role = 'courier' AND NOT u.is_blocked AND c.lat IS NOT NULL
      AND c.location_at > now() - make_interval(mins => (s->>'location_stale_min')::int)
      AND NOT EXISTS (SELECT 1 FROM order_offers f WHERE f.order_id = v_id AND f.courier_id = c.tg_id)
      AND (SELECT count(*) FROM orders x WHERE x.courier_id = c.tg_id AND x.status = 'accepted')
          < (s->>'max_active_orders')::int
      AND haversine_km(o.lat, o.lon, c.lat, c.lon) <= (s->>'max_radius_km')::float8
    ORDER BY 2 LIMIT 1;
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

CREATE OR REPLACE FUNCTION set_offer_message(p jsonb) RETURNS jsonb LANGUAGE sql AS $$
    UPDATE order_offers SET message_id = (p->>'message_id')::bigint WHERE id = (p->>'offer_id')::bigint
    RETURNING jsonb_build_object('ok', true)
$$;

-- Taklif dostavchiga yetib bormadi (botni bloklagan) — keyingi tekshiruvda boshqasiga o'tadi
CREATE OR REPLACE FUNCTION offer_failed(p jsonb) RETURNS jsonb LANGUAGE sql AS $$
    UPDATE orders SET offer_expires_at = now() - interval '1 second'
    WHERE id = (p->>'order_id')::bigint AND status = 'offered' AND offered_to = (p->>'courier_id')::bigint
    RETURNING jsonb_build_object('ok', true)
$$;

CREATE OR REPLACE FUNCTION due_orders(p jsonb) RETURNS jsonb LANGUAGE sql STABLE AS $$
    SELECT jsonb_build_object('ids', COALESCE(jsonb_agg(id ORDER BY id), '[]'))
    FROM orders WHERE status IN ('new', 'unassigned') OR (status = 'offered' AND offer_expires_at < now())
$$;

CREATE OR REPLACE FUNCTION stale_couriers(p jsonb) RETURNS jsonb LANGUAGE sql AS $$
    WITH x AS (
        UPDATE couriers SET stale_notified = TRUE
        WHERE is_online AND is_active AND NOT stale_notified
          AND (location_at IS NULL OR location_at < now() - make_interval(mins => (settings_json()->>'location_stale_min')::int))
        RETURNING tg_id)
    SELECT jsonb_build_object('ids', COALESCE(jsonb_agg(tg_id), '[]')) FROM x
$$;

CREATE OR REPLACE FUNCTION accept_offer(p jsonb) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE v_id bigint := (p->>'order_id')::bigint; v_c bigint := (p->>'courier_id')::bigint;
BEGIN
    PERFORM 1 FROM orders WHERE id = v_id AND status = 'offered' AND offered_to = v_c
        AND offer_expires_at + interval '15 seconds' > now() FOR UPDATE;
    IF NOT FOUND THEN RETURN jsonb_build_object('ok', false); END IF;
    UPDATE orders SET status = 'accepted', courier_id = v_c, accepted_at = now(),
                      offered_to = NULL, offer_expires_at = NULL WHERE id = v_id;
    UPDATE order_offers SET result = 'accepted', responded_at = now()
    WHERE order_id = v_id AND courier_id = v_c AND result = 'pending';
    RETURN jsonb_build_object('ok', true, 'order', order_json(v_id));
END $$;

CREATE OR REPLACE FUNCTION decline_offer(p jsonb) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE v_id bigint := (p->>'order_id')::bigint; v_c bigint := (p->>'courier_id')::bigint;
BEGIN
    PERFORM 1 FROM orders WHERE id = v_id AND status = 'offered' AND offered_to = v_c FOR UPDATE;
    IF NOT FOUND THEN RETURN jsonb_build_object('ok', false); END IF;
    UPDATE order_offers SET result = 'declined', responded_at = now()
    WHERE order_id = v_id AND courier_id = v_c AND result = 'pending';
    UPDATE orders SET status = 'new', offered_to = NULL, offer_expires_at = NULL WHERE id = v_id;
    RETURN jsonb_build_object('ok', true);
END $$;

CREATE OR REPLACE FUNCTION release_order(p jsonb) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE v_id bigint := (p->>'order_id')::bigint; v_c bigint := (p->>'courier_id')::bigint; o orders%ROWTYPE;
BEGIN
    SELECT * INTO o FROM orders WHERE id = v_id AND status = 'accepted' AND courier_id = v_c FOR UPDATE;
    IF NOT FOUND THEN RETURN jsonb_build_object('ok', false); END IF;
    UPDATE order_offers SET result = 'released', responded_at = now()
    WHERE order_id = v_id AND courier_id = v_c AND result = 'accepted';
    UPDATE orders SET status = 'new', courier_id = NULL, accepted_at = NULL WHERE id = v_id;
    RETURN jsonb_build_object('ok', true, 'client_id', o.client_id);
END $$;

CREATE OR REPLACE FUNCTION delivery_info(p jsonb) RETURNS jsonb LANGUAGE sql STABLE AS $$
    SELECT jsonb_build_object('ok', true, 'order', order_json(o.id), 'balance', bottle_balance_json(o.client_id))
    FROM orders o
    WHERE o.id = (p->>'order_id')::bigint AND o.status = 'accepted' AND o.courier_id = (p->>'courier_id')::bigint
$$;

CREATE OR REPLACE FUNCTION complete_delivery(p jsonb) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
    v_id bigint := (p->>'order_id')::bigint; v_c bigint := (p->>'courier_id')::bigint;
    o orders%ROWTYPE; r record;
BEGIN
    SELECT * INTO o FROM orders WHERE id = v_id AND status = 'accepted' AND courier_id = v_c FOR UPDATE;
    IF NOT FOUND THEN RETURN jsonb_build_object('ok', false); END IF;
    UPDATE orders SET status = 'delivered', delivered_at = now() WHERE id = v_id;
    INSERT INTO bottle_ledger(client_id, order_id, volume_l, delta, reason, created_by)
    SELECT o.client_id, v_id, volume_l, SUM(qty), 'delivered', v_c FROM order_items
    WHERE order_id = v_id AND returnable GROUP BY volume_l;
    FOR r IN SELECT key::int AS vol, value::int AS n FROM jsonb_each_text(COALESCE(p->'returns', '{}'))
             WHERE value ~ '^\d{1,3}$' AND value::int > 0 LOOP
        INSERT INTO bottle_ledger(client_id, order_id, volume_l, delta, reason, created_by)
        VALUES (o.client_id, v_id, r.vol, -r.n, 'returned', v_c);
    END LOOP;
    RETURN jsonb_build_object('ok', true, 'client_id', o.client_id, 'total', o.total,
                              'balance', bottle_balance_json(o.client_id));
END $$;

CREATE OR REPLACE FUNCTION courier_orders(p jsonb) RETURNS jsonb LANGUAGE sql STABLE AS $$
    SELECT jsonb_build_object('orders', COALESCE(jsonb_agg(order_json(id) ORDER BY id), '[]'))
    FROM orders WHERE courier_id = (p->>'tg_id')::bigint AND status = 'accepted'
$$;

CREATE OR REPLACE FUNCTION courier_today(p jsonb) RETURNS jsonb LANGUAGE sql STABLE AS $$
    SELECT jsonb_build_object(
        'delivered', (SELECT count(*) FROM orders WHERE courier_id = (p->>'tg_id')::bigint AND status = 'delivered'
                      AND delivered_at >= period_start(1)),
        'cash', (SELECT COALESCE(SUM(total), 0) FROM orders WHERE courier_id = (p->>'tg_id')::bigint
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

CREATE OR REPLACE FUNCTION assign_order(p jsonb) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
    v_id bigint := (p->>'order_id')::bigint; v_c bigint := (p->>'courier_id')::bigint;
    o orders%ROWTYPE; v_prev bigint; v_pending jsonb;
BEGIN
    SELECT * INTO o FROM orders WHERE id = v_id FOR UPDATE;
    IF NOT FOUND OR o.status NOT IN ('new', 'offered', 'unassigned', 'accepted') THEN
        RETURN jsonb_build_object('error', 'Bu buyurtmani tayinlab bo''lmaydi (yakunlangan yoki bekor qilingan).');
    END IF;
    PERFORM 1 FROM users u JOIN couriers c ON c.tg_id = u.tg_id
    WHERE u.tg_id = v_c AND u.role = 'courier' AND c.is_active;
    IF NOT FOUND THEN RETURN jsonb_build_object('error', 'Dostavchi topilmadi yoki faol emas.'); END IF;
    IF o.status = 'accepted' AND o.courier_id = v_c THEN
        RETURN jsonb_build_object('error', 'Buyurtma allaqachon shu dostavchida.');
    END IF;
    v_prev := CASE WHEN o.status = 'accepted' THEN o.courier_id END;
    WITH x AS (UPDATE order_offers SET result = 'cancelled', responded_at = now()
               WHERE order_id = v_id AND result = 'pending' RETURNING courier_id, message_id)
    SELECT jsonb_agg(jsonb_build_object('courier_id', courier_id, 'message_id', message_id)) INTO v_pending FROM x;
    IF v_prev IS NOT NULL THEN
        UPDATE order_offers SET result = 'released', responded_at = now()
        WHERE order_id = v_id AND courier_id = v_prev AND result = 'accepted';
    END IF;
    UPDATE orders SET status = 'accepted', courier_id = v_c, accepted_at = now(),
                      offered_to = NULL, offer_expires_at = NULL WHERE id = v_id;
    INSERT INTO order_offers(order_id, courier_id, result, responded_at) VALUES (v_id, v_c, 'accepted', now());
    PERFORM audit((p->>'actor')::bigint, 'order_assigned',
                  jsonb_build_object('order_id', v_id, 'courier', v_c, 'previous', v_prev));
    RETURN jsonb_build_object('ok', true, 'pending', v_pending, 'prev_courier', v_prev, 'order', order_json(v_id));
END $$;

CREATE OR REPLACE FUNCTION cancel_order(p jsonb) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
    v_id bigint := (p->>'order_id')::bigint; v_actor bigint := (p->>'actor')::bigint;
    v_by_client boolean := COALESCE((p->>'by_client')::boolean, true);
    o orders%ROWTYPE; v_pending jsonb;
BEGIN
    SELECT * INTO o FROM orders WHERE id = v_id FOR UPDATE;
    IF NOT FOUND OR (v_by_client AND o.client_id <> v_actor) THEN
        RETURN jsonb_build_object('error', 'Buyurtma topilmadi.');
    END IF;
    IF v_by_client AND o.status = 'accepted' THEN
        RETURN jsonb_build_object('error', 'Dostavchi buyurtmani olib bo''lgan. Bekor qilish uchun operatorga murojaat qiling.');
    END IF;
    IF o.status NOT IN ('new', 'offered', 'unassigned', 'accepted') THEN
        RETURN jsonb_build_object('error', 'Bu buyurtmani bekor qilib bo''lmaydi.');
    END IF;
    WITH x AS (UPDATE order_offers SET result = 'cancelled', responded_at = now()
               WHERE order_id = v_id AND result = 'pending' RETURNING courier_id, message_id)
    SELECT jsonb_agg(jsonb_build_object('courier_id', courier_id, 'message_id', message_id)) INTO v_pending FROM x;
    UPDATE orders SET status = 'cancelled', cancelled_at = now(), cancelled_by = v_actor,
                      cancel_reason = left(COALESCE(p->>'reason', ''), 200),
                      offered_to = NULL, offer_expires_at = NULL WHERE id = v_id;
    PERFORM audit(v_actor, 'order_cancelled',
                  jsonb_build_object('order_id', v_id, 'by_client', v_by_client, 'previous_status', o.status));
    RETURN jsonb_build_object('ok', true, 'pending', v_pending, 'prev_status', o.status,
                              'courier_id', o.courier_id, 'client_id', o.client_id);
END $$;

-- =====================================================================
-- Admin panel funksiyalari
-- =====================================================================
CREATE OR REPLACE FUNCTION admin_overview(p jsonb) RETURNS jsonb LANGUAGE sql STABLE AS $$
    SELECT jsonb_build_object(
        'orders', (SELECT COALESCE(jsonb_agg(order_json(id) ORDER BY id DESC), '[]') FROM (
                     SELECT id FROM orders WHERE status IN ('new', 'offered', 'unassigned', 'accepted')
                     UNION SELECT id FROM (SELECT id FROM orders WHERE status IN ('delivered', 'cancelled')
                                           ORDER BY id DESC LIMIT 40) d) x),
        'couriers', (SELECT COALESCE(jsonb_agg(jsonb_build_object(
                        'tg_id', u.tg_id, 'name', u.full_name, 'phone', u.phone, 'username', u.username,
                        'is_active', c.is_active, 'is_online', c.is_online, 'lat', c.lat, 'lon', c.lon,
                        'location_at', c.location_at,
                        'fresh', COALESCE(c.location_at > now() - make_interval(mins => (settings_json()->>'location_stale_min')::int), false),
                        'active', (SELECT count(*) FROM orders o WHERE o.courier_id = c.tg_id AND o.status = 'accepted'),
                        'today', (SELECT count(*) FROM orders o WHERE o.courier_id = c.tg_id AND o.status = 'delivered'
                                  AND o.delivered_at >= period_start(1)),
                        'cash', (SELECT COALESCE(SUM(total), 0) FROM orders o WHERE o.courier_id = c.tg_id
                                 AND o.status = 'delivered' AND o.delivered_at >= period_start(1))
                     ) ORDER BY u.full_name), '[]')
                     FROM couriers c JOIN users u ON u.tg_id = c.tg_id WHERE u.role = 'courier'),
        'products', (SELECT COALESCE(jsonb_agg(to_jsonb(pr) ORDER BY volume_l), '[]') FROM products pr),
        'settings', settings_json())
$$;

CREATE OR REPLACE FUNCTION admin_create_invite(p jsonb) RETURNS jsonb LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO courier_invites(code, created_by, expires_at)
    VALUES (p->>'code', (p->>'actor')::bigint, now() + interval '24 hours');
    PERFORM audit((p->>'actor')::bigint, 'invite_created', '{}'::jsonb);
    RETURN jsonb_build_object('ok', true);
END $$;

CREATE OR REPLACE FUNCTION admin_courier_update(p jsonb) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE v_c bigint := (p->>'courier_id')::bigint; v_active int;
BEGIN
    IF p->>'op' = 'toggle' THEN
        UPDATE couriers SET is_active = NOT is_active, is_online = FALSE WHERE tg_id = v_c;
    ELSIF p->>'op' = 'remove' THEN
        SELECT count(*) INTO v_active FROM orders WHERE courier_id = v_c AND status = 'accepted';
        IF v_active > 0 THEN
            RETURN jsonb_build_object('error', format('Unda %s ta faol buyurtma bor. Avval ularni boshqasiga o''tkazing.', v_active));
        END IF;
        UPDATE couriers SET is_active = FALSE, is_online = FALSE WHERE tg_id = v_c;
        UPDATE users SET role = 'client' WHERE tg_id = v_c;
    ELSE
        RETURN jsonb_build_object('error', 'Noma''lum amal');
    END IF;
    PERFORM audit((p->>'actor')::bigint, 'courier_' || (p->>'op'), jsonb_build_object('courier', v_c));
    RETURN jsonb_build_object('ok', true);
END $$;

CREATE OR REPLACE FUNCTION admin_product_update(p jsonb) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE old products%ROWTYPE; v_price bigint;
BEGIN
    SELECT * INTO old FROM products WHERE id = (p->>'id')::int FOR UPDATE;
    IF NOT FOUND THEN RETURN jsonb_build_object('error', 'Mahsulot topilmadi'); END IF;
    IF p ? 'price' THEN
        IF (p->>'price') !~ '^\d{1,8}$' THEN RETURN jsonb_build_object('error', 'Narx noto''g''ri'); END IF;
        v_price := (p->>'price')::bigint;
        IF v_price > 10000000 THEN RETURN jsonb_build_object('error', 'Narx juda katta'); END IF;
    END IF;
    UPDATE products SET
        price      = COALESCE(v_price, price),
        returnable = COALESCE((p->>'returnable')::boolean, returnable),
        is_active  = COALESCE((p->>'is_active')::boolean, is_active)
    WHERE id = old.id;
    PERFORM audit((p->>'actor')::bigint, 'product_update',
                  jsonb_build_object('id', old.id, 'old', to_jsonb(old), 'change', p - 'actor'));
    RETURN jsonb_build_object('ok', true);
END $$;

CREATE OR REPLACE FUNCTION admin_setting_set(p jsonb) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE k text := p->>'key'; v text := trim(COALESCE(p->>'value', '')); n numeric; old text;
BEGIN
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

CREATE OR REPLACE FUNCTION admin_stats(p jsonb) RETURNS jsonb LANGUAGE sql STABLE AS $$
    WITH since AS (SELECT period_start(COALESCE((p->>'days')::int, 1)) AS t)
    SELECT jsonb_build_object(
        'created',   (SELECT count(*) FROM orders, since WHERE created_at >= since.t),
        'delivered', (SELECT count(*) FROM orders, since WHERE status = 'delivered' AND delivered_at >= since.t),
        'cancelled', (SELECT count(*) FROM orders, since WHERE status = 'cancelled' AND cancelled_at >= since.t),
        'revenue',   (SELECT COALESCE(SUM(total), 0) FROM orders, since WHERE status = 'delivered' AND delivered_at >= since.t),
        'fees',      (SELECT COALESCE(SUM(delivery_fee), 0) FROM orders, since WHERE status = 'delivered' AND delivered_at >= since.t),
        'products',  (SELECT COALESCE(jsonb_agg(x ORDER BY x.volume_l), '[]') FROM (
                        SELECT i.volume_l, i.title, SUM(i.qty)::int AS qty, SUM(i.qty * i.unit_price) AS sum
                        FROM order_items i JOIN orders o ON o.id = i.order_id, since
                        WHERE o.status = 'delivered' AND o.delivered_at >= since.t
                        GROUP BY i.volume_l, i.title) x),
        'couriers',  (SELECT COALESCE(jsonb_agg(x ORDER BY x.cash DESC), '[]') FROM (
                        SELECT u.full_name AS name, count(*) AS n, SUM(o.total) AS cash
                        FROM orders o JOIN users u ON u.tg_id = o.courier_id, since
                        WHERE o.status = 'delivered' AND o.delivered_at >= since.t
                        GROUP BY u.tg_id, u.full_name) x),
        'daily',     (SELECT COALESCE(jsonb_agg(x ORDER BY x.day), '[]') FROM (
                        SELECT (delivered_at AT TIME ZONE (settings_json()->>'tz'))::date AS day,
                               SUM(total) AS revenue, count(*) AS n
                        FROM orders, since WHERE status = 'delivered' AND delivered_at >= since.t
                        GROUP BY 1) x))
$$;

CREATE OR REPLACE FUNCTION admin_bottles(p jsonb) RETURNS jsonb LANGUAGE sql STABLE AS $$
    SELECT jsonb_build_object(
        'totals', (SELECT COALESCE(jsonb_agg(x ORDER BY x.volume_l), '[]') FROM (
                     SELECT volume_l, SUM(delta)::int AS n FROM bottle_ledger GROUP BY volume_l) x),
        'clients', (SELECT COALESCE(jsonb_agg(x ORDER BY x.n DESC), '[]') FROM (
                     SELECT u.tg_id, u.full_name AS name, u.phone, l.volume_l, SUM(l.delta)::int AS n
                     FROM bottle_ledger l JOIN users u ON u.tg_id = l.client_id
                     WHERE COALESCE(p->>'digits', '') = ''
                        OR regexp_replace(COALESCE(u.phone, ''), '\D', '', 'g') LIKE '%' || (p->>'digits')
                     GROUP BY u.tg_id, u.full_name, u.phone, l.volume_l
                     HAVING SUM(l.delta) <> 0 ORDER BY n DESC LIMIT 50) x),
        'found', (SELECT COALESCE(jsonb_agg(jsonb_build_object('tg_id', tg_id, 'name', full_name, 'phone', phone)), '[]')
                  FROM (SELECT * FROM users WHERE length(COALESCE(p->>'digits', '')) >= 7
                        AND regexp_replace(COALESCE(phone, ''), '\D', '', 'g') LIKE '%' || (p->>'digits') LIMIT 5) u))
$$;

CREATE OR REPLACE FUNCTION admin_bottle_adjust(p jsonb) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE v_delta int;
BEGIN
    IF (p->>'delta') !~ '^[+-]?\d{1,3}$' OR (p->>'delta')::int = 0 THEN
        RETURN jsonb_build_object('error', 'Masalan: +2 yoki -1');
    END IF;
    v_delta := (p->>'delta')::int;
    PERFORM 1 FROM users WHERE tg_id = (p->>'client_id')::bigint;
    IF NOT FOUND THEN RETURN jsonb_build_object('error', 'Mijoz topilmadi'); END IF;
    INSERT INTO bottle_ledger(client_id, volume_l, delta, reason, note, created_by)
    VALUES ((p->>'client_id')::bigint, (p->>'volume_l')::int, v_delta, 'adjust', 'admin tuzatishi', (p->>'actor')::bigint);
    PERFORM audit((p->>'actor')::bigint, 'bottle_adjust', p - 'actor');
    RETURN jsonb_build_object('ok', true, 'balance', bottle_balance_json((p->>'client_id')::bigint));
END $$;

-- =====================================================================
-- Zaxira nusxa va tozalash
-- =====================================================================
CREATE OR REPLACE FUNCTION export_all(p jsonb) RETURNS jsonb LANGUAGE sql STABLE AS $$
    SELECT jsonb_build_object(
        'version', 1, 'exported_at', now(),
        'users', (SELECT COALESCE(jsonb_agg(t), '[]') FROM users t),
        'couriers', (SELECT COALESCE(jsonb_agg(t), '[]') FROM couriers t),
        'courier_invites', (SELECT COALESCE(jsonb_agg(t), '[]') FROM courier_invites t),
        'products', (SELECT COALESCE(jsonb_agg(t), '[]') FROM products t),
        'settings', (SELECT COALESCE(jsonb_agg(t), '[]') FROM settings t),
        'orders', (SELECT COALESCE(jsonb_agg(t), '[]') FROM orders t),
        'order_items', (SELECT COALESCE(jsonb_agg(t), '[]') FROM order_items t),
        'order_offers', (SELECT COALESCE(jsonb_agg(t), '[]') FROM order_offers t),
        'bottle_ledger', (SELECT COALESCE(jsonb_agg(t), '[]') FROM bottle_ledger t),
        'audit_log', (SELECT COALESCE(jsonb_agg(t), '[]') FROM audit_log t))
$$;

-- Faqat YANGI (bo'sh) bazaga tiklash uchun
CREATE OR REPLACE FUNCTION import_all(p jsonb) RETURNS jsonb LANGUAGE plpgsql AS $$
BEGIN
    IF EXISTS (SELECT 1 FROM orders) OR EXISTS (SELECT 1 FROM users) THEN
        RAISE EXCEPTION 'Baza bo''sh emas — tiklash faqat yangi bazaga qilinadi';
    END IF;
    DELETE FROM products;
    INSERT INTO users SELECT * FROM jsonb_populate_recordset(NULL::users, p->'users');
    INSERT INTO couriers SELECT * FROM jsonb_populate_recordset(NULL::couriers, p->'couriers');
    INSERT INTO courier_invites SELECT * FROM jsonb_populate_recordset(NULL::courier_invites, p->'courier_invites');
    INSERT INTO products SELECT * FROM jsonb_populate_recordset(NULL::products, p->'products');
    INSERT INTO settings SELECT * FROM jsonb_populate_recordset(NULL::settings, p->'settings')
        ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value;
    INSERT INTO orders SELECT * FROM jsonb_populate_recordset(NULL::orders, p->'orders');
    INSERT INTO order_items SELECT * FROM jsonb_populate_recordset(NULL::order_items, p->'order_items');
    INSERT INTO order_offers SELECT * FROM jsonb_populate_recordset(NULL::order_offers, p->'order_offers');
    INSERT INTO bottle_ledger SELECT * FROM jsonb_populate_recordset(NULL::bottle_ledger, p->'bottle_ledger');
    INSERT INTO audit_log SELECT * FROM jsonb_populate_recordset(NULL::audit_log, p->'audit_log');
    PERFORM setval(pg_get_serial_sequence('products', 'id'), COALESCE((SELECT max(id) FROM products), 1));
    PERFORM setval(pg_get_serial_sequence('orders', 'id'), COALESCE((SELECT max(id) FROM orders), 1));
    PERFORM setval(pg_get_serial_sequence('order_items', 'id'), COALESCE((SELECT max(id) FROM order_items), 1));
    PERFORM setval(pg_get_serial_sequence('order_offers', 'id'), COALESCE((SELECT max(id) FROM order_offers), 1));
    PERFORM setval(pg_get_serial_sequence('bottle_ledger', 'id'), COALESCE((SELECT max(id) FROM bottle_ledger), 1));
    PERFORM setval(pg_get_serial_sequence('audit_log', 'id'), COALESCE((SELECT max(id) FROM audit_log), 1));
    RETURN jsonb_build_object('ok', true, 'orders', (SELECT count(*) FROM orders));
END $$;

-- Kuniga bir marta zaxira olish kerakmi? (true bo'lsa, shu kun belgilanadi)
CREATE OR REPLACE FUNCTION backup_due(p jsonb) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE v_today text := (now() AT TIME ZONE (settings_json()->>'tz'))::date::text;
        v_hour int := extract(hour FROM now() AT TIME ZONE (settings_json()->>'tz'))::int;
BEGIN
    IF v_hour < 3 THEN RETURN jsonb_build_object('due', false); END IF;
    UPDATE settings SET value = v_today WHERE key = 'last_backup_day' AND value IS DISTINCT FROM v_today;
    IF NOT FOUND THEN RETURN jsonb_build_object('due', false); END IF;
    DELETE FROM processed_updates WHERE created_at < now() - interval '3 days';
    DELETE FROM sessions WHERE updated_at < now() - interval '7 days';
    RETURN jsonb_build_object('due', true, 'day', v_today);
END $$;

CREATE OR REPLACE FUNCTION set_api_url(p jsonb) RETURNS jsonb LANGUAGE sql AS $$
    INSERT INTO settings(key, value) VALUES ('api_url', left(p->>'url', 200))
    ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value
    RETURNING jsonb_build_object('ok', true)
$$;

CREATE OR REPLACE FUNCTION get_api_url(p jsonb) RETURNS jsonb LANGUAGE sql STABLE AS $$
    SELECT jsonb_build_object('url', (SELECT value FROM settings WHERE key = 'api_url'))
$$;

-- =====================================================================
-- Xavfsizlik: jadvallar va funksiyalarga faqat server kaliti (service_role) kira oladi.
-- Ochiq "anon" kalit bilan hech narsa o'qib/yozib bo'lmaydi.
-- =====================================================================
DO $$
DECLARE t text;
BEGIN
    FOREACH t IN ARRAY ARRAY['users', 'couriers', 'courier_invites', 'products', 'settings', 'orders',
                             'order_items', 'order_offers', 'bottle_ledger', 'audit_log', 'sessions',
                             'processed_updates'] LOOP
        EXECUTE format('ALTER TABLE %I ENABLE ROW LEVEL SECURITY', t);
        EXECUTE format('REVOKE ALL ON TABLE %I FROM anon, authenticated', t);
        EXECUTE format('GRANT ALL ON TABLE %I TO service_role', t);
    END LOOP;
END $$;
DO $$
DECLARE f record;
BEGIN
    FOR f IN SELECT p.oid::regprocedure AS sig FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
             WHERE n.nspname = 'public' AND p.prokind = 'f' LOOP
        EXECUTE format('ALTER FUNCTION %s SET search_path = public, pg_temp', f.sig);
    END LOOP;
END $$;
REVOKE EXECUTE ON ALL FUNCTIONS IN SCHEMA public FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA public TO service_role;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO service_role;

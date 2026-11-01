-- ZamZam v3: katalog (rasmli mahsulotlar, rahbar yangi mahsulot qo'shadi), mijoz ro'yxati (ism, tel, joylashuv).
-- 002_v2.sql dan keyin ishga tushiriladi. Qayta ishga tushirish xavfsiz.

ALTER TABLE products ALTER COLUMN volume_l DROP NOT NULL;
ALTER TABLE products ADD COLUMN IF NOT EXISTS image_url TEXT;
ALTER TABLE products ADD COLUMN IF NOT EXISTS description TEXT;
ALTER TABLE products ADD COLUMN IF NOT EXISTS sort_order INT NOT NULL DEFAULT 0;
ALTER TABLE products ADD COLUMN IF NOT EXISTS unit TEXT NOT NULL DEFAULT 'dona';
ALTER TABLE products ALTER COLUMN returnable SET DEFAULT FALSE;
ALTER TABLE order_items ALTER COLUMN volume_l DROP NOT NULL;
ALTER TABLE users ADD COLUMN IF NOT EXISTS name_locked BOOLEAN NOT NULL DEFAULT FALSE;

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'products_returnable_vol_chk') THEN
        ALTER TABLE products ADD CONSTRAINT products_returnable_vol_chk CHECK (NOT returnable OR volume_l IS NOT NULL);
    END IF;
END $$;

UPDATE products SET sort_order = volume_l WHERE sort_order = 0 AND volume_l IS NOT NULL;

-- Telegram ismi o'zgarsa ham, ro'yxatda yozilgan ism-familiya saqlanib qoladi
CREATE OR REPLACE FUNCTION upsert_user(p jsonb) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE u users%ROWTYPE;
BEGIN
    INSERT INTO users(tg_id, full_name, username)
    VALUES ((p->>'tg_id')::bigint, COALESCE(p->>'full_name', ''), p->>'username')
    ON CONFLICT (tg_id) DO UPDATE
        SET full_name = CASE WHEN users.name_locked THEN users.full_name ELSE EXCLUDED.full_name END,
            username = EXCLUDED.username
    WHERE (users.username IS DISTINCT FROM EXCLUDED.username)
       OR (NOT users.name_locked AND users.full_name IS DISTINCT FROM EXCLUDED.full_name);
    SELECT * INTO u FROM users WHERE tg_id = (p->>'tg_id')::bigint;
    RETURN to_jsonb(u) || jsonb_build_object('session',
        (SELECT data FROM sessions WHERE tg_id = u.tg_id AND updated_at > now() - interval '1 day'));
END $$;

CREATE OR REPLACE FUNCTION get_session(p jsonb) RETURNS jsonb LANGUAGE sql STABLE AS $$
    SELECT jsonb_build_object('data',
        (SELECT data FROM sessions WHERE tg_id = (p->>'tg_id')::bigint AND updated_at > now() - interval '1 day'))
$$;

-- Mijoz ro'yxati: ism-familiya, telefon, joylashuv (har biri alohida qadamda saqlanadi)
CREATE OR REPLACE FUNCTION client_register(p jsonb) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE u users%ROWTYPE;
BEGIN
    IF p ? 'name' AND length(trim(p->>'name')) < 3 THEN
        RETURN jsonb_build_object('error', 'Ism-familiyani to''liq yozing');
    END IF;
    UPDATE users SET
        full_name    = CASE WHEN p ? 'name' THEN left(trim(p->>'name'), 80) ELSE full_name END,
        name_locked  = name_locked OR p ? 'name',
        phone        = COALESCE(p->>'phone', phone),
        last_lat     = COALESCE((p->>'lat')::float8, last_lat),
        last_lon     = COALESCE((p->>'lon')::float8, last_lon),
        last_address = CASE WHEN p ? 'address' THEN left(p->>'address', 300) ELSE last_address END
    WHERE tg_id = (p->>'tg_id')::bigint
    RETURNING * INTO u;
    IF NOT FOUND THEN RETURN jsonb_build_object('error', 'Foydalanuvchi topilmadi'); END IF;
    RETURN jsonb_build_object('ok', true, 'name', u.full_name, 'phone', u.phone,
        'registered', u.name_locked AND u.phone IS NOT NULL AND u.last_lat IS NOT NULL);
END $$;

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
        'bottles', bottle_balance_json((p->>'tg_id')::bigint),
        'debt', debt_balance((p->>'tg_id')::bigint),
        'orders', (SELECT COALESCE(jsonb_agg(order_json(id) ORDER BY id DESC), '[]')
                   FROM (SELECT id FROM orders WHERE client_id = (p->>'tg_id')::bigint ORDER BY id DESC LIMIT 15) x))
$$;

-- Savatcha endi mahsulot ID bo'yicha: {"3": 2, "7": 1}
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

-- Rahbar: yangi mahsulot
CREATE OR REPLACE FUNCTION admin_product_create(p jsonb) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE v_id int; v_vol int;
BEGIN
    IF length(trim(COALESCE(p->>'title', ''))) < 2 THEN RETURN jsonb_build_object('error', 'Nomini kiriting'); END IF;
    IF COALESCE(p->>'price', '') !~ '^\d{1,8}$' THEN RETURN jsonb_build_object('error', 'Narxni kiriting'); END IF;
    IF COALESCE(p->>'wholesale_price', '') !~ '^(\d{1,8})?$' THEN RETURN jsonb_build_object('error', 'Optom narx noto''g''ri'); END IF;
    IF COALESCE(p->>'volume_l', '') !~ '^(\d{1,3})?$' THEN RETURN jsonb_build_object('error', 'Hajm noto''g''ri'); END IF;
    v_vol := NULLIF(p->>'volume_l', '')::int;
    IF COALESCE((p->>'returnable')::boolean, false) AND v_vol IS NULL THEN
        RETURN jsonb_build_object('error', 'Qaytariladigan idish uchun hajmini (litr) kiriting');
    END IF;
    IF v_vol IS NOT NULL AND EXISTS (SELECT 1 FROM products WHERE volume_l = v_vol) THEN
        RETURN jsonb_build_object('error', format('%s litrlik mahsulot allaqachon bor', v_vol));
    END IF;
    INSERT INTO products(title, price, wholesale_price, volume_l, returnable, description, unit, sort_order, is_active)
    VALUES (left(trim(p->>'title'), 60), (p->>'price')::bigint, NULLIF(p->>'wholesale_price', '')::bigint, v_vol,
            COALESCE((p->>'returnable')::boolean, false), NULLIF(left(trim(COALESCE(p->>'description', '')), 300), ''),
            COALESCE(NULLIF(left(trim(COALESCE(p->>'unit', '')), 12), ''), 'dona'),
            COALESCE((SELECT max(sort_order) FROM products), 0) + 10, TRUE)
    RETURNING id INTO v_id;
    PERFORM audit((p->>'actor')::bigint, 'product_created', p - 'actor');
    RETURN jsonb_build_object('ok', true, 'id', v_id);
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
    IF p ? 'title' AND length(trim(p->>'title')) < 2 THEN RETURN jsonb_build_object('error', 'Nomini kiriting'); END IF;
    IF COALESCE((p->>'returnable')::boolean, false) AND old.volume_l IS NULL THEN
        RETURN jsonb_build_object('error', 'Hajmi ko''rsatilmagan mahsulot idishini qaytarib bo''lmaydi');
    END IF;
    IF p ? 'image_url' AND (COALESCE(p->>'image_url', '') !~ '^(https://[^\s"''<>]+)?$' OR length(p->>'image_url') > 400) THEN
        RETURN jsonb_build_object('error', 'Rasm manzili noto''g''ri');
    END IF;
    UPDATE products SET
        price           = COALESCE(v_price, price),
        wholesale_price = CASE WHEN p ? 'wholesale_price' THEN v_wprice ELSE wholesale_price END,
        returnable      = COALESCE((p->>'returnable')::boolean, returnable),
        is_active       = COALESCE((p->>'is_active')::boolean, is_active),
        title           = CASE WHEN p ? 'title' THEN left(trim(p->>'title'), 60) ELSE title END,
        description     = CASE WHEN p ? 'description' THEN NULLIF(left(trim(p->>'description'), 300), '') ELSE description END,
        unit            = CASE WHEN p ? 'unit' THEN COALESCE(NULLIF(left(trim(p->>'unit'), 12), ''), 'dona') ELSE unit END,
        sort_order      = COALESCE((p->>'sort_order')::int, sort_order),
        image_url       = CASE WHEN p ? 'image_url' THEN NULLIF(p->>'image_url', '') ELSE image_url END
    WHERE id = old.id;
    PERFORM audit((p->>'actor')::bigint, 'product_update',
                  jsonb_build_object('id', old.id, 'old', to_jsonb(old), 'change', p - 'actor'));
    RETURN jsonb_build_object('ok', true);
END $$;

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
                        'cash', (SELECT COALESCE(SUM(COALESCE(paid_amount, total)), 0) FROM orders o WHERE o.courier_id = c.tg_id
                                 AND o.status = 'delivered' AND o.delivered_at >= period_start(1))
                     ) ORDER BY u.full_name), '[]')
                     FROM couriers c JOIN users u ON u.tg_id = c.tg_id WHERE u.role = 'courier'),
        'products', (SELECT COALESCE(jsonb_agg(to_jsonb(pr) ORDER BY pr.sort_order, pr.id), '[]') FROM products pr),
        'settings', settings_json())
$$;

-- Eski (v2) zaxira nusxasida yangi ustunlar yo'q — standart qiymat bilan tiklanadi
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

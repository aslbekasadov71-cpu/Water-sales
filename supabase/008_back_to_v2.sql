-- v2 ga qaytish (GPS'siz): mijoz mini app'i savatchani litr bo'yicha yuboradi, ro'yxatdan o'tish uchun telefon yetarli.
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
                     FROM products pr WHERE pr.is_active AND pr.volume_l IS NOT NULL),
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
             JOIN products pr ON pr.volume_l::text = c.key AND pr.is_active
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
    FROM jsonb_each_text(p->'cart') c JOIN products pr ON pr.volume_l::text = c.key AND pr.is_active;
    UPDATE users SET last_lat = (p->>'lat')::float8, last_lon = (p->>'lon')::float8,
                     last_address = left(COALESCE(p->>'address', ''), 300) WHERE tg_id = v_client;
    RETURN jsonb_build_object('id', v_id, 'created', true, 'order', order_json(v_id));
END $$;

ALTER FUNCTION client_me(jsonb) SET search_path = public, pg_temp;
ALTER FUNCTION create_order(jsonb) SET search_path = public, pg_temp;

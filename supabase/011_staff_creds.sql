-- Rahbar xodimga yangi login + parol (va ixtiyoriy yangi ism/telefon) beradi.
-- Eski Telegram sessiyasi yopiladi: xodim botga yangi login-parol bilan qayta kiradi.
CREATE OR REPLACE FUNCTION admin_staff_update(p jsonb) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE s staff%ROWTYPE; v_active int; v_login text;
BEGIN
    SELECT * INTO s FROM staff WHERE id = (p->>'id')::int FOR UPDATE;
    IF NOT FOUND THEN RETURN jsonb_build_object('error', 'Xodim topilmadi'); END IF;
    IF p->>'op' IN ('toggle', 'unbind', 'creds') AND s.is_active AND s.tg_id IS NOT NULL THEN
        SELECT count(*) INTO v_active FROM orders WHERE courier_id = s.tg_id AND status = 'accepted';
        IF v_active > 0 THEN
            RETURN jsonb_build_object('error', format('Unda %s ta faol buyurtma bor. Avval ularni yetkazsin yoki boshqasiga o''tkazing.', v_active));
        END IF;
    END IF;
    IF p->>'op' = 'toggle' THEN
        UPDATE staff SET is_active = NOT is_active WHERE id = s.id;
        IF s.tg_id IS NOT NULL THEN
            UPDATE couriers SET is_active = NOT s.is_active AND s.role = 'courier', is_online = FALSE WHERE tg_id = s.tg_id;
        END IF;
    ELSIF p->>'op' = 'reset' THEN
        UPDATE staff SET pass_hash = p->>'pass_hash', pass_salt = p->>'pass_salt' WHERE id = s.id;
    ELSIF p->>'op' IN ('unbind', 'creds') THEN
        IF p->>'op' = 'creds' THEN
            v_login := lower(trim(p->>'login'));
            IF v_login !~ '^[a-z0-9_.]{3,32}$' THEN
                RETURN jsonb_build_object('error', 'Login 3–32 belgi: lotin harflari, raqam, _ yoki .');
            END IF;
            IF EXISTS (SELECT 1 FROM staff WHERE login = v_login AND id <> s.id) THEN
                RETURN jsonb_build_object('error', 'Bu login band');
            END IF;
            IF coalesce(p->>'pass_hash', '') = '' THEN RETURN jsonb_build_object('error', 'Parol yo''q'); END IF;
            UPDATE staff SET login = v_login, pass_hash = p->>'pass_hash', pass_salt = p->>'pass_salt',
                   full_name = COALESCE(NULLIF(left(trim(p->>'full_name'), 80), ''), full_name),
                   phone = COALESCE(NULLIF(left(p->>'phone', 30), ''), phone)
            WHERE id = s.id;
        END IF;
        UPDATE staff SET tg_id = NULL WHERE id = s.id;
        IF s.tg_id IS NOT NULL THEN
            UPDATE couriers SET is_active = FALSE, is_online = FALSE WHERE tg_id = s.tg_id;
            UPDATE shifts SET ended_at = now() WHERE courier_id = s.tg_id AND ended_at IS NULL;
            UPDATE users SET role = 'client' WHERE tg_id = s.tg_id AND role = 'courier';
        END IF;
    ELSE
        RETURN jsonb_build_object('error', 'Noma''lum amal');
    END IF;
    PERFORM audit((p->>'actor')::bigint, 'staff_' || (p->>'op'),
        jsonb_build_object('id', s.id, 'login', s.login, 'new_login', v_login));
    RETURN jsonb_build_object('ok', true, 'tg_id', s.tg_id, 'login', COALESCE(v_login, s.login));
END $$;
ALTER FUNCTION admin_staff_update(jsonb) SET search_path = public, pg_temp;

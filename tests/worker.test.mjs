// ZamZam v2 ni haqiqiy PostgreSQL'da (schema.sql + 002_v2.sql) boshidan oxirigacha sinaydi.
// Ishga tushirish: TEST_PG_HOST=/path/to/socket npm test
import { test, before } from "node:test";
import assert from "node:assert/strict";
import { spawn, spawnSync } from "node:child_process";
import { createApp, verifyInitData, hashPassword, formatAddress } from "../worker/worker.js";

const HOST = process.env.TEST_PG_HOST || "/home/pgtest";
const TOKEN = "123456:CLIENT_TOKEN";
const OWNER = 1, CLIENT = 500, C_NEAR = 11, C_MID = 12, C_FAR = 13;
const BASE = { lat: 41.3111, lon: 69.2797 };
const KM = 1 / 111.2;

function psql(db, sql) {
  const r = spawnSync("psql", ["-h", HOST, "-U", "postgres", "-d", db, "-At", "-v", "ON_ERROR_STOP=1", "-q"], { input: sql, encoding: "utf8" });
  if (r.status !== 0) throw new Error(r.stderr);
  return r.stdout.trim();
}

function freshDb() {
  const db = `zz_${process.pid}_${Math.random().toString(36).slice(2, 8)}`;
  psql("postgres", `CREATE DATABASE ${db};`);
  for (const role of ["anon", "authenticated", "service_role"]) {
    spawnSync("psql", ["-h", HOST, "-U", "postgres", "-d", "postgres", "-qc", `CREATE ROLE ${role} NOLOGIN`], { encoding: "utf8" });
  }
  for (const f of ["supabase/schema.sql", "supabase/002_v2.sql", "supabase/003_v3.sql", "supabase/004_v3_1.sql", "supabase/005_no_gps.sql", "supabase/006_honesty.sql", "supabase/007_rating_v2.sql", "supabase/008_back_to_v2.sql", "supabase/009_v5.sql", "supabase/010_live.sql", "supabase/011_staff_creds.sql"]) {
    const r = spawnSync("psql", ["-h", HOST, "-U", "postgres", "-d", db, "-v", "ON_ERROR_STOP=1", "-q", "-f", f], { encoding: "utf8" });
    if (r.status !== 0) throw new Error(f + ": " + r.stderr);
  }
  return db;
}

function makeRpc(db) {
  return (name, p) => new Promise((resolve, reject) => {
    const proc = spawn("psql", ["-h", HOST, "-U", "postgres", "-d", db, "-At", "-q", "-v", "ON_ERROR_STOP=1", "-v", `p=${JSON.stringify(p)}`]);
    let out = "", err = "";
    proc.stdout.on("data", (d) => (out += d));
    proc.stderr.on("data", (d) => (err += d));
    proc.on("close", (code) => (code === 0 ? resolve(out.trim() ? JSON.parse(out.trim()) : null) : reject(new Error(`${name}: ${err}`))));
    proc.stdin.end(`SELECT public.${name}(:'p'::jsonb);`);
  });
}

class FakeTg {
  constructor(name) { this.name = name; this.calls = []; this.blocked = new Set(); this.nextId = 1000; }
  async call(method, payload) {
    this.calls.push({ method, ...payload });
    if (method === "getMe") return { username: `zamzam_${this.name}_bot` };
    if (this.blocked.has(payload.chat_id)) return null;
    if (method === "sendMessage" || method === "sendLocation") return { message_id: this.nextId++ };
    return true;
  }
  msgs(chat) { return this.calls.filter((c) => c.method === "sendMessage" && c.chat_id === chat); }
  texts(chat) { return this.msgs(chat).map((c) => c.text); }
  last(chat) { return this.msgs(chat).at(-1); }
  edits(chat) { return this.calls.filter((c) => c.method === "editMessageText" && c.chat_id === chat).map((c) => c.text); }
  lastEdit(chat) { return this.calls.filter((c) => c.method === "editMessageText" && c.chat_id === chat).at(-1); }
  alerts() { return this.calls.filter((c) => c.method === "answerCallbackQuery" && c.show_alert).map((c) => c.text); }
}

function setup() {
  const db = freshDb();
  const rpc = makeRpc(db);
  const client = new FakeTg("client");
  const staff = new FakeTg("staff");
  const docs = [];
  const background = [];
  const app = createApp({
    env: { ADMIN_IDS: String(OWNER), WEBAPP_URL: "https://zamzam-water.onrender.com", WEBHOOK_SECRET: "s" },
    rpc, tg: (m, p) => client.call(m, p), tgStaff: (m, p) => staff.call(m, p), apiUrl: "https://bot.example.com",
    sendDocument: async (chat, name, content) => docs.push({ chat, name, content }),
    background: (p) => background.push(p),
    geocode: async () => "Toshkent, Navro'z mahallasi, Amir Temur ko'chasi, 12-uy",
  });
  return { db, rpc, client, staff, app, docs, background, sql: (s) => psql(db, s) };
}

let uid = 1;
const user = (id, name = "Ali") => ({ id, is_bot: false, first_name: name });
const msg = (id, extra) => ({ update_id: uid++, message: { message_id: uid, from: user(id), chat: { id, type: "private" }, ...extra } });
const cb = (id, data, message_id = 77) => ({ update_id: uid++, callback_query: { id: "cb" + uid, from: user(id), data, message: { message_id, chat: { id, type: "private" } } } });

async function signInitData(userObj, token = TOKEN, ageSec = 0) {
  const enc = new TextEncoder();
  const h = async (k, d) => new Uint8Array(await crypto.subtle.sign("HMAC", await crypto.subtle.importKey("raw", k, { name: "HMAC", hash: "SHA-256" }, false, ["sign"]), d));
  const params = new URLSearchParams({ auth_date: String(Math.floor(Date.now() / 1000) - ageSec), user: JSON.stringify(userObj) });
  const dc = [...params.entries()].sort(([a], [b]) => (a < b ? -1 : 1)).map(([k, v]) => `${k}=${v}`).join("\n");
  params.set("hash", [...(await h(await h(enc.encode("WebAppData"), enc.encode(token)), enc.encode(dc)))].map((x) => x.toString(16).padStart(2, "0")).join(""));
  return params.toString();
}

async function seed(t) {
  t.sql(`INSERT INTO users(tg_id, full_name, phone, name_locked, last_lat, last_lon) VALUES (${CLIENT}, 'Mijoz', '+998901112233', TRUE, 41.3, 69.28);`);
  for (const [id, d] of [[C_NEAR, 0.5], [C_MID, 1.2], [C_FAR, 3.0]]) {
    t.sql(`INSERT INTO users(tg_id, full_name, phone, role) VALUES (${id}, 'Dostavchi${id}', '+99890${id}', 'courier');
           INSERT INTO couriers(tg_id, is_online, lat, lon, location_at) VALUES (${id}, TRUE, ${BASE.lat + d * KM}, ${BASE.lon}, now());
           INSERT INTO staff(login, pass_hash, pass_salt, full_name, role, tg_id) VALUES ('c${id}', 'x', 'x', 'Dostavchi${id}', 'courier', ${id});`);
  }
}

async function placeOrder(t, cart = { 3: 5, 1: 2 }, idem = "k" + Math.random(), who = CLIENT) {
  const r = await t.app.api({ action: "order", lat: BASE.lat, lon: BASE.lon, address: "12-uy", time: "Tezroq", cart, idem }, user(who), "client");
  await Promise.all(t.background.splice(0));
  return r;
}

const admin = (t, body) => t.app.api(body, user(OWNER), "staff");

before(() => {
  const r = spawnSync("psql", ["-h", HOST, "-U", "postgres", "-c", "select 1"], { encoding: "utf8" });
  if (r.status !== 0) throw new Error("PostgreSQL ishlamayapti: " + r.stderr);
});

test("initData imzosi va parol xeshi", async () => {
  const good = await signInitData({ id: 42, first_name: "A" });
  assert.equal((await verifyInitData(good, TOKEN)).id, 42);
  assert.equal(await verifyInitData(good, "999:OTHER"), null);
  assert.equal(await verifyInitData(good.replace("42", "43"), TOKEN), null);
  assert.equal(await verifyInitData(await signInitData({ id: 1 }, TOKEN, 90000), TOKEN), null);
  const h = await hashPassword("sirli123");
  assert.equal((await hashPassword("sirli123", h.salt)).hash, h.hash);
  assert.notEqual((await hashPassword("boshqa", h.salt)).hash, h.hash);
});

test("mijoz boti: ro'yxat (ism -> telefon -> joylashuv), menyu, mini app tugmasi", async () => {
  const t = setup();
  await t.app.onClientUpdate(msg(700, { text: "/start" }));
  assert.match(t.client.last(700).text, /1\/3/);
  // buyurtma ro'yxatsiz o'tmaydi
  assert.match((await placeOrder(t, { 3: 1 }, "x1", 700)).error, /ro'yxatdan/);
  await t.app.onClientUpdate(msg(700, { text: "Ali" }));                         // familiyasiz
  assert.match(t.client.last(700).text, /to'liq/);
  await t.app.onClientUpdate(msg(700, { text: "Aziz  Karimov" }));
  assert.ok(t.client.last(700).reply_markup.keyboard[0][0].request_contact);
  await t.app.onClientUpdate(msg(700, { contact: { user_id: 701, phone_number: "998901111111" } })); // birovning raqami
  assert.match(t.client.last(700).text, /o'zingizning/);
  await t.app.onClientUpdate(msg(700, { contact: { user_id: 700, phone_number: "998 90 123-45-67" } }));
  // raqam darrov saqlanmaydi — avval so'raladi
  assert.match(t.client.last(700).text, /shu raqam bo'ladimi/);
  assert.equal(t.client.last(700).reply_markup.inline_keyboard[0][0].callback_data, "rg:pok");
  assert.equal(t.sql("SELECT coalesce(phone,'-') FROM users WHERE tg_id=700"), "-");
  await t.app.onClientUpdate(cb(700, "rg:pok"));
  assert.ok(t.client.last(700).reply_markup.keyboard[0][0].request_location);
  await t.app.onClientUpdate(msg(700, { location: { latitude: 41.31, longitude: 69.28 } }));
  // manzil avtomatik: uy, ko'cha, mahalla — tasdiqlanmaguncha saqlanmaydi
  assert.match(t.client.last(700).text, /Navro'z mahallasi, Amir Temur ko'chasi, 12-uy/);
  assert.equal(t.sql("SELECT coalesce(last_lat::text,'-') FROM users WHERE tg_id=700"), "-");
  await t.app.onClientUpdate(cb(700, "rg:aadd"));
  await t.app.onClientUpdate(msg(700, { text: "45-xonadon, 2-podyezd" }));
  assert.match(t.client.last(700).text, /12-uy, 45-xonadon, 2-podyezd/);
  await t.app.onClientUpdate(cb(700, "rg:aok"));
  assert.equal(t.sql("SELECT full_name||','||phone||','||last_lat FROM users WHERE tg_id=700"), "Aziz Karimov,+998901234567,41.31");
  assert.equal(t.sql("SELECT last_address FROM users WHERE tg_id=700"), "Toshkent, Navro'z mahallasi, Amir Temur ko'chasi, 12-uy, 45-xonadon, 2-podyezd");
  assert.ok(t.client.texts(700).some((x) => x.includes("Ro'yxatdan o'tdingiz")));
  const menuMsg = t.client.msgs(700).at(-2);
  assert.equal(menuMsg.reply_markup.keyboard[0][0].web_app, undefined);        // klaviatura tugmasida web_app YO'Q
  const appBtn = t.client.last(700).reply_markup.inline_keyboard[0][0];
  assert.match(appBtn.web_app.url, /^https:\/\/zamzam-water\.onrender\.com\/\?api=https%3A%2F%2Fbot\.example\.com/);
  // Telegram ismi o'zgarsa ham ro'yxatdagi ism saqlanadi
  assert.deepEqual(menuMsg.reply_markup.keyboard.flat().map((b) => b.text), ["▶️ Boshlash", "📦 Buyurtmalarim", "📞 Aloqa"]);
  await t.app.onClientUpdate(msg(700, { text: "▶️ Boshlash" }));
  assert.ok(t.client.last(700).reply_markup.inline_keyboard[0][0].web_app);
  await t.app.onClientUpdate(msg(700, { text: "💧 Buyurtma berish" }));          // eski klaviatura ham ishlaydi
  assert.ok(t.client.last(700).reply_markup.inline_keyboard[0][0].web_app);
  assert.equal(t.sql("SELECT full_name FROM users WHERE tg_id=700"), "Aziz Karimov");
  assert.equal(t.staff.calls.length, 0);                                         // mijoz boti xodimlar botiga yozmaydi
  const me = await t.app.api({ action: "me" }, user(700), "client");
  assert.equal(me.products.length, 3);
  assert.ok(me.products.every((x) => x.id));
  assert.equal(me.user.type, "retail");
  assert.equal(me.user.registered, true);
});

test("katalog: rahbar yangi mahsulot qo'shadi (rasm bilan), mijoz uni buyurtma qiladi", async () => {
  const t = setup();
  await seed(t);
  const uploads = [];
  t.app = createApp({
    env: { ADMIN_IDS: String(OWNER), WEBAPP_URL: "https://zamzam-water.onrender.com", WEBHOOK_SECRET: "s" },
    rpc: t.rpc, tg: (m, p) => t.client.call(m, p), tgStaff: (m, p) => t.staff.call(m, p), apiUrl: "https://bot.example.com",
    sendDocument: async () => {}, background: (p) => t.background.push(p),
    uploadImage: async (name, bytes, type) => { uploads.push({ name, n: bytes.length, type }); return "https://cdn.example.com/" + name; },
  });
  assert.match((await admin(t, { action: "a_product_create", title: "Stakan", price: "abc" })).error, /Narx/);
  assert.match((await admin(t, { action: "a_product_create", title: "Idish", price: 1000, returnable: true })).error, /hajmini/);
  assert.match((await admin(t, { action: "a_product_create", title: "Yana 20", price: 1000, volume_l: 20 })).error, /allaqachon/);
  const c = await admin(t, { action: "a_product_create", title: "Pompa", price: "45000", description: "Qo'l pompasi", unit: "dona" });
  assert.ok(c.ok);
  assert.deepEqual(await t.app.api({ action: "a_product_create", title: "X", price: 1 }, user(CLIENT), "staff"), { error: "Ruxsat yo'q" });
  // rasm: soxta fayl rad etiladi, haqiqiy JPEG qabul qilinadi
  assert.match((await admin(t, { action: "a_product_image", id: c.id, data: "data:image/jpeg;base64," + btoa("hello") })).error, /rasm emas/);
  const jpg = "data:image/jpeg;base64," + Buffer.from([0xff, 0xd8, 0xff, 0xe0, 1, 2, 3]).toString("base64");
  const up = await admin(t, { action: "a_product_image", id: c.id, data: jpg });
  assert.ok(up.ok);
  assert.equal(uploads[0].type, "image/jpeg");
  assert.ok((await admin(t, { action: "a_product", id: c.id, title: "Suv pompasi", sort_order: 1 })).ok);
  assert.match((await admin(t, { action: "a_product", id: c.id, image_url: "javascript:alert(1)" })).error, /Rasm/);

  const me = await t.app.api({ action: "me" }, user(CLIENT), "client");
  assert.equal(me.products[0].title, "Suv pompasi");                            // sort_order bo'yicha birinchi
  assert.equal(me.products[0].image_url, up.url);
  assert.equal(me.products[0].volume_l, null);
  // noto'g'ri savatcha
  assert.match((await placeOrder(t, { 999: 1 })).error, /noto'g'ri/);
  assert.match((await placeOrder(t, { "1; drop": 1 })).error, /noto'g'ri/);
  const r = await placeOrder(t, { [c.id]: 1, 3: 2 });                            // pompa + 2×20L
  assert.ok(r.ok);
  await t.app.onStaffUpdate(cb(C_NEAR, `acc:${r.id}`));
  await t.app.onStaffUpdate(cb(C_NEAR, `dlv:${r.id}`));
  assert.match(t.staff.last(C_NEAR).text, /20 litr/);                           // faqat idishli mahsulot so'raladi
  await t.app.onStaffUpdate(cb(C_NEAR, "rt:2"));
  await t.app.onStaffUpdate(cb(C_NEAR, "df:no"));
  await t.app.onStaffUpdate(cb(C_NEAR, "pay:full"));
  assert.match(t.staff.lastEdit(C_NEAR).text, /Suv pompasi: 1 ta berildi/);
  await t.app.onStaffUpdate(cb(C_NEAR, "dc:yes"));
  assert.equal(t.sql(`SELECT status FROM orders WHERE id=${r.id}`), "delivered");
  assert.equal(t.sql(`SELECT COALESCE(SUM(delta),0) FROM bottle_ledger WHERE client_id=${CLIENT}`), "0");
  // zaxira nusxada yangi ustunlar bor va eski (v2) nusxa ham tiklanadi
  const dump = await t.rpc("export_all", {});
  assert.ok(dump.products.some((x) => x.image_url === up.url));
  const t2 = setup();
  for (const u of dump.users) delete u.name_locked;
  for (const x of dump.products) { delete x.sort_order; delete x.unit; }
  assert.ok((await t2.rpc("import_all", dump)).ok);
  assert.equal(t2.sql("SELECT count(*) FROM products WHERE unit='dona'"), "4");
});

test("xodimlar boti: login/parol, xato urinishlar bloki, parol xabari o'chiriladi", async () => {
  const t = setup();
  assert.match((await admin(t, { action: "a_staff_create", full_name: "Jasur", phone: "901112233", login: "Jasur", password: "123" })).error, /6 belgi/);
  const created = await admin(t, { action: "a_staff_create", full_name: "Jasur", phone: "901112233", login: "Jasur", password: "maxfiy123", role: "courier" });
  assert.ok(created.ok);
  assert.match((await admin(t, { action: "a_staff_create", full_name: "Xasan", login: "jasur", password: "maxfiy123", role: "courier" })).error, /band/);
  assert.equal(t.sql("SELECT login FROM staff"), "jasur");

  // ro'yxatda yo'q odam xodimlar botida faqat login so'raladi
  await t.app.onStaffUpdate(msg(900, { text: "/start" }));
  assert.match(t.staff.last(900).text, /Loginingizni kiriting/);
  await t.app.onStaffUpdate(msg(900, { text: "jasur" }));
  await t.app.onStaffUpdate(msg(900, { text: "notogri", message_id: 4242 }));
  assert.ok(t.staff.calls.some((c) => c.method === "deleteMessage" && c.chat_id === 900));
  assert.match(t.staff.last(900).text, /noto'g'ri/);
  assert.equal(t.sql("SELECT count(*) FROM staff WHERE tg_id=900"), "0");

  await t.app.onStaffUpdate(msg(900, { text: "jasur" }));
  await t.app.onStaffUpdate(msg(900, { text: "maxfiy123" }));
  assert.equal(t.sql("SELECT tg_id FROM staff WHERE login='jasur'"), "900");
  assert.equal(t.sql("SELECT role FROM users WHERE tg_id=900"), "courier");
  assert.equal(t.sql("SELECT is_active FROM couriers WHERE tg_id=900"), "t");
  assert.match(t.staff.last(900).text, /Dostavchi uchun qo'llanma/);
  assert.match(t.staff.last(OWNER).text, /Jasur \(dostavchi\) xodimlar botiga kirdi/);

  // 5 marta xato -> blok
  for (let i = 0; i < 5; i++) {
    await t.app.onStaffUpdate(msg(901, { text: "/start" }));
    await t.app.onStaffUpdate(msg(901, { text: "jasur" }));
    await t.app.onStaffUpdate(msg(901, { text: "xato" + i }));
  }
  await t.app.onStaffUpdate(msg(901, { text: "jasur" }));
  assert.match(t.staff.last(901).text, /Juda ko'p noto'g'ri urinish/);

  // chiqish
  await t.app.onStaffUpdate(msg(900, { text: "🚪 Chiqish" }));
  assert.equal(t.sql("SELECT count(*) FROM staff WHERE tg_id=900"), "0");
  assert.equal(t.sql("SELECT is_active FROM couriers WHERE tg_id=900"), "f");
});

test("GPS'siz: «Ishni boshlash» -> zavod, buyurtma eng yaqiniga, yetkazgach dostavchi o'sha manzilda", async () => {
  const t = setup();
  const h = await hashPassword("maxfiy123");
  t.sql(`INSERT INTO users(tg_id, full_name, phone, name_locked, last_lat, last_lon) VALUES (${CLIENT}, 'Mijoz', '+998901112233', TRUE, 41.3, 69.28);
         INSERT INTO staff(login, pass_hash, pass_salt, full_name, role) VALUES ('ali', '${h.hash}', '${h.salt}', 'Ali', 'courier'), ('vali', '${h.hash}', '${h.salt}', 'Vali', 'courier')`);
  for (const [id, login] of [[950, "ali"], [951, "vali"]]) {
    await t.app.onStaffUpdate(msg(id, { text: "/start" }));
    await t.app.onStaffUpdate(msg(id, { text: login }));
    await t.app.onStaffUpdate(msg(id, { text: "maxfiy123" }));
  }
  assert.equal(t.staff.last(950).reply_markup.keyboard[0][0].text, "🟢 Ishni boshlash");
  assert.equal(t.staff.last(950).reply_markup.keyboard[0][0].request_location, undefined);   // joylashuv so'ralmaydi
  assert.match((await admin(t, { action: "a_setting", key: "factory", value: "abc" })).error, /Koordinata/);
  assert.ok((await admin(t, { action: "a_setting", key: "factory", value: "41.3000, 69.2000" })).ok);
  await t.app.onStaffUpdate(msg(950, { text: "🟢 Ishni boshlash" }));
  await t.app.onStaffUpdate(msg(951, { text: "🟢 Ishni boshlash" }));
  assert.match(t.staff.last(950).text, /Ish boshlandi/);
  assert.equal(t.staff.last(950).reply_markup.keyboard[0][0].text, "🔴 Ishni tugatish");
  assert.equal(t.sql("SELECT lat||','||lon||','||loc_source FROM couriers WHERE tg_id=950"), "41.3,69.2,factory");
  // 950 uzoqroq buyurtmani yetkazadi -> endi u o'sha manzilda
  const far = { lat: 41.35, lon: 69.30 };
  let r = await t.app.api({ action: "order", ...far, address: "Uzoq", time: "", cart: { 3: 1 }, idem: "f1" }, user(CLIENT), "client");
  await Promise.all(t.background.splice(0));
  const first = t.sql(`SELECT offered_to FROM orders WHERE id=${r.id}`);
  await t.app.onStaffUpdate(cb(Number(first), `acc:${r.id}`));
  t.sql(`UPDATE orders SET status='delivered', delivered_at=now() WHERE id=${r.id}`);
  assert.equal(t.sql(`SELECT loc_source FROM couriers WHERE tg_id=${first}`), "delivery");
  // yangi buyurtma o'sha mahallada -> o'sha dostavchiga
  r = await t.app.api({ action: "order", lat: 41.351, lon: 69.301, address: "Qo'shni", time: "", cart: { 3: 1 }, idem: "f2" }, user(CLIENT), "client");
  await Promise.all(t.background.splice(0));
  assert.equal(t.sql(`SELECT offered_to FROM orders WHERE id=${r.id}`), first);
  assert.match(t.staff.last(Number(first)).text, /Sizdan taxminan/);
  // mijozga soxta mashina ko'rsatilmaydi (GPS yo'q)
  await t.app.onStaffUpdate(cb(Number(first), `acc:${r.id}`));
  const me = await t.app.api({ action: "me" }, user(CLIENT), "client");
  assert.equal(me.orders[0].courier_loc, null);
  // qabul qilgan buyurtmasi bor dostavchi — o'sha yo'nalishdagi navbatdagi buyurtmani oladi
  const r3 = await t.app.api({ action: "order", lat: 41.3512, lon: 69.3012, address: "Yana", time: "", cart: { 3: 1 }, idem: "f3" }, user(CLIENT), "client");
  await Promise.all(t.background.splice(0));
  assert.equal(t.sql(`SELECT offered_to FROM orders WHERE id=${r3.id}`), first);
  await t.app.onStaffUpdate(msg(950, { text: "🔴 Ishni tugatish" }));
  assert.equal(t.sql("SELECT is_online FROM couriers WHERE tg_id=950"), "f");
});

test("to'liq oqim: buyurtma -> qabul -> mijoz dostavchini xaritada ko'radi -> yaroqsiz tara + qisman to'lov", async () => {
  const t = setup();
  await seed(t);
  const r = await placeOrder(t);                                  // 20L×5 + 5L×2 = 89 000
  assert.ok(r.ok);
  assert.equal(t.staff.texts(C_NEAR).length, 1);                  // taklif xodimlar botida
  assert.equal(t.client.texts(C_NEAR).length, 0);
  await t.app.onStaffUpdate(cb(C_NEAR, `acc:${r.id}`));
  const notify = t.client.last(CLIENT);
  assert.match(notify.text, /qabul qilindi/);
  assert.match(notify.reply_markup.inline_keyboard[0][0].web_app.url, /#orders$/);
  // jonli joylashuv yangilanadi -> mijoz ko'radi
  await t.app.onStaffUpdate({ update_id: uid++, edited_message: { from: user(C_NEAR), chat: { id: C_NEAR, type: "private" },
    location: { latitude: 41.3123, longitude: 69.2799 } } });
  const me = await t.app.api({ action: "me" }, user(CLIENT), "client");
  assert.equal(me.orders[0].courier_loc.lat, 41.3123);

  await t.app.onStaffUpdate(cb(C_NEAR, `dlv:${r.id}`));
  await t.app.onStaffUpdate(cb(C_NEAR, "rt:3"));                   // 3 ta yaroqli bo'sh idish
  assert.match(t.staff.lastEdit(C_NEAR).text, /Yaroqsiz/);
  await t.app.onStaffUpdate(cb(C_NEAR, "df:yes"));
  await t.app.onStaffUpdate(cb(C_NEAR, "dq:1"));
  await t.app.onStaffUpdate(msg(C_NEAR, { text: "Darz ketgan" }));
  await t.app.onStaffUpdate(cb(C_NEAR, "df:no"));
  assert.match(t.staff.lastEdit(C_NEAR).text, /Mijoz qancha to'ladi/);
  await t.app.onStaffUpdate(cb(C_NEAR, "pay:custom"));
  await t.app.onStaffUpdate(msg(C_NEAR, { text: "500000" }));
  assert.match(t.staff.last(C_NEAR).text, /juda katta/);
  await t.app.onStaffUpdate(msg(C_NEAR, { text: "50 000" }));
  assert.match(t.staff.last(C_NEAR).text, /Qarzga yoziladi: <b>39 000 so'm/);
  await t.app.onStaffUpdate(cb(C_NEAR, "dc:yes"));

  assert.equal(t.sql(`SELECT status||','||paid_amount||','||debt_amount FROM orders WHERE id=${r.id}`), "delivered,50000,39000");
  assert.equal(t.sql(`SELECT SUM(delta) FROM debt_ledger WHERE client_id=${CLIENT}`), "39000");
  assert.equal(t.sql(`SELECT kind||','||qty||','||text FROM order_notes`), "defective,1,Darz ketgan");
  assert.equal(t.sql(`SELECT SUM(delta) FROM bottle_ledger WHERE client_id=${CLIENT}`), "2");   // 5 berildi, 3 qaytdi
  const last = t.client.last(CLIENT).text;
  assert.match(last, /Qarzga yozildi: <b>39 000 so'm/);
  assert.match(last, /yaroqsiz 20 L idish: 1 ta \(Darz ketgan\)/);
  assert.match(t.staff.last(OWNER).text, /Qarzga: 39 000[\s\S]*Yaroqsiz tara: 20 L × 1/);
  const today = await t.rpc("courier_today", { tg_id: C_NEAR });
  assert.equal(Number(today.cash), 50000);
  assert.equal(Number(today.debts), 39000);

  // keyingi buyurtmada eski qarzi bilan to'laydi
  const r2 = await placeOrder(t, { 3: 1 });
  await t.app.onStaffUpdate(cb(C_NEAR, `acc:${r2.id}`));
  await t.app.onStaffUpdate(cb(C_NEAR, `dlv:${r2.id}`));
  await t.app.onStaffUpdate(cb(C_NEAR, "rt:1"));
  await t.app.onStaffUpdate(cb(C_NEAR, "df:no"));
  assert.match(t.staff.lastEdit(C_NEAR).text, /eski qarzi: <b>39 000/);
  await t.app.onStaffUpdate(cb(C_NEAR, "pay:all"));
  await t.app.onStaffUpdate(cb(C_NEAR, "dc:yes"));
  assert.equal(t.sql(`SELECT SUM(delta) FROM debt_ledger WHERE client_id=${CLIENT}`), "0");
});

test("optom mijoz: rahbar belgilaydi, optom narx qo'llanadi", async () => {
  const t = setup();
  await seed(t);
  const pid = Number(t.sql("SELECT id FROM products WHERE volume_l=20"));
  assert.deepEqual(await admin(t, { action: "a_product", id: pid, price: 15000, wholesale_price: 12000 }), { ok: true });
  let me = await t.app.api({ action: "me" }, user(CLIENT), "client");
  assert.equal(me.products.find((p) => p.volume_l === 20).price, 15000);
  assert.deepEqual(await admin(t, { action: "a_client_update", client_id: CLIENT, type: "wholesale", business: "Bir Zumda" }), { ok: true });
  me = await t.app.api({ action: "me" }, user(CLIENT), "client");
  assert.equal(me.user.type, "wholesale");
  assert.equal(me.products.find((p) => p.volume_l === 20).price, 12000);
  assert.equal(me.products.find((p) => p.volume_l === 5).price, 7000);   // optom narx berilmagan -> dona narx
  const r = await placeOrder(t, { 3: 20 });
  assert.equal(t.sql(`SELECT total||','||price_type FROM orders WHERE id=${r.id}`), "240000,wholesale");
  assert.match(t.staff.last(C_NEAR).text, /optom/);
  assert.equal(t.sql("SELECT business_name FROM users WHERE tg_id=" + CLIENT), "Bir Zumda");
  const list = await admin(t, { action: "a_clients", filter: "wholesale" });
  assert.equal(list.clients.length, 1);
});

test("rad etish -> keyingisi, vaqt tugashi -> rahbarga, rahbar tayinlaydi", async () => {
  const t = setup();
  await seed(t);
  const r = await placeOrder(t);
  await t.app.onStaffUpdate(cb(C_NEAR, `dec:${r.id}`));
  assert.equal(t.staff.texts(C_MID).length, 1);
  t.sql(`UPDATE orders SET offer_expires_at = now() - interval '1 minute' WHERE id=${r.id}`);
  await t.app.tick();
  assert.equal(t.staff.texts(C_FAR).length, 1);                                // masofa chegarasi yo'q — keyingi eng yaqiniga
  await t.app.onStaffUpdate(cb(C_FAR, `dec:${r.id}`));
  assert.equal(t.sql(`SELECT status FROM orders WHERE id=${r.id}`), "unassigned");
  const ownerMsg = t.staff.last(OWNER);
  assert.match(ownerMsg.text, /bo'sh dostavchi topilmadi/);
  assert.match(ownerMsg.reply_markup.inline_keyboard[0][0].web_app.url, /admin\.html\?api=.*#order-/);
  assert.deepEqual(await t.app.api({ action: "a_assign", order_id: r.id, courier_id: C_FAR }, user(OWNER), "client"), { error: "Ruxsat yo'q" });
  assert.deepEqual(await t.app.api({ action: "a_assign", order_id: r.id, courier_id: C_FAR }, user(CLIENT), "staff"), { error: "Ruxsat yo'q" });
  assert.deepEqual(await admin(t, { action: "a_assign", order_id: r.id, courier_id: C_MID }), { ok: true });
  assert.match(t.staff.last(C_MID).text, /Rahbar sizga buyurtma/);
});

test("parallel 5 ta 'Qabul qilaman' — faqat bittasi o'tadi", async () => {
  const t = setup();
  await seed(t);
  const r = await placeOrder(t);
  const res = await Promise.all([1, 2, 3, 4, 5].map(() => t.rpc("accept_offer", { order_id: r.id, courier_id: C_NEAR })));
  assert.equal(res.filter((x) => x.ok).length, 1);
});

test("bekor qilish qoidalari va bir xil xabar ikki marta", async () => {
  const t = setup();
  await seed(t);
  const r = await placeOrder(t);
  assert.deepEqual(await t.app.api({ action: "cancel", order_id: r.id }, user(999), "client"), { error: "Buyurtma topilmadi." });
  assert.deepEqual(await t.app.api({ action: "cancel", order_id: r.id }, user(CLIENT), "client"), { ok: true });
  assert.ok(t.staff.edits(C_NEAR).some((e) => e.includes("bekor qilindi")));
  const r2 = await placeOrder(t);
  await t.app.onStaffUpdate(cb(C_NEAR, `acc:${r2.id}`));
  assert.match((await t.app.api({ action: "cancel", order_id: r2.id }, user(CLIENT), "client")).error, /olib bo'lgan/);
  assert.deepEqual(await admin(t, { action: "a_cancel", order_id: r2.id, reason: "Test" }), { ok: true });
  assert.match(t.client.last(CLIENT).text, /Sabab: Test/);
  const u = msg(CLIENT, { text: "/id" });
  await t.app.onClientUpdate(u);
  await t.app.onClientUpdate(u);
  assert.equal(t.client.texts(CLIENT).filter((x) => x.includes("ID raqamingiz")).length, 1);
});

test("rahbar: qarz yozish/to'lash, xodimni to'xtatish, hisobot, zaxira va tiklash", async () => {
  const t = setup();
  await seed(t);
  assert.ok((await admin(t, { action: "a_debt", client_id: CLIENT, kind: "debt", amount: "20 000", note: "eski" })).ok);
  assert.equal((await admin(t, { action: "a_debt", client_id: CLIENT, kind: "payment", amount: 5000 })).debt, 15000);
  assert.match((await admin(t, { action: "a_debt", client_id: CLIENT, kind: "payment", amount: "-5" })).error, /Summani/);
  assert.match((await admin(t, { action: "a_debt", client_id: CLIENT, kind: "payment", amount: 15001 })).error, /qarzdan katta/);
  const c = await admin(t, { action: "a_client", client_id: CLIENT });
  assert.equal(c.debt, 15000);
  assert.equal(c.debt_history.length, 2);
  assert.equal((await admin(t, { action: "a_clients", filter: "debt" })).clients[0].tg_id, CLIENT);

  const sid = Number(t.sql(`SELECT id FROM staff WHERE tg_id=${C_NEAR}`));
  const r = await placeOrder(t, { 3: 2 });
  await t.app.onStaffUpdate(cb(C_NEAR, `acc:${r.id}`));
  assert.match((await admin(t, { action: "a_staff_update", id: sid, op: "toggle" })).error, /faol buyurtma/);
  await t.app.onStaffUpdate(cb(C_NEAR, `dlv:${r.id}`));
  await t.app.onStaffUpdate(cb(C_NEAR, "rt:0"));
  await t.app.onStaffUpdate(cb(C_NEAR, "df:no"));
  await t.app.onStaffUpdate(cb(C_NEAR, "pay:full"));
  await t.app.onStaffUpdate(cb(C_NEAR, "dc:yes"));
  assert.ok((await admin(t, { action: "a_staff_update", id: sid, op: "toggle" })).ok);
  assert.equal(t.sql(`SELECT is_active FROM couriers WHERE tg_id=${C_NEAR}`), "f");
  assert.match(t.staff.last(C_NEAR).text, /holati o'zgartirildi/);
  assert.ok((await admin(t, { action: "a_staff_update", id: sid, op: "reset", password: "yangiparol1" })).ok);
  const list = await admin(t, { action: "a_staff" });
  assert.equal(list.staff.length, 3);
  assert.equal(list.bot, "zamzam_staff_bot");

  const st = await admin(t, { action: "a_stats", days: 1 });
  assert.equal(Number(st.revenue), 30000);
  assert.equal(Number(st.debt_total), 15000);

  await admin(t, { action: "a_backup" });
  const dump = JSON.parse(t.docs[0].content);
  assert.equal(dump.version, 4);
  assert.equal(dump.staff.length, 3);
  const t2 = setup();
  await assert.rejects(t.rpc("import_all", dump));
  assert.ok((await t2.rpc("import_all", dump)).ok);
  assert.equal(t2.sql(`SELECT SUM(delta) FROM debt_ledger WHERE client_id=${CLIENT}`), "15000");
  assert.equal(t2.sql("SELECT count(*) FROM staff"), "3");
});

test("taymer: eskirgan joylashuv eslatmasi xodimlar botida, kunlik zaxira bir marta", async () => {
  const t = setup();
  await seed(t);
  t.sql(`UPDATE couriers SET location_at = now() - interval '1 hour' WHERE tg_id=${C_FAR}`);
  await t.app.tick();
  await t.app.tick();
  assert.equal(t.staff.texts(C_FAR).length, 0);                                // GPS eslatmalari endi yo'q
  const hour = Number(new Date().toLocaleString("en-GB", { timeZone: "Asia/Tashkent", hour: "2-digit", hour12: false }));
  if (hour >= 3) assert.equal(t.docs.length, 1);
});

test("halollik: mijoz tasdig'i/e'tirozi, yulduz, kassa, reyting, 'kim oldi'", async () => {
  const t = setup();
  await seed(t);
  const r = await placeOrder(t, { 3: 2 });                                     // 2×20L = 30 000
  await t.app.onStaffUpdate(cb(C_NEAR, `acc:${r.id}`));
  // boshqa ishdagi dostavchilarga ovozsiz "kim oldi" xabari
  const note = t.staff.last(C_MID);
  assert.match(note.text, new RegExp(`#${r.id} ni <b>Dostavchi${C_NEAR}</b> oldi`));
  assert.equal(note.disable_notification, true);
  await t.app.onStaffUpdate(msg(C_FAR, { text: "📋 Kim nima oldi" }));
  assert.match(t.staff.last(C_FAR).text, new RegExp(`#${r.id} — <b>Dostavchi${C_NEAR}</b>`));
  // dostavchi 10 000 olib, 20 000 ni "qarz" deb yozadi
  await t.app.onStaffUpdate(cb(C_NEAR, `dlv:${r.id}`));
  await t.app.onStaffUpdate(cb(C_NEAR, "rt:2"));
  await t.app.onStaffUpdate(cb(C_NEAR, "df:no"));
  await t.app.onStaffUpdate(cb(C_NEAR, "pay:custom"));
  await t.app.onStaffUpdate(msg(C_NEAR, { text: "10000" }));
  await t.app.onStaffUpdate(cb(C_NEAR, "dc:yes"));
  const conf = t.client.last(CLIENT);
  assert.match(conf.text, /Siz to'lagan naqd pul: <b>10 000 so'm/);
  assert.match(conf.text, /Qarzga yozildi: <b>20 000 so'm/);
  assert.match(conf.text, /qaytargan bo'sh 20 L idish: 2 ta/);
  assert.equal(conf.reply_markup.inline_keyboard[1][0].callback_data, `cbad:${r.id}`);
  // kassa avtomatik
  assert.equal((await t.rpc("courier_cash", { tg_id: C_NEAR })).balance, 10000);
  // mijoz e'tiroz bildiradi -> rahbarga darhol
  await t.app.onClientUpdate(cb(CLIENT, `cbad:${r.id}`));
  assert.match(t.staff.last(OWNER).text, /Mijoz e'tiroz bildirdi/);
  await t.app.onClientUpdate(msg(CLIENT, { text: "30 000 to'ladim, qarz yo'q" }));
  assert.match(t.staff.last(OWNER).text, /30 000 to'ladim/);
  assert.match(t.client.last(CLIENT).text, /rahbarga yetkazildi/);
  // ikkinchi marta o'zgartirib bo'lmaydi
  await t.app.onClientUpdate(cb(CLIENT, `cok:${r.id}`));
  assert.match(t.client.alerts().at(-1), /allaqachon/);
  // boshqa mijoz birovning buyurtmasini tasdiqlay olmaydi
  t.sql(`INSERT INTO users(tg_id, full_name, phone, name_locked, last_lat, last_lon) VALUES (777, 'Begona', '+998900000777', TRUE, 41.3, 69.28)`);
  assert.equal((await t.rpc("client_confirm", { order_id: r.id, client_id: 777, ok: true })).ok, false);
  // reyting: e'tiroz ball tushiradi
  const ex = await admin(t, { action: "a_overview" });
  assert.equal(ex.extra.disputes.length, 1);
  assert.equal(ex.extra.cash[String(C_NEAR)], 10000);
  // rahbar pulni qabul qiladi
  assert.match((await admin(t, { action: "a_cash_handover", courier_id: C_NEAR, amount: 20000 })).error, /katta/);
  assert.equal((await admin(t, { action: "a_cash_handover", courier_id: C_NEAR, amount: "10 000" })).balance, 0);
  assert.match(t.staff.last(C_NEAR).text, /topshirdingiz/);
  assert.deepEqual(await t.app.api({ action: "a_cash_handover", courier_id: C_NEAR, amount: 1 }, user(C_NEAR), "staff"), { error: "Ruxsat yo'q" });
  assert.ok((await admin(t, { action: "a_dispute_resolve", order_id: r.id })).ok);
  // yulduz: ikkinchi buyurtma
  const r2 = await placeOrder(t, { 3: 1 });
  const who = Number(t.sql(`SELECT offered_to FROM orders WHERE id=${r2.id}`));
  await t.app.onStaffUpdate(cb(who, `acc:${r2.id}`));
  await t.app.onStaffUpdate(cb(who, `dlv:${r2.id}`));
  await t.app.onStaffUpdate(cb(who, "rt:1"));
  await t.app.onStaffUpdate(cb(who, "df:no"));
  await t.app.onStaffUpdate(cb(who, "pay:full"));
  await t.app.onStaffUpdate(cb(who, "dc:yes"));
  await t.app.onClientUpdate(cb(CLIENT, `cok:${r2.id}`));
  assert.equal(t.sql(`SELECT client_confirm FROM orders WHERE id=${r2.id}`), "ok");
  assert.ok(Number(t.sql(`SELECT count(*) FROM orders WHERE client_confirm='ok' AND courier_id=${who}`)) >= 1);
});

test("v5: smena va ish soati, «Mening hisobim», rahbar uchun jamoa statistikasi va kassa tarixi", async () => {
  const t = setup();
  await seed(t);
  t.sql(`UPDATE couriers SET is_online = FALSE`);
  await t.app.onStaffUpdate(msg(C_NEAR, { text: "🟢 Ishni boshlash" }));
  assert.equal(t.sql(`SELECT count(*) FROM shifts WHERE courier_id=${C_NEAR} AND ended_at IS NULL`), "1");
  await t.app.onStaffUpdate(msg(C_NEAR, { text: "🟢 Ishni boshlash" }));                  // ikki marta — bitta smena
  assert.equal(t.sql(`SELECT count(*) FROM shifts WHERE courier_id=${C_NEAR}`), "1");
  t.sql(`UPDATE shifts SET started_at = now() - interval '2 hours 5 minutes' WHERE courier_id=${C_NEAR}`);
  const r = await placeOrder(t, { 3: 2 });
  assert.equal(t.sql(`SELECT offered_to FROM orders WHERE id=${r.id}`), String(C_NEAR));   // faqat u ishda
  await t.app.onStaffUpdate(cb(C_NEAR, `acc:${r.id}`));
  await t.app.onStaffUpdate(cb(C_NEAR, `dlv:${r.id}`));
  await t.app.onStaffUpdate(cb(C_NEAR, "rt:2"));
  await t.app.onStaffUpdate(cb(C_NEAR, "df:no"));
  await t.app.onStaffUpdate(cb(C_NEAR, "pay:full"));
  await t.app.onStaffUpdate(cb(C_NEAR, "dc:yes"));
  await t.app.onStaffUpdate(msg(C_NEAR, { text: "📊 Mening hisobim" }));
  const rep = t.staff.last(C_NEAR).text;
  assert.match(rep, /Ishdasiz/);
  assert.match(rep, /2 soat 5 daq/);
  assert.match(rep, /Olingan naqd: 30 000 so'm/);
  assert.match(rep, /Qo'lingizda \(topshirilmagan\): <b>30 000 so'm/);
  // rahbar: real ish rejimi
  const team = await admin(t, { action: "a_team", days: 1 });
  const me = team.list.find((x) => x.tg_id === C_NEAR);
  assert.equal(me.online, true);
  assert.ok(me.minutes >= 125);
  assert.equal(me.delivered, 1);
  assert.equal(Number(me.collected), 30000);
  assert.equal(Number(me.balance), 30000);
  assert.ok(me.shift_started);
  assert.equal(team.list.find((x) => x.tg_id === C_FAR).online, false);
  await admin(t, { action: "a_cash_handover", courier_id: C_NEAR, amount: 25000 });
  const hist = await admin(t, { action: "a_cash_history" });
  assert.equal(hist.list[0].amount, 25000);
  assert.equal(hist.list[0].courier, `Dostavchi${C_NEAR}`);
  const det = await admin(t, { action: "a_courier", tg_id: C_NEAR });
  assert.equal(det.shifts.length, 1);
  assert.deepEqual(det.cash.map((c) => c.kind), ["handover", "collected"]);
  assert.equal(det.orders[0].id, r.id);
  // smenani yakunlash
  await t.app.onStaffUpdate(msg(C_NEAR, { text: "🔴 Ishni tugatish" }));
  assert.match(t.staff.last(C_NEAR).text, /Bu smena: 2 soat 5 daq/);
  assert.match(t.staff.last(C_NEAR).text, /Qo'lingizda \(rahbarga topshirilmagan\): <b>5 000 so'm/);
  assert.equal(t.sql(`SELECT count(*) FROM shifts WHERE ended_at IS NULL AND courier_id=${C_NEAR}`), "0");
  assert.deepEqual(await t.app.api({ action: "a_team" }, user(C_NEAR), "staff"), { error: "Ruxsat yo'q" });
});

test("v5: reklama bannerlari (yuklash, tartib, o'chirish) va mijoz sozlamalari", async () => {
  const t = setup();
  await seed(t);
  t.app = createApp({
    env: { ADMIN_IDS: String(OWNER), WEBAPP_URL: "https://zamzam-water.onrender.com", WEBHOOK_SECRET: "s", SUPABASE_URL: "https://abc.supabase.co" },
    rpc: t.rpc, tg: (m, p) => t.client.call(m, p), tgStaff: (m, p) => t.staff.call(m, p), apiUrl: "https://bot.example.com",
    sendDocument: async () => {}, background: (p) => t.background.push(p),
    signUpload: async (bucket, name) => ({ uploadUrl: `https://abc.supabase.co/storage/v1/object/upload/sign/${bucket}/${name}?token=x`,
                                           publicUrl: `https://abc.supabase.co/storage/v1/object/public/${bucket}/${name}` }),
  });
  assert.match((await admin(t, { action: "a_banner_upload", type: "application/pdf", size: 10 })).error, /video yoki/);
  assert.match((await admin(t, { action: "a_banner_upload", type: "video/mp4", size: 60 * 1024 * 1024 })).error, /50 MB/);
  const up = await admin(t, { action: "a_banner_upload", type: "video/mp4", size: 5e6 });
  assert.equal(up.kind, "video");
  assert.match(up.public_url, /\/object\/public\/banners\/b_.*\.mp4$/);
  assert.match((await admin(t, { action: "a_banner_create", kind: "video", url: "https://evil.com/x.mp4" })).error, /noto'g'ri/);
  const b1 = await admin(t, { action: "a_banner_create", kind: "video", url: up.public_url, title: "Yangi 19 L" });
  const up2 = await admin(t, { action: "a_banner_upload", type: "image/jpeg", size: 2e5 });
  const b2 = await admin(t, { action: "a_banner_create", kind: up2.kind, url: up2.public_url });
  let me = await t.app.api({ action: "me" }, user(CLIENT), "client");
  assert.deepEqual(me.banners.map((b) => b.id), [b1.id, b2.id]);
  assert.ok((await admin(t, { action: "a_banner_update", id: b2.id, op: "up" })).ok);
  me = await t.app.api({ action: "me" }, user(CLIENT), "client");
  assert.deepEqual(me.banners.map((b) => b.kind), ["image", "video"]);
  await admin(t, { action: "a_banner_update", id: b1.id, op: "toggle" });              // o'chirildi — mijozga ko'rinmaydi
  me = await t.app.api({ action: "me" }, user(CLIENT), "client");
  assert.equal(me.banners.length, 1);
  await admin(t, { action: "a_banner_update", id: b2.id, op: "delete" });
  assert.equal((await admin(t, { action: "a_banners" })).list.length, 1);
  assert.deepEqual(await t.app.api({ action: "a_banner_update", id: b1.id, op: "delete" }, user(CLIENT), "staff"), { error: "Ruxsat yo'q" });
  // mijoz sozlamalari
  assert.match((await t.app.api({ action: "profile", name: "Ali" }, user(CLIENT), "client")).error, /to'liq/);
  assert.equal((await t.app.api({ action: "profile", name: "  Aziz   Karimov " }, user(CLIENT), "client")).name, "Aziz Karimov");
  const loc = await t.app.api({ action: "profile", lat: 41.35, lon: 69.31, address: "Yangi uy, 5-qavat" }, user(CLIENT), "client");
  assert.equal(loc.address, "Yangi uy, 5-qavat");
  assert.match((await t.app.api({ action: "profile", lat: "abc", lon: 1 }, user(CLIENT), "client")).error, /Manzil/);
  me = await t.app.api({ action: "me" }, user(CLIENT), "client");
  assert.equal(me.user.name, "Aziz Karimov");
  assert.equal(me.user.last_lat, 41.35);
  // Telegram ismi o'zgarsa ham saqlangan ism qoladi
  await t.app.onClientUpdate(msg(CLIENT, { text: "/start" }));
  assert.equal(t.sql(`SELECT full_name FROM users WHERE tg_id=${CLIENT}`), "Aziz Karimov");
});

test("v6: jonli joylashuv — yo'riqnoma, qabul, 15 daqiqalik oyna va eslatma", async () => {
  const t = setup();
  await seed(t);
  t.sql(`UPDATE couriers SET is_online = FALSE`);
  await t.app.onStaffUpdate(msg(C_NEAR, { text: "🟢 Ishni boshlash" }));
  const start = t.staff.last(C_NEAR);
  assert.match(start.text, /Jonli joylashuvni yoqish/);
  assert.ok(start.reply_markup.keyboard.flat().some((b) => b.text === "📡 Jonli joylashuvni yoqish"));
  assert.ok(!start.reply_markup.keyboard.flat().some((b) => /Reyting/.test(b.text)));
  // jonli joylashuv birinchi xabari
  await t.app.onStaffUpdate(msg(C_NEAR, { location: { latitude: 41.31, longitude: 69.28, live_period: 28800 } }));
  assert.match(t.staff.last(C_NEAR).text, /Jonli joylashuv yoqildi.*8 soat/);
  assert.equal(t.sql(`SELECT loc_source FROM couriers WHERE tg_id=${C_NEAR}`), "gps");
  // 10 daqiqa yangilanmasa ham mijoz ko'radi (oyna 15 daq)
  const r = await placeOrder(t, { 3: 1 });
  await t.app.onStaffUpdate(cb(C_NEAR, `acc:${r.id}`));
  t.sql(`UPDATE couriers SET location_at = now() - interval '10 minutes' WHERE tg_id=${C_NEAR}`);
  let me = await t.app.api({ action: "me" }, user(CLIENT), "client");
  assert.ok(me.orders[0].courier_loc);
  t.sql(`UPDATE couriers SET location_at = now() - interval '20 minutes' WHERE tg_id=${C_NEAR}`);
  me = await t.app.api({ action: "me" }, user(CLIENT), "client");
  assert.equal(me.orders[0].courier_loc, null);
  // smena 3 daqiqadan oshdi, GPS eskirgan -> bir marta eslatma
  t.sql(`UPDATE shifts SET started_at = now() - interval '5 minutes' WHERE courier_id=${C_NEAR}`);
  assert.deepEqual((await t.rpc("stale_couriers", {})).ids.map(Number), [C_NEAR]);
  assert.deepEqual((await t.rpc("stale_couriers", {})).ids, []);
  // yangi joylashuv kelsa eslatma qayta yoqiladi
  await t.app.onStaffUpdate({ update_id: uid++, edited_message: { from: user(C_NEAR), chat: { id: C_NEAR, type: "private" }, location: { latitude: 41.311, longitude: 69.281 } } });
  assert.equal(t.sql(`SELECT stale_notified FROM couriers WHERE tg_id=${C_NEAR}`), "f");
});

test("mijoz: «📦 Buyurtmalarim» ro'yxatni chatning o'zida ko'rsatadi", async () => {
  const t = setup();
  await seed(t);
  await t.app.onClientUpdate(msg(CLIENT, { text: "📦 Buyurtmalarim" }));
  assert.match(t.client.last(CLIENT).text, /hali buyurtma yo'q/);
  const r = await placeOrder(t, { 3: 2 });
  await t.app.onStaffUpdate(cb(C_NEAR, `acc:${r.id}`));
  await t.app.onClientUpdate(msg(CLIENT, { text: "📦 Buyurtmalarim" }));
  const m = t.client.last(CLIENT);
  assert.match(m.text, new RegExp(`#${r.id}`));
  assert.match(m.text, /Yo'lda/);
  assert.match(m.text, /Dostavchi\d+/);
  assert.match(m.reply_markup.inline_keyboard[0][0].text, /xaritada/);
});

test("rahbar xodimga yangi login va parol beradi — eskisi ishlamaydi, xodim qayta kiradi", async () => {
  const t = setup();
  const created = await admin(t, { action: "a_staff_create", full_name: "Jasur", phone: "901112233", login: "jasur", password: "maxfiy123", role: "courier" });
  await t.app.onStaffUpdate(msg(900, { text: "/start" }));
  await t.app.onStaffUpdate(msg(900, { text: "jasur" }));
  await t.app.onStaffUpdate(msg(900, { text: "maxfiy123" }));
  assert.equal(t.sql("SELECT tg_id FROM staff WHERE login='jasur'"), "900");
  const id = Number(t.sql("SELECT id FROM staff WHERE login='jasur'"));
  // faqat rahbar
  assert.deepEqual(await t.app.api({ action: "a_staff_update", id, op: "creds", login: "x1", password: "yangi12345" }, user(900), "staff"), { error: "Ruxsat yo'q" });
  assert.match((await admin(t, { action: "a_staff_update", id, op: "creds", login: "ab", password: "yangi12345" })).error, /Login/);
  assert.match((await admin(t, { action: "a_staff_update", id, op: "creds", login: "jasur2", password: "123" })).error, /6 belgi/);
  const r = await admin(t, { action: "a_staff_update", id, op: "creds", login: "Jasur2", password: "yangi12345", full_name: "Jasur Aliyev" });
  assert.equal(r.ok, true);
  assert.equal(r.login, "jasur2");
  assert.equal(t.sql(`SELECT login || '|' || full_name || '|' || coalesce(tg_id::text,'-') FROM staff WHERE id=${id}`), "jasur2|Jasur Aliyev|-");
  assert.match(t.staff.last(900).text, /yangi login va parol/);
  // eski login endi ishlamaydi
  await t.app.onStaffUpdate(msg(900, { text: "/start" }));
  await t.app.onStaffUpdate(msg(900, { text: "jasur" }));
  await t.app.onStaffUpdate(msg(900, { text: "maxfiy123" }));
  assert.equal(t.sql("SELECT count(*) FROM staff WHERE tg_id=900"), "0");
  // yangisi ishlaydi
  await t.app.onStaffUpdate(msg(900, { text: "/start" }));
  await t.app.onStaffUpdate(msg(900, { text: "jasur2" }));
  await t.app.onStaffUpdate(msg(900, { text: "yangi12345" }));
  assert.equal(t.sql("SELECT tg_id FROM staff WHERE login='jasur2'"), "900");
  assert.equal(t.sql("SELECT is_active FROM couriers WHERE tg_id=900"), "t");
  // band login
  await admin(t, { action: "a_staff_create", full_name: "Vali", login: "vali", password: "maxfiy123", role: "courier" });
  assert.match((await admin(t, { action: "a_staff_update", id, op: "creds", login: "vali", password: "yangi12345" })).error, /band/);
  assert.ok(created.ok || created.id);
});

test("ro'yxat: boshqa raqam kiritish va manzilni o'zi yozish; manzil formati", async () => {
  const t = setup();
  await t.app.onClientUpdate(msg(710, { text: "/start" }));
  await t.app.onClientUpdate(msg(710, { text: "Vali Aliyev" }));
  await t.app.onClientUpdate(msg(710, { contact: { user_id: 710, phone_number: "998901111111" } }));
  await t.app.onClientUpdate(cb(710, "rg:poth"));
  assert.match(t.client.last(710).text, /raqamni yozing/);
  await t.app.onClientUpdate(msg(710, { text: "12345" }));
  assert.match(t.client.last(710).text, /noto'g'ri/);
  await t.app.onClientUpdate(msg(710, { text: "93 555 44 33" }));
  assert.equal(t.sql("SELECT phone FROM users WHERE tg_id=710"), "+998935554433");
  await t.app.onClientUpdate(msg(710, { location: { latitude: 41.3, longitude: 69.2 } }));
  await t.app.onClientUpdate(cb(710, "rg:anew"));
  await t.app.onClientUpdate(msg(710, { text: "Chilonzor 9-kvartal, 14-uy" }));
  await t.app.onClientUpdate(cb(710, "rg:aok"));
  assert.equal(t.sql("SELECT last_address FROM users WHERE tg_id=710"), "Chilonzor 9-kvartal, 14-uy");
  assert.ok(t.client.texts(710).some((x) => x.includes("Ro'yxatdan o'tdingiz")));
  assert.equal(formatAddress({ house_number: "7", road: "Ipak Yo'li ko'chasi", neighbourhood: "Navro'z MFY", city: "Shahrisabz" }),
    "Shahrisabz, Navro'z MFY, Ipak Yo'li ko'chasi, 7-uy");
});

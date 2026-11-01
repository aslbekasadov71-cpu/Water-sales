/**
 * ZamZam suv boti v5 — ikki bot + mini app API + taymer.
 *
 *  • Mijoz boti (BOT_TOKEN): faqat buyurtma berish (mini app).
 *  • Xodimlar boti (STAFF_BOT_TOKEN): rahbar va dostavchilar; har biri login + parol bilan kiradi.
 *
 * Sozlamalar (Render -> Environment yoki Cloudflare -> Variables):
 *   BOT_TOKEN, STAFF_BOT_TOKEN, ADMIN_IDS (rahbar Telegram ID'lari, parolsiz kiradi),
 *   SUPABASE_URL, SUPABASE_SERVICE_KEY, WEBHOOK_SECRET, WEBAPP_URL, BACKUP_CHAT_ID (ixtiyoriy)
 *
 * Pul va holatga oid barcha amallar bazadagi funksiyalarda, bitta tranzaksiyada bajariladi.
 */

// ============================ Matn yordamchilari ============================
const esc = (s) => String(s ?? "").replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
const money = (n) => Math.round(Number(n) || 0).toString().replace(/\B(?=(\d{3})+(?!\d))/g, " ") + " so'm";
const km = (d) => (d == null ? "—" : d < 1 ? `${Math.round(d * 1000)} m` : `${Number(d).toFixed(1)} km`);
const mapLink = (lat, lon) => `https://yandex.uz/maps/?pt=${lon},${lat}&z=17&l=map`;
const normPhone = (raw) => {
  const d = String(raw || "").replace(/\D/g, "");
  return d ? "+" + d : "";
};
const fmtTime = (iso, tz = "Asia/Tashkent") => {
  if (!iso) return "—";
  try {
    return new Date(iso).toLocaleString("ru-RU", { timeZone: tz, day: "2-digit", month: "2-digit", hour: "2-digit", minute: "2-digit" });
  } catch {
    return String(iso);
  }
};

const STATUS = {
  new: "🆕 Yangi", offered: "📨 Dostavchiga taklif qilingan", unassigned: "⚠️ Dostavchi topilmadi",
  accepted: "🚚 Yo'lda", delivered: "✅ Yetkazildi", cancelled: "❌ Bekor qilingan",
};

function itemsText(items) {
  return (items || []).map((i) => `• ${esc(i.title)} × ${i.qty} = ${money(i.unit_price * i.qty)}`).join("\n");
}

function orderCard(o, { contacts = true, title } = {}) {
  const lines = [title || `📦 <b>Buyurtma #${o.id}</b>${o.price_type === "wholesale" ? " · 🏪 optom" : ""}`,
    `Holati: ${STATUS[o.status] || o.status}`, `🕒 ${fmtTime(o.created_at)}`];
  if (o.client) lines.push(`👤 Mijoz: ${esc(o.client.business ? `${o.client.business} (${o.client.name})` : o.client.name)}`);
  if (contacts) {
    lines.push(`📞 ${esc(o.phone)}`);
    lines.push(`🏠 ${esc(o.address) || "—"}`);
    lines.push(`🗺 <a href="${mapLink(o.lat, o.lon)}">Xaritada ochish</a>`);
  }
  lines.push("", itemsText(o.items));
  if (Number(o.delivery_fee)) lines.push(`🚚 Yetkazish: ${money(o.delivery_fee)}`);
  lines.push(`💵 <b>Jami: ${money(o.total)}</b> (naqd)`);
  lines.push(`🕐 Vaqt: ${esc(o.time) || "—"}`);
  if (o.courier) lines.push(`🚴 Dostavchi: ${esc(o.courier.name)} ${esc(o.courier.phone || "")}`);
  return lines.join("\n");
}

const hm = (min) => { const m = Math.max(0, Math.round(Number(min) || 0)); return m >= 60 ? `${Math.floor(m / 60)} soat ${m % 60} daq` : `${m} daq`; };
const COURIER_HELP =
  "🚚 <b>Dostavchi uchun qo'llanma</b>\n\n" +
  "1. Ishga chiqqanda «🟢 Ishni boshlash» ni bosing va jonli joylashuvni ulashing (📎 → Joylashuv → Jonli, 8 soat).\n" +
  "2. Buyurtma sizga yaqin bo'lsa xabar keladi — «✅ Qabul qilaman» ni bosing.\n" +
  "3. Yetkazgach albatta «✅ Yetkazildi» ni bosing: qaytarilgan bo'sh idishlar, yaroqsiz tara va olingan pulni kiriting. " +
  "Shu orqali tizim qayerdaligingizni biladi va keyingi yaqin buyurtmani sizga beradi.\n" +
  "4. Ish tugagach «🔴 Ishni tugatish».";

const LIVE_HELP =
  "📡 <b>Jonli joylashuvni yoqish</b> (mijoz sizni xaritada ko'radi):\n" +
  "1. Pastdagi 📎 (skrepka) tugmasini bosing\n" +
  "2. «Joylashuv» / «Location» ni tanlang\n" +
  "3. «Jonli joylashuvni ulashish» → <b>8 soat</b> ni tanlang\n\n" +
  "Bir marta yoqsangiz kun bo'yi o'zi yangilanib turadi. Ish tugagach to'xtatishingiz mumkin.";

const B = {
  order: "💧 Buyurtma berish", start: "▶️ Boshlash", myOrders: "📦 Buyurtmalarim", contact: "📞 Aloqa", phone: "📱 Raqamni yuborish",
  location: "📍 Joylashuvni yuborish",
  online: "🟢 Ishni boshlash", refresh: "📍 Joylashuvni yangilash", offline: "🔴 Ishni tugatish", active: "📋 Faol buyurtmalarim",
  today: "📊 Mening hisobim", logout: "🚪 Chiqish", panel: "🛠 Boshqaruv paneli",
  board: "📋 Kim nima oldi", live: "📡 Jonli joylashuvni yoqish",
};

// ============================ Parol ============================
const enc = new TextEncoder();
const hex = (b) => [...b].map((x) => x.toString(16).padStart(2, "0")).join("");
const PBKDF2_ITER = 100_000;

export async function hashPassword(password, saltHex) {
  const salt = saltHex ? Uint8Array.from(saltHex.match(/../g).map((h) => parseInt(h, 16))) : crypto.getRandomValues(new Uint8Array(16));
  const key = await crypto.subtle.importKey("raw", enc.encode(password), "PBKDF2", false, ["deriveBits"]);
  const bits = await crypto.subtle.deriveBits({ name: "PBKDF2", salt, iterations: PBKDF2_ITER, hash: "SHA-256" }, key, 256);
  return { hash: hex(new Uint8Array(bits)), salt: hex(salt) };
}
function safeEqual(a, b) {
  if (typeof a !== "string" || typeof b !== "string" || a.length !== b.length) return false;
  let d = 0;
  for (let i = 0; i < a.length; i++) d |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return d === 0;
}

// ============================ Ilova ============================
export function createApp(deps) {
  const { env, rpc } = deps;
  const tgC = deps.tg;                       // mijoz boti
  const tgS = deps.tgStaff || deps.tg;       // xodimlar boti
  const adminIds = new Set(String(env.ADMIN_IDS || "").split(",").map((s) => s.trim()).filter(Boolean).map(Number));
  const webappUrl = String(env.WEBAPP_URL || "https://zamzam-water.onrender.com").replace(/\/$/, "");
  let apiUrl = deps.apiUrl || null;
  let staffUsername = null;
  let ownerCache = null;

  const appLink = (page = "", hash = "") => `${webappUrl}/${page}?api=${encodeURIComponent(apiUrl || "")}${hash ? "#" + hash : ""}`;
  const inline = (rows) => ({ inline_keyboard: rows });
  const reply = (rows) => ({ keyboard: rows, resize_keyboard: true, is_persistent: true });
  const contactKb = { keyboard: [[{ text: B.phone, request_contact: true }]], resize_keyboard: true, one_time_keyboard: true };

  const mk = (tg) => ({
    send: (chat_id, text, extra = {}) =>
      tg("sendMessage", { chat_id, text, parse_mode: "HTML", link_preview_options: { is_disabled: true }, ...extra }),
    edit: (chat_id, message_id, text, reply_markup) =>
      message_id ? tg("editMessageText", { chat_id, message_id, text, parse_mode: "HTML",
        link_preview_options: { is_disabled: true }, ...(reply_markup ? { reply_markup } : {}) }) : null,
    answer: (id, text = "", alert = false) => tg("answerCallbackQuery", { callback_query_id: id, text, show_alert: alert }),
  });
  const C = mk(tgC);
  const S = mk(tgS);

  async function ownerIds() {
    if (!ownerCache) {
      const extra = (await rpc("staff_owner_ids", {}))?.ids || [];
      ownerCache = new Set([...adminIds, ...extra.map(Number)]);
    }
    return ownerCache;
  }
  const isOwner = async (id) => (await ownerIds()).has(Number(id));
  const notifyOwners = async (text, extra) => { for (const id of await ownerIds()) await S.send(id, text, extra); };
  const adminPanelKb = (hash = "") => inline([[{ text: "🛠 Boshqaruv panelini ochish", web_app: { url: appLink("admin.html", hash) } }]]);
  const clientAppKb = (hash = "", text = "💧 Buyurtma berish") => inline([[{ text, web_app: { url: appLink("", hash) } }]]);
  const courierOrderKb = (id) => inline([[{ text: "✅ Yetkazildi", callback_data: `dlv:${id}` }],
                                         [{ text: "↩️ Buyurtmani qaytarish", callback_data: `rel:${id}` }]]);
  // Dostavchi Telegram jonli joylashuvini ulashadi; bo'lmasa joyi zavod / buyurtma / oxirgi yetkazgan manzildan aniqlanadi
  const courierMenu = (online = false) => reply([
    [{ text: online ? B.offline : B.online }], ...(online ? [[{ text: B.live }]] : []),
    [{ text: B.active }, { text: B.today }], [{ text: B.board }], [{ text: B.logout }]]);
  const ownerMenu = () => reply([[{ text: B.panel }]]);
  const clientMenu = () => reply([[{ text: B.start }], [{ text: B.myOrders }, { text: B.contact }]]);

  // «📦 Buyurtmalarim» — ro'yxat shu yerning o'zida, chatda ko'rinadi
  async function showClientOrders(uid) {
    const me = await rpc("client_me", { tg_id: uid });
    const orders = me?.orders || [];
    if (!orders.length) return C.send(uid, "Sizda hali buyurtma yo'q. Birinchi buyurtmani bering 👇", { reply_markup: clientAppKb("", "💧 Buyurtma berish") });
    const live = orders.filter((o) => ["new", "offered", "unassigned", "accepted"].includes(o.status));
    const done = orders.filter((o) => !live.includes(o)).slice(0, 3);
    const short = (o) => (o.items || []).map((i) => `${esc(i.title)} × ${i.qty}`).join(", ");
    const lines = [];
    if (live.length) {
      lines.push("🟢 <b>Faol buyurtmalar</b>");
      for (const o of live) {
        lines.push("", `<b>#${o.id}</b> · ${STATUS[o.status] || o.status}`, `${short(o)}`, `💵 ${money(o.total)} · 🕒 ${fmtTime(o.created_at)}`);
        if (o.courier) lines.push(`🚴 ${esc(o.courier.name)}${o.courier.phone ? " · " + esc(o.courier.phone) : ""}`);
        else lines.push("⏳ Dostavchi biriktirilmoqda…");
      }
    } else lines.push("Hozir faol buyurtmangiz yo'q.");
    if (done.length) {
      lines.push("", "📋 <b>Oxirgi buyurtmalar</b>");
      for (const o of done) lines.push(`#${o.id} · ${STATUS[o.status] || o.status} · ${money(o.total)} · ${fmtTime(o.delivered_at || o.created_at)}`);
    }
    if (Number(me.debt) > 0) lines.push("", `💳 Qarzingiz: <b>${money(me.debt)}</b>`);
    const kb = [];
    const tracked = live.find((o) => o.status === "accepted");
    if (tracked) kb.push([{ text: `🗺 #${tracked.id} — dostavchini xaritada ko'rish`, web_app: { url: appLink("", "orders") } }]);
    kb.push([{ text: "📦 Batafsil ochish", web_app: { url: appLink("", "orders") } }, { text: "💧 Yangi buyurtma", web_app: { url: appLink("", "") } }]);
    return C.send(uid, lines.join("\n"), { reply_markup: inline(kb) });
  }

  async function staffBotUsername() {
    if (!staffUsername) staffUsername = (await tgS("getMe", {}))?.username || null;
    return staffUsername;
  }

  // Buyurtmani kim olganini boshqa ishdagi dostavchilarga ovozsiz bildiramiz — ikki kishi bitta mijozga bormasin
  async function broadcastTaken(order, courierId) {
    const ids = (await rpc("online_courier_ids", {}))?.ids || [];
    const name = esc(order.courier?.name || "Dostavchi");
    for (const id of ids) {
      if (Number(id) === Number(courierId)) continue;
      await S.send(id, `📌 #${order.id} ni <b>${name}</b> oldi · ${esc(order.address) || "manzil xaritada"}`, { disable_notification: true });
    }
  }

  async function boardText() {
    const b = await rpc("orders_board", {});
    const lines = ["📋 <b>Hozir yo'lda bo'lgan buyurtmalar</b>", ""];
    for (const x of b.taken) lines.push(`#${x.id} — <b>${esc(x.courier)}</b> · ${esc(x.address) || "xaritada"} (${fmtTime(x.accepted_at)})`);
    if (!b.taken.length) lines.push("Hozir hech kim yo'lda emas.");
    if (Number(b.waiting)) lines.push("", `⏳ Dostavchi kutayotgan buyurtmalar: ${b.waiting} ta`);
    return lines.join("\n");
  }

  async function notifyClientAccepted(order) {
    await C.send(order.client_id, `🚚 Buyurtma #${order.id} qabul qilindi!\nDostavchi: ${esc(order.courier?.name)}\n` +
      `📞 ${esc(order.courier?.phone || "")}\nDostavchini xaritada kuzatishingiz mumkin 👇`,
      { reply_markup: clientAppKb("orders", "🗺 Dostavchini xaritada ko'rish") });
  }

  async function sendCourierOrder(courierId, order, header) {
    await tgS("sendLocation", { chat_id: courierId, latitude: order.lat, longitude: order.lon });
    await S.send(courierId, `${header}\n\n${orderCard(order)}`, { reply_markup: courierOrderKb(order.id) });
  }

  // ---------- Taqsimlash ----------
  async function dispatch(orderId) {
    const r = await rpc("dispatch_order", { order_id: orderId });
    for (const e of r.expired || []) await S.edit(e.courier_id, e.message_id, `⌛ Buyurtma #${orderId}: javob berish vaqti tugadi.`);
    if (r.action === "offer") {
      const o = r.order;
      const mins = Math.max(1, Math.floor(r.timeout_sec / 60));
      const msg = await S.send(r.courier_id,
        `🆕 <b>Yangi buyurtma #${o.id}</b>${o.price_type === "wholesale" ? " · 🏪 optom" : ""}\n` +
        (r.distance_km != null ? `📏 Sizdan taxminan ${km(r.distance_km)}\n` : "") + `🏠 ${esc(o.address) || "—"}\n\n${itemsText(o.items)}\n` +
        `💵 Jami: <b>${money(o.total)}</b> (naqd)\n🕐 Vaqt: ${esc(o.time)}\n\n⏳ Javob berish uchun ${mins} daqiqa vaqtingiz bor.`,
        { reply_markup: inline([[{ text: "✅ Qabul qilaman", callback_data: `acc:${o.id}` },
                                 { text: "❌ Rad etaman", callback_data: `dec:${o.id}` }]]) });
      if (msg) await rpc("set_offer_message", { offer_id: r.offer_id, message_id: msg.message_id });
      else await rpc("offer_failed", { order_id: o.id, courier_id: r.courier_id });
    } else if (r.action === "unassigned" && r.notify_admin) {
      const o = r.order;
      await notifyOwners(`⚠️ <b>Buyurtma #${o.id}</b>: bo'sh dostavchi topilmadi (hammasi band, rad etgan yoki ishda emas). ` +
        `Paneldan qo'lda tayinlang.\n\n${orderCard(o)}`, apiUrl ? { reply_markup: adminPanelKb(`order-${o.id}`) } : {});
      await C.send(o.client_id, `⏳ Buyurtma #${o.id}: hozircha yaqin atrofda bo'sh dostavchi yo'q. ` +
        "Operator tez orada buyurtmangizni dostavchiga biriktiradi.");
    }
    return r;
  }

  async function tick() {
    const { ids } = await rpc("due_orders", {});
    for (const id of ids) {
      try { await dispatch(id); } catch (e) { console.error("dispatch", id, e); }
    }
    const stale = await rpc("stale_couriers", {});
    for (const id of stale.ids) {
      await S.send(id, "📡 Jonli joylashuvingiz kelmayapti — mijoz sizni xaritada ko'rmayapti.\n\n" + LIVE_HELP,
        { reply_markup: courierMenu(true) });
    }
    const b = await rpc("backup_due", {});
    if (b.due) await sendBackup(env.BACKUP_CHAT_ID ? [env.BACKUP_CHAT_ID] : [...(await ownerIds())], b.day);
  }

  async function sendBackup(chatIds, day) {
    const data = await rpc("export_all", {});
    const body = JSON.stringify(data);
    const name = `zamzam_${day || new Date().toISOString().slice(0, 10)}.json`;
    for (const chat of chatIds) {
      await deps.sendDocument(chat, name, body,
        `💾 ZamZam zaxira nusxasi ${day || ""}\nBuyurtmalar: ${data.orders.length} ta, mijozlar: ${data.users.length} ta`);
    }
  }

  async function upsertFrom(from) {
    return rpc("upsert_user", { tg_id: from.id, full_name: [from.first_name, from.last_name].filter(Boolean).join(" "), username: from.username || null });
  }

  function privateFrom(u) {
    const msg = u.message, cb = u.callback_query;
    const from = (msg || cb)?.from;
    const chat = msg?.chat || cb?.message?.chat;
    if (!from || from.is_bot || (chat && chat.type !== "private")) return null;
    return { msg, cb, from };
  }

  // =================================================================== MIJOZ BOTI
  // Ro'yxatdan o'tish: ism-familiya -> telefon -> joylashuv. Mijoz sessiyasi xodimnikidan ajralishi uchun kalit = -tg_id.
  const NAME_RE = /^[\p{L}ʻʼ'`‘’.-]{2,}(\s+[\p{L}ʻʼ'`‘’.-]{2,}){1,3}$/u;
  const isRegistered = (u) => Boolean(u.name_locked && u.phone && u.last_lat != null);
  const clientSession = (uid, data) => rpc("set_session", { tg_id: -uid, data });

  async function welcomeClient(uid, name) {
    await C.send(uid, `👋 Assalomu alaykum, ${esc(name)}!\nToza ichimlik suvini uyingizgacha yetkazib beramiz. 💧`,
      { reply_markup: clientMenu() });
    return C.send(uid, "Katalogni ochib, kerakli mahsulotni tanlang 👇", { reply_markup: clientAppKb("", "💧 Katalogni ochish") });
  }

  async function askNextRegStep(uid, user, from) {
    if (!user.name_locked) {
      await clientSession(uid, { flow: "reg", step: "name" });
      const tgName = [from.first_name, from.last_name].filter(Boolean).join(" ").trim();
      const kb = NAME_RE.test(tgName)
        ? { keyboard: [[{ text: tgName }]], resize_keyboard: true, one_time_keyboard: true }
        : { remove_keyboard: true };
      return C.send(uid, "👋 Assalomu alaykum! ZamZam suv yetkazib berish xizmatiga xush kelibsiz. 💧\n\n" +
        "Ro'yxatdan o'tish 3 qadam:\n<b>1/3.</b> Ism va familiyangizni yozing (masalan: <i>Aziz Karimov</i>):", { reply_markup: kb });
    }
    if (!user.phone) {
      await clientSession(uid, { flow: "reg", step: "phone" });
      return C.send(uid, "<b>2/3.</b> Telefon raqamingizni yuboring — dostavchi siz bilan shu raqam orqali bog'lanadi 👇",
        { reply_markup: contactKb });
    }
    if (user.last_lat == null) {
      await clientSession(uid, { flow: "reg", step: "location" });
      return C.send(uid, "<b>3/3.</b> Suv yetkaziladigan manzilni yuboring. Uyda bo'lsangiz, pastdagi tugmani bosing 👇\n" +
        "<i>Boshqa joyda bo'lsangiz: 📎 → Joylashuv → xaritada uyingizni belgilang.</i>",
        { reply_markup: { keyboard: [[{ text: B.location, request_location: true }]], resize_keyboard: true, one_time_keyboard: true } });
    }
    await clientSession(uid, null);
    await C.send(uid, `✅ Ro'yxatdan o'tdingiz, ${esc(user.full_name)}!`);
    return welcomeClient(uid, user.full_name);
  }

  async function onRegister(msg, from, user) {
    const uid = from.id;
    const text = (msg.text || "").trim();
    if (msg.contact) {
      if (msg.contact.user_id !== from.id) {
        return C.send(uid, `Iltimos, «${B.phone}» tugmasi orqali o'zingizning raqamingizni yuboring.`, { reply_markup: contactKb });
      }
      const phone = normPhone(msg.contact.phone_number);
      await rpc("client_register", { tg_id: uid, phone });
      user.phone = phone;
    } else if (msg.location && user.name_locked && user.phone) {
      const { latitude: lat, longitude: lon } = msg.location;
      await rpc("client_register", { tg_id: uid, lat, lon });
      user.last_lat = lat;
      user.last_lon = lon;
    } else if (text && !text.startsWith("/") && !user.name_locked) {
      const sess = (await rpc("get_session", { tg_id: -uid }))?.data;
      if (sess?.step === "name") {
        const name = text.replace(/\s+/g, " ");
        if (!NAME_RE.test(name) || name.length > 60) {
          return C.send(uid, "Iltimos, ism va familiyangizni to'liq, harflar bilan yozing (masalan: <i>Aziz Karimov</i>):");
        }
        const r = await rpc("client_register", { tg_id: uid, name });
        if (r.error) return C.send(uid, "⚠️ " + esc(r.error));
        user.full_name = r.name;
        user.name_locked = true;
      }
    }
    return askNextRegStep(uid, user, from);
  }

  const DISPUTE_REASONS = { money: "To'lov summasi noto'g'ri yozilgan", water: "Suv to'liq kelmadi", bottles: "Idishlar soni noto'g'ri", other: "Boshqa" };

  async function onClientCallback(cb, from) {
    const [kind, idS, arg] = String(cb.data || "").split(":");
    const id = Number(idS);
    const mid = cb.message?.message_id;
    const oldText = cb.message?.text || "";
    if (kind === "cok") {
      const r = await rpc("client_confirm", { order_id: id, client_id: from.id, ok: true });
      if (!r.ok) return C.answer(cb.id, r.error || "Xatolik", true);
      await C.answer(cb.id, "Rahmat!");
      return C.edit(from.id, mid, `${esc(oldText)}\n\n✅ <b>Tasdiqladingiz. Rahmat!</b> 💧`);
    }
    if (kind === "cbad") {
      const r = await rpc("client_confirm", { order_id: id, client_id: from.id, ok: false });
      if (!r.ok) return C.answer(cb.id, r.error || "Xatolik", true);
      await C.answer(cb.id);
      await rpc("set_session", { tg_id: -from.id, data: { flow: "dispute", order_id: id } });
      await notifyOwners(`🚨 <b>Mijoz e'tiroz bildirdi!</b>\n\n${orderCard(r.order)}\n\nSababi kutilmoqda...`,
        apiUrl ? { reply_markup: adminPanelKb(`order-${id}`) } : {});
      return C.edit(from.id, mid, `${esc(oldText)}\n\n⚠️ <b>Rahbarga xabar berildi.</b> Nima noto'g'ri?`,
        inline([[{ text: DISPUTE_REASONS.money, callback_data: `dn:${id}:money` }], [{ text: DISPUTE_REASONS.water, callback_data: `dn:${id}:water` }],
                [{ text: DISPUTE_REASONS.bottles, callback_data: `dn:${id}:bottles` }], [{ text: "✍️ O'zim yozaman", callback_data: `dn:${id}:other` }]]));
    }
    if (kind === "dn") {
      await C.answer(cb.id);
      if (arg === "other") return C.edit(from.id, mid, `${esc(oldText)}\n\n✍️ Muammoni qisqacha yozib yuboring:`);
      return onDisputeNote(from, id, DISPUTE_REASONS[arg] || "Boshqa", mid, oldText);
    }
    return C.answer(cb.id, "Bu tugma eskirgan.", true);
  }

  async function onDisputeNote(from, orderId, note, mid, oldText) {
    const r = await rpc("client_dispute_note", { order_id: orderId, client_id: from.id, note });
    await rpc("set_session", { tg_id: -from.id, data: null });
    if (!r) return C.send(from.id, "Bu buyurtma bo'yicha e'tiroz qabul qilinmadi yoki muddati o'tgan.");
    await notifyOwners(`🚨 Buyurtma #${orderId} — mijoz e'tirozi sababi:\n<b>${esc(note)}</b>\nDostavchi: ${esc(r.order.courier?.name || "")} ${esc(r.order.courier?.phone || "")}`);
    const done = "🙏 Rahmat, e'tirozingiz rahbarga yetkazildi. Tez orada siz bilan bog'lanishadi.";
    if (mid) return C.edit(from.id, mid, `${esc(oldText)}\n\n${done}`);
    return C.send(from.id, done, { reply_markup: clientMenu() });
  }

  async function onClientUpdate(u) {
    const p = privateFrom(u);
    if (!p) return;
    if (u.update_id != null && !(await rpc("claim_update", { update_id: u.update_id })).fresh) return;
    const { msg, cb, from } = p;
    const user = await upsertFrom(from);
    if (user.is_blocked) return;
    if (cb) return onClientCallback(cb, from);
    const text = (msg.text || "").trim();

    if (text === "/id") return C.send(from.id, `Sizning Telegram ID raqamingiz: <code>${from.id}</code>`);
    if (!isRegistered(user)) return onRegister(msg, from, user);
    if (msg.location) {
      await rpc("client_register", { tg_id: from.id, lat: msg.location.latitude, lon: msg.location.longitude });
      return C.send(from.id, "📍 Manzilingiz yangilandi. Keyingi buyurtmada shu manzil tanlanadi.", { reply_markup: clientMenu() });
    }
    if (text.startsWith("/start") || text === B.start) return welcomeClient(from.id, user.full_name);
    if (text && !text.startsWith("/") && ![B.order, B.start, B.myOrders, B.contact].includes(text)) {
      const sess = (await rpc("get_session", { tg_id: -from.id }))?.data;
      if (sess?.flow === "dispute") return onDisputeNote(from, sess.order_id, text);
    }
    // eski klaviaturasi qolgan mijozlar uchun: buyurtma oynasini ochib, yangi menyuni ham beradi
    if (text === B.order) {
      await C.send(from.id, "Menyu yangilandi 👇", { reply_markup: clientMenu() });
      return C.send(from.id, "Mahsulotni tanlash uchun 👇", { reply_markup: clientAppKb("", "💧 Katalogni ochish") });
    }
    if (text === B.myOrders) return showClientOrders(from.id);
    if (text === B.contact) {
      const st = (await rpc("client_me", { tg_id: from.id })).settings;
      return C.send(from.id, `📞 Savol va takliflar uchun: ${esc(st.support_phone || "tez orada qo'shiladi")}`);
    }
    return C.send(from.id, "Quyidagi menyudan tanlang 👇", { reply_markup: clientMenu() });
  }

  // =================================================================== XODIMLAR BOTI
  async function onStaffUpdate(u) {
    const ed = u.edited_message;
    if (ed) {
      // Jonli joylashuv yangilanishi — eng ko'p keladigan xabar
      if (ed.location && ed.chat?.type === "private") {
        await rpc("courier_location", { tg_id: ed.from.id, lat: ed.location.latitude, lon: ed.location.longitude, go_online: false });
      }
      return;
    }
    const p = privateFrom(u);
    if (!p) return;
    // ikki botning update_id lari to'qnashmasligi uchun manfiy kalit
    if (u.update_id != null && !(await rpc("claim_update", { update_id: -u.update_id })).fresh) return;
    const { msg, cb, from } = p;
    const user = await upsertFrom(from);
    const session = user.session || null;
    const staff = await rpc("staff_me", { tg_id: from.id });
    const owner = await isOwner(from.id);
    const role = owner ? "owner" : staff?.role || null;

    if (!role) return onLogin(msg, cb, from, session);
    if (cb) return role === "courier" ? onCourierCallback(cb, from, session) : S.answer(cb.id, "Bu tugma eskirgan.", true);
    const text = (msg.text || "").trim();

    if (text === "/id") return S.send(from.id, `Sizning Telegram ID raqamingiz: <code>${from.id}</code>`);
    if (text === B.logout || text === "/chiqish") {
      if (adminIds.has(from.id) && !staff) return S.send(from.id, "Siz bosh admin sifatida doim kirgansiz (ADMIN_IDS).");
      const r = await rpc("staff_logout", { tg_id: from.id });
      if (!r.ok) return S.send(from.id, "⚠️ " + esc(r.error));
      ownerCache = null;
      await tgS("setChatMenuButton", { chat_id: from.id, menu_button: { type: "commands" } });
      return S.send(from.id, "🚪 Tizimdan chiqdingiz. Qayta kirish uchun /start bosing.", { reply_markup: { remove_keyboard: true } });
    }
    if (role === "owner") return onOwnerMessage(msg, text, from);
    return onCourierMessage(msg, text, from, session, staff);
  }

  async function onLogin(msg, cb, from, session) {
    const uid = from.id;
    if (cb) return S.answer(cb.id, "Avval tizimga kiring: /start", true);
    const text = (msg.text || "").trim();
    if (text.startsWith("/start") || !session || session.flow !== "login") {
      await rpc("set_session", { tg_id: uid, data: { flow: "login", step: "login" } });
      return S.send(uid, "🔐 <b>ZamZam xodimlar tizimi</b>\n\nLoginingizni kiriting:", { reply_markup: { remove_keyboard: true } });
    }
    if ((await rpc("staff_login_blocked", { tg_id: uid })).blocked) {
      return S.send(uid, "⛔ Juda ko'p noto'g'ri urinish. 15 daqiqadan keyin qayta urinib ko'ring.");
    }
    if (session.step === "login") {
      if (!/^[A-Za-z0-9_.]{3,32}$/.test(text)) return S.send(uid, "Login faqat lotin harflari va raqamlardan iborat. Qayta kiriting:");
      await rpc("set_session", { tg_id: uid, data: { flow: "login", step: "password", login: text.toLowerCase() } });
      return S.send(uid, "Parolingizni kiriting:\n<i>(xavfsizlik uchun xabaringiz darhol o'chiriladi)</i>");
    }
    // parol: xabarni chatdan o'chiramiz
    await tgS("deleteMessage", { chat_id: uid, message_id: msg.message_id });
    const auth = await rpc("staff_auth_get", { login: session.login });
    let ok = false;
    if (auth && auth.is_active && text) {
      const h = await hashPassword(text, auth.pass_salt);
      ok = safeEqual(h.hash, auth.pass_hash);
    }
    await rpc("staff_login_record", { tg_id: uid, ok });
    if (!ok) {
      await rpc("set_session", { tg_id: uid, data: { flow: "login", step: "login" } });
      return S.send(uid, "❌ Login yoki parol noto'g'ri. Loginni qaytadan kiriting:");
    }
    const r = await rpc("staff_bind", { staff_id: auth.id, tg_id: uid });
    await rpc("set_session", { tg_id: uid, data: null });
    ownerCache = null;
    if (!r.ok) return S.send(uid, "❌ Hisob faol emas. Rahbarga murojaat qiling.");
    await notifyOwners(`🔐 ${esc(r.full_name)} (${r.role === "owner" ? "rahbar" : "dostavchi"}) xodimlar botiga kirdi.`);
    return greetStaff(uid, r.role, r.full_name);
  }

  async function greetStaff(uid, role, name) {
    if (role === "owner") {
      await tgS("setChatMenuButton", { chat_id: uid, menu_button: { type: "web_app", text: "Panel", web_app: { url: appLink("admin.html") } } });
      await S.send(uid, `👋 Xush kelibsiz, ${esc(name)}! Siz rahbar sifatida kirdingiz.`, { reply_markup: ownerMenu() });
      return S.send(uid, "Boshqaruv paneli 👇", { reply_markup: adminPanelKb() });
    }
    const online = (await rpc("staff_me", { tg_id: uid }))?.online;
    await S.send(uid, `👋 Xush kelibsiz, ${esc(name)}!\n\n${COURIER_HELP}`, { reply_markup: courierMenu(Boolean(online)) });
  }

  async function onOwnerMessage(msg, text, from) {
    if (text.startsWith("/start")) return greetStaff(from.id, "owner", from.first_name || "");
    return S.send(from.id, "Boshqaruv paneli 👇", { reply_markup: adminPanelKb() });
  }

  // ---------- Dostavchi ----------
  async function onCourierMessage(m, text, from, session, staff) {
    const uid = from.id;
    if (m.location) {
      // ixtiyoriy: dostavchi o'zi joylashuv yuborsa, eng aniq ma'lumot sifatida olinadi
      const r = await rpc("courier_location", { tg_id: uid, lat: m.location.latitude, lon: m.location.longitude, go_online: false });
      if (!r?.ok) return S.send(uid, "⚠️ Hisobingiz dostavchi sifatida faol emas. Rahbarga murojaat qiling.");
      if (m.location.live_period) {
        const h = Math.round(m.location.live_period / 3600);
        return S.send(uid, `📡 <b>Jonli joylashuv yoqildi</b>${h >= 1 && m.location.live_period < 0x7fffffff ? ` (${h} soat)` : ""}. ` +
          "Endi mijoz sizni xaritada ko'radi, buyurtmalar ham eng yaqiniga beriladi.");
      }
      return S.send(uid, "📍 Joylashuv qabul qilindi. Yaxshisi <b>jonli</b> joylashuvni yoqing — u o'zi yangilanib turadi.\n\n" + LIVE_HELP);
    }
    if (text.startsWith("/start")) return greetStaff(uid, "courier", staff?.full_name || from.first_name);
    if (text === B.online || text === B.refresh) {
      const r = await rpc("courier_set_online", { tg_id: uid, online: true });
      if (!r?.ok) return S.send(uid, "⚠️ Hisobingiz dostavchi sifatida faol emas. Rahbarga murojaat qiling.");
      return S.send(uid, `✅ <b>Ish boshlandi</b> — ${fmtTime(r.started_at).split(", ").pop()}\nSizga yaqin buyurtmalar keladi.\n\n` +
        LIVE_HELP + "\n\nHar bir yetkazishdan keyin «✅ Yetkazildi» ni bosishni unutmang.",
        { reply_markup: courierMenu(true) });
    }
    if (text === B.live) return S.send(uid, LIVE_HELP, { reply_markup: courierMenu(true) });
    if (text === B.offline) {
      const r = await rpc("courier_set_online", { tg_id: uid, online: false });
      const sm = await rpc("courier_summary", { tg_id: uid });
      const lines = ["🔴 <b>Ish tugatildi.</b> Endi sizga yangi buyurtma kelmaydi.", "",
        `⏱ Bu smena: ${hm(r.minutes)}`, `✅ Bugun yetkazildi: ${sm.delivered} ta`, `💵 Bugun olingan naqd: ${money(sm.collected)}`,
        `💰 Qo'lingizda (rahbarga topshirilmagan): <b>${money(sm.balance)}</b>`];
      if (Number(r.active)) lines.push("", `⚠️ Sizda hali ${r.active} ta yetkazilmagan buyurtma bor — ularni yetkazishni unutmang.`);
      return S.send(uid, lines.join("\n"), { reply_markup: courierMenu(false) });
    }
    if (text === B.active) {
      const { orders } = await rpc("courier_orders", { tg_id: uid });
      if (!orders.length) return S.send(uid, "Sizda hozir faol buyurtma yo'q.");
      for (const o of orders) await S.send(uid, orderCard(o), { reply_markup: courierOrderKb(o.id) });
      return;
    }
    if (text === B.board) return S.send(uid, await boardText());
    if (text === B.today) {
      const r = await rpc("courier_today", { tg_id: uid });
      const sm = await rpc("courier_summary", { tg_id: uid });
      const lines = ["📊 <b>Mening hisobim — bugun</b>", "",
        sm.shift_started ? `🟢 Ishdasiz: ${fmtTime(sm.shift_started).split(", ").pop()} dan beri` : "⚪ Hozir ishda emassiz",
        `⏱ Bugun ishlagan vaqt: ${hm(sm.minutes)}`,
        `✅ Yetkazilgan: ${sm.delivered} ta${Number(sm.active) ? ` · yo'lda: ${sm.active} ta` : ""}`,
        `🧾 Sotuv: ${money(sm.revenue)}`,
        `💵 Olingan naqd: ${money(sm.collected)}`,
        ...(Number(sm.debts) ? [`📝 Qarzga berilgan: ${money(sm.debts)}`] : []),
        ...(Number(sm.handed) ? [`📤 Rahbarga topshirildi: ${money(sm.handed)}`] : []),
        ...r.bottles.map((b) => `🫙 ${b.volume_l} L: berildi ${b.given}, qaytarib olindi ${b.returned}`),
        "", `💰 Qo'lingizda (topshirilmagan): <b>${money(sm.balance)}</b>`];
      return S.send(uid, lines.join("\n"));
    }
    if (session?.flow === "dlv" && session.await) return onDeliveryText(uid, session, text);
    return S.send(uid, "Quyidagi menyudan tanlang 👇", { reply_markup: courierMenu(Boolean(staff?.online)) });
  }

  // ---------- Yetkazish jarayoni: idishlar -> yaroqsiz tara -> to'lov -> tasdiq ----------
  const numKb = (prefix, from = 0, extraRows = []) => inline([
    [...Array(6).keys()].map((i) => ({ text: String(i + from), callback_data: `${prefix}:${i + from}` })),
    [...Array(5).keys()].map((i) => ({ text: String(i + from + 6), callback_data: `${prefix}:${i + from + 6}` })),
    [{ text: "✍️ Boshqa son", callback_data: `${prefix}:-1` }],
    ...extraRows,
  ]);

  function stepView(s) {
    const hdr = `🫙 Buyurtma #${s.order_id}\n`;
    if (s.step === "ret") {
      const vol = s.vols[s.idx];
      return { text: `${hdr}Mijozdan nechta bo'sh <b>${vol} litr</b> idish qaytarib oldingiz? (yaroqlilarini)\n\n` +
        `Hozir berildi: ${s.deliveredVol[vol] || 0} ta\nMijozda oldindan bor edi: ${s.balance[vol] || 0} ta`, kb: numKb("rt") };
    }
    if (s.step === "def_ask") {
      const list = s.defective.map((d) => `• ${d.volume_l} L × ${d.qty}: ${esc(d.comment || "izohsiz")}`).join("\n");
      return { text: `${hdr}Yaroqsiz (qabul qilinmagan) tara bormi?` + (list ? `\n\nKiritilgan:\n${list}` : ""),
        kb: inline([[{ text: s.defective.length ? "➡️ Yo'q, davom etish" : "✅ Yo'q", callback_data: "df:no" },
                     { text: s.defective.length ? "➕ Yana qo'shish" : "⚠️ Bor", callback_data: "df:yes" }]]) };
    }
    if (s.step === "def_vol") {
      return { text: `${hdr}Qaysi idish yaroqsiz?`, kb: inline([s.vols.map((v) => ({ text: `${v} L`, callback_data: `dv:${v}` }))]) };
    }
    if (s.step === "def_qty") return { text: `${hdr}Nechta <b>${s.def_vol} L</b> idish yaroqsiz (qabul qilinmadi)?`, kb: numKb("dq", 1) };
    if (s.step === "def_comment") {
      return { text: `${hdr}Sababini qisqacha yozing (masalan: <i>darz ketgan, iflos, boshqa firmaniki</i>):`,
        kb: inline([[{ text: "⏭ Izohsiz", callback_data: "dsk:0" }]]) };
    }
    if (s.step === "pay") {
      const rows = [[{ text: `✅ To'liq to'ladi — ${money(s.total)}`, callback_data: "pay:full" }]];
      if (s.debt > 0) rows.push([{ text: `💰 Eski qarzi bilan — ${money(s.total + s.debt)}`, callback_data: "pay:all" }]);
      rows.push([{ text: "📝 To'lamadi (hammasi qarzga)", callback_data: "pay:zero" }]);
      rows.push([{ text: "✍️ Boshqa summa (qisman)", callback_data: "pay:custom" }]);
      return { text: `${hdr}💵 Mijoz qancha to'ladi?\n\nBuyurtma: <b>${money(s.total)}</b>` +
        (s.debt > 0 ? `\nMijozning eski qarzi: <b>${money(s.debt)}</b>` : ""), kb: inline(rows) };
    }
    // summary
    const lines = [`📋 <b>Buyurtma #${s.order_id} — tekshiring</b>`, ""];
    for (const it of s.items) lines.push(`• ${esc(it.title)}: ${it.qty} ta berildi`);
    for (const [vol, n] of Object.entries(s.returns)) lines.push(`• ${vol} L bo'sh idish qaytarib olindi: ${n} ta`);
    for (const d of s.defective) lines.push(`• ⚠️ ${d.volume_l} L yaroqsiz, qabul qilinmadi: ${d.qty} ta — ${esc(d.comment || "izohsiz")}`);
    lines.push("", `💵 Buyurtma: ${money(s.total)}`, `💰 Olindi: <b>${money(s.paid)}</b>`);
    const diff = s.total - s.paid;
    if (diff > 0) lines.push(`📝 Qarzga yoziladi: <b>${money(diff)}</b>`);
    if (diff < 0) lines.push(`✅ Eski qarzdan to'landi: ${money(-diff)}`);
    return { text: lines.join("\n"), kb: inline([[{ text: "✅ Tasdiqlash", callback_data: "dc:yes" }],
                                                 [{ text: "🔄 Qaytadan kiritish", callback_data: "dc:redo" }]]) };
  }

  async function showStep(uid, s, messageId) {
    // "Boshqa son" kabi qo'lda kiritish holatlari alohida o'rnatiladi; bu yerda faqat izoh kutiladi
    s.await = s.step === "def_comment" ? "def_comment" : null;
    await rpc("set_session", { tg_id: uid, data: s });
    const v = stepView(s);
    if (messageId) return S.edit(uid, messageId, v.text, v.kb);
    return S.send(uid, v.text, { reply_markup: v.kb });
  }

  function nextAfterReturns(s) {
    s.step = s.vols.length ? "def_ask" : "pay";
  }

  async function onDeliveryText(uid, s, text) {
    const num = /^\d{1,7}$/.test(text.replace(/\s/g, "")) ? Number(text.replace(/\s/g, "")) : null;
    if (s.await === "ret_custom") {
      if (num == null || num > 500) return S.send(uid, "Iltimos, 0 dan 500 gacha raqam yozing.");
      s.returns[s.vols[s.idx]] = num;
      s.idx += 1;
      s.await = null;
      if (s.idx >= s.vols.length) nextAfterReturns(s);
      return showStep(uid, s, null);
    }
    if (s.await === "def_qty_custom") {
      if (num == null || num < 1 || num > 500) return S.send(uid, "Iltimos, 1 dan 500 gacha raqam yozing.");
      s.def_qty = num;
      s.step = "def_comment";
      s.await = null;
      return showStep(uid, s, null);
    }
    if (s.await === "def_comment") {
      s.defective.push({ volume_l: s.def_vol, qty: s.def_qty, comment: text.slice(0, 300) });
      s.step = "def_ask";
      s.await = null;
      return showStep(uid, s, null);
    }
    if (s.await === "pay_custom") {
      if (num == null) return S.send(uid, "Iltimos, summani raqam bilan yozing (masalan: 30000).");
      if (num > s.total + Math.max(s.debt, 0)) return S.send(uid, `Summa juda katta. Eng ko'pi: ${money(s.total + Math.max(s.debt, 0))}`);
      s.paid = num;
      s.step = "summary";
      s.await = null;
      return showStep(uid, s, null);
    }
    return S.send(uid, "Quyidagi tugmalardan foydalaning.");
  }

  async function onCourierCallback(cb, from, session) {
    const [kind, arg] = String(cb.data || "").split(":");
    const uid = from.id;
    const mid = cb.message?.message_id;
    const id = Number(arg);

    if (kind === "acc") {
      const r = await rpc("accept_offer", { order_id: id, courier_id: uid });
      if (!r.ok) {
        await S.answer(cb.id, "Bu buyurtma endi mavjud emas yoki javob vaqti tugagan.", true);
        return tgS("editMessageReplyMarkup", { chat_id: uid, message_id: mid, reply_markup: inline([]) });
      }
      await S.edit(uid, mid, `✅ <b>Siz qabul qildingiz</b>\n\n${orderCard(r.order)}`, courierOrderKb(id));
      await tgS("sendLocation", { chat_id: uid, latitude: r.order.lat, longitude: r.order.lon });
      await notifyClientAccepted(r.order);
      await S.answer(cb.id, "Qabul qilindi ✅");
      return broadcastTaken(r.order, uid);
    }
    if (kind === "dec") {
      const r = await rpc("decline_offer", { order_id: id, courier_id: uid });
      await S.edit(uid, mid, `❌ Buyurtma #${id} rad etildi.`);
      await S.answer(cb.id);
      if (r.ok) await dispatch(id);
      return;
    }
    if (kind === "rel") {
      const r = await rpc("release_order", { order_id: id, courier_id: uid });
      if (!r.ok) return S.answer(cb.id, "Bu buyurtma sizda emas.", true);
      await S.edit(uid, mid, `↩️ Buyurtma #${id} qaytarildi, boshqa dostavchiga beriladi.`);
      await S.answer(cb.id);
      await notifyOwners(`↩️ Dostavchi ${esc(from.first_name)} buyurtma #${id} ni qaytardi. Boshqa dostavchi qidirilmoqda.`);
      await C.send(r.client_id, `ℹ️ Buyurtma #${id}: dostavchi almashtirilmoqda, biroz kuting.`);
      await dispatch(id);
      return;
    }
    if (kind === "dlv") {
      const info = await rpc("delivery_info", { order_id: id, courier_id: uid });
      if (!info?.ok) return S.answer(cb.id, "Bu buyurtma sizda emas yoki allaqachon yakunlangan.", true);
      const deliveredVol = {};
      for (const i of info.order.items) if (i.returnable) deliveredVol[i.volume_l] = (deliveredVol[i.volume_l] || 0) + i.qty;
      const items = info.order.items.map((i) => ({ title: i.title, qty: i.qty }));
      const vols = [...new Set(info.order.items.filter((i) => i.returnable).map((i) => i.volume_l))].sort((a, b) => a - b);
      const balance = {};
      for (const b of info.balance) balance[b.volume_l] = b.balance;
      const s = { flow: "dlv", order_id: id, vols, idx: 0, returns: {}, defective: [], deliveredVol, items, balance,
                  total: Number(info.order.total), debt: Number(info.debt) || 0, paid: null, step: vols.length ? "ret" : "pay" };
      await S.answer(cb.id);
      return showStep(uid, s, null);
    }
    if (session?.flow !== "dlv") return S.answer(cb.id, "Bu tugma eskirgan. «✅ Yetkazildi» ni qayta bosing.", true);
    const s = session;
    await S.answer(cb.id);

    if (kind === "rt") {
      if (s.step !== "ret") return;
      if (id === -1) { s.await = "ret_custom"; await rpc("set_session", { tg_id: uid, data: s });
        return S.edit(uid, mid, "✍️ Qaytarib olingan yaroqli bo'sh idishlar sonini yozing:"); }
      s.returns[s.vols[s.idx]] = id;
      s.idx += 1;
      if (s.idx >= s.vols.length) nextAfterReturns(s);
      return showStep(uid, s, mid);
    }
    if (kind === "df") {
      if (arg === "no") s.step = "pay";
      else s.step = s.vols.length > 1 ? "def_vol" : "def_qty";
      if (s.step === "def_qty") s.def_vol = s.vols[0];
      return showStep(uid, s, mid);
    }
    if (kind === "dv") { s.def_vol = id; s.step = "def_qty"; return showStep(uid, s, mid); }
    if (kind === "dq") {
      if (id === -1) { s.await = "def_qty_custom"; await rpc("set_session", { tg_id: uid, data: s });
        return S.edit(uid, mid, "✍️ Yaroqsiz idishlar sonini yozing:"); }
      s.def_qty = id;
      s.step = "def_comment";
      return showStep(uid, s, mid);
    }
    if (kind === "dsk") {
      s.defective.push({ volume_l: s.def_vol, qty: s.def_qty, comment: "" });
      s.step = "def_ask";
      s.await = null;
      return showStep(uid, s, mid);
    }
    if (kind === "pay") {
      if (arg === "custom") { s.await = "pay_custom"; await rpc("set_session", { tg_id: uid, data: s });
        return S.edit(uid, mid, `✍️ Mijoz qancha to'ladi? Summani yozing (buyurtma: ${money(s.total)}):`); }
      s.paid = arg === "full" ? s.total : arg === "all" ? s.total + Math.max(s.debt, 0) : 0;
      s.step = "summary";
      return showStep(uid, s, mid);
    }
    if (kind === "dc") {
      if (arg === "redo") {
        Object.assign(s, { idx: 0, returns: {}, defective: [], paid: null, await: null, step: s.vols.length ? "ret" : "pay" });
        return showStep(uid, s, mid);
      }
      if (s.step !== "summary") return;
      const r = await rpc("complete_delivery", { order_id: s.order_id, courier_id: uid, returns: s.returns,
        defective: s.defective, paid: String(s.paid) });
      if (!r.ok) {
        if (r.error) return S.edit(uid, mid, "⚠️ " + esc(r.error), inline([[{ text: "🔄 Qaytadan kiritish", callback_data: "dc:redo" }]]));
        await rpc("set_session", { tg_id: uid, data: null });
        return S.edit(uid, mid, "ℹ️ Bu buyurtma allaqachon yakunlangan.");
      }
      await rpc("set_session", { tg_id: uid, data: null });
      await S.edit(uid, mid, `✅ Buyurtma #${s.order_id} yetkazildi. Rahmat!\nMijozga tekshirish uchun xabar yuborildi.`);
      const staffName = (await rpc("staff_me", { tg_id: uid }))?.full_name;
      // Mijozning o'zi tekshiradi: dostavchi kiritgan pul, qarz va idishlar to'g'rimi
      const t = [`✅ <b>Buyurtma #${s.order_id} yetkazildi</b>`, `🚚 Dostavchi: ${esc(staffName || from.first_name)}`, "",
        "Dostavchi quyidagilarni kiritdi — iltimos, tekshiring:"];
      for (const it of s.items) t.push(`• ${esc(it.title)}: ${it.qty} ta`);
      for (const [vol, n] of Object.entries(s.returns)) if (Number(n)) t.push(`• Siz qaytargan bo'sh ${vol} L idish: ${n} ta`);
      for (const d of s.defective) t.push(`• Qabul qilinmagan yaroqsiz ${d.volume_l} L idish: ${d.qty} ta${d.comment ? ` (${esc(d.comment)})` : ""}`);
      t.push("", `💵 Siz to'lagan naqd pul: <b>${money(s.paid)}</b>`);
      if (s.total - s.paid > 0) t.push(`📝 Qarzga yozildi: <b>${money(s.total - s.paid)}</b>`);
      if (s.total - s.paid < 0) t.push(`✅ Eski qarzdan to'landi: ${money(s.paid - s.total)}`);
      if (Number(r.debt) > 0) t.push(`📒 Umumiy qarzingiz: <b>${money(r.debt)}</b>`);
      if (r.balance.length) t.push("", "🫙 Sizdagi idishlarimiz: " + r.balance.map((b) => `${b.volume_l} L — ${b.balance} ta`).join(", "));
      t.push("", "Hammasi to'g'rimi?");
      await C.send(r.client_id, t.join("\n"), { reply_markup: inline([[{ text: "✅ Ha, hammasi to'g'ri", callback_data: `cok:${s.order_id}` }],
        [{ text: "⚠️ Yo'q, noto'g'ri", callback_data: `cbad:${s.order_id}` }]]) });
      if (s.defective.length || s.total - s.paid > 0) {
        await notifyOwners(`ℹ️ Buyurtma #${s.order_id} yetkazildi (${esc(staffName || from.first_name)}).` +
          (s.total - s.paid > 0 ? `\n📝 Qarzga: ${money(s.total - s.paid)}` : "") +
          (s.defective.length ? `\n⚠️ Yaroqsiz tara: ${s.defective.map((d) => `${d.volume_l} L × ${d.qty}`).join(", ")}` : ""));
      }
      return;
    }
  }

  // =================================================================== MINI APP API
  async function api(body, user, via) {
    const uid = user.id;
    const a = body.action;
    await rpc("upsert_user", { tg_id: uid, full_name: [user.first_name, user.last_name].filter(Boolean).join(" "), username: user.username || null });

    // --- mijoz ---
    if (a === "me") return { ...(await rpc("client_me", { tg_id: uid })), is_admin: via === "staff" && (await isOwner(uid)) };
    if (a === "order") {
      const r = await rpc("create_order", { client_id: uid, lat: body.lat, lon: body.lon, address: body.address,
        time: body.time, cart: body.cart, idem: String(body.idem || "").slice(0, 64) });
      if (r.error) return { error: r.error };
      if (r.created) {
        await C.send(uid, `✅ <b>Buyurtma #${r.id} qabul qilindi!</b>\nYaqin atrofdagi dostavchi qidirilmoqda...`);
        deps.background(dispatch(r.id).catch((e) => console.error("dispatch", e)));
      }
      return { ok: true, id: r.id };
    }
    if (a === "profile") {
      const p = { tg_id: uid };
      if ("name" in body) p.name = String(body.name || "").slice(0, 80);
      if ("lat" in body) { p.lat = Number(body.lat); p.lon = Number(body.lon); if (!Number.isFinite(p.lat) || !Number.isFinite(p.lon)) return { error: "Manzil noto'g'ri" }; }
      if ("address" in body) p.address = String(body.address || "").slice(0, 300);
      return rpc("client_profile_update", p);
    }
    if (a === "confirm") {
      const ok = body.ok === true;
      const note = String(body.note || "").slice(0, 500);
      const r = await rpc("client_confirm", { order_id: body.order_id, client_id: uid, ok, note });
      if (!r.ok) return { error: r.error };
      if (!ok) {
        await notifyOwners(`🚨 <b>Mijoz e'tiroz bildirdi!</b>\n\n${orderCard(r.order)}\n\nSabab: <b>${esc(note || "yozilmagan")}</b>`,
          apiUrl ? { reply_markup: adminPanelKb(`order-${body.order_id}`) } : {});
      }
      return { ok: true };
    }
    if (a === "cancel") {
      const r = await rpc("cancel_order", { order_id: body.order_id, actor: uid, by_client: true, reason: "Mijoz bekor qildi" });
      if (r.error) return { error: r.error };
      for (const p of r.pending || []) await S.edit(p.courier_id, p.message_id, `❌ Buyurtma #${body.order_id} bekor qilindi.`);
      await notifyOwners(`ℹ️ Mijoz buyurtma #${body.order_id} ni bekor qildi.`);
      return { ok: true };
    }

    // --- rahbar ---
    if (!a?.startsWith("a_")) return { error: "Noma'lum amal" };
    if (via !== "staff" || !(await isOwner(uid))) return { error: "Ruxsat yo'q" };

    if (a === "a_overview") return { ...(await rpc("admin_overview", {})), extra: await rpc("admin_extra", {}) };
    if (a === "a_team") return rpc("admin_team", { days: [1, 7, 30].includes(body.days) ? body.days : 1 });
    if (a === "a_courier") return rpc("admin_courier_detail", { tg_id: Number(body.tg_id) || 0 });
    if (a === "a_cash_history") return rpc("admin_cash_history", {});
    if (a === "a_banners") return rpc("admin_banners", {});
    if (a === "a_banner_upload") {
      // Video katta bo'lishi mumkin — fayl brauzerdan to'g'ridan-to'g'ri Supabase Storage'ga yuklanadi (bir martalik imzoli havola)
      const types = { "video/mp4": ["video", "mp4"], "video/webm": ["video", "webm"], "video/quicktime": ["video", "mov"],
                      "image/jpeg": ["image", "jpg"], "image/png": ["image", "png"], "image/webp": ["image", "webp"] };
      const t = types[String(body.type || "")];
      if (!t) return { error: "Faqat MP4/WebM/MOV video yoki JPG/PNG/WebP rasm" };
      if (!(Number(body.size) > 0) || Number(body.size) > 50 * 1024 * 1024) return { error: "Fayl 50 MB dan oshmasin" };
      if (!deps.signUpload) return { error: "Yuklash sozlanmagan" };
      const name = `b_${Date.now().toString(36)}_${Math.random().toString(36).slice(2, 8)}.${t[1]}`;
      const r = await deps.signUpload("banners", name);
      if (!r) return { error: "Yuklash havolasini olib bo'lmadi, qayta urinib ko'ring" };
      return { ok: true, kind: t[0], upload_url: r.uploadUrl, public_url: r.publicUrl };
    }
    if (a === "a_banner_create") {
      const url = String(body.url || "");
      const prefix = String(env.SUPABASE_URL || "").replace(/\/$/, "") + "/storage/v1/object/public/banners/";
      if (!url.startsWith(prefix) && !deps.allowAnyBannerUrl) return { error: "Fayl manzili noto'g'ri" };
      return rpc("admin_banner_create", { actor: uid, kind: body.kind, url, title: String(body.title || "") });
    }
    if (a === "a_banner_update") {
      if (!["toggle", "delete", "up", "down", "title"].includes(body.op)) return { error: "Noma'lum amal" };
      return rpc("admin_banner_update", { actor: uid, id: body.id, op: body.op, title: String(body.title || "") });
    }
    if (a === "a_cash_handover") {
      const r = await rpc("admin_cash_handover", { actor: uid, courier_id: body.courier_id,
        amount: String(body.amount ?? "").replace(/\s/g, ""), note: String(body.note || "").slice(0, 200) });
      if (r.ok) await S.send(body.courier_id, `💰 Rahbarga <b>${money(r.amount)}</b> topshirdingiz.\nQo'lingizda qoldi: <b>${money(r.balance)}</b>`);
      return r;
    }
    if (a === "a_dispute_resolve") return rpc("admin_dispute_resolve", { actor: uid, order_id: body.order_id, note: String(body.note || "") });
    if (a === "a_stats") return rpc("admin_stats", { days: [1, 7, 30].includes(body.days) ? body.days : 1 });
    if (a === "a_clients") return rpc("admin_clients", { digits: String(body.digits || "").replace(/\D/g, "").slice(-9),
      filter: ["all", "wholesale", "debt", "bottles"].includes(body.filter) ? body.filter : "all" });
    if (a === "a_client") return rpc("admin_client", { client_id: body.client_id });
    if (a === "a_client_update") {
      const p = { actor: uid, client_id: body.client_id };
      if ("type" in body) p.type = body.type;
      if ("business" in body) p.business = String(body.business ?? "");
      return rpc("admin_client_update", p);
    }
    if (a === "a_debt") return rpc("admin_debt_record", { actor: uid, client_id: body.client_id, kind: body.kind,
      amount: String(body.amount ?? "").replace(/\s/g, ""), note: String(body.note || "").slice(0, 200) });
    if (a === "a_bottle_adjust") return rpc("admin_bottle_adjust", { actor: uid, client_id: body.client_id, volume_l: body.volume_l, delta: String(body.delta) });
    if (a === "a_product") {
      const p = { actor: uid, id: body.id };
      for (const k of ["price", "wholesale_price", "returnable", "is_active", "title", "description", "unit", "image_url"]) if (k in body) p[k] = body[k];
      for (const k of ["title", "description", "unit", "image_url"]) if (k in p) p[k] = String(p[k] ?? "");
      if ("sort_order" in body && Number.isInteger(body.sort_order) && Math.abs(body.sort_order) < 1e6) p.sort_order = body.sort_order;
      if ("price" in p) p.price = String(p.price);
      if ("wholesale_price" in p) p.wholesale_price = p.wholesale_price == null ? "" : String(p.wholesale_price);
      return rpc("admin_product_update", p);
    }
    if (a === "a_product_create") {
      return rpc("admin_product_create", { actor: uid, title: String(body.title || ""), price: String(body.price ?? ""),
        wholesale_price: body.wholesale_price == null ? "" : String(body.wholesale_price),
        volume_l: body.volume_l == null ? "" : String(body.volume_l), returnable: Boolean(body.returnable),
        description: String(body.description || ""), unit: String(body.unit || "") });
    }
    if (a === "a_product_image") {
      // Rasm brauzerda kichraytirilib (JPEG/WebP, ~800px) base64 ko'rinishida keladi
      const m = /^data:image\/(jpeg|png|webp);base64,([A-Za-z0-9+/=]+)$/.exec(String(body.data || ""));
      if (!m) return { error: "Rasm formati noto'g'ri (JPG, PNG yoki WebP)" };
      const bytes = Uint8Array.from(atob(m[2]), (c) => c.charCodeAt(0));
      if (bytes.length > 1_500_000) return { error: "Rasm juda katta (1.5 MB dan oshmasin)" };
      const magic = { jpeg: [0xff, 0xd8, 0xff], png: [0x89, 0x50, 0x4e], webp: [0x52, 0x49, 0x46] }[m[1]];
      if (!magic.every((b, i) => bytes[i] === b)) return { error: "Fayl rasm emas" };
      if (!deps.uploadImage) return { error: "Rasm yuklash sozlanmagan" };
      const name = `p${Number(body.id) || 0}_${Date.now().toString(36)}.${m[1] === "jpeg" ? "jpg" : m[1]}`;
      const url = await deps.uploadImage(name, bytes, `image/${m[1]}`);
      if (!url) return { error: "Rasmni saqlab bo'lmadi, qayta urinib ko'ring" };
      if (body.id) {
        const r = await rpc("admin_product_update", { actor: uid, id: body.id, image_url: url });
        if (r.error) return r;
      }
      return { ok: true, url };
    }
    if (a === "a_setting") return rpc("admin_setting_set", { actor: uid, key: body.key, value: String(body.value ?? "") });
    if (a === "a_assign") {
      const r = await rpc("assign_order", { order_id: body.order_id, courier_id: body.courier_id, actor: uid });
      if (r.error) return r;
      const o = r.order;
      for (const p of r.pending || []) await S.edit(p.courier_id, p.message_id, `ℹ️ Buyurtma #${o.id} boshqa dostavchiga berildi.`);
      if (r.prev_courier) await S.send(r.prev_courier, `ℹ️ Buyurtma #${o.id} rahbar tomonidan boshqa dostavchiga o'tkazildi.`);
      await sendCourierOrder(body.courier_id, o, `📌 <b>Rahbar sizga buyurtma #${o.id} ni biriktirdi</b>`);
      await notifyClientAccepted(o);
      await broadcastTaken(o, body.courier_id);
      return { ok: true };
    }
    if (a === "a_cancel") {
      const reason = String(body.reason || "Operator tomonidan bekor qilindi").slice(0, 200);
      const r = await rpc("cancel_order", { order_id: body.order_id, actor: uid, by_client: false, reason });
      if (r.error) return r;
      for (const p of r.pending || []) await S.edit(p.courier_id, p.message_id, `❌ Buyurtma #${body.order_id} bekor qilindi.`);
      if (r.prev_status === "accepted" && r.courier_id) await S.send(r.courier_id, `❌ Buyurtma #${body.order_id} bekor qilindi. Bormang.`);
      await C.send(r.client_id, `❌ Buyurtma #${body.order_id} bekor qilindi.\nSabab: ${esc(reason)}`);
      return { ok: true };
    }
    if (a === "a_staff") return { ...(await rpc("admin_staff_list", {})), bot: await staffBotUsername() };
    if (a === "a_staff_create") {
      const pw = String(body.password || "");
      if (pw.length < 6) return { error: "Parol kamida 6 belgi bo'lsin" };
      const h = await hashPassword(pw);
      return rpc("admin_staff_create", { actor: uid, login: body.login, full_name: body.full_name,
        phone: normPhone(body.phone), role: body.role, pass_hash: h.hash, pass_salt: h.salt });
    }
    if (a === "a_staff_update") {
      if (!["toggle", "reset", "unbind"].includes(body.op)) return { error: "Noma'lum amal" };
      const p = { actor: uid, id: body.id, op: body.op };
      if (body.op === "reset") {
        const pw = String(body.password || "");
        if (pw.length < 6) return { error: "Parol kamida 6 belgi bo'lsin" };
        const h = await hashPassword(pw);
        p.pass_hash = h.hash;
        p.pass_salt = h.salt;
      }
      const r = await rpc("admin_staff_update", p);
      ownerCache = null;
      if (r.ok && r.tg_id && body.op !== "reset") {
        await tgS("setChatMenuButton", { chat_id: r.tg_id, menu_button: { type: "commands" } });
        await S.send(r.tg_id, body.op === "unbind" ? "ℹ️ Sizni tizimdan chiqarishdi. Qayta kirish uchun /start." :
          "ℹ️ Hisobingiz holati o'zgartirildi.", { reply_markup: { remove_keyboard: true } });
      }
      return r;
    }
    if (a === "a_backup") {
      await sendBackup([uid], null);
      return { ok: true };
    }
    return { error: "Noma'lum amal" };
  }

  async function setup(origin) {
    apiUrl = origin;
    await rpc("set_api_url", { url: origin });
    const allowed = ["message", "edited_message", "callback_query"];
    const c = await tgC("setWebhook", { url: `${origin}/tg`, secret_token: env.WEBHOOK_SECRET, allowed_updates: allowed });
    await tgC("setMyCommands", { commands: [{ command: "start", description: "Bosh menyu" }] });
    await tgC("setChatMenuButton", { menu_button: { type: "web_app", text: "Buyurtma", web_app: { url: appLink("") } } });
    let s = true;
    if (deps.tgStaff) {
      s = await tgS("setWebhook", { url: `${origin}/tg-staff`, secret_token: env.WEBHOOK_SECRET, allowed_updates: allowed });
      await tgS("setMyCommands", { commands: [{ command: "start", description: "Kirish / bosh menyu" },
                                              { command: "chiqish", description: "Tizimdan chiqish" }] });
    }
    return Boolean(c && s);
  }

  async function loadApiUrl() {
    if (!apiUrl) apiUrl = (await rpc("get_api_url", {}))?.url || null;
  }

  return { onClientUpdate, onStaffUpdate, onUpdate: onClientUpdate, api, tick, dispatch, setup, loadApiUrl };
}

// ============================ Mini app imzosini tekshirish ============================
async function hmac(key, data) {
  const k = await crypto.subtle.importKey("raw", key, { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  return new Uint8Array(await crypto.subtle.sign("HMAC", k, data));
}

export async function verifyInitData(initData, botToken, maxAgeSec = 86400) {
  if (!initData || typeof initData !== "string" || !botToken) return null;
  const params = new URLSearchParams(initData);
  const hash = params.get("hash");
  if (!hash) return null;
  params.delete("hash");
  const dataCheck = [...params.entries()].sort(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0)).map(([k, v]) => `${k}=${v}`).join("\n");
  const secret = await hmac(enc.encode("WebAppData"), enc.encode(botToken));
  const sig = hex(await hmac(secret, enc.encode(dataCheck)));
  if (!safeEqual(sig, hash)) return null;
  const authDate = Number(params.get("auth_date") || 0);
  if (!authDate || Date.now() / 1000 - authDate > maxAgeSec) return null;
  try {
    return JSON.parse(params.get("user"));
  } catch {
    return null;
  }
}

// ============================ Platformaga ulash ============================
function makeTg(token) {
  const base = `https://api.telegram.org/bot${token}`;
  return async function tg(method, payload) {
    for (let attempt = 0; attempt < 2; attempt++) {
      try {
        const res = await fetch(`${base}/${method}`, { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(payload) });
        const data = await res.json();
        if (data.ok) return data.result;
        if (res.status === 429 && attempt === 0) {
          await new Promise((r) => setTimeout(r, Math.min(5, data.parameters?.retry_after || 1) * 1000));
          continue;
        }
        if (!String(data.description || "").includes("message is not modified")) console.warn("tg", method, data.description);
        return null;
      } catch (e) {
        console.warn("tg", method, e);
        return null;
      }
    }
    return null;
  };
}

function makeDeps(env, ctx) {
  const staffToken = env.STAFF_BOT_TOKEN || env.BOT_TOKEN;
  async function rpc(name, p) {
    const res = await fetch(`${env.SUPABASE_URL.replace(/\/$/, "")}/rest/v1/rpc/${name}`, {
      method: "POST",
      // Yangi "sb_secret_..." kalitlari faqat apikey sarlavhasida yuboriladi; eski JWT kalitlar ikkalasida
      headers: String(env.SUPABASE_SERVICE_KEY).startsWith("sb_")
        ? { apikey: env.SUPABASE_SERVICE_KEY, "Content-Type": "application/json" }
        : { apikey: env.SUPABASE_SERVICE_KEY, Authorization: `Bearer ${env.SUPABASE_SERVICE_KEY}`, "Content-Type": "application/json" },
      body: JSON.stringify({ p }),
    });
    const text = await res.text();
    if (!res.ok) throw new Error(`rpc ${name}: ${res.status} ${text}`);
    return text ? JSON.parse(text) : null;
  }
  async function sendDocument(chatId, filename, content, caption) {
    const form = new FormData();
    form.append("chat_id", String(chatId));
    form.append("caption", caption);
    form.append("document", new Blob([content], { type: "application/json" }), filename);
    const res = await fetch(`https://api.telegram.org/bot${staffToken}/sendDocument`, { method: "POST", body: form });
    if (!res.ok) console.warn("sendDocument", await res.text());
  }
  async function uploadImage(name, bytes, type) {
    const base = env.SUPABASE_URL.replace(/\/$/, "");
    const key = String(env.SUPABASE_SERVICE_KEY);
    const res = await fetch(`${base}/storage/v1/object/products/${name}`, {
      method: "POST",
      headers: { apikey: key, ...(key.startsWith("sb_") ? {} : { Authorization: `Bearer ${key}` }),
                 "Content-Type": type, "x-upsert": "true", "Cache-Control": "max-age=31536000" },
      body: bytes,
    });
    if (!res.ok) { console.warn("upload", res.status, await res.text()); return null; }
    return `${base}/storage/v1/object/public/products/${name}`;
  }
  async function signUpload(bucket, name) {
    const base = env.SUPABASE_URL.replace(/\/$/, "");
    const key = String(env.SUPABASE_SERVICE_KEY);
    const res = await fetch(`${base}/storage/v1/object/upload/sign/${bucket}/${name}`, {
      method: "POST",
      headers: { apikey: key, ...(key.startsWith("sb_") ? {} : { Authorization: `Bearer ${key}` }), "Content-Type": "application/json" },
      body: "{}",
    });
    if (!res.ok) { console.warn("signUpload", res.status, await res.text()); return null; }
    const j = await res.json();
    const rel = j.url || j.signedURL;
    if (!rel) return null;
    return { uploadUrl: `${base}/storage/v1${rel.startsWith("/") ? rel : "/" + rel}`, publicUrl: `${base}/storage/v1/object/public/${bucket}/${name}` };
  }
  return {
    env, rpc, sendDocument, uploadImage, signUpload,
    tg: makeTg(env.BOT_TOKEN),
    tgStaff: env.STAFF_BOT_TOKEN ? makeTg(env.STAFF_BOT_TOKEN) : null,
    background: (p) => (ctx?.waitUntil ? ctx.waitUntil(p) : p),
  };
}

const CORS = { "Access-Control-Allow-Origin": "*", "Access-Control-Allow-Headers": "content-type", "Access-Control-Allow-Methods": "POST, OPTIONS" };
const jsonRes = (obj, status) => new Response(JSON.stringify(obj), { status, headers: { "Content-Type": "application/json", ...CORS } });

export default {
  async fetch(request, env, ctx) {
    const url = new URL(request.url);
    const app = createApp({ ...makeDeps(env, ctx), apiUrl: url.origin });

    if ((url.pathname === "/tg" || url.pathname === "/tg-staff") && request.method === "POST") {
      if (request.headers.get("X-Telegram-Bot-Api-Secret-Token") !== env.WEBHOOK_SECRET) return new Response("forbidden", { status: 403 });
      try {
        const update = await request.json();
        if (url.pathname === "/tg") await app.onClientUpdate(update);
        else await app.onStaffUpdate(update);
      } catch (e) {
        console.error("update", e);
      }
      return new Response("ok");
    }

    if (url.pathname === "/api") {
      if (request.method === "OPTIONS") return new Response(null, { headers: CORS });
      if (request.method !== "POST") return jsonRes({ error: "POST" }, 405);
      let body;
      try {
        body = await request.json();
      } catch {
        return jsonRes({ error: "JSON xato" }, 400);
      }
      let via = "client";
      let user = await verifyInitData(body.initData, env.BOT_TOKEN);
      if (!user && env.STAFF_BOT_TOKEN) {
        user = await verifyInitData(body.initData, env.STAFF_BOT_TOKEN);
        via = "staff";
      }
      if (!user) return jsonRes({ error: "Sahifani bot ichidagi tugma orqali qayta oching." }, 401);
      try {
        return jsonRes(await app.api(body, user, via), 200);
      } catch (e) {
        console.error("api", e);
        return jsonRes({ error: "Server xatosi, qaytadan urinib ko'ring." }, 500);
      }
    }

    if (url.pathname === "/setup") {
      if (!env.WEBHOOK_SECRET || url.searchParams.get("secret") !== env.WEBHOOK_SECRET) return new Response("forbidden", { status: 403 });
      const missing = ["BOT_TOKEN", "ADMIN_IDS", "SUPABASE_URL", "SUPABASE_SERVICE_KEY", "WEBHOOK_SECRET"].filter((k) => !env[k]);
      if (missing.length) return new Response("Sozlanmagan: " + missing.join(", "), { status: 500 });
      const ok = await app.setup(url.origin);
      return new Response(ok ? `✅ Botlar ulandi${env.STAFF_BOT_TOKEN ? " (mijoz + xodimlar)" : " (faqat mijoz boti — STAFF_BOT_TOKEN yo'q)"}.` :
        "❌ Webhook o'rnatilmadi — tokenlarni tekshiring.", { headers: { "Content-Type": "text/plain; charset=utf-8" } });
    }

    return new Response("ZamZam bot ishlayapti 💧", { headers: { "Content-Type": "text/plain; charset=utf-8" } });
  },

  async scheduled(event, env, ctx) {
    const app = createApp(makeDeps(env, ctx));
    await app.loadApiUrl();
    await app.tick();
  },
};

# 💧 ZamZam — suv yetkazib berish boti

Telegram bot va mini app. Mijoz suv buyurtma qiladi, buyurtma **faqat radius ichidagi (standart 2 km) eng yaqin bo'sh dostavchiga** boradi. **Oylik to'lov yo'q**: hammasi bepul xizmatlarda ishlaydi.

| Qism | Qayerda | Narx |
|---|---|---|
| Mijoz va admin mini app (`index.html`, `admin.html`) | Render — statik sayt | bepul |
| Bot va API (`worker/worker.js` + `server.mjs`) | Render — Web Service (yoki Cloudflare Workers) | bepul |
| Baza (`supabase/schema.sql`) | Supabase | bepul (500 MB) |

## Imkoniyatlar (v6)

Tizim **ikki botdan** iborat: **mijoz boti** (buyurtma berish) va **xodimlar boti** (rahbar va dostavchilar, shaxsiy login + parol). Dizayn: ko'k-oq, Solar ikonkalari.

**Mijoz**
- Birinchi kirishda botda 3 qadam: ism-familiya → telefon (tugma) → lokatsiya (tugma). Hammasi saqlanadi.
- Mini app: **reklama banneri** (video/rasm, ovozsiz, avtomatik aylanadi), **rasmli katalog** (5/10/20 L, pompa, kuler…), savatcha.
- Buyurtma: saqlangan manzil avtomatik, vaqt, naqd to'lov. Buyurtmalarim: holat bosqichlari, dostavchi ismi/telefoni, bekor qilish, takrorlash, "hammasi to'g'rimi?" tasdig'i.
- **Yandex Go uslubidagi kuzatish:** dostavchi jonli joylashuvni yoqqan bo'lsa, mijoz xaritada mashinani, masofa va taxminiy vaqtni ko'radi.
- Sozlamalar: ism-familiya, manzil, idishlarim, qarzim, aloqa.

**Dostavchi (xodimlar boti)**
- «🟢 Ishni boshlash» / «🔴 Ishni tugatish» — smena va ish soati yoziladi. Ish boshlanganda bot Telegram jonli joylashuvini (📎 → Joylashuv → Jonli, 8 soat) yoqishni o'rgatadi; yoqilmasa bir marta eslatadi.
- Buyurtma taklifi → qabul / rad → yetkazish: qaytgan idish, yaroqsiz tara, olingan pul.
- «📊 Mening hisobim»: ish vaqti, yetkazgan, olgan naqd, qo'lida (topshirilmagan) pul. «📋 Kim nima oldi».

**Rahbar paneli — real ish rejimi**
- Menyu: Bugun · Buyurtmalar · Xodimlar · Boshqa (mijozlar, mahsulotlar, bannerlar, hisobot, sozlamalar).
- «Bugun»: bugun sotilgan pul (naqd/qarz), kutayotgan buyurtmalar, hozir ishdagilar va qo'lidagi pul. Ogohlantirish faqat muammo bo'lsa.
- Xodimlar: kim ishda, nechta yetkazdi, necha soat ishladi, qo'lida qancha pul, jonli joylashuvi (Yandex xaritada ochiladi); smenalar, kassa, buyurtmalar tarixi.
- Kassa: «Pul qabul qildim» va to'liq tarix (kim, qachon, qancha olib keldi).
- Reklama bannerlari: video/rasm yuklash (50 MB gacha, Supabase Storage `banners`), tartib, yashirish, o'chirish.
- Buyurtmalar, mijozlar (qarz, idish, optom), mahsulotlar (rasm, narx), hisobot, sozlamalar, zaxira.

## Xavfsizlik va ishonchlilik
- Pulga oid barcha amallar bazadagi funksiyalarda, **bitta tranzaksiyada** bajariladi:
  - bitta buyurtmani ikki dostavchi ololmaydi;
  - tugma ikki marta bosilsa ham ikkita buyurtma yaratilmaydi;
  - yetkazilgan buyurtma ikki marta hisoblanmaydi.
- Narx har doim bazadan olinadi, mini app yuborgan narxga ishonilmaydi.
- Mini app so'rovlari Telegram imzosi (`initData`) bilan tekshiriladi. Rahbar paneli faqat xodimlar botidan va faqat rahbarlarga ochiladi.
- Xodim parollari PBKDF2 (100 000 marta) bilan shifrlanadi. Kiritilgan parol xabari chatdan darhol o'chiriladi. 5 marta xato kiritilsa, 15 daqiqaga blok qo'yiladi.
- Bazaga faqat server kaliti bilan kirish mumkin. Ochiq kalit bilan jadvallarni o'qib bo'lmaydi (RLS yoqilgan).
- Buyurtma va idish yozuvlari o'chirilmaydi. Admin harakatlari `audit_log` jadvaliga yoziladi.
- **Har kuni** (soat 03:00 dan keyin) bazaning to'liq nusxasi adminning Telegram'iga fayl bo'lib keladi.

---

## O'rnatish (taxminan 20 daqiqa)

> ⚠️ Bot tokeni, Supabase kaliti va `WEBHOOK_SECRET` faqat Cloudflare sozlamalariga yoziladi. Ularni GitHub'ga yoki chatga yozmang.

### 1. Supabase (baza)
1. [supabase.com](https://supabase.com) da ro'yxatdan o'ting va **New project** oching. Region: *Central EU (Frankfurt)*.
2. Chap menyuda **SQL Editor** ni oching va ketma-ket ishga tushiring: `supabase/schema.sql`, `supabase/002_v2.sql`, `supabase/003_v3.sql`.
   Rasm uchun: **Storage → New bucket** → nomi `products`, **Public** yoqilgan.
3. **Project Settings → API** bo'limidan quyidagilarni ko'chirib oling:
   - `Project URL`, masalan `https://abcd.supabase.co`;
   - `service_role` kaliti (**maxfiy!**).

### 2-variant (hozir ishlatilmoqda). Render Web Service (bot)
1. Render → **New → Web Service** → shu repo.
2. Region: *Frankfurt*, Build command: `npm install`, Start command: `node server.mjs`, Plan: *Free*.
3. **Environment** bo'limiga: `BOT_TOKEN` (mijoz boti), `STAFF_BOT_TOKEN` (xodimlar boti), `ADMIN_IDS` (parolsiz kiradigan bosh rahbar), `SUPABASE_URL`, `SUPABASE_SERVICE_KEY`, `WEBHOOK_SECRET`, `WEBAPP_URL`, `NODE_VERSION=22`.
4. Ishga tushganda bot Telegram'ga **o'zi ulanadi** (loglarda "✅ Bot ulandi" chiqadi), har 30 soniyada taymer ishlaydi va uxlab qolmaslik uchun o'ziga murojaat qiladi.

> Render'ning bepul tarifi bir akkauntdagi barcha bepul serverlar uchun oyiga 750 soat beradi. Bu bot bir o'zi ~744 soat ishlaydi, shuning uchun shu akkauntdagi boshqa bepul bot serverlarini o'chirib qo'yish tavsiya etiladi.

### 2-variant o'rniga: Cloudflare (bot)
1. [dash.cloudflare.com](https://dash.cloudflare.com) da bepul ro'yxatdan o'ting.
2. **Workers & Pages → Create → Create Worker** ni bosing. Nomi: `zamzam-bot`, keyin **Deploy**.
3. **Edit code** ni bosing, bor kodni o'chiring, `worker/worker.js` matnini joylang va yana **Deploy** qiling.
4. **Settings → Variables and Secrets** bo'limiga quyidagilarni qo'shing:

   | Nomi | Turi | Qiymati |
   |---|---|---|
   | `BOT_TOKEN` | Secret | @BotFather bergan token |
   | `ADMIN_IDS` | Text | adminning Telegram ID'si (botga `/id` yozib bilinadi) |
   | `SUPABASE_URL` | Text | 1-qadamdagi Project URL |
   | `SUPABASE_SERVICE_KEY` | Secret | 1-qadamdagi service_role kaliti |
   | `WEBHOOK_SECRET` | Secret | o'zingiz o'ylab topgan uzun so'z, masalan `ZamZam2026xyzQwe` (faqat harf va raqam) |
   | `WEBAPP_URL` | Text | `https://zamzam-water.onrender.com` |

5. **Settings → Triggers → Cron Triggers → Add** bo'limida har daqiqani tanlang: `* * * * *`.
6. Brauzerda quyidagi manzilni oching (o'z ma'lumotlaringiz bilan):
   `https://zamzam-bot.<sizning-nomingiz>.workers.dev/setup?secret=<WEBHOOK_SECRET>`
   Sahifada **"✅ Bot ulandi"** yozuvi chiqishi kerak.

### 3. Render (mini app)
Statik sayt shu repo'ga ulangan bo'lsa, boshqa ish yo'q: GitHub'ga har yangilanish avtomatik chiqadi. Agar sozlash kerak bo'lsa, **Publish directory** ga `.` qo'ying, **Build command** bo'sh qolsin.

### 4. Tekshirish
1. Botga `/start` yozing. Admin sifatida **🛠 Admin panel** tugmasi chiqadi.
2. Panelda **Mahsulot** bo'limiga kirib narxlarni kiriting, so'ng "Narxlar yakuniy" ni yoqing.
3. **Dostavchi → Qo'shish** orqali havola yarating va dostavchiga yuboring.
4. Boshqa telefondan mijoz sifatida buyurtma berib sinab ko'ring.

---

## Zaxira nusxadan tiklash
Har kuni Telegram'ga `zamzam_YYYY-MM-DD.json` fayli keladi. Uni tiklash uchun:
1. Yangi Supabase loyihasi oching va unda `schema.sql` ni ishga tushiring.
2. SQL Editor'da quyidagini bajaring (fayl ichidagi matnni qo'shtirnoqlar orasiga qo'ying):
   ```sql
   SELECT import_all('<json fayl matni>'::jsonb);
   ```
   Tiklash faqat **bo'sh** bazaga ishlaydi, mavjud ma'lumotni hech qachon ustidan yozmaydi.
3. Cloudflare'dagi `SUPABASE_URL` va `SUPABASE_SERVICE_KEY` ni yangi loyihanikiga almashtiring.

## Bepul tariflar haqida
- **Cloudflare Workers:** kuniga 100 000 so'rov. 20–25 dostavchining jonli joylashuvi bilan ham bemalol yetadi.
- **Supabase:** 500 MB baza, API so'rovlari cheklanmagan. 1 hafta faolsiz qolgan loyiha uxlatiladi, lekin bot har daqiqa murojaat qilgani uchun bunday bo'lmaydi.
- Bepul tariflar shartlari kelajakda o'zgarishi mumkin. Shuning uchun kunlik zaxira nusxa muhim.

## Dasturchilar uchun: sinovlar
`tests/worker.test.mjs` botni **haqiqiy PostgreSQL** bazasida boshidan oxirigacha sinaydi (12 ta sinov):
- buyurtma, eng yaqin dostavchi, qabul qilish, yetkazish, idishlar hisobi;
- rad etish, vaqt tugashi, admin tayinlashi;
- 5 ta parallel "Qabul qilaman" bosilganda faqat bittasi o'tishi;
- bekor qilish, buzilgan savatcha, imzo tekshiruvi;
- zaxira nusxa va uni tiklash;
- mijoz ro'yxati, katalog (yangi mahsulot, rasm tekshiruvi, idishsiz mahsulotni yetkazish).

```bash
TEST_PG_HOST=/path/to/pg/socket npm test
```

## Halollik va nazorat
- **Mijoz tasdig'i:** «Yetkazildi» dan keyin mijozga dostavchi kiritgan hamma narsa (suv, qaytgan idish, to'langan pul, qarz) boradi. Mijoz «⚠️ Noto'g'ri» desa — rahbarga darhol xabar va panelda qizil ogohlantirish.
- **Kassa:** yetkazishda olingan naqd avtomatik dostavchi hisobiga yoziladi. Rahbar paneldan «Pul topshirdi» ni bosadi. Dostavchi qo'lidagi pulni botdagi «Bugungi hisobot» da ko'radi.
- **Kim oldi:** buyurtma olinganda ishdagi boshqa dostavchilarga ovozsiz xabar; botda «📋 Kim nima oldi» ro'yxati.

## Taqsimlash
Jonli joylashuv (oxirgi 15 daqiqa) bo'lsa — shu nuqta. Bo'lmasa dostavchining joyi ishidan aniqlanadi: smena boshida — zavod (rahbar Sozlamalarda belgilaydi), keyin — qabul qilgan buyurtmasi manzili yoki oxirgi yetkazgan uyi. Buyurtma shu nuqtaga eng yaqin bo'sh dostavchiga beriladi.

## Xarita
Mini app'da [OpenFreeMap](https://openfreemap.org) (OpenStreetMap ma'lumotlari, MapLibre) ishlatiladi — bepul, kalit kerak emas, tijoriy foydalanishga ruxsat bor. Pin ostidagi ko'cha/uy raqami OpenStreetMap Nominatim orqali aniqlanadi.
Bazaga ketma-ket `004_v3_1.sql`, `005_no_gps.sql`, `006_honesty.sql`, `007_rating_v2.sql`, `008_back_to_v2.sql`, `009_v5.sql`, `010_live.sql` ham qo'llanadi. Storage: `products` va `banners` (public) bucketlari.

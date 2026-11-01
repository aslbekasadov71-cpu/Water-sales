// Render (yoki istalgan Node.js server) uchun: worker/worker.js ni oddiy HTTP serverda ishga tushiradi.
// Cloudflare kerak emas. Render "Web Service": Build command: npm install, Start command: node server.mjs
import http from "node:http";
import worker from "./worker/worker.js";

const env = process.env;
const PORT = Number(env.PORT || 10000);
const PUBLIC_URL = (env.RENDER_EXTERNAL_URL || env.PUBLIC_URL || "").replace(/\/$/, "");
const TICK_MS = 30_000;

const ctx = {
  waitUntil(p) {
    Promise.resolve(p).catch((e) => console.error("background", e));
  },
};

const server = http.createServer(async (req, res) => {
  try {
    const url = new URL(req.url, PUBLIC_URL || `https://${req.headers.host}`);
    if (url.pathname === "/health") {
      res.writeHead(200, { "Content-Type": "text/plain" });
      return res.end("ok");
    }
    const chunks = [];
    let size = 0;
    for await (const c of req) {
      size += c.length;
      if (size > 4_000_000) { res.writeHead(413); return res.end("too large"); }
      chunks.push(c);
    }
    const headers = {};
    for (const k of ["content-type", "x-telegram-bot-api-secret-token"]) if (req.headers[k]) headers[k] = req.headers[k];
    const hasBody = !["GET", "HEAD"].includes(req.method) && chunks.length;
    const request = new Request(url, { method: req.method, headers, body: hasBody ? Buffer.concat(chunks) : undefined });
    const r = await worker.fetch(request, env, ctx);
    res.writeHead(r.status, Object.fromEntries(r.headers));
    res.end(Buffer.from(await r.arrayBuffer()));
  } catch (e) {
    console.error("request", e);
    if (!res.headersSent) res.writeHead(500);
    res.end("error");
  }
});

// Har 30 soniyada: vaqti tugagan takliflarni keyingi dostavchiga o'tkazish, kunlik zaxira va h.k.
let ticking = false;
async function tick() {
  if (ticking) return;
  ticking = true;
  try {
    await worker.scheduled({}, env, ctx);
  } catch (e) {
    console.error("tick", e);
  } finally {
    ticking = false;
  }
}

server.listen(PORT, async () => {
  console.log(`ZamZam bot ${PORT}-portda ishga tushdi`);
  const missing = ["BOT_TOKEN", "ADMIN_IDS", "SUPABASE_URL", "SUPABASE_SERVICE_KEY", "WEBHOOK_SECRET"].filter((k) => !env[k]);
  if (missing.length) {
    console.error("Sozlanmagan o'zgaruvchilar:", missing.join(", "));
    return;
  }
  // Telegram webhook'ni avtomatik ulash (qo'lda /setup ochish shart emas)
  if (PUBLIC_URL) {
    const r = await worker.fetch(new Request(`${PUBLIC_URL}/setup?secret=${encodeURIComponent(env.WEBHOOK_SECRET)}`), env, ctx);
    console.log("Webhook:", await r.text());
  }
  setInterval(tick, TICK_MS);
  tick();
  // Bepul Render serveri uxlab qolmasligi uchun o'ziga murojaat (har 10 daqiqada)
  if (PUBLIC_URL) setInterval(() => fetch(`${PUBLIC_URL}/health`).catch(() => {}), 10 * 60 * 1000);
});

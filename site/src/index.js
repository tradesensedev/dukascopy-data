const GH = "https://api.github.com";
const NAME_RE = /^(.+)_(\d{4})_(bid|ask)\.csv(\.gz)?$/;
const TTL = 5 * 60 * 1000;
let memo = { t: 0, body: null };

const hdr = (env) => {
  const h = { "User-Agent": "dukascopy-data-site", Accept: "application/vnd.github+json" };
  if (env.GITHUB_TOKEN) h.Authorization = `Bearer ${env.GITHUB_TOKEN}`;
  return h;
};

// fallback: manifest ekhono nai hole API theke banao
async function indexFromApi(env) {
  const m = {};
  for (let page = 1; page <= 20; page++) {
    const r = await fetch(`${GH}/repos/${env.GH_REPO}/releases?per_page=100&page=${page}`, { headers: hdr(env) });
    if (!r.ok) throw new Error("release list failed: " + r.status);
    const rels = await r.json();
    for (const rel of rels) {
      if (!rel.tag_name.startsWith(env.GH_PREFIX)) continue;
      for (const a of rel.assets || []) {
        const x = NAME_RE.exec(a.name); if (!x) continue;
        const d = (m[x[1]] = m[x[1]] || {}), y = +x[2];
        const e = (d[y] = d[y] || { b: 0, a: 0, u: "" });
        e[x[3] === "bid" ? "b" : "a"] = a.size;
        const u = a.updated_at.slice(0, 10); if (u > e.u) e.u = u;
      }
    }
    if (rels.length < 100) break;
  }
  const out = { v: 1, gen: new Date().toISOString(), m: {} };
  for (const [k, d] of Object.entries(m)) {
    const ys = Object.keys(d).map(Number).sort((a, b) => a - b);
    out.m[k] = { y: ys, b: ys.map((y) => d[y].b), a: ys.map((y) => d[y].a), u: ys.map((y) => d[y].u) };
  }
  return JSON.stringify(out);
}

async function getIndex(env, force) {
  if (!force && memo.body && Date.now() - memo.t < TTL) return memo.body;
  let body = null;
  try {
    const r = await fetch(`https://github.com/${env.GH_REPO}/releases/download/meta/index.json`);
    if (r.ok) body = await r.text();
  } catch {}
  if (!body) body = await indexFromApi(env);
  memo = { t: Date.now(), body };
  return body;
}

async function download(name, env) {
  const m = NAME_RE.exec(name);
  if (!m) return new Response("Bad name", { status: 400 });
  const base = `https://github.com/${env.GH_REPO}/releases/download/${env.GH_PREFIX}${m[1]}/`;
  let nm = name, r = await fetch(base + encodeURIComponent(nm));
  if (!r.ok) {                                   // .gz na thakle .csv, ba ulto
    nm = nm.endsWith(".gz") ? nm.slice(0, -3) : nm + ".gz";
    r = await fetch(base + encodeURIComponent(nm));
  }
  if (!r.ok) return new Response("Not found", { status: 404 });
  const h = new Headers({
    "content-type": "application/octet-stream",
    "content-disposition": `attachment; filename="${nm}"`,
    "x-gz": nm.endsWith(".gz") ? "1" : "0",
    "cache-control": "no-store",
  });
  const len = r.headers.get("content-length");
  if (len) h.set("content-length", len);
  return new Response(r.body, { headers: h });
}

export default {
  async fetch(req, env) {
    const url = new URL(req.url);
    try {
      if (url.pathname === "/api/index") {
        return new Response(await getIndex(env, url.searchParams.has("fresh")), {
          headers: { "content-type": "application/json", "cache-control": "public, max-age=300" },
        });
      }
      if (url.pathname.startsWith("/dl/")) return await download(decodeURIComponent(url.pathname.slice(4)), env);
    } catch (e) {
      return new Response("Error: " + e.message, { status: 502 });
    }
    return new Response("Not found", { status: 404 });
  },
};

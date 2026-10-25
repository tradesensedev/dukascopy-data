const GH = "https://api.github.com";
let memo = { t: 0, files: null };
const TTL = 5 * 60 * 1000;
const NAME_RE = /^([A-Z0-9]+)_(\d{4})_(bid|ask)\.csv(\.gz)?$/;

const hdr = (env, accept) => ({
  Authorization: `Bearer ${env.GITHUB_TOKEN}`,
  "User-Agent": "dukascopy-data-site",
  "X-GitHub-Api-Version": "2022-11-28",
  Accept: accept,
});

async function listAssets(env, force = false) {
  if (!force && memo.files && Date.now() - memo.t < TTL) return memo.files;
  const out = [];
  for (let page = 1; page <= 5; page++) {
    const r = await fetch(`${GH}/repos/${env.GH_REPO}/releases?per_page=100&page=${page}`, {
      headers: hdr(env, "application/vnd.github+json"),
    });
    if (!r.ok) throw new Error("release list failed: " + r.status);
    const rels = await r.json();
    for (const rel of rels) {
      if (!rel.tag_name.startsWith(env.GH_PREFIX)) continue;
      for (const a of rel.assets || []) {
        const m = NAME_RE.exec(a.name);
        if (m) out.push({ name: a.name, id: a.id, market: m[1], year: +m[2], side: m[3], size: a.size, updated: a.updated_at });
      }
    }
    if (rels.length < 100) break;
  }
  memo = { t: Date.now(), files: out };
  return out;
}

async function viaApi(env, name) {
  let files = await listAssets(env);
  let f = files.find((x) => x.name === name);
  if (!f) files = await listAssets(env, true), (f = files.find((x) => x.name === name));
  if (!f) return null;
  let r = await fetch(`${GH}/repos/${env.GH_REPO}/releases/assets/${f.id}`, {
    headers: hdr(env, "application/octet-stream"), redirect: "manual",
  });
  if (r.status >= 300 && r.status < 400) r = await fetch(r.headers.get("location"));
  return r;
}

async function download(name, env) {
  const m = NAME_RE.exec(name);
  if (!m) return new Response("Bad name", { status: 400 });
  // public repo: API chhara shorashori stream (fast)
  let r = await fetch(`https://github.com/${env.GH_REPO}/releases/download/${env.GH_PREFIX}${m[1]}/${name}`);
  if (!r.ok) r = await viaApi(env, name);
  if (!r) return new Response("Not found", { status: 404 });
  if (!r.ok) return new Response("Upstream error " + r.status, { status: 502 });
  const h = new Headers({
    "content-type": "application/octet-stream",
    "content-disposition": `attachment; filename="${name}"`,
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
      if (url.pathname === "/api/files") {
        const files = await listAssets(env, url.searchParams.has("fresh"));
        return Response.json(files, { headers: { "cache-control": "no-store" } });
      }
      if (url.pathname.startsWith("/dl/")) return await download(decodeURIComponent(url.pathname.slice(4)), env);
    } catch (e) {
      return new Response("Error: " + e.message, { status: 502 });
    }
    return new Response("Not found", { status: 404 });
  },
};

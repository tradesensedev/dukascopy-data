const GH = "https://api.github.com";

function ghHeaders(env, accept) {
  return {
    Authorization: `Bearer ${env.GITHUB_TOKEN}`,
    "User-Agent": "dukascopy-data-site",
    "X-GitHub-Api-Version": "2022-11-28",
    Accept: accept,
  };
}

const CACHE_KEY = new Request("https://cache.internal/assets-v1");

async function listAssets(env, ctx, force = false) {
  const cache = caches.default;
  if (!force) {
    const hit = await cache.match(CACHE_KEY);
    if (hit) return hit.json();
  }
  const rel = await fetch(`${GH}/repos/${env.GH_REPO}/releases/tags/${env.GH_TAG}`, {
    headers: ghHeaders(env, "application/vnd.github+json"),
  });
  if (!rel.ok) throw new Error("release lookup failed: " + rel.status);
  const { id } = await rel.json();

  const out = [];
  for (let page = 1; page < 20; page++) {
    const r = await fetch(`${GH}/repos/${env.GH_REPO}/releases/${id}/assets?per_page=100&page=${page}`, {
      headers: ghHeaders(env, "application/vnd.github+json"),
    });
    if (!r.ok) throw new Error("asset list failed: " + r.status);
    const items = await r.json();
    for (const a of items) {
      const m = /^([A-Z0-9]+)_(\d{4})_(bid|ask)\.csv$/.exec(a.name);
      if (m) out.push({ name: a.name, id: a.id, market: m[1], year: +m[2], side: m[3], size: a.size, updated: a.updated_at });
    }
    if (items.length < 100) break;
  }
  const res = new Response(JSON.stringify(out), {
    headers: { "content-type": "application/json", "cache-control": "max-age=600" },
  });
  ctx.waitUntil(cache.put(CACHE_KEY, res.clone()));
  return out;
}

async function fetchAsset(env, id) {
  let r = await fetch(`${GH}/repos/${env.GH_REPO}/releases/assets/${id}`, {
    headers: ghHeaders(env, "application/octet-stream"),
    redirect: "manual",
  });
  if (r.status >= 300 && r.status < 400) r = await fetch(r.headers.get("location"));
  return r;
}

async function download(name, env, ctx) {
  let files = await listAssets(env, ctx);
  let f = files.find((x) => x.name === name);
  if (!f) return new Response("Not found", { status: 404 });

  let r = await fetchAsset(env, f.id);
  if (r.status === 404) {
    // asset was replaced by the weekly update -> refresh list and retry
    files = await listAssets(env, ctx, true);
    f = files.find((x) => x.name === name);
    if (!f) return new Response("Not found", { status: 404 });
    r = await fetchAsset(env, f.id);
  }
  if (!r.ok) return new Response("Upstream error " + r.status, { status: 502 });

  return new Response(r.body, {
    headers: {
      "content-type": "text/csv",
      "content-disposition": `attachment; filename="${f.name}"`,
      "cache-control": "no-store",
    },
  });
}

export default {
  async fetch(req, env, ctx) {
    const url = new URL(req.url);
    try {
      if (url.pathname === "/api/files") {
        const files = await listAssets(env, ctx, url.searchParams.has("fresh"));
        return Response.json(files, { headers: { "cache-control": "no-store" } });
      }
      if (url.pathname.startsWith("/dl/")) {
        return await download(decodeURIComponent(url.pathname.slice(4)), env, ctx);
      }
    } catch (e) {
      return new Response("Error: " + e.message, { status: 502 });
    }
    return new Response("Not found", { status: 404 });
  },
};

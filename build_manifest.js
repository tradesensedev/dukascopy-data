// usage: node build_manifest.js raw.jsonl index.json
const fs = require("fs");
const [, , inp, outp] = process.argv;
const RE = /^(.+)_(\d{4})_(bid|ask)\.csv(\.gz)?$/;
const mk = {}, done = new Set();
for (const line of fs.readFileSync(inp, "utf8").split("\n")) {
  if (!line.trim()) continue;
  const rel = JSON.parse(line);
  const market = rel.t.replace(/^m1-/, "");
  for (const a of rel.a) {
    if (a.n === "_complete.txt") { done.add(market); continue; }
    const x = RE.exec(a.n); if (!x) continue;
    const k = x[3] === "bid" ? "b" : "a", y = +x[2], gz = !!x[4];
    const d = (mk[x[1]] = mk[x[1]] || {});
    const e = (d[y] = d[y] || { b: 0, a: 0, u: "" });
    if (gz || !e[k]) e[k] = a.s;
    const u = a.u.slice(0, 10); if (u > e.u) e.u = u;
  }
}
const out = { v: 2, gen: new Date().toISOString(), m: {}, done: [...done].sort() };
for (const [m, d] of Object.entries(mk)) {
  const ys = Object.keys(d).map(Number).sort((a, b) => a - b);
  out.m[m] = { y: ys, b: ys.map((y) => d[y].b), a: ys.map((y) => d[y].a), u: ys.map((y) => d[y].u) };
}
fs.writeFileSync(outp, JSON.stringify(out));
console.log("markets:", Object.keys(out.m).length, "| complete:", out.done.length);

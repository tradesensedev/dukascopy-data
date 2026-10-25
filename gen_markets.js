// usage: node gen_markets.js [--stocks]
const fs = require("fs");
const SRC = "https://raw.githubusercontent.com/Leo4815162342/dukascopy-node/master/README.md";
const withStocks = process.argv.includes("--stocks");

const ALIAS = { usatechidxusd: "US100", usa500idxusd: "US500", deuidxeur: "GER40", gbridxgbp: "UK100",
  jpnidxjpy: "JP225", hkgidxhkd: "HK50", ausidxaud: "AUS200", dollaridxusd: "DXY",
  lightcmdusd: "USOIL", coppercmdusd: "XCUUSD" };
const MAP = {
  "Forex major currencies": ["Forex Majors", ""], "Forex currencies": ["Forex Crosses", ""],
  "Forex metals": ["Metals", "Spot"], "Metals commodities": ["Metals", "Futures"],
  "Energy commodities": ["Energy", ""], "Agricultural commodities": ["Agriculture", ""],
  "Bonds": ["Bonds", ""], "Crypto assets": ["Crypto", ""], "Crypto Curr": ["Crypto", ""],
  "ETFs": ["ETFs", "Global"], "Germany ETFs": ["ETFs", "Germany"], "France ETFs": ["ETFs", "France"],
  "Hong Kong ETFs": ["ETFs", "Hong Kong"], "United States ETFs": ["ETFs", "United States"],
  "Africa": ["Indices", "Africa"], "America": ["Indices", "America"], "Asia": ["Indices", "Asia"], "Europe": ["Indices", "Europe"],
  "Mutual Funds": ["Funds", ""], "Ungrouped": ["Other", ""],
};
const ORDER = ["Forex Majors", "Metals", "Indices", "Energy", "Crypto", "Agriculture", "Bonds",
  "Forex Crosses", "ETFs", "Funds", "Other", "Stocks"];

const clean = (s) => s
  .replace(/<[^>]*>/g, "")                      // html tag
  .replace(/\[([^\]]*)\]\([^)]*\)/g, "$1")      // [text](link)
  .replace(/^[#>*\-+\s]+/, "")                  // heading/list marker
  .replace(/[^\x20-\x7E]/g, "")                 // emoji
  .replace(/\(\d+\)/, "").replace(/\s+/g, " ").trim();

(async () => {
  const lines = (await (await fetch(SRC)).text()).split(/\r?\n/);

  // pass 1: TOC theke group-er naam (- [Bonds (3)](#anchor))
  const names = new Set();
  for (const line of lines) {
    const t = /^\s*[-*+]\s*\[(.+?)\]\(#[^)]*\)\s*$/.exec(line);
    if (t) { const n = clean(t[1]); if (n && n.length < 40) names.add(n); }
  }
  console.log("TOC group found:", names.size);
  if (names.size < 10) {
    console.log("TOC parse hoyni. README-r instrument-er age-r kichu line:");
    const i = lines.findIndex((l) => /Instruments/.test(l));
    console.log(lines.slice(Math.max(0, i), i + 12).join("\n"));
    process.exit(1);
  }

  // pass 2: group heading (jekhane naam mile) + instrument row
  let head = null; const rows = [], seen = new Set(), heads = {};
  for (const line of lines) {
    if (/^\s*\|/.test(line)) {
      const m = /^\|\s*\[([^\]]+)\]\([^)]*\)\s*\|\s*`([^`]+)`\s*\|\s*([^|]*?)\s*\|/.exec(line);
      if (!m || !head) continue;
      const id = m[2], sym = ALIAS[id] || id.toUpperCase();
      if (seen.has(sym)) continue; seen.add(sym);
      const t = Date.parse(m[3] + " UTC"), y = isNaN(t) ? 0 : new Date(t).getUTCFullYear();
      const start = !y || y <= 2000 ? 2003 : Math.max(y, 1990);
      const [cat, sub] = MAP[head] || ["Stocks", head];
      heads[head] = (heads[head] || 0) + 1;
      rows.push({ sym, id, name: m[1], cat, sub, start, on: withStocks || cat !== "Stocks" });
      continue;
    }
    if (/^\s*[-*+]\s*\[/.test(line)) continue;       // TOC line
    const c = clean(line);
    if (names.has(c)) head = c;
  }

  rows.sort((a, b) => ORDER.indexOf(a.cat) - ORDER.indexOf(b.cat));
  const out = {}, stat = {};
  for (const r of rows) {
    out[r.sym] = { id: r.id, name: r.name, cat: r.cat, sub: r.sub, start: r.start, on: r.on };
    stat[r.cat] = stat[r.cat] || { total: 0, on: 0 }; stat[r.cat].total++; if (r.on) stat[r.cat].on++;
  }
  fs.writeFileSync("markets.json", JSON.stringify(out, null, 1));
  console.table(stat);
  console.log("total:", rows.length, "| enabled:", rows.filter((r) => r.on).length);
  console.log("\nStocks-e gelo (shudhu desh-er naam hote hobe):");
  console.log(Object.entries(heads).filter(([h]) => !MAP[h]).map(([h, n]) => `${h} (${n})`).join(", "));
})();

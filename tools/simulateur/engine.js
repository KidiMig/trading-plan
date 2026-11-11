// Moteur de simulation : rejoue chaque zone du plan sur les bougies H1 XM.
// Résultats en R (multiples du risque), puis en argent selon le capital et le risque choisis.
(function (root) {
  function pad(n) { return (n < 10 ? "0" : "") + n; }
  function iso(ms) { var d = new Date(ms); return d.getUTCFullYear() + "-" + pad(d.getUTCMonth() + 1) + "-" + pad(d.getUTCDate()) + " " + pad(d.getUTCHours()) + ":" + pad(d.getUTCMinutes()); }
  function ms(t) { return Date.parse(t.replace(" ", "T") + ":00Z"); }
  var H = 3600e3;
  // Heure du serveur XM : UTC+3 jusqu'au 25 oct. 2026, UTC+2 ensuite
  function serverDate(t) { var m = ms(t); var off = m < Date.parse("2026-10-25T01:00:00Z") ? 3 : 2; return iso(m + off * H).slice(0, 10); }

  function simulate(DATA, o) {
    o = o || {};
    var opt = {
      entry: o.entry || "edge",          // "edge" bord de zone, "mid" milieu
      dayFilter: o.dayFilter !== false,  // vente sous l'ouverture du jour, achat au-dessus
      newsBlock: o.newsBlock !== false,  // pas d'entrée 30 min avant/après une annonce du plan
      skipNewsDay: !!o.skipNewsDay,      // aucune entrée un jour d'annonce forte
      closeBeforeNews: !!o.closeBeforeNews, // fermer les positions avant une annonce forte
      tp1BE: o.tp1BE !== false,          // stop au prix d'entrée au TP1
      trail: o.trail !== false,          // stop suiveur H1 dès 0,5 R
      endHour: o.endHour || 16,          // dernière heure d'entrée (Cayenne)
      maxPos: o.maxPos || 4,
      maxLoss: o.maxLoss || 2,           // pertes maximum par jour
      friday: o.friday !== false,        // fermeture du vendredi 16h
      onlyTop: o.onlyTop || 0,           // 0 = toutes les zones, N = N premières
      markets: o.markets || null
    };
    var trades = [];
    var dates = Object.keys(DATA.plans).sort();
    var openPos = [];                    // positions ouvertes (pour le maximum)
    dates.forEach(function (d) {
      var plan = DATA.plans[d];
      var newsMs = (plan.news || []).map(function (n) { return ms(n) + 3 * H; }); // Cayenne -> UTC
      if (opt.skipNewsDay && newsMs.length) return;
      var start = ms(d + " 12:00"), stop = ms(d + " 00:00") + (opt.endHour + 3) * H;
      var zones = plan.zones.filter(function (z) { return !opt.markets || opt.markets.indexOf(z.sym) >= 0; });
      zones = zones.slice(0, opt.onlyTop || zones.length);
      var lossesToday = 0;
      // candidats : première bougie où l'ordre serait rempli
      var cand = [];
      zones.forEach(function (z, rank) {
        if (opt.markets && opt.markets.indexOf(z.sym) < 0) return;
        var bars = DATA.h1[z.sym]; if (!bars) return;
        var sell = z.dir === "SELL";
        var entry = opt.entry === "mid" ? (z.zlo + z.zhi) / 2 : (sell ? z.zlo : z.zhi);
        var risk = Math.abs(z.sl - entry); if (!(risk > 0)) return;
        for (var i = 0; i < bars.length; i++) {
          var b = bars[i], t = ms(b[0]);
          if (t < start) continue;
          if (t >= stop) break;
          var hit = sell ? b[2] >= entry : b[3] <= entry;
          if (!hit) continue;
          // la zone est annulée si l'objectif 1 est déjà atteint avant l'entrée
          var reason = null;
          if (opt.newsBlock && newsMs.some(function (n) { return t + H > n - 30 * 60e3 && t < n + 30 * 60e3; })) reason = "annonce";
          if (!reason && opt.dayFilter) {
            var op = (DATA.d1open[z.sym] || {})[serverDate(b[0])];
            if (op && (sell ? entry >= op : entry <= op)) reason = "filtre du jour";
          }
          if (reason) continue;      // on attend la bougie suivante dans la fenêtre
          cand.push({ z: z, rank: rank, i: i, t: t, entry: entry, risk: risk, sell: sell });
          break;
        }
      });
      cand.sort(function (a, b) { return a.t - b.t || a.rank - b.rank; });
      cand.forEach(function (c) {
        openPos = openPos.filter(function (p) { return p.exit > c.t; });
        if (openPos.length >= opt.maxPos) return;
        if (openPos.some(function (p) { return p.sym === c.z.sym; })) return;
        if (lossesToday >= opt.maxLoss) return;
        var r = run(DATA, c, opt, newsMs);
        if (!r) return;
        var spreadR = (DATA.spread[c.z.sym] || 0) / c.risk;
        var R = r.R - spreadR;
        var tr = { date: d, sym: c.z.sym, dir: c.z.dir, rank: c.rank + 1, entry: c.entry, sl: c.z.sl, tp: c.z.tp, open: iso(c.t), close: iso(r.exitT), exitPx: r.px, how: r.how, R: Math.round(R * 100) / 100 };
        trades.push(tr);
        openPos.push({ sym: c.z.sym, exit: r.exitT });
        if (R < 0) lossesToday++;
      });
    });
    trades.sort(function (a, b) { return a.close < b.close ? -1 : a.close > b.close ? 1 : 0; });
    return trades;
  }

  function run(DATA, c, opt, newsMs) {
    var bars = DATA.h1[c.z.sym], sell = c.sell, e = c.entry, sl = c.z.sl, tp = c.z.tp, tp1 = c.z.tp1;
    var dir = sell ? -1 : 1, risk = c.risk, be = false, trailOn = false;
    for (var i = c.i; i < bars.length; i++) {
      var b = bars[i], t = ms(b[0]), hi = b[2], lo = b[3];
      var dow = new Date(t).getUTCDay(), hr = new Date(t).getUTCHours();
      if (opt.friday && dow === 5 && hr >= 19) return { R: dir * (b[1] - e) / risk, px: b[1], exitT: t, how: "vendredi 16h" };
      if (opt.closeBeforeNews && i > c.i && newsMs.some(function (n) { return n > t && n - t <= H; }))
        return { R: dir * (b[1] - e) / risk, px: b[1], exitT: t, how: "avant annonce" };
      var hitSL = sell ? hi >= sl : lo <= sl;
      if (hitSL) return { R: dir * (sl - e) / risk, px: sl, exitT: t + H - 60e3, how: be ? "stop au prix d'entrée" : (trailOn ? "stop suiveur" : "SL") };
      if (i === c.i) continue;   // pas d'objectif dans la bougie d'entrée (prudent)
      var hitTP = sell ? lo <= tp : hi >= tp;
      if (hitTP) return { R: dir * (tp - e) / risk, px: tp, exitT: t + H - 60e3, how: "TP" };
      if (opt.tp1BE && !be && (sell ? lo <= tp1 : hi >= tp1)) { be = true; sl = sell ? Math.min(sl, e) : Math.max(sl, e); }
      if (opt.trail && i >= c.i + 2) {
        var gain = dir * (b[4] - e) / risk;
        if (gain >= 0.5) {
          trailOn = true;
          var p1 = bars[i - 1], p2 = bars[i];
          var lvl = sell ? Math.max(p1[2], p2[2]) : Math.min(p1[3], p2[3]);
          if (sell ? lvl < sl : lvl > sl) sl = lvl;
        }
      }
    }
    return null; // encore ouverte
  }

  function money(trades, capital, riskPct) {
    var eq = capital, peak = capital, dd = 0, curve = [{ t: trades.length ? trades[0].open : "", v: capital }];
    trades.forEach(function (tr) {
      var pl = eq * riskPct / 100 * tr.R;
      tr.pl = Math.round(pl * 100) / 100;
      eq += pl; peak = Math.max(peak, eq); dd = Math.max(dd, (peak - eq) / peak);
      tr.eq = Math.round(eq * 100) / 100;
      curve.push({ t: tr.close, v: eq });
    });
    var wins = trades.filter(function (t) { return t.R > 0; });
    var losses = trades.filter(function (t) { return t.R <= 0; });
    function avg(a) { return a.length ? a.reduce(function (s, t) { return s + t.R; }, 0) / a.length : 0; }
    return { final: eq, curve: curve, maxDD: dd, n: trades.length, win: trades.length ? wins.length / trades.length : 0, avgW: avg(wins), avgL: avg(losses), exp: avg(trades) };
  }

  // Projection : tirages au hasard dans les résultats passés (en R), trade par trade
  function project(Rs, capital, riskPct, nTrades, runs, seed) {
    var s = seed || 12345;
    function rnd() { s = (s * 1664525 + 1013904223) % 4294967296; return s / 4294967296; }
    var finals = [], paths = [], ruin = 0, dbl = 0, dd30 = 0;
    for (var k = 0; k < runs; k++) {
      var eq = capital, peak = capital, mdd = 0, path = [eq];
      for (var i = 0; i < nTrades; i++) {
        var R = Rs[Math.floor(rnd() * Rs.length)];
        eq += eq * riskPct / 100 * R; if (eq < 0) eq = 0;
        peak = Math.max(peak, eq); mdd = Math.max(mdd, peak > 0 ? (peak - eq) / peak : 1);
        path.push(eq);
      }
      finals.push(eq); paths.push(path);
      if (eq < capital * 0.5) ruin++;
      if (eq >= capital * 2) dbl++;
      if (mdd >= 0.3) dd30++;
    }
    var idx = finals.map(function (v, i) { return i; }).sort(function (a, b) { return finals[a] - finals[b]; });
    function q(p) { return finals[idx[Math.min(runs - 1, Math.floor(p * runs))]]; }
    var bands = [];
    for (var i = 0; i <= nTrades; i++) {
      var col = paths.map(function (p) { return p[i]; }).sort(function (a, b) { return a - b; });
      bands.push([col[Math.floor(0.1 * runs)], col[Math.floor(0.5 * runs)], col[Math.floor(0.9 * runs)]]);
    }
    return { p10: q(0.1), p50: q(0.5), p90: q(0.9), pHalf: ruin / runs, pDouble: dbl / runs, pDD30: dd30 / runs, bands: bands };
  }

  var api = { simulate: simulate, money: money, project: project };
  if (typeof module !== "undefined") module.exports = api; else root.SimEngine = api;
})(this);

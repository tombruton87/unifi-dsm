// UniFi Network's tabs on the chassis window: Devices, Adopt, Memory, and UniFi's part of Backups, Site address, Updates, Storage and Maintenance.
(function (P) {
  "use strict";
  var $ = function (id) { return document.getElementById(id); };
  var STATES = { 0: ["offline", "bad"], 1: ["online", "ok"], 2: ["waiting for adoption", "warn"], 4: ["updating firmware", "warn"], 5: ["provisioning", "warn"], 6: ["heartbeat missed", "warn"], 7: ["adopting", "warn"], 9: ["adoption failed", "bad"], 10: ["isolated", "bad"], 11: ["isolated", "bad"] };
  function ufUrl(st) { return ((st.app || {}).url || "").replace(/\/$/, ""); }
  function links(st) { document.querySelectorAll(".uf-link").forEach(function (x) { x.href = ufUrl(st) ? ufUrl(st) + (x.dataset.path || "/manage") : "#"; }); }
  function touched(id) { ["input", "change"].forEach(function (e) { $(id).addEventListener(e, function () { $(id).dataset.touched = "1"; }); }); }
  function quiet(id, v) { if (!$(id).dataset.touched) { if ($(id).type === "checkbox") $(id).checked = !!v; else $(id).value = v == null ? "" : v; } }
  function plural(n, one, many) { return n + " " + (n === 1 ? one : many); }
  function dur(s) { if (!s) return "–"; if (s < 3600) return Math.round(s / 60) + " min"; if (s < 172800) return Math.round(s / 3600) + " h"; return Math.round(s / 86400) + " days"; }
  function devs(st) { return ((st.app || {}).devices) || []; }
  function adopted(st) { return devs(st).filter(function (d) { return d.adopted; }); }
  function pending(st) { return devs(st).filter(function (d) { return !d.adopted; }); }
  function empty(tb, text, cols) { var r = P.el("tr"), c = P.cell(text, "empty"); c.colSpan = cols; r.appendChild(c); tb.appendChild(r); }
  function who(d, sites) { var w = P.el("div"); w.appendChild(P.el("b", d.name || d.model_name || d.mac)); w.appendChild(P.el("span", (d.name ? d.model_name : d.mac) + (sites > 1 ? " · " + (d.site_desc || d.site) : ""), "sub")); return w; }

  // ---------------------------------------------------------------- Devices
  P.register("devices", {
    render: function (st) {
      var a = st.app || {}, all = adopted(st), t = $("dv-tiles"), sites = (a.sites || []).length;
      links(st); $("dv-setup").hidden = !a.setup_pending;
      $("dv-err").hidden = !a.api_error; $("dv-err").textContent = a.api_error ? a.api_error + " — Maintenance → UniFi administrators → dsm-package → Repair puts it right." : "";
      var on = all.filter(function (d) { return d.state === 1; }).length, clients = all.reduce(function (s, d) { return s + (d.clients || 0); }, 0), upd = all.filter(function (d) { return d.upgradable; }).length;
      P.clear(t); P.tile(t, on + " / " + all.length, "devices online"); P.tile(t, String(clients), clients === 1 ? "client connected" : "clients connected");
      P.tile(t, String(pending(st).length), "waiting for adoption"); P.tile(t, String(upd), upd === 1 ? "firmware update" : "firmware updates");
      if (sites > 1) P.tile(t, String(sites), "sites");
      $("dv-at").textContent = a.devices_at ? "read " + P.ago(a.devices_at) : "";
      var tb = $("dv-list"), sig = JSON.stringify(all) + sites; if (tb.dataset.sig === sig) return; tb.dataset.sig = sig; P.clear(tb);
      if (!all.length) empty(tb, a.up ? "No devices adopted yet — the Adopt tab shows how." : "UniFi isn't running.", 6);
      all.forEach(function (d) {
        var s = STATES[d.state] || ["state " + d.state, "warn"], fw = P.el("div");
        fw.appendChild(P.el("span", d.version || "–")); if (d.upgradable) fw.appendChild(P.el("span", "update: " + (d.upgrade_to || "available"), "sub upd"));
        P.row(tb, [P.cell(who(d, sites)), d.ip || "–", P.cell(P.chip(s[0], s[1])), P.cell(fw), P.cell(String(d.clients || 0), "n"), P.cell(d.state === 1 ? dur(d.uptime) : d.last_seen ? "seen " + P.ago(d.last_seen) : "–", "n")]);
      });
    },
    badge: function (st) { var n = adopted(st).filter(function (d) { return d.state === 0; }).length; $("badge-devices").hidden = !n; $("badge-devices").textContent = String(n); }
  });

  // ---------------------------------------------------------------- Adopt
  ["ih-host", "pt-inform", "pt-stun", "pt-disc", "pt-portal", "pt-ph", "pt-phs"].forEach(touched);
  P.register("adopt", {
    render: function (st) {
      var a = st.app || {}, inf = a.inform || {}, pend = pending(st);
      links(st);
      $("ad-url").textContent = inf.url || "…"; $("ad-cmd").textContent = "set-inform " + (inf.url || "");
      document.querySelectorAll(".ad-ip").forEach(function (x) { x.textContent = a.lan_ip || inf.host || ""; });
      $("ad-8080").textContent = inf.port === 8080 ? "" : "(Not while the inform port is " + inf.port + ": devices look for UniFi on 8080 only — use set-inform.)";
      $("ad-note").textContent = "This Synology's address and UniFi's inform port (" + inf.port + "). STUN is on " + inf.stun + "/UDP." + (inf.host !== a.lan_ip ? " Devices are told " + inf.host + " (set below)." : "");
      quiet("ih-host", inf.host); quiet("pt-inform", inf.port); quiet("pt-stun", inf.stun); quiet("pt-disc", inf.discovery); quiet("pt-portal", inf.portal); quiet("pt-ph", inf.portal_http); quiet("pt-phs", inf.portal_https);
      $("pt-web").textContent = st.port || ""; $("pt-portal-ports").hidden = !$("pt-portal").checked;
      var tb = $("ad-pending"), sig = JSON.stringify(pend) + P.busy; if (tb.dataset.sig === sig) return; tb.dataset.sig = sig; P.clear(tb);
      if (!pend.length) empty(tb, "No device is waiting. A new one appears here a minute after it's been given the inform address.", 4);
      pend.forEach(function (d) { var o = P.el("a", "Adopt in UniFi", "btn"); o.href = ufUrl(st) ? ufUrl(st) + "/manage/default/devices" : "#"; o.target = "_blank"; o.rel = "noopener";
        P.row(tb, [P.cell(who(d, 1)), d.ip || "–", P.cell(P.el("code", d.mac)), P.cell(o, "n")]); });
    },
    badge: function (st) { var n = pending(st).length; $("badge-adopt").hidden = !n; $("badge-adopt").textContent = String(n); }
  });
  $("ad-copy").onclick = function () { P.copy($("ad-url").textContent, $("ad-copy"), $("ad-url")); };
  $("ad-copy-cmd").onclick = function () { P.copy($("ad-cmd").textContent, $("ad-copy-cmd"), $("ad-cmd")); };
  $("pt-portal").addEventListener("change", function () { $("pt-portal-ports").hidden = !$("pt-portal").checked; });
  $("ih-save").onclick = function () {
    P.act("informhost", { host: $("ih-host").value.trim() }, "Tell devices to inform to " + $("ih-host").value.trim() + "? UniFi stops for a minute while it changes.").then(function () { $("ih-host").dataset.touched = ""; });
  };
  $("pt-save").onclick = function () {
    var inf = ((P.S && P.S.status && P.S.status.app) || {}).inform || {}, warn = String(inf.port) !== $("pt-inform").value ? "\n\nThe inform port changes: every device adopted on " + inf.port + " needs set-inform with the new address." : "";
    P.act("ports", { inform: $("pt-inform").value, stun: $("pt-stun").value, disc: $("pt-disc").value, portal: $("pt-portal").checked ? 1 : 0, portal_http: $("pt-ph").value, portal_https: $("pt-phs").value },
      "Save the ports and restart UniFi? It's away for a minute or two." + warn).then(function () { ["pt-inform", "pt-stun", "pt-disc", "pt-portal", "pt-ph", "pt-phs"].forEach(function (id) { $(id).dataset.touched = ""; }); });
  };

  // ---------------------------------------------------------------- Memory
  ["mm-heap", "mm-cache"].forEach(touched);
  P.register("memory", {
    render: function (st) {
      var m = (st.app || {}).memory || {}, t = $("mm-tiles");
      P.clear(t); P.tile(t, m.ram_mb ? P.mb(m.ram_mb) : "–", "memory in this NAS"); P.tile(t, m.avail_mb != null ? P.mb(m.avail_mb) : "–", "available now");
      P.tile(t, m.server_mb != null ? P.mb(m.server_mb) : "–", "UniFi uses (heap " + P.mb(m.heap_mb) + ")"); P.tile(t, m.db_mb != null ? P.mb(m.db_mb) : "–", "MongoDB uses (cache " + P.mb((m.cache_gb || 0) * 1024) + ")");
      quiet("mm-heap", String(m.heap_mb || 1024)); quiet("mm-cache", String(m.cache_gb || 0.5));
      $("mm-hint").textContent = m.ram_mb ? "For " + P.mb(m.ram_mb) + " of memory the package suggests " + P.mb(m.suggested_heap) + " of heap and a " + P.mb(m.suggested_cache * 1024) + " cache." : "";
      $("mm-db").textContent = "The database is " + (((st.app || {}).db_image) || "MongoDB") + " — chosen for this NAS's processor when the package was installed (MongoDB 5 and later need a CPU with AVX).";
    }
  });
  $("mm-save").onclick = function () { P.act("memory", { heap: $("mm-heap").value, cache: $("mm-cache").value }, "Save and restart UniFi with these memory settings? It's away for a minute or two.").then(function () { $("mm-heap").dataset.touched = ""; $("mm-cache").dataset.touched = ""; }); };

  // ---------------------------------------------------------------- Overview tiles
  P.register("overview", { tiles: function (t, st) {
    var all = adopted(st), on = all.filter(function (d) { return d.state === 1; }).length, cl = all.reduce(function (s, d) { return s + (d.clients || 0); }, 0);
    P.tile(t, on + " / " + all.length, "UniFi devices online"); P.tile(t, String(cl), "clients"); if (pending(st).length) P.tile(t, String(pending(st).length), "waiting for adoption");
  } });

  // ---------------------------------------------------------------- Backups: UniFi's own, beside the package's
  (function () { var c = $("ub-cards"), sec = document.querySelector('section[data-page="backups"]'); if (c && sec) { var first = sec.querySelector(".card"); sec.insertBefore(c, first ? first.nextSibling : null); c.hidden = false; } })();
  $("ub-copy").onclick = function () { P.act("copyunf", {}); };
  P.register("backups", { render: function (st) {
    var u = ((st.app || {}).unf) || {}, files = u.files || [], tb = $("ub-list"), sig = JSON.stringify(files) + P.busy + P.role; if (tb.dataset.sig === sig) return; tb.dataset.sig = sig; P.clear(tb);
    if (!files.length) empty(tb, "UniFi hasn't made an autobackup yet — its first is due on its schedule (UniFi → Settings → System → Backups).", 4);
    files.forEach(function (f) { var c; if (f.copied) { c = P.el("a", "Save", "btn"); c.href = P.withToken("api.cgi?action=unf&name=" + encodeURIComponent(f.name)); } else c = P.el("span", "not copied yet", "muted small");
      P.row(tb, [P.cell(P.el("code", f.name)), P.cell(P.bytes(f.size), "n"), P.when(f.at), P.cell(c, "n")]); });
  } });

  // ---------------------------------------------------------------- Site address: HTTPS, and DSM's reverse proxy talks HTTPS to UniFi
  touched("set-tls");
  (function () { var li = document.querySelector('section[data-page="site"] ol li'); if (li) li.innerHTML = li.innerHTML.replace("destination <code>HTTP</code>", "destination <code>HTTPS</code>"); })();
  P.register("site", {
    fill: function (st) { $("set-tls").value = (st.app || {}).tls || "own"; },
    values: function () { return { tls: $("set-tls").value }; },
    render: function (st) {
      var a = st.app || {}, c = a.cert, tb = $("tls-info"), acts = $("tls-actions");
      quiet("set-tls", a.tls || "own");
      $("tls-card").hidden = a.tls_source !== "dsm" && a.tls_source !== "self"; P.clear(tb); P.clear(acts);
      if (c && !$("tls-card").hidden) {
        P.kv(tb, "Issued to", c.subject || "–"); P.kv(tb, "Issued by", c.issuer || "–"); P.kv(tb, "Expires", (c.expires || "–") + (c.days_left != null ? " (" + c.days_left + " days)" : ""));
        $("tls-note").textContent = a.tls_source === "dsm" ? "DSM's system-default certificate, put into UniFi's keystore. A renewal is picked up within a day." : "DSM's certificate wasn't found, so a self-signed one is used.";
        acts.appendChild(P.btn("Read DSM's certificate again", "", function () { P.act("refreshcert", {}, "Read DSM's certificate again and restart UniFi?"); }));
      }
    }
  });

  // ---------------------------------------------------------------- Maintenance: UniFi's administrators
  P.register("maintenance", { render: function (st) {
    var a = st.app || {}, us = a.users || [], tb = $("ad-list"), sig = JSON.stringify(us) + P.busy + P.role; if (tb.dataset.sig === sig) return; tb.dataset.sig = sig; P.clear(tb);
    if (!us.length) empty(tb, a.setup_pending ? "Your administrator is made when UniFi has started." : "No administrators found in UniFi's database.", 4);
    us.forEach(function (u) {
      var w = P.el("div"); w.appendChild(P.el("b", u.name)); if (u.email) w.appendChild(P.el("span", u.email, "sub"));
      var pkg = u.name === a.pkg_admin, role = pkg ? "read-only (the package)" : u.super ? "super administrator" : (u.roles || []).join(", ") || "–";
      var b = pkg ? P.btn("Repair", "", function () { P.act("adminpw", { id: u.id }, "Make the package's read-only account sign in again?"); })
                  : P.btn("New password", "", function () { P.act("adminpw", { id: u.id }, "Make a new password for " + u.name + "?\n\nThe old one stops working."); });
      P.row(tb, [P.cell(w), role, u.last_login ? P.ago(u.last_login) : "–", P.cell(b, "n")]);
    });
  } });
  P.register("secretNote", function (s) { return s.kind === "devices" ? "Sign in to UniFi with it (Open UniFi Network on the Overview), then keep it in a password manager or change it in UniFi (your name, top right → Account). Your browser warns about UniFi's self-signed certificate once." : "Sign in to UniFi with it, then change it in UniFi if you like."; });

  // ---------------------------------------------------------------- Updates: UniFi is pinned to a linuxserver.io release
  P.register("updates", {
    render: function (st) {
      var box = $("upd-app"), iu = st.image_update || {}, a = st.app || {}; P.clear(box);
      box.appendChild(P.el("p", "Installed: UniFi Network " + (st.version || "?") + (a.image ? " (" + a.image + ")" : "") + ", with " + (a.db_image || "MongoDB") + "."));
      if (iu.available) {
        box.appendChild(P.el("p", (iu.note ? iu.note + ". " : "") + "UniFi Network " + iu.version + " is out (" + iu.latest + "). Updating backs everything up first, then moves UniFi to the new release, which migrates its database as it starts: away for a few minutes. Devices keep working meanwhile.", "muted small"));
        var l = P.el("a", "What's new"); l.href = iu.page; l.target = "_blank"; l.rel = "noopener"; box.appendChild(l); box.appendChild(P.el("span", " "));
        box.appendChild(P.btn("Update UniFi Network to " + iu.version, "primary", function () { P.act("updateapp", {}, "Update UniFi Network to " + iu.version + "? A backup is made first; UniFi is away for a few minutes."); }));
      } else if (iu.error) box.appendChild(P.el("p", "Couldn't look for a newer UniFi Network: " + iu.error + ".", "muted small"));
      else box.appendChild(P.el("p", (iu.note ? iu.note + ". " : iu.latest ? "This is the newest release (" + iu.latest + ")" + (iu.checked ? ", checked " + P.ago(iu.checked) : "") + ". " : "")
        + "The package keeps UniFi at a release and moves it on when you say so. UniFi's own update notice inside the app doesn't apply here: updates come through this tab.", "muted small"));
    }
  });

  // ---------------------------------------------------------------- Storage
  P.register("storage", { render: function (app, st, box) {
    P.clear(box); var c = P.el("div", null, "card"); c.appendChild(P.el("h2", "Inside UniFi's data folder")); var tbl = P.el("table"), tb = P.el("tbody"); tbl.appendChild(tb); c.appendChild(tbl);
    [["Settings, certificate and sites", app.data], ["UniFi's autobackups", app.autobackups], ["Logs", app.logs], ["Autobackup copies in the shared folder", app.copies]].forEach(function (p) { P.kv(tb, p[0], P.mb(p[1] || 0), true); });
    box.appendChild(c);
  } });
})(window.Panel);

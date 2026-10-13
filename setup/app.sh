# UniFi Network's hooks for the chassis core (sourced by run-core.sh). The core
# gives: say, env_get/env_set, rand, compose, in_volume, cname, svc_up,
# leave_secret, notify, fresh, now, for_window, wait_ready, make_backup,
# record_backup, sync_dsm, MSG, VAR, APP, LOG, PKG_NAME, PKG_TITLE, IMAGE_UPDATE,
# and the tls_* helpers (chassis tls.sh).
#
# UniFi's first-run wizard is done through the same API calls the wizard makes:
# your administrator (password shown once), the controller's name, country and
# time zone, the address devices inform to, autobackups on — and a read-only
# account for the package, "dsm-package", which is all the window uses to read
# devices. Writes that need more than read-only (the inform host later, a new
# password) go to UniFi's MongoDB directly, the way Ubiquiti's own recovery
# steps do, while UniFi is stopped where it matters.
#
# The UniFi image is pinned to a linuxserver.io release (lscr.io, which the
# core's Docker Hub check can't read): the package looks for newer releases
# itself and moves the pin when you press Update. MongoDB is pinned to a
# version this UniFi supports, chosen once by CPU: MongoDB 5 and later need AVX,
# which many Synology Celerons (J4125, J3455…) don't have — they get 4.4.

US=""; UD=""; UF_JAR=""; UF_CODE=0; TLS_RESTART=0
UF_REPO=lscr.io/linuxserver/unifi-network-application
UF_PINNED=$UF_REPO:10.6.106-ls149     # the release this package was tested with
DB_NEW=mongo:8.0.32                   # x86-64 with AVX, ARMv8.2 and later
DB_MID=mongo:7.0.43                   # AVX, but a Linux kernel of 6.19 or later, which MongoDB 8.0 refuses to start on (SERVER-121912)
DB_OLD=mongo:4.4.30                   # x86-64 without AVX
DB_ARM_OLD=mongo:4.4.18               # ARMv8.0: the last 4.4 that runs there
PKG_ADMIN=dsm-package
UNF_DIR=autobackups                   # UniFi's autobackups, copied into the share
UNF_KEEP=30

app_validate() {   # key value → 0 if the value has the key's shape
  case "$1" in
    INFORM_PORT|STUN_PORT|DISC_PORT|PORTAL_HTTP|PORTAL_HTTPS) [[ "$2" =~ ^[0-9]{4,5}$ ]] && (( $2 >= 1024 && $2 <= 65535 )) ;;
    PORTAL)      [[ "$2" =~ ^[01]$ ]] ;;
    ADMIN_USER)  [[ "$2" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,31}$ ]] ;;
    ADMIN_EMAIL) [[ "$2" =~ ^[A-Za-z0-9._+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]] && (( ${#2} <= 120 )) ;;
    COUNTRY)     [[ "$2" =~ ^[A-Z]{2}$ ]] ;;
    TLS)         [[ "$2" =~ ^(own|dsm)$ ]] ;;
    JAVA_HEAP)   [[ "$2" =~ ^(384|512|768|1024|1536|2048|3072)$ ]] ;;
    DB_CACHE)    [[ "$2" =~ ^(0\.25|0\.5|1|2)$ ]] ;;
    INFORM_HOST) [[ "$2" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]] && (( ${#2} <= 253 )) ;;
    ADMIN_ID)    [[ "$2" =~ ^[0-9a-f]{24}$ ]] ;;
    *) return 1 ;;
  esac
}

# ------------------------------------------------------------ small things
strong_password() { echo "$(rand 5)-$(rand 5)-$(rand 5)-$(rand 5)"; }
newer() { [[ "$1" != "$2" && "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n 1)" == "$1" ]]; }   # is $1 newer than $2?
uf_tag() { local i=${1:-$(env_get UNIFI_IMAGE)}; [[ "$i" =~ ^lscr\.io/linuxserver/unifi-network-application:([0-9]+\.[0-9]+\.[0-9]+-ls[0-9]+)$ ]] && echo "${BASH_REMATCH[1]}"; true; }
is_ip() { [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; }
new_kernel() { local k; k=$(uname -r | grep -oE '^[0-9]+\.[0-9]+'); [[ -n "$k" ]] && newer "$k" 6.18; }   # 6.19 or later (DSM 7.2 runs 4.4 or 5.10)
pick_db() {   # MongoDB this CPU can run: 5.0 and later need AVX on x86-64, ARMv8.2 on ARM; 8.0 won't start on a kernel of 6.19 or later
  local new=$DB_NEW; new_kernel && new=$DB_MID
  case "$(uname -m)" in
    x86_64)  if grep -qw avx /proc/cpuinfo 2>/dev/null; then echo "$new"; else echo "$DB_OLD"; fi ;;
    aarch64) if grep -qw asimdhp /proc/cpuinfo 2>/dev/null; then echo "$new"; else echo "$DB_ARM_OLD"; fi ;;
    *)       echo "$DB_OLD" ;;
  esac
}
ram_mb() { awk '/^MemTotal:/ {print int($2 / 1024)}' /proc/meminfo 2>/dev/null; }
avail_mb() { awk '/^MemAvailable:/ {print int($2 / 1024)}' /proc/meminfo 2>/dev/null; }
memory_defaults() {   # → "heap cache" for this NAS's memory
  local r; r=$(ram_mb); r=${r:-2048}
  if (( r <= 2560 )); then echo "512 0.25"; elif (( r <= 4608 )); then echo "768 0.25"; else echo "1024 0.5"; fi
}
portal_env() {   # the guest portal's ports are published only while it's on
  if [[ "$(env_get PORTAL)" == 1 ]]; then env_set PORTAL_HTTP_PUB "$(env_get PORTAL_HTTP)"; env_set PORTAL_HTTPS_PUB "$(env_get PORTAL_HTTPS)"
  else env_set PORTAL_HTTP_PUB "127.0.0.1:"; env_set PORTAL_HTTPS_PUB "127.0.0.1:"; fi
}
inform_url() { echo "http://$(env_get INFORM_HOST):$(env_get INFORM_PORT)/inform"; }

# UniFi's settings file (data/system.properties in the config volume): the
# package's lines — ports, the database, the address devices use — rewritten
# every start; anything else in it (UniFi's own lines, yours) is kept.
PROPS_KEYS='unifi\.https\.port|unifi\.http\.port|unifi\.stun\.port|portal\.http\.port|portal\.https\.port|system_ip|db\.mongo\.local|db\.mongo\.uri|statdb\.mongo\.uri|unifi\.db\.name'
props_write() {
  local pw host; pw=$(env_get DB_PASSWORD); host=$(env_get INFORM_HOST)
  {
    echo "## set by the unifi DSM package at every start (other lines are kept)"
    echo "unifi.https.port=$(env_get HTTP_PORT)"
    echo "unifi.http.port=$(env_get INFORM_PORT)"
    echo "unifi.stun.port=$(env_get STUN_PORT)"
    echo "portal.http.port=$(env_get PORTAL_HTTP)"
    echo "portal.https.port=$(env_get PORTAL_HTTPS)"
    is_ip "$host" && echo "system_ip=$host"
    echo "db.mongo.local=false"
    echo "db.mongo.uri=mongodb://unifi:$pw@db:27017/unifi?tls=false&authSource=admin"
    echo "statdb.mongo.uri=mongodb://unifi:$pw@db:27017/unifi_stat?tls=false&authSource=admin"
    echo "unifi.db.name=unifi"
  } | in_volume config rw -- "mkdir -p /vol/data; f=/vol/data/system.properties; { [ -f \$f ] && grep -vE '^(## set by the unifi DSM package.*|($PROPS_KEYS)=.*)\$' \$f; cat; } > /tmp/p; cat /tmp/p > \$f; chown 1000:1000 /vol/data \$f; chmod 640 \$f" 2>>"$LOG"
}
dbinit_write() {   # linuxserver.io's init script: UniFi's database user, made when MongoDB starts on an empty volume
  in_volume dbinit rw -- 'cat > /vol/init-mongo.sh && chmod 755 /vol/init-mongo.sh' 2>>"$LOG" <<'SH'
#!/bin/bash
# UniFi's own database user (from linuxserver.io's documentation); runs once, when MongoDB starts on an empty volume.
if which mongosh > /dev/null 2>&1; then mongo_init_bin='mongosh'; else mongo_init_bin='mongo'; fi
"${mongo_init_bin}" <<EOF
use ${MONGO_AUTHSOURCE}
db.auth("${MONGO_INITDB_ROOT_USERNAME}", "${MONGO_INITDB_ROOT_PASSWORD}")
db.createUser({
  user: "${MONGO_USER}",
  pwd: "${MONGO_PASS}",
  roles: [
    "clusterMonitor",
    { db: "${MONGO_DBNAME}", role: "dbOwner" },
    { db: "${MONGO_DBNAME}_stat", role: "dbOwner" },
    { db: "${MONGO_DBNAME}_audit", role: "dbOwner" },
    { db: "${MONGO_DBNAME}_restore", role: "dbOwner" }
  ]
})
EOF
SH
}

# ------------------------------------------------------------ MongoDB, as its administrator
mdb() {   # JavaScript on stdin → what it prints, in database "unifi" (lines starting @@ are the answer)
  docker exec -i "$UD" sh -c 'b=mongosh; command -v mongosh >/dev/null 2>&1 || b=mongo; exec "$b" --quiet --norc -u root -p "$MONGO_INITDB_ROOT_PASSWORD" --authenticationDatabase admin unifi' 2>>"$LOG" | sed -n 's/^\(unifi> \)*@@//p'   # mongosh echoes its prompt when it reads stdin
}
db_ready() { [[ "$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{end}}' "$UD" 2>/dev/null)" == healthy ]]; }
db_up() { svc_up db || compose up -d db >> "$LOG" 2>&1; local i; for i in $(seq 1 90); do db_ready && return 0; sleep 2; done; return 1; }
JS_OID='function oid(o) { return o == null ? "" : (o.toHexString ? o.toHexString() : (o.str || String(o))); }'

# ------------------------------------------------------------ UniFi's API
uf_base() { echo "https://127.0.0.1:$(env_get HTTP_PORT)"; }
uf_status() { curl -sk --max-time 5 "$(uf_base)/status" 2>/dev/null; }
uf_call() {   # jar method path [json on stdin when 4th arg is -] → body; UF_CODE
  local jar=$1 m=$2 p=$3 out csrf
  csrf=$(awk '$6 == "csrf_token" || $6 == "TOKEN" {print $7}' "$jar" 2>/dev/null | tail -n 1)
  if [[ "${4:-}" == - ]]; then
    out=$(curl -sk --max-time 30 -b "$jar" -c "$jar" -X "$m" "$(uf_base)$p" -H 'Content-Type: application/json' ${csrf:+-H "X-Csrf-Token: $csrf"} --data-binary @- -w '\n%{http_code}' 2>/dev/null)
  else
    out=$(curl -sk --max-time 30 -b "$jar" -c "$jar" -X "$m" "$(uf_base)$p" ${csrf:+-H "X-Csrf-Token: $csrf"} -w '\n%{http_code}' 2>/dev/null </dev/null)
  fi
  chmod 600 "$jar" 2>/dev/null
  UF_CODE=${out##*$'\n'}; printf '%s' "${out%$'\n'*}"
}
uf_ok() { [[ "$(jq -r '.meta.rc // empty' <<< "$1" 2>/dev/null)" == ok ]]; }
uf_why() { jq -r '.meta.msg // empty' <<< "$1" 2>/dev/null | head -c 120; }
uf_login() {   # jar user password → 0 when signed in
  local out; rm -f "$1"
  out=$(jq -cn --arg u "$2" --arg p "$3" '{username: $u, password: $p, remember: false}' | uf_call "$1" POST /api/login -)
  uf_ok "$out"
}
pkg_api() {   # path → body, as the package's read-only account (signed in again once if the session ended)
  local out try
  for try in 1 2; do
    if [[ ! -s "$UF_JAR" ]]; then uf_login "$UF_JAR" "$PKG_ADMIN" "$(env_get PKG_API_PASS)" || { UF_CODE=401; return 1; }; fi
    out=$(uf_call "$UF_JAR" GET "$1")
    if [[ "$UF_CODE" == 401 ]] || [[ "$(uf_why "$out")" == api.err.LoginRequired ]]; then rm -f "$UF_JAR"; continue; fi
    break
  done
  printf '%s' "$out"; uf_ok "$out" || [[ "$UF_CODE" =~ ^2 && "$out" != *'"rc":"error"'* ]]
}

# ------------------------------------------------------------ lifecycle hooks
app_first_env() {
  local mem heap cache
  env_set UNIFI_IMAGE "$UF_PINNED"; env_set DB_IMAGE "$(pick_db)"
  env_set DB_PASSWORD "$(rand 32)"; env_set DB_ROOT_PASSWORD "$(rand 32)"; env_set PKG_API_PASS "$(rand 32)"
  env_set INFORM_PORT "${INFORM_PORT:-8080}"; env_set STUN_PORT "${STUN_PORT:-3478}"; env_set DISC_PORT "${DISC_PORT:-10001}"
  env_set PORTAL 0; env_set PORTAL_HTTP 8880; env_set PORTAL_HTTPS 8843
  env_set INFORM_HOST "$LAN_IP"; env_set APP_URL "https://$LAN_IP:$HTTP_PORT"
  env_set ADMIN_USER "${ADMIN_USER:-admin}"; env_set ADMIN_EMAIL "${ADMIN_EMAIL:-}"; env_set COUNTRY "${COUNTRY:-US}"
  mem=$(memory_defaults); heap=${mem% *}; cache=${mem#* }
  env_set JAVA_HEAP "${JAVA_HEAP:-$heap}"; env_set DB_CACHE "${DB_CACHE:-$cache}"
  env_set TLS "${TLS:-own}"; env_set TLS_SOURCE own; env_set DOWN_ALERTS 1
  portal_env
  touch "$VAR/.needs-setup"
  say "UniFi gets ${JAVA_HEAP:-$heap} MB of Java heap and MongoDB a ${DB_CACHE:-$cache} GB cache ($(ram_mb) MB in this NAS); $(env_get DB_IMAGE) suits this CPU ($(uname -m)$(grep -qw avx /proc/cpuinfo 2>/dev/null && echo ', AVX'))"
}
app_load_env() { US=$(cname server); UD=$(cname db); UF_JAR="$VAR/.uf-jar"; return 0; }
app_before_up() {
  portal_env
  dbinit_write || say "✗ MongoDB's init script couldn't be written"
  follow_pinned || true
  props_write || say "✗ UniFi's settings file couldn't be written"
  tls_setup || say "✗ HTTPS with DSM's certificate couldn't be set up: $MSG"
  return 0
}
follow_pinned() {   # a newer package brings a newer tested UniFi (and MongoDB patch): .env follows — never back, a backup first
  local cur pin=${UF_PINNED##*:} db cur_db
  cur=$(uf_tag)
  if [[ -n "$cur" ]] && newer "$pin" "$cur"; then
    say "this package brings UniFi Network $pin (installed: $cur) — first, a backup"
    if docker volume inspect "${PKG_NAME}_db" >/dev/null 2>&1 && db_up && make_backup pre-update; then record_backup true "$MADE"; env_set UNIFI_IMAGE "$UF_PINNED"; say "UniFi moves to $pin; the state from before is in $MADE"
    else say "✗ couldn't back up first, so UniFi stays at $cur for now — the next start tries again"; fi
  fi
  cur_db=$(env_get DB_IMAGE)
  for db in "$DB_NEW" "$DB_MID" "$DB_OLD" "$DB_ARM_OLD"; do   # patch releases of the same MongoDB version only
    [[ "${cur_db%.*}" == "${db%.*}" && "$cur_db" != "$db" ]] && newer "${db##*:}" "${cur_db##*:}" && { env_set DB_IMAGE "$db"; say "MongoDB ${cur_db##*:} → ${db##*:} (a patch release)"; }
  done
  return 0
}
app_health() { [[ "$(uf_status | jq -r '.meta.up // empty' 2>/dev/null)" == true ]]; }
app_version() {
  local v; v=$(uf_status | jq -r '.meta.server_version // empty' 2>/dev/null) || true
  [[ -n "$v" ]] || v=$(uf_tag); v=${v%-ls*}
  printf '%s' "$v" | tr -cd '0-9A-Za-z.-' | head -c 30
}
app_after_up() { first_setup 180; return 0; }

# The first start: UniFi's setup wizard, done through its own API.
first_setup() {   # [tries]
  [[ -f "$VAR/.needs-setup" ]] || return 0
  local i out pw user email jar="$VAR/.owner-jar" code ccode
  for i in $(seq 1 "${1:-1}"); do app_health && break; sleep 2; done
  app_health || { say "UniFi isn't answering yet — your administrator is made when it does"; return 0; }
  user=$(env_get ADMIN_USER); email=$(env_get ADMIN_EMAIL)
  if [[ "$(uf_status | jq -r '.meta.setup // empty' 2>/dev/null)" == false ]] || admins_exist; then
    say "UniFi is already set up (a restored or earlier database) — its administrators are left as they are"
  else
    pw=$(strong_password)
    out=$(jq -cn --arg n "$user" --arg e "$email" --arg p "$pw" '{cmd: "add-default-admin", name: $n, email: $e, x_password: $p}' | uf_call "$jar" POST /api/cmd/sitemgr -)
    uf_ok "$out" || { say "✗ UniFi didn't make your administrator ($(uf_why "$out"), HTTP $UF_CODE) — trying again shortly"; rm -f "$jar"; return 0; }
    uf_login "$jar" "$user" "$pw" || { say "✗ the new administrator couldn't sign in to UniFi — trying again shortly"; rm -f "$jar"; return 0; }
    ccode=$(uf_call "$jar" GET /api/stat/ccode | jq -r --arg c "$(env_get COUNTRY)" '[.data[]? | select((.key // "" | ascii_upcase) == $c) | .code][0] // empty' 2>/dev/null)
    owner_post() { local o; o=$(uf_call "$jar" POST "$1" -); uf_ok "$o" || say "✗ UniFi refused $1: $(uf_why "$o")"; }
    jq -cn --arg h "$(env_get INFORM_HOST)" '{name: "UniFi Network", hostname: $h}' | owner_post /api/set/setting/super_identity
    [[ -n "$ccode" ]] && jq -cn --arg c "$ccode" '{code: ($c | tonumber? // $c)}' | owner_post /api/set/setting/country
    [[ -n "$ccode" ]] || say "the country $(env_get COUNTRY) isn't one UniFi knows — set it in UniFi (Settings → System → Country)"
    jq -cn --arg t "$(env_get TZ)" '{timezone: $t}' | owner_post /api/set/setting/locale
    jq -cn --arg u "$user" --arg p "$(rand 16)" '{x_ssh_username: $u, x_ssh_password: $p}' | owner_post /api/set/setting/mgmt
    echo '{"override_inform_host": true, "autobackup_enabled": true, "autobackup_cron_expr": "0 1 * * 1"}' | owner_post /api/set/setting/super_mgmt   # weekly, Mondays at 1:00 (UniFi's own default is monthly)
    make_pkg_account "$jar"
    echo '{"cmd": "set-installed"}' | owner_post /api/cmd/system
    uf_call "$jar" POST /api/logout >/dev/null; rm -f "$jar"
    leave_secret "UniFi Network ($user)" "$pw" devices
    say "first start: your UniFi administrator \"$user\" was made (the password is shown once in the window); devices are told to inform to $(inform_url)"
  fi
  rm -f "$VAR/.needs-setup" "$UF_JAR"
  ensure_api || true
}
make_pkg_account() {   # owner's jar → the package's read-only account
  local out
  out=$(jq -cn --arg n "$PKG_ADMIN" --arg p "$(env_get PKG_API_PASS)" \
    '{cmd: "create-admin", name: $n, email: "dsm-package@localhost.localdomain", x_password: $p, role: "readonly", permissions: [], requires_new_password: false}' \
    | uf_call "$1" POST /api/s/default/cmd/sitemgr -)
  uf_ok "$out" && say "the package's read-only UniFi account ($PKG_ADMIN) was made" || say "✗ UniFi didn't make the package's read-only account: $(uf_why "$out")"
}
admins_exist() { [[ "$(echo 'print("@@" + db.admin.countDocuments({}))' | mdb | tr -cd '0-9')" =~ ^[1-9] ]]; }

# The package's own account: if it can't sign in (a backup from another install
# was restored, or it was deleted in UniFi), its password is put back in the database.
ensure_api() {
  app_health || return 1
  uf_login "$UF_JAR" "$PKG_ADMIN" "$(env_get PKG_API_PASS)" && return 0
  local hash out
  hash=$(openssl passwd -6 "$(env_get PKG_API_PASS)")
  out=$(printf '%s\nvar a = db.admin.findOne({name: "%s"}); if (a) { db.admin.updateOne({_id: a._id}, {$set: {x_shadow: "%s", requires_new_password: false}}); print("@@reset"); } else print("@@missing");\n' "$JS_OID" "$PKG_ADMIN" "$hash" | mdb)
  case "$out" in
    reset) say "the package's read-only UniFi account couldn't sign in; its password was put back"; sleep 2
           uf_login "$UF_JAR" "$PKG_ADMIN" "$(env_get PKG_API_PASS)" && return 0
           say "✗ …and it still can't sign in — the Devices tab stays empty until it can"; return 1 ;;
    missing) say "✗ the package's read-only UniFi account ($PKG_ADMIN) isn't in UniFi any more — Maintenance → Administrators makes it again"; return 1 ;;
    *) return 1 ;;
  esac
}

# ------------------------------------------------------------ HTTPS: UniFi's own certificate, or DSM's
tls_setup() {   # TLS=dsm: DSM's system-default certificate imported into UniFi's keystore; own: UniFi's self-signed one
  local mode; mode=$(env_get TLS); mode=${mode:-own}
  if [[ "$mode" == dsm ]]; then
    tls_prepare config || return 1
    keystore_import || { MSG="the certificate couldn't be put into UniFi's keystore"; return 1; }
  elif [[ "$(env_get TLS_SOURCE)" != own ]]; then   # back to UniFi's own: its image makes a fresh keystore at start
    in_volume config rw -- 'rm -rf /vol/data/keystore /vol/tls' </dev/null 2>>"$LOG"; env_set TLS_SOURCE own; echo null > "$VAR/cert.json"
    say "HTTPS: back to UniFi's own self-signed certificate"
  fi
  return 0
}
keystore_import() {   # the PEM files in config/tls → UniFi's keystore, with the password UniFi expects (aircontrolenterprise is UniFi's fixed default)
  docker run --rm -i --user 0:0 --entrypoint bash -v "${PKG_NAME}_config:/config" "$(env_get UNIFI_IMAGE)" -c '
    set -e; cd /tmp
    openssl pkcs12 -export -inkey /config/tls/privkey.pem -in /config/tls/fullchain.pem -out u.p12 -name unifi -password pass:aircontrolenterprise
    rm -f ks; keytool -importkeystore -noprompt -deststorepass aircontrolenterprise -destkeypass aircontrolenterprise -destkeystore ks -srckeystore u.p12 -srcstoretype PKCS12 -srcstorepass aircontrolenterprise -alias unifi >/dev/null 2>&1
    mkdir -p /config/data; cp ks /config/data/keystore; chown 1000:1000 /config/data/keystore' </dev/null >> "$LOG" 2>&1
}

# ------------------------------------------------------------ what the window shows
models_json() {   # UniFi's own catalogue of models (dl/uidb/uidb.json in its image): short name → product name
  local f="$VAR/.models.json" tag; tag=$(uf_tag)
  if [[ ! -s "$f" || "$(cat "$VAR/.models.tag" 2>/dev/null)" != "$tag" ]] && svc_up server; then
    docker exec "$US" cat /usr/lib/unifi/dl/uidb/uidb.json 2>/dev/null | jq -c '[.devices[]? | . as $d | (.shortnames // [])[] | {key: ., value: $d.product.name}] | from_entries' > "$f.tmp" 2>/dev/null \
      && [[ -s "$f.tmp" ]] && mv "$f.tmp" "$f" && echo "$tag" > "$VAR/.models.tag" || rm -f "$f.tmp"
  fi
  cat "$f" 2>/dev/null || echo '{}'
}
devices_json() {   # every site's devices, as the read-only account sees them (kept for 15 s)
  local f="$VAR/.devices.json" sites s out all='[]' sysinfo models
  if fresh "$f" 15; then cat "$f"; return 0; fi
  sites=$(pkg_api /api/self/sites | jq -c '[.data[]? | {name, desc}]' 2>/dev/null) || sites=''
  [[ "$sites" == \[* ]] || { echo '{"error": "UniFi'"'"'s API didn'"'"'t answer the package'"'"'s read-only account"}'; return 0; }
  models=$(models_json)
  for s in $(jq -r '.[].name' <<< "$sites" | tr -cd 'A-Za-z0-9_\n-'); do
    out=$(pkg_api "/api/s/$s/stat/device") || continue
    all=$(jq -c --argjson all "$all" --arg site "$s" --arg desc "$(jq -r --arg s "$s" '.[] | select(.name == $s) | .desc' <<< "$sites")" --argjson models "$models" \
      '$all + [.data[]? | {mac, ip, name: (.name // ""), model, model_name: ($models[.model // ""] // .model // ""), type, state, adopted: (.adopted // false),
          version: (.version // ""), upgradable: (.upgradable // false), upgrade_to: (.upgrade_to_firmware // ""), clients: (.num_sta // 0), uptime: (.uptime // 0),
          last_seen: (.last_seen // 0), site: $site, site_desc: $desc}]' <<< "$out" 2>/dev/null || echo "$all")
  done
  sysinfo=$(pkg_api /api/s/default/stat/sysinfo | jq -c '.data[0] // {} | {version, hostname, inform_port, https_port, ip_addrs, timezone, autobackup, update_available, name}' 2>/dev/null) || sysinfo='{}'
  jq -n -c --argjson d "$all" --argjson s "$sites" --argjson i "${sysinfo:-{\}}" --argjson at "$(now)" '{at: $at, devices: $d, sites: $s, sysinfo: $i}' > "$f.tmp" 2>/dev/null && chmod 600 "$f.tmp" && mv "$f.tmp" "$f"
  cat "$f" 2>/dev/null || echo '{}'
}
admins_json() {   # UniFi's administrators and their roles, from its database (kept for 5 minutes)
  local f="$VAR/.admins.json"
  fresh "$f" 300 && { cat "$f"; return 0; }
  svc_up db || { echo '[]'; return 0; }
  printf '%s\nvar sup = {}; db.site.find({attr_hidden_id: "super"}).forEach(function (s) { sup[oid(s._id)] = 1; });\nvar roles = {}, supers = {}; db.privilege.find().forEach(function (p) { var k = String(p.admin_id); if (sup[String(p.site_id)]) supers[k] = 1; else (roles[k] = roles[k] || []).push(p.role); });\nprint("@@" + JSON.stringify(db.admin.find().toArray().map(function (a) { var k = oid(a._id); return {id: k, name: a.name || "", email: a.email || "", super: !!(supers[k] || a.is_super), roles: roles[k] || [], password: !!a.x_shadow, created: Number(a.time_created || 0), last_login: Number(a.last_login_timestamp || 0)}; })));\n' "$JS_OID" \
    | mdb | tail -n 1 > "$f.tmp"
  if jq -e 'type == "array"' "$f.tmp" >/dev/null 2>&1; then chmod 600 "$f.tmp"; mv "$f.tmp" "$f"; else rm -f "$f.tmp"; fi
  cat "$f" 2>/dev/null || echo '[]'
}
unf_json() {   # UniFi's autobackups in its volume, and the copies in the share (kept for a minute)
  local f="$VAR/.unf.json" inside copied
  fresh "$f" 60 && { cat "$f"; return 0; }
  inside=$(in_volume config ro -- 'cd /vol/data/backup/autobackup 2>/dev/null && for x in *.unf; do [ -f "$x" ] && stat -c "%n	%s	%Y" "$x"; done; true' </dev/null 2>/dev/null)
  copied=$(cd "$APP/$UNF_DIR" 2>/dev/null && for x in *.unf; do [[ -f "$x" ]] && printf '%s\n' "$x"; done; true)
  jq -n -c --arg in "$inside" --arg cp "$copied" --argjson at "$(now)" \
    '($cp | split("\n") | map(select(length > 0))) as $c
     | {at: $at, files: ($in | split("\n") | map(select(length > 0) | split("\t") | {name: .[0], size: (.[1] | tonumber? // 0), at: (.[2] | tonumber? // 0)} | . + {copied: (.name as $n | $c | index($n) != null)}) | sort_by(-.at)),
        copies: ($c | length)}' > "$f.tmp" 2>/dev/null && mv "$f.tmp" "$f"
  cat "$f" 2>/dev/null || echo '{}'
}
memory_json() {   # the NAS's memory and what UniFi's two containers use (kept for 30 s)
  local f="$VAR/.mem.json" stats
  fresh "$f" 30 && { cat "$f"; return 0; }
  stats=$(docker stats --no-stream --format '{{.Name}}	{{.MemUsage}}' "$US" "$UD" 2>/dev/null | awk -F'\t' '{split($2, a, " / "); v = a[1]; n = v + 0; if (v ~ /GiB/) n *= 1024; else if (v ~ /KiB/) n /= 1024; printf "%s\t%d\n", $1, n}')
  jq -n -c --arg s "$stats" --argjson ram "$(ram_mb || echo 0)" --argjson avail "$(avail_mb || echo 0)" --arg heap "$(env_get JAVA_HEAP)" --arg cache "$(env_get DB_CACHE)" --arg us "$US" --arg ud "$UD" --arg def "$(memory_defaults)" \
    '($s | split("\n") | map(select(length > 0) | split("\t") | {key: .[0], value: (.[1] | tonumber? // 0)}) | from_entries) as $m
     | {ram_mb: $ram, avail_mb: $avail, heap_mb: ($heap | tonumber? // 1024), cache_gb: ($cache | tonumber? // 0.5), server_mb: $m[$us], db_mb: $m[$ud],
        suggested_heap: ($def | split(" ")[0] | tonumber), suggested_cache: ($def | split(" ")[1] | tonumber)}' > "$f.tmp" 2>/dev/null && mv "$f.tmp" "$f"
  cat "$f" 2>/dev/null || echo '{}'
}
app_status() {
  local dev='{}' adm='[]' unf='{}' mem='{}'
  if svc_up server && app_health; then dev=$(devices_json); fi
  [[ "$dev" == \{* ]] || dev='{}'
  adm=$(admins_json); [[ "$adm" == \[* ]] || adm='[]'
  unf=$(unf_json); [[ "$unf" == \{* ]] || unf='{}'
  mem=$(memory_json); [[ "$mem" == \{* ]] || mem='{}'
  [[ -s "$VAR/cert.json" ]] || echo null > "$VAR/cert.json"
  jq -n -c --argjson dev "$dev" --argjson adm "$adm" --argjson unf "$unf" --argjson mem "$mem" --argjson cert "$(cat "$VAR/cert.json" 2>/dev/null || echo null)" \
     --arg up "$(svc_up server && echo 1)" --arg url "$(env_get APP_URL)" --arg ip "$(env_get LAN_IP)" --arg host "$(env_get INFORM_HOST)" --arg iport "$(env_get INFORM_PORT)" \
     --arg stun "$(env_get STUN_PORT)" --arg disc "$(env_get DISC_PORT)" --arg portal "$(env_get PORTAL)" --arg ph "$(env_get PORTAL_HTTP)" --arg phs "$(env_get PORTAL_HTTPS)" \
     --arg image "$(env_get UNIFI_IMAGE)" --arg dbimage "$(env_get DB_IMAGE)" --arg tls "$(env_get TLS)" --arg tlss "$(env_get TLS_SOURCE)" --arg alerts "$(env_get DOWN_ALERTS)" \
     --argjson pending "$([[ -f "$VAR/.needs-setup" ]] && echo true || echo false)" --arg admin "$(env_get ADMIN_USER)" --arg pkgadmin "$PKG_ADMIN" --arg unfdir "$UNF_DIR" \
    '{up: ($up == "1"), url: $url, lan_ip: $ip, setup_pending: $pending, admin: $admin, pkg_admin: $pkgadmin,
      inform: {host: $host, port: ($iport | tonumber? // 8080), url: ("http://" + $host + ":" + $iport + "/inform"), stun: ($stun | tonumber? // 3478), discovery: ($disc | tonumber? // 10001),
               portal: ($portal == "1"), portal_http: ($ph | tonumber? // 8880), portal_https: ($phs | tonumber? // 8843)},
      devices: ($dev.devices // []), sites: ($dev.sites // []), sysinfo: ($dev.sysinfo // {}), devices_at: ($dev.at // 0), api_error: ($dev.error // ""),
      users: $adm, unf: $unf, unf_dir: $unfdir, memory: $mem, image: $image, db_image: $dbimage, tls: $tls, tls_source: $tlss, cert: $cert, alerts: ($alerts == "1")}'
}

# ------------------------------------------------------------ DSM notifications: a device offline, a device waiting
check_devices() {
  local d now_s told="$VAR/.down-told" pend="$VAR/.pending-told" line mac name model since
  d=$(devices_json); jq -e '.devices' <<< "$d" >/dev/null 2>&1 || return 0
  touch "$told" "$pend"; now_s=$(now)
  # Adopted, offline (state 0) for 10 minutes: told once per outage; back online clears it.
  while IFS=$'\t' read -r mac name model since; do
    [[ -n "$mac" ]] || continue
    grep -qx "$mac" "$told" && continue
    (( since > 0 && now_s - since >= 600 )) || continue
    echo "$mac" >> "$told"
    [[ "$(env_get DOWN_ALERTS)" == 1 ]] && notify devicedown 0 "$name" "$model"
  done < <(jq -r '.devices[] | select(.adopted and .state == 0) | [.mac, (if .name == "" then .mac else .name end), .model_name, .last_seen] | @tsv' <<< "$d" 2>/dev/null)
  jq -r '.devices[] | select(.adopted and .state != 0) | .mac' <<< "$d" 2>/dev/null | while read -r mac; do sed -i "/^$mac\$/d" "$told"; done
  # Waiting for adoption: told once per device.
  while IFS=$'\t' read -r mac model; do
    [[ -n "$mac" ]] || continue; grep -qx "$mac" "$pend" && continue
    echo "$mac" >> "$pend"; notify devicepending 0 "$model" "$mac"
  done < <(jq -r '.devices[] | select(.adopted | not) | [.mac, .model_name] | @tsv' <<< "$d" 2>/dev/null)
  true
}

# ------------------------------------------------------------ UniFi's autobackups, copied into the share
copy_unf() {   # → MSG; new .unf files go to the share's autobackups/, the newest $UNF_KEEP are kept there
  local dir="$APP/$UNF_DIR" n0 n1 f
  mkdir -p "$dir"; chown "$HOST_UID:$HOST_GID" "$dir" 2>/dev/null || true
  n0=$(find "$dir" -maxdepth 1 -name '*.unf' 2>/dev/null | wc -l)
  in_volume config ro -- 'cd /vol/data/backup/autobackup 2>/dev/null && ls *.unf >/dev/null 2>&1 && tar -cf - *.unf; true' </dev/null 2>>"$LOG" \
    | tar -C "$dir" --skip-old-files -xf - 2>/dev/null; true
  find "$dir" -maxdepth 1 -type f -exec chown "$HOST_UID:$HOST_GID" {} + -exec chmod 640 {} + 2>/dev/null || true
  for f in $(ls -1t "$dir"/*.unf 2>/dev/null | tail -n +$(( UNF_KEEP + 1 ))); do rm -f "$f"; done
  n1=$(find "$dir" -maxdepth 1 -name '*.unf' 2>/dev/null | wc -l)
  rm -f "$VAR/.unf.json"; touch "$VAR/.unf-copied"
  MSG="UniFi's autobackups are in the unifi shared folder, $UNF_DIR/ ($n1 file$( (( n1 == 1 )) || echo s), $(( n1 > n0 ? n1 - n0 : 0 )) new)."
}

# ------------------------------------------------------------ updates: the pinned release, moved on when you say so
# These two replace the core's: its check reads Docker Hub only, and its update prunes every unused image on the NAS.
check_image_update() {
  local cur latest tok code avail=false note=""
  cur=$(uf_tag)
  [[ -n "$cur" ]] || { IMAGE_UPDATE=$(jq -nc --argjson at "$(now)" --arg img "$(env_get UNIFI_IMAGE)" '{checked: $at, image: $img, error: "the image is not a linuxserver.io release the package knows"}'); return 0; }
  latest=$(curl -sSI --max-time 15 https://github.com/linuxserver/docker-unifi-network-application/releases/latest 2>/dev/null | tr -d '\r' | awk 'tolower($1) == "location:" {print $2}' | sed -n 's|.*/releases/tag/\([0-9][0-9.]*-ls[0-9]*\)$|\1|p' | tail -n 1)
  [[ "$latest" =~ ^[0-9]+\.[0-9]+\.[0-9]+-ls[0-9]+$ ]] || latest=$(curl -fsS --max-time 15 https://api.github.com/repos/linuxserver/docker-unifi-network-application/releases/latest 2>/dev/null | jq -r '.tag_name // ""' 2>/dev/null)
  if ! [[ "$latest" =~ ^[0-9]+\.[0-9]+\.[0-9]+-ls[0-9]+$ ]]; then
    IMAGE_UPDATE=$(jq -nc --argjson at "$(now)" --arg img "$(env_get UNIFI_IMAGE)" --arg cur "$cur" '{checked: $at, image: $img, current: $cur, error: "GitHub could not be reached"}'); return 0; fi
  if newer "$latest" "$cur"; then
    tok=$(curl -fsS --max-time 15 "https://ghcr.io/token?scope=repository:linuxserver/unifi-network-application:pull" 2>/dev/null | jq -r '.token // ""' 2>/dev/null)
    code=$(curl -s -o /dev/null -I -w '%{http_code}' --max-time 15 -H "Authorization: Bearer $tok" \
      -H "Accept: application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.docker.distribution.manifest.v2+json" \
      "https://ghcr.io/v2/linuxserver/unifi-network-application/manifests/$latest" 2>/dev/null)
    if [[ "$code" == 200 ]]; then avail=true; else note="UniFi ${latest%-ls*} is out, but its image isn't published yet"; fi
    [[ "$avail" == true && "${latest%%.*}" != "${cur%%.*}" ]] && note="A new major version: read Ubiquiti's release notes before updating"
  fi
  IMAGE_UPDATE=$(jq -nc --argjson at "$(now)" --arg img "$(env_get UNIFI_IMAGE)" --arg cur "$cur" --arg latest "$latest" --argjson avail "$avail" --arg note "$note" \
    '{checked: $at, image: $img, available: $avail, current: $cur, latest: $latest, version: ($latest | sub("-ls[0-9]+$"; "")), note: $note, remote: $latest, local: $cur,
      page: ("https://github.com/linuxserver/docker-unifi-network-application/releases/tag/" + $latest)}')
}
update_app() {   # to the newest release check_image_update found (never a value from the request)
  local cur latest old img
  cur=$(uf_tag); latest=$(jq -r '.latest // ""' <<< "$IMAGE_UPDATE" 2>/dev/null)
  if ! [[ -n "$cur" && "$latest" =~ ^[0-9]+\.[0-9]+\.[0-9]+-ls[0-9]+$ ]] || ! newer "$latest" "$cur" || ! jq -e '.available == true' <<< "$IMAGE_UPDATE" >/dev/null 2>&1; then
    MSG="There's no newer UniFi Network to install — look for updates first."; return 1; fi
  old=$(env_get UNIFI_IMAGE); img="$UF_REPO:$latest"
  say "updating UniFi Network ${cur%-ls*} → ${latest%-ls*} ($latest) — first, a backup"
  make_backup pre-update || { MSG="Couldn't back up first, so UniFi wasn't updated."; return 1; }
  record_backup true "$MADE"
  say "pulling $img"
  docker pull "$img" 2>&1 | grep -vE '^\s*$' | tail -n 5 | tee -a "$LOG" >/dev/null
  docker image inspect "$img" >/dev/null 2>&1 || { MSG="UniFi ${latest%-ls*} couldn't be downloaded; it stays at ${cur%-ls*}."; return 1; }
  env_set UNIFI_IMAGE "$img"
  [[ "$(env_get TLS_SOURCE)" =~ ^(dsm|self)$ ]] && keystore_import
  compose up -d --remove-orphans 2>&1 | tee -a "$LOG" >/dev/null || { MSG="UniFi ${latest%-ls*} didn't start — see the log. The state from before is in $MADE."; return 1; }
  wait_ready 1200 || { MSG="UniFi ${latest%-ls*} hasn't answered yet — it may still be migrating its database; see the log. The state from before is in $MADE."; return 1; }
  [[ "$old" != "$img" ]] && { docker image rm "$old" >> "$LOG" 2>&1 && say "removed the old image $old" || true; }
  rm -f "$VAR/.models.json" "$VAR/.devices.json"; check_image_update
  MSG="UniFi Network is updated to $(app_version). The state from before is in $MADE."
}

app_tick() {
  first_setup 1
  svc_up server || return 0
  if ! fresh "$VAR/.dev-check" 120; then touch "$VAR/.dev-check"; app_health && { [[ -s "$UF_JAR" ]] || ensure_api; } && check_devices; fi
  fresh "$VAR/.unf-copied" 86400 || { copy_unf; say "$MSG"; }
  fresh "$VAR/.cert-check" 86400 && return 0; touch "$VAR/.cert-check"
  if [[ "$(env_get TLS)" == dsm ]]; then
    tls_refresh_dsm config
    [[ "$CERT_REFRESH" == changed ]] && keystore_import && { docker restart "$US" >> "$LOG" 2>&1 || true; }
  fi
  return 0
}

# ------------------------------------------------------------ settings, logs, storage, backups, report
app_settings() {   # HTTPS, and the address: UniFi's port only speaks HTTPS
  local old; old=$(env_get TLS_SOURCE)
  [[ -n "${TLS:-}" ]] && env_set TLS "$TLS"
  local url; url=$(env_get APP_URL)
  [[ "$(env_get SSL_PROXY)" != 1 && "$url" == http://* ]] && { env_set APP_URL "https://${url#http://}"; say "the address is https://${url#http://} — UniFi serves HTTPS itself"; }
  props_write
  tls_setup || say "✗ $MSG"
  [[ "$(env_get TLS_SOURCE)" != "$old" || "$(env_get TLS)" == dsm ]] && TLS_RESTART=1
  rm -f "$UF_JAR"
  return 0
}
app_after_settings() {
  (( TLS_RESTART )) || return 0
  TLS_RESTART=0; say "restarting UniFi for its certificate"
  docker restart "$US" >> "$LOG" 2>&1; wait_ready 600 || true
}
app_logs() {   # UniFi's own server log (the container's log is only its start-up)
  docker exec "$US" tail -n 300 /config/logs/server.log > "$VAR/logs/unifi.log.tmp" 2>/dev/null || echo "UniFi's server log isn't there yet." > "$VAR/logs/unifi.log.tmp"
  for_window "$VAR/logs/unifi.log"
}
app_storage() {
  in_volume config ro -- 'cd /vol; printf "autobackups\t%s\n" "$(du -sm data/backup 2>/dev/null | cut -f1)"; printf "logs\t%s\n" "$(du -sm logs 2>/dev/null | cut -f1)"; printf "data\t%s\n" "$(du -sm --exclude=backup data 2>/dev/null | cut -f1)"; true' </dev/null 2>/dev/null \
    | { cat; printf 'copies\t%s\n' "$(du -sm "$APP/$UNF_DIR" 2>/dev/null | cut -f1)"; } \
    | jq -R -s -c 'split("\n") | map(select(length > 0) | split("\t") | {key: .[0], value: (.[1] | tonumber? // 0)}) | from_entries' 2>/dev/null || echo "{}"
}
app_backup() {   # dir — UniFi paused (not stopped) while MongoDB is dumped and its data folder copied, so the two match
  local paused=0 t0 ok=0
  db_ready || db_up || { say "✗ MongoDB isn't running, so there's nothing consistent to back up"; return 1; }
  if svc_up server; then docker pause "$US" >> "$LOG" 2>&1 && paused=1; fi
  t0=$(now)
  docker exec "$UD" sh -c 'exec mongodump --quiet -u root -p "$MONGO_INITDB_ROOT_PASSWORD" --authenticationDatabase admin --archive --gzip' > "$1/mongo.archive.gz" 2>>"$LOG" \
    && gzip -t "$1/mongo.archive.gz" 2>/dev/null && [[ -s "$1/mongo.archive.gz" ]] \
    && in_volume config ro -- 'tar -C /vol -czf - --exclude="./logs/*" --exclude="./data/db" .' > "$1/config.tar.gz" 2>>"$LOG" </dev/null \
    && tar -tzf "$1/config.tar.gz" >/dev/null 2>&1 && ok=1
  (( paused )) && { docker unpause "$US" >> "$LOG" 2>&1 || true; say "UniFi was paused for $(( $(now) - t0 )) s while its data was copied"; }
  (( ok )) || { say "✗ UniFi's database or data folder couldn't be copied"; return 1; }
  printf 'db_image=%s\nunifi_image=%s\n' "$(env_get DB_IMAGE)" "$(env_get UNIFI_IMAGE)" > "$1/IMAGES"
}
app_restore() {   # dir — the core has stopped the containers
  [[ -s "$1/mongo.archive.gz" && -s "$1/config.tar.gz" ]] || { MSG="That backup has no UniFi database or data folder."; return 1; }
  in_volume config rw -- 'find /vol -mindepth 1 -delete && tar -C /vol -xzf - && mkdir -p /vol/logs && chown -R 1000:1000 /vol' < "$1/config.tar.gz" 2>>"$LOG" || { MSG="UniFi's data folder didn't unpack."; return 1; }
  props_write; env_set TLS_SOURCE "$(tls_source_in config | tr -cd 'a-z')"; [[ -n "$(env_get TLS_SOURCE)" ]] || env_set TLS_SOURCE own
  db_up || { MSG="MongoDB didn't start for the restore."; return 1; }
  # UniFi's databases only: MongoDB's own users stay as this install made them (their passwords are in .env).
  docker exec -i "$UD" sh -c 'exec mongorestore --quiet -u root -p "$MONGO_INITDB_ROOT_PASSWORD" --authenticationDatabase admin --drop --nsInclude "unifi*" --archive --gzip' < "$1/mongo.archive.gz" >> "$LOG" 2>&1 \
    || { MSG="UniFi's database didn't load — see the log."; return 1; }
  rm -f "$VAR/.needs-setup" "$UF_JAR" "$VAR/.devices.json" "$VAR/.admins.json" "$VAR/.unf.json" "$VAR/.down-told"
}
app_report() {
  local d; d=$(devices_json); jq -e '.devices' <<< "$d" >/dev/null 2>&1 || d='{}'
  echo "== UniFi: $(app_version) ($(env_get UNIFI_IMAGE)); MongoDB: $(env_get DB_IMAGE); CPU $(uname -m)$(grep -qw avx /proc/cpuinfo 2>/dev/null && echo ', AVX')"
  echo "== devices: $(jq '.devices | length' <<< "$d" 2>/dev/null) ($(jq '[.devices[]? | select(.state == 1)] | length' <<< "$d" 2>/dev/null) online, $(jq '[.devices[]? | select(.adopted | not)] | length' <<< "$d" 2>/dev/null) waiting); sites: $(jq '.sites | length' <<< "$d" 2>/dev/null)"
  jq -r '.devices[]? | "   \(.model_name) (\(.model)), state \(.state), firmware \(.version)\(if .upgradable then " → " + .upgrade_to else "" end), \(.clients) clients"' <<< "$d" 2>/dev/null
  echo "== ports: web $(env_get HTTP_PORT), inform $(env_get INFORM_PORT), STUN $(env_get STUN_PORT)/udp, discovery $(env_get DISC_PORT)/udp, guest portal $([[ "$(env_get PORTAL)" == 1 ]] && echo "$(env_get PORTAL_HTTP)/$(env_get PORTAL_HTTPS)" || echo off)"
  echo "== inform: $(inform_url); UniFi says: $(jq -c '.sysinfo | {inform_port, hostname}' <<< "$d" 2>/dev/null)"
  echo "== memory: Java heap $(env_get JAVA_HEAP) MB, MongoDB cache $(env_get DB_CACHE) GB; $(jq -c . <<< "$(memory_json)" 2>/dev/null)"
  echo "== HTTPS: $(env_get TLS) (in use: $(env_get TLS_SOURCE))"
  echo "== UniFi's autobackups: $(jq -c '{files: (.files | length), copies}' <<< "$(unf_json)" 2>/dev/null)"
  echo "== administrators: $(jq 'length' <<< "$(admins_json)" 2>/dev/null)"
  echo; echo "== UniFi's server log (last 80 lines)"; docker exec "$US" tail -n 80 /config/logs/server.log 2>/dev/null
  :
}
app_wipe() { docker volume rm "${PKG_NAME}_dbinit" >> "$LOG" 2>&1 || true; }
app_extra_ports() {   # beside the web port, in DSM's firewall list
  printf '[%s_inform]\ntitle="%s: device inform"\ndesc="%s"\nport_forward="no"\ndst.ports="%s/tcp"\n' "$PKG_NAME" "$PKG_TITLE" "$PKG_TITLE" "$(env_get INFORM_PORT)"
  printf '[%s_stun]\ntitle="%s: STUN"\ndesc="%s"\nport_forward="no"\ndst.ports="%s/udp"\n' "$PKG_NAME" "$PKG_TITLE" "$PKG_TITLE" "$(env_get STUN_PORT)"
  printf '[%s_discovery]\ntitle="%s: device discovery"\ndesc="%s"\nport_forward="no"\ndst.ports="%s/udp"\n' "$PKG_NAME" "$PKG_TITLE" "$PKG_TITLE" "$(env_get DISC_PORT)"
  [[ "$(env_get PORTAL)" == 1 ]] && printf '[%s_portal]\ntitle="%s: guest portal"\ndesc="%s"\nport_forward="no"\ndst.ports="%s,%s/tcp"\n' "$PKG_NAME" "$PKG_TITLE" "$PKG_TITLE" "$(env_get PORTAL_HTTP)" "$(env_get PORTAL_HTTPS)"
  true
}

# ------------------------------------------------------------ the window's actions
ports_in_use() {   # → the ports something other than UniFi listens on, on this NAS (the setup container shares its network)
  local ours; ours=$(docker port "$US" 2>/dev/null | sed -n 's/.*:\([0-9]*\)$/\1/p' | sort -u)
  ss -Hlntu 2>/dev/null | awk '{print $5}' | sed 's/.*://' | grep -E '^[0-9]+$' | sort -un | grep -vxF -f <(printf '%s\n' $ours 0) || true
}
recreate() { compose up -d --remove-orphans >> "$LOG" 2>&1 && wait_ready "${1:-900}"; }
app_act() {   # action (request vars are set)
  local hash out p taken old name list
  case "$1" in
    ports)
      old=$(env_get INFORM_PORT)
      list="$(env_get HTTP_PORT) ${INFORM_PORT:-} ${STUN_PORT:-} ${DISC_PORT:-}"; [[ "${PORTAL:-0}" == 1 ]] && list="$list ${PORTAL_HTTP:-} ${PORTAL_HTTPS:-}"
      [[ -n "${INFORM_PORT:-}" && -n "${STUN_PORT:-}" && -n "${DISC_PORT:-}" ]] || { MSG="Give every port."; return 1; }
      [[ "$(tr ' ' '\n' <<< "$list" | grep -c .)" == "$(tr ' ' '\n' <<< "$list" | grep . | sort -u | wc -l)" ]] || { MSG="Each port must be different (the web port is $(env_get HTTP_PORT))."; return 1; }
      taken=$(ports_in_use)
      for p in $list; do grep -qx "$p" <<< "$taken" && { MSG="Port $p is already used by something else on this Synology."; return 1; }; done
      env_set INFORM_PORT "$INFORM_PORT"; env_set STUN_PORT "$STUN_PORT"; env_set DISC_PORT "$DISC_PORT"; env_set PORTAL "${PORTAL:-0}"
      [[ -n "${PORTAL_HTTP:-}" ]] && env_set PORTAL_HTTP "$PORTAL_HTTP"; [[ -n "${PORTAL_HTTPS:-}" ]] && env_set PORTAL_HTTPS "$PORTAL_HTTPS"
      portal_env; props_write || { MSG="UniFi's settings file couldn't be written."; return 1; }
      recreate 900 || { MSG="UniFi didn't come back with the new ports — see the log."; return 1; }
      sync_dsm; rm -f "$VAR/.devices.json"
      MSG="Ports saved: inform $(env_get INFORM_PORT), STUN $(env_get STUN_PORT)/udp, discovery $(env_get DISC_PORT)/udp$([[ "$(env_get PORTAL)" == 1 ]] && echo ", guest portal $(env_get PORTAL_HTTP) and $(env_get PORTAL_HTTPS)")."
      [[ "$old" != "$(env_get INFORM_PORT)" ]] && MSG="$MSG Devices adopted before keep informing to port $old: run set-inform $(inform_url) on each (Adopt tab)." ;;
    informhost)
      old=$(env_get INFORM_HOST)
      [[ "$INFORM_HOST" != "$old" ]] || { MSG="Devices already inform to $old."; return 0; }
      svc_up db || { MSG="MongoDB isn't running."; return 1; }
      say "devices will inform to $INFORM_HOST (was $old): UniFi stops while its setting is changed"
      compose stop -t 60 server >> "$LOG" 2>&1 || true
      out=$(printf 'db.setting.updateOne({key: "super_identity"}, {$set: {hostname: "%s"}}); db.setting.updateOne({key: "super_mgmt"}, {$set: {override_inform_host: true}}); print("@@ok");\n' "$INFORM_HOST" | mdb)
      [[ "$out" == ok ]] || { compose up -d server >> "$LOG" 2>&1; MSG="UniFi's setting couldn't be changed — see the log."; return 1; }
      env_set INFORM_HOST "$INFORM_HOST"; props_write
      recreate 900 || { MSG="UniFi didn't come back — see the log."; return 1; }
      rm -f "$VAR/.devices.json"
      MSG="Devices are told to inform to $(inform_url). Devices that can still reach $old move over by themselves; any that can't need set-inform (Adopt tab)." ;;
    memory)
      env_set JAVA_HEAP "${JAVA_HEAP:-$(env_get JAVA_HEAP)}"; env_set DB_CACHE "${DB_CACHE:-$(env_get DB_CACHE)}"
      recreate 900 || { MSG="UniFi didn't come back with the new memory settings — see the log."; return 1; }
      rm -f "$VAR/.mem.json"
      MSG="UniFi now has $(env_get JAVA_HEAP) MB of Java heap and MongoDB a $(env_get DB_CACHE) GB cache." ;;
    copyunf) copy_unf ;;
    adminpw)   # a new password through UniFi's database, as Ubiquiti's own recovery steps do it
      name=$(printf '%s\nvar a = db.admin.findOne({_id: ObjectId("%s")}); print("@@" + (a ? a.name : ""));\n' "$JS_OID" "$ADMIN_ID" | mdb)
      [[ -n "$name" ]] || { MSG="There's no such administrator in UniFi."; return 1; }
      if [[ "$name" == "$PKG_ADMIN" ]]; then rm -f "$UF_JAR"; ensure_api && MSG="The package's read-only account signs in again." || { MSG="The package's account couldn't be put right — see the log."; return 1; }; return 0; fi
      p=$(strong_password); hash=$(openssl passwd -6 "$p")
      out=$(printf 'var r = db.admin.updateOne({_id: ObjectId("%s")}, {$set: {x_shadow: "%s", requires_new_password: false}}); print("@@" + (r.matchedCount !== undefined ? r.matchedCount : r.nMatched));\n' "$ADMIN_ID" "$hash" | mdb)
      [[ "$out" == 1 ]] || { MSG="UniFi's database didn't take the new password."; return 1; }
      leave_secret "UniFi Network ($name)" "$p" maintenance; rm -f "$VAR/.admins.json"
      MSG="The new password for $name is shown below, once." ;;
    refreshcert)
      [[ "$(env_get TLS)" == dsm ]] || { MSG="HTTPS uses UniFi's own certificate — choose DSM's on the Site address tab first."; return 1; }
      tls_prepare config && keystore_import || { MSG="The certificate couldn't be put in place — see the log."; return 1; }
      docker restart "$US" >> "$LOG" 2>&1; wait_ready 600 || { MSG="UniFi hasn't come back yet — see the log."; return 1; }
      MSG="UniFi uses DSM's certificate as it is now." ;;
    *) MSG="Unknown request."; return 1 ;;
  esac
}

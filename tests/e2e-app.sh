# UniFi Network's steps for the chassis harness (chassis/tests/e2e.sh <appdir> act).
# There are no UniFi devices here: the controller side is tested for real —
# the first-run setup through UniFi's API, the package's read-only account,
# the ports UniFi tells devices, the inform host, memory, UniFi's own
# autobackups, new passwords, HTTPS, a backup and restore and the pinned update —
# and two devices are put into UniFi's database to see the Devices and Adopt tabs fill.
# Ports: e2e uses web 8444 (E2E_PORT), inform 8081 and discovery 11001/udp; 8443, 8080 and 10001 are taken on the test box.
app_e2e_answers() { printf "INFORM_PORT='8081'\nSTUN_PORT='3478'\nDISC_PORT='11001'\nADMIN_USER='admin'\nADMIN_EMAIL='admin@example.com'\nCOUNTRY='GB'\nTLS='own'\nJAVA_HEAP='512'\nDB_CACHE='0.25'\n"; }
wait_for() { local i; for i in $(seq 1 "$2"); do touch "$VAR/watching"; jq -e "$1" "$VAR/status.json" >/dev/null 2>&1 && return 0; sleep 1; done; return 1; }
secret() { local s; s=$(jq -r --arg k "${1:-devices}" 'select(.kind == $k) | .password' "$VAR/secret.json" 2>/dev/null); rm -f "$VAR/secret.json"; printf '%s' "$s"; }
UF() { echo "https://127.0.0.1:$PORT"; }
JAR=""
login() { rm -f "$JAR"; curl -sk -c "$JAR" -H 'Content-Type: application/json' -d "$(jq -cn --arg u "$1" --arg p "$2" '{username: $u, password: $p}')" "$(UF)/api/login" | jq -r '.meta.rc // "?"'; }
uf() { local m=$1 p=$2 d=${3:-} csrf; csrf=$(awk '$6 == "csrf_token" {print $7}' "$JAR" 2>/dev/null | tail -n 1)
  if [[ -n "$d" ]]; then curl -sk -b "$JAR" -c "$JAR" -X "$m" -H 'Content-Type: application/json' ${csrf:+-H "X-Csrf-Token: $csrf"} -d "$d" "$(UF)$p"; else curl -sk -b "$JAR" -c "$JAR" -X "$m" "$(UF)$p"; fi; }
mongo() { docker exec -i unifi-db sh -c 'exec mongosh --quiet --norc -u root -p "$MONGO_INITDB_ROOT_PASSWORD" --authenticationDatabase admin unifi' | sed 's/^\(unifi> \)*//'; }
envv() { docker exec "$NAME" sh -c "grep -E '^$1=' '$APP/.env' | tail -n 1 | cut -d= -f2-"; }
props() { docker run --rm -v unifi_config:/c:ro alpine cat /c/data/system.properties 2>/dev/null; }
told() { grep -cE "told DSM: $1|notification \($1\)" "$VAR/package.log"; }
app_e2e_act() {
  local fail=0 pw pw2 aid pkgpw b2 i n0 cron mac1 mac2 cert t0
  JAR=$E2E/owner.jar
  log "unifi"
  echo "  (status: $(curl -sk "$(UF)/status" | jq -c .meta), version $(jq -r .version "$VAR/status.json"), db $(envv DB_IMAGE))"
  # The first-run wizard, through UniFi's API: your administrator, shown once.
  pw=$(secret devices)
  [[ ${#pw} -ge 20 ]] && echo "  ok   a one-time password was left for the window" || { echo "  FAIL no password secret"; fail=1; }
  [[ "$(login admin "$pw")" == ok ]] && echo "  ok   it signs in to UniFi as admin" || { echo "  FAIL owner sign-in"; fail=1; }
  uf GET /api/self | jq -e '.data[0] | .name == "admin" and .email == "admin@example.com"' >/dev/null && echo "  ok   admin is UniFi's administrator, with the wizard's email (is_super: $(uf GET /api/self | jq -c .data[0].is_super))" || { echo "  FAIL self: $(uf GET /api/self | head -c 300)"; fail=1; }
  uf GET /api/s/default/get/setting | jq -e '[.data[] | select(.key == "super_identity" or .key == "super_mgmt" or .key == "country" or .key == "locale")] | (map(select(.key == "super_identity"))[0].hostname == "127.0.0.1") and (map(select(.key == "super_mgmt"))[0].override_inform_host == true) and (map(select(.key == "super_mgmt"))[0].autobackup_enabled == true) and (map(select(.key == "locale"))[0].timezone == "Europe/London")' >/dev/null \
    && uf GET /api/s/default/get/setting/super_mgmt | jq -e '.data[0].autobackup_cron_expr == "0 1 * * 1"' >/dev/null && echo "  ok   UniFi's settings: inform host 127.0.0.1 (overridden), autobackups on (weekly), Europe/London, country $(uf GET /api/s/default/get/setting/country | jq -c '.data[0].code')" || { echo "  FAIL settings: $(uf GET /api/s/default/get/setting | jq -c '[.data[] | select(.key == "super_identity" or .key == "super_mgmt" or .key == "country" or .key == "locale")]' | head -c 600)"; fail=1; }
  [[ "$(uf GET /api/s/default/get/setting/country | jq -r '.data[0].code')" == 826 ]] && echo "  ok   the country is the United Kingdom (826), from GB" || { echo "  FAIL country"; fail=1; }
  # The package's account: read-only.
  wait_for '.app.users | length == 2' 60 && wait_for '([.app.users[] | select(.name == "dsm-package")][0].roles == ["readonly"]) and ([.app.users[] | select(.name == "admin")][0].super)' 5 && echo "  ok   the window lists 2 administrators: admin (super administrator) and dsm-package (read-only)" || { echo "  FAIL users: $(jq -c .app.users "$VAR/status.json")"; fail=1; }
  JAR=$E2E/pkg.jar; pkgpw=$(envv PKG_API_PASS)
  [[ "$(login dsm-package "$pkgpw")" == ok ]] && [[ "$(uf POST /api/s/default/set/setting/super_identity '{"name":"x"}' | jq -r .meta.rc)" == error ]] && echo "  ok   dsm-package signs in, and UniFi refuses it a change" || { echo "  FAIL pkg account"; fail=1; }
  JAR=$E2E/owner.jar
  # The ports UniFi tells devices, and what's published.
  props | grep -qx 'unifi.http.port=8081' && props | grep -qx "unifi.https.port=$PORT" && props | grep -qx 'system_ip=127.0.0.1' && echo "  ok   system.properties: inform 8081, web $PORT, system_ip" || { echo "  FAIL props: $(props | grep -v '^#' | paste -sd' ')"; fail=1; }
  wait_for ".app.sysinfo.inform_port == 8081 and .app.sysinfo.https_port == $PORT" 60 && echo "  ok   UniFi says: inform port 8081, web $PORT (read by dsm-package)" || { echo "  FAIL sysinfo: $(jq -c .app.sysinfo "$VAR/status.json")"; fail=1; }
  docker port unifi-server | sort | paste -sd' ' | grep -q "3478/udp -> 0.0.0.0:3478" && docker port unifi-server 8081 | grep -q 8081 && docker port unifi-server 10001/udp | grep -q 11001 && docker port unifi-server 8880 | grep -q '^127.0.0.1:' \
    && echo "  ok   published: $(docker port unifi-server | grep -v '::' | sed 's/ -> /→/' | paste -sd' ')" || { echo "  FAIL ports: $(docker port unifi-server | paste -sd' ')"; fail=1; }
  jq -e '.app.inform.url == "http://127.0.0.1:8081/inform"' "$VAR/status.json" >/dev/null && echo "  ok   the Adopt tab's inform address: $(jq -r .app.inform.url "$VAR/status.json")" || { echo "  FAIL inform url"; fail=1; }
  # Two devices put into UniFi's database (no hardware here): one adopted and offline for an hour, one waiting.
  mac1=f4:e2:c6:00:00:01; mac2=f4:e2:c6:00:00:02; n0=$(told devicedown); local p0; p0=$(told devicepending)
  docker stop -t 60 unifi-server >/dev/null   # UniFi reads its devices as it starts
  printf 'var s = db.site.findOne({name: "default"}); var t = Math.floor(Date.now() / 1000);
    db.device.insertOne({mac: "%s", ip: "192.168.1.31", model: "U7PG2", type: "uap", name: "Office AP", adopted: true, site_id: String(s._id), version: "6.6.77.15402", state: 0, last_seen: t - 3600, cfgversion: "1", serial: "F4E2C6000001"});
    db.device.insertOne({mac: "%s", ip: "192.168.1.32", model: "UAL6", type: "uap", adopted: false, site_id: String(s._id), version: "6.6.77.15402", state: 2, last_seen: t, serial: "F4E2C6000002"}); print("ok");\n' "$mac1" "$mac2" | mongo >/dev/null
  docker start unifi-server >/dev/null; for i in $(seq 1 120); do [[ "$(curl -sk "$(UF)/status" | jq -r .meta.up)" == true ]] && break; sleep 3; done
  for i in $(seq 1 60); do (( $(told devicedown) > n0 )) && break; touch "$VAR/watching"; sleep 3; done
  wait_for "any(.app.devices[]; .mac == \"$mac1\")" 60; wait_for "any(.app.devices[]; .mac == \"$mac2\")" 30
  jq -e --arg m "$mac1" '.app.devices[] | select(.mac == $m) | .name == "Office AP" and .model_name == "Access Point AC Pro" and .adopted and .state == 0' "$VAR/status.json" >/dev/null \
    && echo "  ok   Devices: Office AP (Access Point AC Pro, from UniFi's own model list), offline" || { echo "  FAIL devices: $(jq -c .app.devices "$VAR/status.json")"; fail=1; }
  jq -e --arg m "$mac2" 'any(.app.devices[]; .mac == $m and (.adopted | not))' "$VAR/status.json" >/dev/null && echo "  ok   Adopt: the U6 Lite is listed as waiting" || echo "  note UniFi doesn't list a device put in its database as waiting (it lists ones that inform): $(jq -c '[.app.devices[] | {mac, adopted, state}]' "$VAR/status.json")"
  (( $(told devicedown) == n0 + 1 )) && echo "  ok   offline for an hour: DSM was told once (only attempted: no DSM here)" || { echo "  FAIL devicedown: $(told devicedown) vs $n0"; fail=1; }
  # Ports: one taken on this machine is refused; then inform 8082 and the guest portal on, and back.
  request "ACTION='ports'" "INFORM_PORT='8080'" "STUN_PORT='3478'" "DISC_PORT='11001'" "PORTAL='0'" "PORTAL_HTTP='8880'" "PORTAL_HTTPS='8843'" >/dev/null && { echo "  FAIL a port in use was accepted"; fail=1; } || echo "  ok   a port in use is refused: $(jq -r .last.message "$VAR/status.json")"
  request "ACTION='ports'" "INFORM_PORT='8082'" "STUN_PORT='3478'" "DISC_PORT='11001'" "PORTAL='1'" "PORTAL_HTTP='8880'" "PORTAL_HTTPS='8843'" || fail=1
  docker port unifi-server 8082 | grep -q '0.0.0.0:8082' && docker port unifi-server 8880 | grep -q '0.0.0.0:8880' && props | grep -qx 'unifi.http.port=8082' && wait_for '.app.sysinfo.inform_port == 8082' 60 \
    && echo "  ok   inform on 8082 and the guest portal published; UniFi says 8082; the message: $(jq -r .last.message "$VAR/status.json" | cut -c1-140)…" || { echo "  FAIL ports 8082: $(docker port unifi-server | paste -sd' ')"; fail=1; }
  request "ACTION='ports'" "INFORM_PORT='8081'" "STUN_PORT='3478'" "DISC_PORT='11001'" "PORTAL='0'" "PORTAL_HTTP='8880'" "PORTAL_HTTPS='8843'" || fail=1
  # The inform host: a name, then back.
  request "ACTION='informhost'" "INFORM_HOST='nas.example.lan'" || fail=1
  [[ "$(login admin "$pw")" == ok ]] && [[ "$(uf GET /api/s/default/get/setting/super_identity | jq -r '.data[0].hostname')" == nas.example.lan ]] && ! props | grep -q '^system_ip=' \
    && wait_for '.app.inform.url == "http://nas.example.lan:8081/inform"' 10 && echo "  ok   inform host nas.example.lan: in UniFi's settings and the Adopt tab" || { echo "  FAIL informhost: $(uf GET /api/s/default/get/setting/super_identity | head -c 200)"; fail=1; }
  request "ACTION='informhost'" "INFORM_HOST='127.0.0.1'" || fail=1
  # Memory.
  request "ACTION='memory'" "JAVA_HEAP='384'" "DB_CACHE='0.5'" || fail=1
  docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' unifi-server | grep -qx 'MEM_LIMIT=384' && docker inspect -f '{{join .Config.Cmd " "}}' unifi-db | grep -q 'wiredTigerCacheSizeGB 0.5' \
    && echo "  ok   memory: Java heap 384 MB, MongoDB cache 0.5 GB" || { echo "  FAIL memory"; fail=1; }
  wait_for '.app.memory.server_mb > 0 and .app.memory.db_mb > 0' 60 && echo "  ok   the Memory tab: $(jq -c '.app.memory' "$VAR/status.json")" || { echo "  FAIL memory tab: $(jq -c .app.memory "$VAR/status.json")"; fail=1; }
  request "ACTION='memory'" "JAVA_HEAP='512'" "DB_CACHE='0.25'" || fail=1
  # UniFi's own autobackup: made every minute for this test, copied into the share, offered for download.
  [[ "$(login admin "$pw")" == ok ]]; cron=$(uf GET /api/s/default/get/setting/super_mgmt | jq -r '.data[0].autobackup_cron_expr // ""')
  uf POST /api/s/default/set/setting/super_mgmt '{"autobackup_cron_expr": "* * * * *"}' >/dev/null
  for i in $(seq 1 60); do docker exec unifi-server sh -c 'ls /config/data/backup/autobackup/*.unf' >/dev/null 2>&1 && break; sleep 5; done
  [[ "$(login admin "$pw")" == ok ]]; uf POST /api/s/default/set/setting/super_mgmt "$(jq -cn --arg c "${cron:-30 0 1 * *}" '{autobackup_cron_expr: $c}')" >/dev/null
  request "ACTION='copyunf'" || fail=1
  local unf; unf=$(ls "$APP/autobackups"/*.unf 2>/dev/null | head -n 1 || docker exec "$NAME" sh -c "ls '$APP'/autobackups/*.unf" | head -n 1)
  [[ -n "$unf" ]] && wait_for '.app.unf.files | length >= 1 and .[0].copied' 70 && echo "  ok   UniFi made an autobackup ($(jq -r '.app.unf.files[0] | "\(.name), \(.size) bytes"' "$VAR/status.json")); copied into the share: $(basename "$unf")" || { echo "  FAIL autobackup: $(jq -c .app.unf "$VAR/status.json")"; fail=1; }
  # A new password for admin, straight into UniFi's database.
  aid=$(jq -r '.app.users[] | select(.name == "admin") | .id' "$VAR/status.json")
  request "ACTION='adminpw'" "ADMIN_ID='$aid'" || fail=1; pw2=$(secret maintenance)
  [[ -n "$pw2" && "$(login admin "$pw2")" == ok && "$(login admin "$pw")" != ok ]] && echo "  ok   admin's new password signs in, the old one doesn't (no restart needed)" || { echo "  FAIL adminpw: new $(login admin "$pw2"), old $(login admin "$pw")"; fail=1; }
  # The package's account broken in UniFi, then repaired.
  printf 'db.admin.updateOne({name: "dsm-package"}, {$set: {x_shadow: "$6$x$broken"}}); print("ok");\n' | mongo >/dev/null; rm -f "$VAR/.uf-jar" "$VAR/.devices.json"
  wait_for '.app.api_error != ""' 60 && echo "  ok   with dsm-package broken, the Devices tab says so: $(jq -r .app.api_error "$VAR/status.json")" || echo "  note the window didn't notice the broken account (the next tick repairs it first)"
  request "ACTION='adminpw'" "ADMIN_ID='$(jq -r '.app.users[] | select(.name == "dsm-package") | .id' "$VAR/status.json")'" || fail=1
  rm -f "$VAR/.devices.json"; wait_for '.app.api_error == "" and (.app.devices | length) >= 1' 60 && echo "  ok   Repair: dsm-package reads the devices again" || { echo "  FAIL repair: $(jq -c '.app.api_error' "$VAR/status.json")"; fail=1; }
  # HTTPS with DSM's certificate (not a Synology here: a self-signed one goes into UniFi's keystore), then back to UniFi's own.
  request "ACTION='settings'" "APP_URL='https://127.0.0.1:$PORT'" "HTTP_PORT='$PORT'" "SSL_PROXY='0'" "APP_TZ='Europe/London'" "TLS='dsm'" || fail=1
  cert=$(echo | openssl s_client -connect "127.0.0.1:$PORT" 2>/dev/null | openssl x509 -noout -subject 2>/dev/null)
  [[ "$cert" == *"UniFi Network on 127.0.0.1"* && "$(envv TLS_SOURCE)" == self ]] && echo "  ok   HTTPS: the package's certificate is served ($cert)" || { echo "  FAIL tls: $cert, source $(envv TLS_SOURCE)"; fail=1; }
  request "ACTION='settings'" "APP_URL='https://127.0.0.1:$PORT'" "HTTP_PORT='$PORT'" "SSL_PROXY='0'" "APP_TZ='Europe/London'" "TLS='own'" || fail=1
  cert=$(echo | openssl s_client -connect "127.0.0.1:$PORT" 2>/dev/null | openssl x509 -noout -subject 2>/dev/null)
  [[ "$cert" == *"CN"*"unifi"* && "$cert" != *"UniFi Network on"* ]] && echo "  ok   back to UniFi's own certificate ($cert)" || { echo "  FAIL tls own: $cert"; fail=1; }
  # A backup, a change, the restore.
  request "ACTION='backup'" || fail=1; b2=$(jq -r '.backups[0].name' "$VAR/status.json")
  tar -tf "$APP/backups/$b2" | grep -q 'mongo.archive.gz$' && tar -tf "$APP/backups/$b2" | grep -q 'config.tar.gz$' && grep -q "UniFi was paused for" "$VAR/package.log" \
    && echo "  ok   $b2: MongoDB dump and data folder, UniFi paused meanwhile ($(grep -o 'UniFi was paused for [0-9]* s' "$VAR/package.log" | tail -n 1))" || { echo "  FAIL backup contents: $(tar -tf "$APP/backups/$b2" | paste -sd' ')"; fail=1; }
  [[ "$(login admin "$pw2")" == ok ]]; uf POST /api/set/setting/super_identity '{"name": "Changed after the backup"}' >/dev/null
  printf 'db.device.deleteOne({mac: "%s"}); print("ok");\n' "$mac1" | mongo >/dev/null
  request "ACTION='restore'" "BACKUP='$b2'" || fail=1
  [[ "$(login admin "$pw2")" == ok && "$(uf GET /api/s/default/get/setting/super_identity | jq -r '.data[0].name')" == "UniFi Network" ]] && printf 'print(db.device.countDocuments({mac: "%s"}));\n' "$mac1" | mongo | grep -qx 1 \
    && echo "  ok   restored: the controller's name and Office AP are back, admin's password still works" || { echo "  FAIL restore: $(uf GET /api/s/default/get/setting/super_identity | head -c 200)"; fail=1; }
  rm -f "$VAR/.devices.json"; wait_for '.app.api_error == "" and any(.app.devices[]; .name == "Office AP")' 90 && echo "  ok   …and the window reads the devices again" || { echo "  FAIL devices after restore: $(jq -c '.app.api_error' "$VAR/status.json")"; fail=1; }
  # Updates: pinned to a linuxserver.io release. Pretend this install is on the release before.
  docker exec "$NAME" sed -i 's|^UNIFI_IMAGE=.*|UNIFI_IMAGE=lscr.io/linuxserver/unifi-network-application:10.6.106-ls148|' "$APP/.env"
  request "ACTION='check'" || fail=1
  jq -e '.image_update | .available == true and .current == "10.6.106-ls148" and (.latest | test("^[0-9]+\\.[0-9]+\\.[0-9]+-ls[0-9]+$"))' "$VAR/status.json" >/dev/null \
    && echo "  ok   a newer release is found on GitHub and ghcr.io: $(jq -r '.image_update | "\(.current) → \(.latest)"' "$VAR/status.json")" || { echo "  FAIL check: $(jq -c .image_update "$VAR/status.json")"; fail=1; }
  local want; want=$(jq -r '.image_update.latest' "$VAR/status.json")
  if [[ "$want" == 10.6.106-ls149 ]]; then
    request "ACTION='updateapp'" || fail=1
    [[ "$(envv UNIFI_IMAGE)" == "lscr.io/linuxserver/unifi-network-application:$want" ]] && jq -e '.image_update.available == false' "$VAR/status.json" >/dev/null && ! grep -q 'image prune' "$VAR/package.log" \
      && echo "  ok   updated through the package's own path (a backup first: $(jq -r '.backup.last.name' "$VAR/status.json"); no image prune)" || { echo "  FAIL updateapp: $(jq -c '.image_update' "$VAR/status.json")"; fail=1; }
  else echo "  note the newest release is $want, not the tested one: the update itself isn't run here (it would download it)"; docker exec "$NAME" sed -i "s|^UNIFI_IMAGE=.*|UNIFI_IMAGE=lscr.io/linuxserver/unifi-network-application:10.6.106-ls149|" "$APP/.env"; fi
  request "ACTION='updateapp'" >/dev/null && { echo "  FAIL an update with nothing newer"; fail=1; } || echo "  ok   nothing newer: $(jq -r .last.message "$VAR/status.json")"
  # DSM's firewall list: every port.
  local sc; sc=$(docker exec "$NAME" bash -c '. /pkg/setup/pkg.env; . /pkg/setup/app.sh; APP='"'$APP'"'; env_get() { grep -E "^$1=" "$APP/.env" | tail -n 1 | cut -d= -f2-; }; app_extra_ports')
  grep -q 'dst.ports="8081/tcp"' <<< "$sc" && grep -q 'dst.ports="3478/udp"' <<< "$sc" && grep -q 'dst.ports="11001/udp"' <<< "$sc" && echo "  ok   the firewall list: inform, STUN and discovery beside the web port" || { echo "  FAIL .sc: $sc"; fail=1; }
  # Storage and logs.
  wait_for '.storage.app | has("data") and has("autobackups")' 30 && echo "  ok   storage: $(jq -c .storage "$VAR/status.json")" || { echo "  FAIL storage: $(jq -c .storage "$VAR/status.json")"; fail=1; }
  for i in $(seq 1 20); do [[ -s "$VAR/logs/unifi.log" ]] && break; touch "$VAR/watching"; sleep 1; done
  grep -q . "$VAR/logs/unifi.log" 2>/dev/null && echo "  ok   UniFi's server log for the window" || { echo "  FAIL unifi.log"; fail=1; }
  (( fail )) && { echo "  unifi: something FAILED"; return 1; }; echo "  unifi: all passed"
}

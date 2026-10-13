# UniFi Network's actions, validated by the CGI before they become a request file.
# No free text: ports are numbers, the inform host is an address or a name,
# memory is picked from a list, an administrator is picked by id from the list the window shows.
port_ok() { [[ "$1" =~ ^[0-9]{4,5}$ ]] && (( $1 >= 1024 && $1 <= 65535 )); }
app_cgi_post() {   # action body → sets $lines, or error
  local a=$1 body=$2 v c inf stun disc portal ph phs web all
  case "$a" in
    copyunf) lines="ACTION='copyunf'" ;;
    refreshcert) lines="ACTION='refreshcert'" ;;
    ports)
      inf=$(param inform "$body"); stun=$(param stun "$body"); disc=$(param disc "$body"); portal=$(param portal "$body"); ph=$(param portal_http "$body"); phs=$(param portal_https "$body")
      for v in "$inf" "$stun" "$disc" "$ph" "$phs"; do port_ok "$v" || error "400 Bad Request" "Each port is a number from 1024 to 65535."; done
      [[ "$portal" =~ ^[01]$ ]] || error "400 Bad Request" "The guest portal is on or off."
      web=$(jq -r '.port // ""' "$VAR/status.json" 2>/dev/null)
      all="$web $inf $stun $disc"; [[ "$portal" == 1 ]] && all="$all $ph $phs"
      [[ "$(tr ' ' '\n' <<< "$all" | grep -c .)" == "$(tr ' ' '\n' <<< "$all" | grep . | sort -u | wc -l)" ]] || error "400 Bad Request" "Each port must be different, and not the web port ($web)."
      lines="ACTION='ports'
INFORM_PORT='$inf'
STUN_PORT='$stun'
DISC_PORT='$disc'
PORTAL='$portal'
PORTAL_HTTP='$ph'
PORTAL_HTTPS='$phs'" ;;
    informhost)
      v=$(decode "$(param host "$body")")
      [[ "$v" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]] && (( ${#v} <= 253 )) || error "400 Bad Request" "An address like 192.168.1.20, or a name like nas.home.lan."
      if [[ "$v" =~ ^[0-9.]+$ ]]; then [[ "$v" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || error "400 Bad Request" "An address has four numbers, like 192.168.1.20."; fi
      lines="ACTION='informhost'
INFORM_HOST='$v'" ;;
    memory)
      v=$(param heap "$body"); c=$(param cache "$body")
      [[ "$v" =~ ^(384|512|768|1024|1536|2048|3072)$ ]] || error "400 Bad Request" "Pick a heap size from the list."
      [[ "$c" =~ ^(0\.25|0\.5|1|2)$ ]] || error "400 Bad Request" "Pick a cache size from the list."
      lines="ACTION='memory'
JAVA_HEAP='$v'
DB_CACHE='$c'" ;;
    adminpw)
      v=$(param id "$body")
      [[ "$v" =~ ^[0-9a-f]{24}$ ]] || error "400 Bad Request" "Pick an administrator from the list."
      jq -e --arg id "$v" 'any(.app.users[]?; .id == $id)' "$VAR/status.json" >/dev/null 2>&1 || error "400 Bad Request" "Pick an administrator from the list."
      lines="ACTION='adminpw'
ADMIN_ID='$v'" ;;
  esac
}
app_cgi_settings() {   # the Site address tab's HTTPS choice; the web port mustn't be one of UniFi's other ports
  local t inf
  t=$(param tls "$body"); [[ -z "$t" || "$t" =~ ^(own|dsm)$ ]] || error "400 Bad Request" "HTTPS uses UniFi's certificate or DSM's."
  inf=$(jq -r '[.app.inform.port, .app.inform.stun, .app.inform.discovery, (if .app.inform.portal then .app.inform.portal_http, .app.inform.portal_https else empty end)] | map(tostring) | join(" ")' "$VAR/status.json" 2>/dev/null)
  [[ " $inf " == *" $port "* ]] && error "400 Bad Request" "Port $port is one of UniFi's device ports (Adopt tab) — pick another for the web app."
  [[ -n "$t" ]] && lines="$lines
TLS='$t'"
  true
}
app_cgi_get() {   # one of UniFi's autobackups, as copied into the share
  local name
  case "$1" in
    unf)
      name=$(param name "$2")
      [[ "$name" =~ ^[A-Za-z0-9._-]{1,120}\.unf$ ]] && jq -e --arg n "$name" 'any(.app.unf.files[]?; .name == $n and .copied)' "$VAR/status.json" >/dev/null 2>&1 && [[ -f "$SHARE/autobackups/$name" ]] || error "404 Not Found" "No such backup."
      printf 'Status: 200 OK\r\nContent-Type: application/octet-stream\r\nContent-Length: %s\r\nContent-Disposition: attachment; filename="%s"\r\n\r\n' "$(stat -c %s "$SHARE/autobackups/$name")" "$name"; cat "$SHARE/autobackups/$name"; exit 0 ;;
  esac
}

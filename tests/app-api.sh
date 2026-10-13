# UniFi Network's CGI checks (sourced by chassis/tests/test-api.sh).
aid=65f1a2b3c4d5e6f708192a3b
jq -c --arg id "$aid" '. + {port: "8443", app: {users: [{id: $id, name: "admin"}], inform: {port: 8080, stun: 3478, discovery: 10001, portal: false, portal_http: 8880, portal_https: 8843},
  unf: {files: [{name: "autobackup_10.6.106_20261012_0100_1760230800000.unf", copied: true}, {name: "autobackup_10.6.106_20261005_0100_1759626000000.unf", copied: false}]}}}' "$CHASSIS_VAR/status.json" > "$CHASSIS_VAR/s.tmp" && mv "$CHASSIS_VAR/s.tmp" "$CHASSIS_VAR/status.json"
expect "copyunf" 202 "$(post "$me" copyunf 'action=copyunf')"; request_is "copyunf request" "ACTION='copyunf'
BY='$me'"
expect "ports good" 202 "$(post "$me" ports 'action=ports&inform=8081&stun=3478&disc=11001&portal=1&portal_http=8880&portal_https=8843')"; request_is "ports request" "ACTION='ports'
INFORM_PORT='8081'
STUN_PORT='3478'
DISC_PORT='11001'
PORTAL='1'
PORTAL_HTTP='8880'
PORTAL_HTTPS='8843'
BY='$me'"
expect "ports: the web port" 400 "$(post "$me" ports 'action=ports&inform=8443&stun=3478&disc=11001&portal=0&portal_http=8880&portal_https=8843')"
expect "ports: twice the same" 400 "$(post "$me" ports 'action=ports&inform=8080&stun=8080&disc=11001&portal=0&portal_http=8880&portal_https=8843')"
expect "ports: portal clash only when on" 202 "$(post "$me" ports 'action=ports&inform=8080&stun=3478&disc=10001&portal=0&portal_http=8080&portal_https=8843')"; rm -f "$CHASSIS_VAR/request"
expect "ports: portal clash when on" 400 "$(post "$me" ports 'action=ports&inform=8080&stun=3478&disc=10001&portal=1&portal_http=8080&portal_https=8843')"
expect "ports: below 1024" 400 "$(post "$me" ports 'action=ports&inform=80&stun=3478&disc=10001&portal=0&portal_http=8880&portal_https=8843')"
expect "ports: injection" 400 "$(post "$me" ports "action=ports&inform=8080'%24(id)&stun=3478&disc=10001&portal=0&portal_http=8880&portal_https=8843")"
expect "informhost ip" 202 "$(post "$me" informhost 'action=informhost&host=192.168.1.20')"; request_is "informhost request" "ACTION='informhost'
INFORM_HOST='192.168.1.20'
BY='$me'"
expect "informhost name" 202 "$(post "$me" informhost 'action=informhost&host=nas.home.lan')"; rm -f "$CHASSIS_VAR/request"
expect "informhost bad ip" 400 "$(post "$me" informhost 'action=informhost&host=192.168.1')"
expect "informhost url" 400 "$(post "$me" informhost 'action=informhost&host=http%3A%2F%2Fnas')"
expect "informhost injection" 400 "$(post "$me" informhost "action=informhost&host=a'%3Bid")"
expect "memory good" 202 "$(post "$me" memory 'action=memory&heap=512&cache=0.25')"; request_is "memory request" "ACTION='memory'
JAVA_HEAP='512'
DB_CACHE='0.25'
BY='$me'"
expect "memory bad heap" 400 "$(post "$me" memory 'action=memory&heap=100&cache=0.25')"
expect "memory bad cache" 400 "$(post "$me" memory 'action=memory&heap=512&cache=0.3')"
expect "adminpw listed" 202 "$(post "$me" adminpw "action=adminpw&id=$aid")"; request_is "adminpw request" "ACTION='adminpw'
ADMIN_ID='$aid'
BY='$me'"
expect "adminpw not listed" 400 "$(post "$me" adminpw 'action=adminpw&id=65f1a2b3c4d5e6f708192a3c')"
expect "adminpw not an id" 400 "$(post "$me" adminpw "action=adminpw&id=x'%3B\$(id)")"
expect "viewer adminpw → 403" 403 "$(CHASSIS_ADMINS=no-such-group post "$me" adminpw "action=adminpw&id=$aid")"
expect "settings with tls" 202 "$(post "$me" settings 'action=settings&url=https%3A%2F%2F192.168.1.20%3A8443&port=8443&ssl_proxy=0&tz=Europe%2FLondon&tls=dsm')"; request_is "settings request" "ACTION='settings'
APP_URL='https://192.168.1.20:8443'
HTTP_PORT='8443'
SSL_PROXY='0'
APP_TZ='Europe/London'
TLS='dsm'
BY='$me'"
expect "settings bad tls" 400 "$(post "$me" settings 'action=settings&url=https%3A%2F%2F192.168.1.20%3A8443&port=8443&ssl_proxy=0&tz=UTC&tls=self')"
expect "settings web port = inform port" 400 "$(post "$me" settings 'action=settings&url=https%3A%2F%2F192.168.1.20%3A8080&port=8080&ssl_proxy=0&tz=UTC&tls=own')"
mkdir -p "$CHASSIS_SHARE/autobackups"; echo unf > "$CHASSIS_SHARE/autobackups/autobackup_10.6.106_20261012_0100_1760230800000.unf"
expect "unf copied" 200 "$(get "$me" 'action=unf&name=autobackup_10.6.106_20261012_0100_1760230800000.unf')"
expect "unf not copied" 404 "$(get "$me" 'action=unf&name=autobackup_10.6.106_20261005_0100_1759626000000.unf')"
expect "unf traversal" 404 "$(get "$me" 'action=unf&name=..%2F.env')"
expect "viewer unf → 403" 403 "$(CHASSIS_ADMINS=no-such-group get "$me" 'action=unf&name=autobackup_10.6.106_20261012_0100_1760230800000.unf')"

#!/bin/sh
# VERSION=0.4.4
# OWRTPsiphon 0.4.4 — lightweight LuCI controller for bepass-org/warp-plus (--cfon).
# Repository: Tan4ig/owrt-psiphon
# Independent educational/experimental project; not affiliated with Psiphon Inc. or Cloudflare, Inc.
# Upstream engine: bepass-org/warp-plus (MIT License).
set -eu

APP_VER="0.4.4"
APP="/opt/owrt-psiphon"
TMP="/tmp/owrt-psiphon-install.$$"
VERSION="1.2.6"

ASSET="https://github.com/bepass-org/warp-plus/releases/download/v${VERSION}/warp-plus_linux-arm64.zip"
ASSET_SHA256="c0b430c117eaa33513fa012aca983303ee88a4bda0f935dc62ff016109e492f3"

log() { printf '\033[1;32m[OWRTPsiphon]\033[0m %s\n' "$*"; }
fail() { printf '\033[1;31m[ОШИБКА]\033[0m %s\n' "$*" >&2; rm -rf "$TMP"; exit 1; }

trap 'rm -rf "$TMP"' EXIT INT TERM

[ "$(id -u)" = 0 ] || fail 'Запустите от root.'
[ "$(uname -m)" = aarch64 ] || fail "Нужна архитектура aarch64, текущая: $(uname -m)"

command -v curl >/dev/null 2>&1 || {
    command -v apk >/dev/null 2>&1 || fail 'Не найден curl и недоступен apk.'
    apk add --no-cache curl || fail 'Не удалось установить curl.'
}
command -v uci >/dev/null 2>&1 || fail 'Не найден UCI.'
command -v jsonfilter >/dev/null 2>&1 || fail 'Не найден jsonfilter.'
[ -d /www/luci-static/resources/view ] || fail 'Не найден LuCI.'

mkdir -p "$TMP" "$APP" "$APP/cache"

if [ ! -x "$APP/warp-plus" ]; then
    log "Загрузка warp-plus v${VERSION}..."
    curl -fL --retry 3 --connect-timeout 20 "$ASSET" -o "$TMP/wp.zip" || fail 'Ошибка загрузки warp-plus.'
    SHA_ADDED=0
    UNZIP_ADDED=0
    if ! command -v sha256sum >/dev/null 2>&1; then
        apk add --no-cache coreutils-sha256sum || fail 'Не удалось установить sha256sum.'
        SHA_ADDED=1
    fi
    ACTUAL_SHA="$(sha256sum "$TMP/wp.zip" | awk '{print $1}')"
    [ "$ACTUAL_SHA" = "$ASSET_SHA256" ] || fail "SHA256 не совпал (ожидался $ASSET_SHA256, получен $ACTUAL_SHA)."
    if ! command -v unzip >/dev/null 2>&1; then
        apk add --no-cache unzip || fail 'Не удалось установить unzip.'
        UNZIP_ADDED=1
    fi
    unzip -tq "$TMP/wp.zip" >/dev/null || fail 'Архив warp-plus повреждён.'
    mkdir -p "$TMP/u"
    unzip -oq "$TMP/wp.zip" -d "$TMP/u" || fail 'Не удалось распаковать warp-plus.'
    WP_CANDIDATE="$(find "$TMP/u" -type f -name warp-plus -print | head -n 1)"
    [ -n "$WP_CANDIDATE" ] && [ -s "$WP_CANDIDATE" ] || fail 'В архиве не найден бинарник warp-plus.'
    ELF_MAGIC="$(head -c 4 "$WP_CANDIDATE" | od -An -t x1 | tr -d ' \n')"
    ELF_MACHINE="$(od -An -t u1 -j 18 -N 2 "$WP_CANDIDATE" | tr -s ' ' | sed 's/^ //;s/ $//')"
    [ "$ELF_MAGIC" = '7f454c46' ] && [ "$ELF_MACHINE" = '183 0' ] || fail 'Бинарник в архиве не является ELF AArch64.'
    cp "$WP_CANDIDATE" "$TMP/warp-plus.new" && chmod 755 "$TMP/warp-plus.new"
    mv -f "$TMP/warp-plus.new" "$APP/warp-plus"
    [ "$UNZIP_ADDED" = 0 ] || apk del unzip >/dev/null 2>&1 || true
    [ "$SHA_ADDED" = 0 ] || apk del coreutils-sha256sum >/dev/null 2>&1 || true
fi

if [ ! -f /etc/config/owrt-psiphon ]; then
    cat << 'EOF' > /etc/config/owrt-psiphon
config owrt-psiphon 'main'
	option enabled '0'
	option autostart '1'
	option auto_scan_boot '0'
	option watchdog_hours '0'
	option country 'NL'
	option last_good_country 'NL'
	option bind '192.168.1.1'
	option port '8086'
	option endpoint '188.114.99.150:1701'
	option test_url 'http://example.com'
EOF
else
    [ "$(uci -q get owrt-psiphon.main.test_url || true)" = "https://ipinfo.io" ] && uci -q set owrt-psiphon.main.test_url='http://example.com'
    [ -n "$(uci -q get owrt-psiphon.main.last_good_country || true)" ] || uci -q set owrt-psiphon.main.last_good_country="$(uci -q get owrt-psiphon.main.country || echo NL)"
    [ -n "$(uci -q get owrt-psiphon.main.autostart || true)" ] || uci -q set owrt-psiphon.main.autostart='1'
    [ -n "$(uci -q get owrt-psiphon.main.auto_scan_boot || true)" ] || uci -q set owrt-psiphon.main.auto_scan_boot='0'
    cur_wh="$(uci -q get owrt-psiphon.main.watchdog_hours || echo 0)"
    case "$cur_wh" in 0|1|6|12|24|boot) ;; *) uci -q set owrt-psiphon.main.watchdog_hours='0' ;; esac
    [ -n "$(uci -q get owrt-psiphon.main.enabled || true)" ] || uci -q set owrt-psiphon.main.enabled='0'
    [ -n "$(uci -q get owrt-psiphon.main.country || true)" ] || uci -q set owrt-psiphon.main.country='NL'
    [ -n "$(uci -q get owrt-psiphon.main.bind || true)" ] || uci -q set owrt-psiphon.main.bind='192.168.1.1'
    [ -n "$(uci -q get owrt-psiphon.main.port || true)" ] || uci -q set owrt-psiphon.main.port='8086'
    [ -n "$(uci -q get owrt-psiphon.main.endpoint || true)" ] || uci -q set owrt-psiphon.main.endpoint='188.114.99.150:1701'
    uci -q commit owrt-psiphon
fi

mkdir -p /etc/init.d /usr/libexec/rpcd /usr/libexec/owrt-psiphon /usr/share/luci/menu.d /usr/share/rpcd/acl.d /www/luci-static/resources/view/owrt-psiphon
rm -f /www/luci-static/resources/view/owrt-psiphon/main-*.js /www/luci-static/resources/view/owrt-psiphon/main_*.js

cat << 'EOF' > /etc/init.d/owrt-psiphon
#!/bin/sh /etc/rc.common
USE_PROCD=1
START=95
STOP=10

BIN="/opt/owrt-psiphon/warp-plus"
CACHE_DIR="/opt/owrt-psiphon/cache"

start_service() {
	[ -x "$BIN" ] || return 1
	. /lib/functions.sh
	config_load owrt-psiphon
	local enabled country bind port endpoint test_url
	config_get_bool enabled main enabled 0
	[ "$enabled" -eq 1 ] || return 0
	config_get country main country NL
	config_get bind main bind 192.168.1.1
	config_get port main port 8086
	config_get endpoint main endpoint "188.114.99.150:1701"
	config_get test_url main test_url "http://example.com"
	mkdir -p "$CACHE_DIR"
	rm -f /var/run/owrt-psiphon-probe.state
	procd_open_instance main
	if [ -n "$endpoint" ]; then
		procd_set_param command "$BIN" -4 -e "$endpoint" --cfon --country "$country" -b "${bind}:${port}" --cache-dir "$CACHE_DIR" --test-url "$test_url"
	else
		procd_set_param command "$BIN" -4 --cfon --country "$country" -b "${bind}:${port}" --cache-dir "$CACHE_DIR" --test-url "$test_url"
	fi
	procd_set_param respawn 3600 5 5
	procd_set_param stdout 1
	procd_set_param stderr 1
	procd_close_instance
}

stop_service() {
	rm -f /var/run/owrt-psiphon-probe.state
}

boot() {
	. /lib/functions.sh
	config_load owrt-psiphon
	local autostart auto_scan_boot watchdog_hours
	config_get_bool autostart main autostart 1
	config_get_bool auto_scan_boot main auto_scan_boot 0
	config_get watchdog_hours main watchdog_hours 0
	if [ "$autostart" -eq 1 ]; then
		uci -q set owrt-psiphon.main.enabled='1' && uci -q commit owrt-psiphon
		start
		if [ "$auto_scan_boot" -eq 1 ] || [ "$watchdog_hours" = "boot" ]; then
			(sleep 15 && /usr/libexec/owrt-psiphon/owrt-psiphonctl scan) </dev/null >/dev/null 2>&1 &
		fi
	else
		uci -q set owrt-psiphon.main.enabled='0' && uci -q commit owrt-psiphon
	fi
}

service_triggers() {
	procd_add_reload_trigger owrt-psiphon
}
EOF

cat << 'EOF' > /usr/libexec/owrt-psiphon/owrt-psiphonctl
#!/bin/sh
APP=/opt/owrt-psiphon
BIN="$APP/warp-plus"
CONFIG=owrt-psiphon.main
REPO_URL="https://raw.githubusercontent.com/Tan4ig/owrt-psiphon/main/install.sh"
WARP_API_URL="https://api.github.com/repos/bepass-org/warp-plus/releases/latest"

BIND="$(uci -q get ${CONFIG}.bind || echo 192.168.1.1)"
PORT="$(uci -q get ${CONFIG}.port || echo 8086)"
COUNTRY="$(uci -q get ${CONFIG}.country || echo NL)"
ENDPOINT="$(uci -q get ${CONFIG}.endpoint || echo 188.114.99.150:1701)"
TEST_URL="$(uci -q get ${CONFIG}.test_url || echo http://example.com)"

SCANFILE="$APP/scan-results.json"
SCAN_PIDFILE=/var/run/owrt-psiphon-scan.pid
PROBE_FILE=/var/run/owrt-psiphon-probe.state
SCAN_LOCK=/var/run/owrt-psiphon-scan.lock
WATCHDOG_LOCK=/var/run/owrt-psiphon-watchdog.lock

ALL_COUNTRIES="NL DE FI SE PL AT CH FR GB NO BE CZ DK EE LV ES IT PT IE BG RO HR HU RS SK SG JP IN AU CA US"
SCAN_LIST="NL DE FI SE PL AT CH FR GB NO"

valid_country() {
	for c in $ALL_COUNTRIES; do [ "$c" = "$1" ] && return 0; done
	return 1
}

json_escape() {
	printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g; s/\r//g; s/\n/\\n/g'
}

reply() {
	printf '{"ok":%s,"message":"%s"}\n' "$1" "$(json_escape "$2")"
}

managed_pid() {
	svc_json="$(ubus call service list '{"name":"owrt-psiphon"}' 2>/dev/null || true)"
	[ -n "$svc_json" ] || return 1
	p="$(jsonfilter -s "$svc_json" -e "@['owrt-psiphon'].instances.main.pid" 2>/dev/null || true)"
	case "$p" in ''|*[!0-9]*) return 1 ;; esac
	kill -0 "$p" 2>/dev/null && printf '%s\n' "$p"
}

port_listening() {
	netstat -lnt 2>/dev/null | awk '{print $4}' | grep -Eq "(:|\.)${PORT}$"
}

port_in_use() {
	netstat -lnt 2>/dev/null | awk '{print $4}' | grep -Eq "(:|\.)${1}$"
}

acquire_lock() {
	lock_dir="$1"
	mkdir -p /var/run
	if mkdir "$lock_dir" 2>/dev/null; then
		printf '%s\n' "$$" > "${lock_dir}/pid"
		return 0
	fi
	old_pid="$(cat "${lock_dir}/pid" 2>/dev/null || true)"
	if [ -n "$old_pid" ] && kill -0 "$old_pid" 2>/dev/null; then
		return 1
	fi
	rm -rf "$lock_dir"
	if mkdir "$lock_dir" 2>/dev/null; then
		printf '%s\n' "$$" > "${lock_dir}/pid"
		return 0
	fi
	return 1
}

release_lock() {
	rm -rf "$1" 2>/dev/null || true
}

ver_gt() {
	v1="$(printf '%s' "$1" | sed 's/^v//')"
	v2="$(printf '%s' "$2" | sed 's/^v//')"
	awk -v v1="$v1" -v v2="$v2" 'BEGIN {
		n1 = split(v1, a, "."); n2 = split(v2, b, ".");
		max = (n1 > n2) ? n1 : n2;
		for (i = 1; i <= max; i++) {
			x = a[i] + 0; y = b[i] + 0;
			if (x > y) exit 0;
			if (x < y) exit 1;
		}
		exit 1;
	}'
}

probe_internal() {
	port_listening || { rm -f "$PROBE_FILE"; return 1; }
	out="$(curl -4 -fsS --max-time 10 --socks5-hostname "${BIND}:${PORT}" -w '\n%{time_starttransfer}' https://ipinfo.io 2>/dev/null)" || { rm -f "$PROBE_FILE"; return 1; }
	body="$(printf '%s\n' "$out" | sed '$d')"
	secs="$(printf '%s\n' "$out" | tail -n 1)"
	cc="$(jsonfilter -s "$body" -e '@.country' 2>/dev/null || true)"
	ip="$(jsonfilter -s "$body" -e '@.ip' 2>/dev/null || true)"
	[ -n "$cc" ] || { rm -f "$PROBE_FILE"; return 1; }
	ms="$(awk -v s="$secs" 'BEGIN { printf "%d", s*1000 }')"
	tmp_p="${PROBE_FILE}.tmp.$$"
printf "PROBE_COUNTRY='%s'\nPROBE_IP='%s'\nPROBE_MS='%s'\n" "$cc" "$ip" "$ms" > "$tmp_p"
mv -f "$tmp_p" "$PROBE_FILE"
}
wait_socks_ready() {
max_wait="${1:-35}"
elapsed=0
while [ "$elapsed" -lt "$max_wait" ]; do
managed_pid >/dev/null || return 1
probe_internal && return 0
sleep 2
elapsed=$((elapsed + 2))
done
return 1
}
sync_cron() {
hours="$(uci -q get ${CONFIG}.watchdog_hours || echo 0)"
CRON_FILE="/etc/crontabs/root"
mkdir -p /etc/crontabs
touch "$CRON_FILE"
grep -v 'owrt-psiphonctl watchdog' "$CRON_FILE" > "${CRON_FILE}.tmp" 2>/dev/null || true
case "$hours" in
1) printf '0 * * * * /usr/libexec/owrt-psiphon/owrt-psiphonctl watchdog >/dev/null 2>&1\n' >> "${CRON_FILE}.tmp" ;;
6|12|24) printf '0 */%s * * * /usr/libexec/owrt-psiphon/owrt-psiphonctl watchdog >/dev/null 2>&1\n' "$hours" >> "${CRON_FILE}.tmp" ;;
esac
mv -f "${CRON_FILE}.tmp" "$CRON_FILE"
/etc/init.d/cron restart >/dev/null 2>&1 || true
}
status() {
running=false; pid=""; listening=false; socks_ok=false; exit_country=""; exit_ip=""; latency=""
if p="$(managed_pid)"; then running=true; pid="$p"; fi
port_listening && listening=true
if [ "$running" = true ] && [ "$listening" = true ] && probe_internal; then
socks_ok=true
exit_country="$(sed -n 's/^PROBE_COUNTRY=//p' "$PROBE_FILE" | tr -d "'" | head -n 1)"
exit_ip="$(sed -n 's/^PROBE_IP=//p' "$PROBE_FILE" | tr -d "'" | head -n 1)"
latency="$(sed -n 's/^PROBE_MS=//p' "$PROBE_FILE" | tr -d "'" | head -n 1)"
else
rm -f "$PROBE_FILE"
fi
app_version="$(cat "$APP/app.version" 2>/dev/null | head -n 1 | tr -d '\r\n' || echo 0.4.4)"
version="v1.2.6"
if [ -x "$BIN" ]; then
v="$("$BIN" version 2>&1 | grep -Eo 'v?[0-9]+.[0-9]+.[0-9]+' | head -n 1 || true)"
[ -n "$v" ] && version="$v"
fi
autostart="$(uci -q get ${CONFIG}.autostart || echo 1)"
auto_scan_boot="$(uci -q get ${CONFIG}.auto_scan_boot || echo 0)"
watchdog_hours="$(uci -q get ${CONFIG}.watchdog_hours || echo 0)"
sub="socks5://${BIND}:${PORT}#OWRTPsiphon"
scan_run=false
if [ -d "$SCAN_LOCK" ]; then
sp="$(cat "${SCAN_LOCK}/pid" 2>/dev/null || true)"
[ -n "$sp" ] && kill -0 "$sp" 2>/dev/null && scan_run=true
fi
printf '{"ok":true,"running":%s,"listening":%s,"socks_ok":%s,"pid":"%s","country":"%s","bind":"%s","port":%s,"app_version":"%s","version":"%s","subscription":"%s","exit_country":"%s","exit_ip":"%s","latency_ms":"%s","autostart":%s,"auto_scan_boot":%s,"watchdog_hours":"%s","scan_running":%s}\n' \
"$running" "$listening" "$socks_ok" "$pid" "$(json_escape "$COUNTRY")" "$(json_escape "$BIND")" "$PORT" "$(json_escape "$app_version")" "$(json_escape "$version")" "$(json_escape "$sub")" "$(json_escape "$exit_country")" "$(json_escape "$exit_ip")" "$(json_escape "$latency")" "$autostart" "$auto_scan_boot" "$(json_escape "$watchdog_hours")" "$scan_run"
}
check_update() {
local_ver="$(cat "$APP/app.version" 2>/dev/null | head -n 1 | tr -d '\r\n' || echo 0.4.4)"
remote_head="$(curl -fsSL --max-time 8 "${REPO_URL}?t=$(date +%s)" 2>/dev/null | head -n 5 || true)"
[ -n "$remote_head" ] || { printf '{"ok":false,"message":"Не удалось связаться с GitHub"}\n'; return 1; }
remote_ver="$(printf '%s\n' "$remote_head" | sed -n 's/^# VERSION=\([0-9][0-9.]*\).*/\1/p' | head -n 1)"
[ -n "$remote_ver" ] || { printf '{"ok":false,"message":"Не удалось определить версию на GitHub"}\n'; return 1; }
if ver_gt "$remote_ver" "$local_ver"; then
printf '{"ok":true,"has_update":true,"remote_version":"%s","message":"Доступно обновление v%s"}\n' "$remote_ver" "$remote_ver"
else
printf '{"ok":true,"has_update":false,"remote_version":"%s","message":"Установлена актуальная версия"}\n' "$local_ver"
fi
}
apply_update() {
tmp_upd="/tmp/owrt-psiphon-update.$$.sh"
curl -fsSL --max-time 15 "${REPO_URL}?t=$(date +%s)" -o "$tmp_upd" 2>/dev/null || { rm -f "$tmp_upd"; reply false 'Ошибка загрузки обновления с GitHub'; return 1; }
head -n 5 "$tmp_upd" | grep -q 'OWRTPsiphon' || { rm -f "$tmp_upd"; reply false 'Загруженный файл не прошел проверку'; return 1; }
chmod 755 "$tmp_upd"
reply true 'Обновление запущено. Страница перезагрузится автоматически.'
if command -v setsid >/dev/null 2>&1; then
setsid sh -c "sleep 1; sh '$tmp_upd' >/dev/null 2>&1; rm -f '$tmp_upd'" </dev/null >/dev/null 2>&1 &
else
(sleep 1; sh "$tmp_upd" >/dev/null 2>&1; rm -f "$tmp_upd") </dev/null >/dev/null 2>&1 &
fi
}
check_warp_update() {
local_ver="1.2.6"
if [ -x "$BIN" ]; then
v="$("$BIN" version 2>&1 | grep -Eo '[0-9]+.[0-9]+.[0-9]+' | head -n 1 || true)"
[ -n "$v" ] && local_ver="$v"
fi
rel_json="$(curl -fsSL --max-time 8 "$WARP_API_URL" 2>/dev/null || true)"
[ -n "$rel_json" ] || { printf '{"ok":false,"message":"Не удалось проверить релизы warp-plus"}\n'; return 1; }
tag="$(jsonfilter -s "$rel_json" -e '@.tag_name' 2>/dev/null || true)"
remote_ver="$(printf '%s' "$tag" | sed 's/^v//')"
[ -n "$remote_ver" ] || { printf '{"ok":false,"message":"Не удалось определить версию warp-plus"}\n'; return 1; }
if ver_gt "$remote_ver" "$local_ver"; then
printf '{"ok":true,"has_update":true,"remote_version":"%s","message":"Доступно обновление v%s"}\n' "$remote_ver" "$remote_ver"
else
printf '{"ok":true,"has_update":false,"remote_version":"%s","message":"Установлена актуальная версия"}\n' "$local_ver"
fi
}
apply_warp_update() {
rel_json="$(curl -fsSL --max-time 10 "$WARP_API_URL" 2>/dev/null || true)"
[ -n "$rel_json" ] || { reply false 'Ошибка получения данных релиза warp-plus'; return 1; }
dl_url="$(jsonfilter -s "$rel_json" -e '@.assets[*].browser_download_url' 2>/dev/null | grep 'linux-arm64.zip$' | head -n 1 || true)"
[ -n "$dl_url" ] || { reply false 'Не найден архив linux-arm64 в релизе'; return 1; }
tmp_w="/tmp/owrt-warp-upd.$$"
mkdir -p "$tmp_w"
if ! curl -fL --max-time 30 "$dl_url" -o "$tmp_w/wp.zip" 2>/dev/null; then
rm -rf "$tmp_w"
reply false 'Ошибка скачивания архива warp-plus'
return 1
fi
UNZIP_TMP=0
if ! command -v unzip >/dev/null 2>&1; then
apk add --no-cache unzip >/dev/null 2>&1 && UNZIP_TMP=1 || { rm -rf "$tmp_w"; reply false 'Не удалось установить unzip'; return 1; }
fi
mkdir -p "$tmp_w/u"
if ! unzip -oq "$tmp_w/wp.zip" -d "$tmp_w/u" 2>/dev/null; then
[ "$UNZIP_TMP" = 1 ] && apk del unzip >/dev/null 2>&1 || true
rm -rf "$tmp_w"
reply false 'Ошибка распаковки архива warp-plus'
return 1
fi
cand="$(find "$tmp_w/u" -type f -name warp-plus -print | head -n 1)"
if [ -z "$cand" ] || [ ! -s "$cand" ]; then
[ "$UNZIP_TMP" = 1 ] && apk del unzip >/dev/null 2>&1 || true
rm -rf "$tmp_w"
reply false 'В архиве не найден бинарник warp-plus'
return 1
fi
was_run=0
managed_pid >/dev/null && was_run=1
[ "$was_run" = 1 ] && /etc/init.d/owrt-psiphon stop >/dev/null 2>&1 || true
cp "$cand" "$BIN.new" && chmod 755 "$BIN.new" && mv -f "$BIN.new" "$BIN"
[ "$UNZIP_TMP" = 1 ] && apk del unzip >/dev/null 2>&1 || true
rm -rf "$tmp_w"
[ "$was_run" = 1 ] && /etc/init.d/owrt-psiphon start >/dev/null 2>&1 || true
reply true 'warp-plus успешно обновлён'
}
start_service() {
if managed_pid >/dev/null; then
if wait_socks_ready 10; then reply true 'Служба уже запущена'
else reply false 'Процесс запущен, но SOCKS5 не отвечает'; fi
return 0
fi
rm -f "$PROBE_FILE"
uci -q set ${CONFIG}.enabled='1' && uci -q commit owrt-psiphon
/etc/init.d/owrt-psiphon start >/dev/null 2>&1 || true
if wait_socks_ready 35; then
uci -q set ${CONFIG}.last_good_country="$COUNTRY" && uci -q commit owrt-psiphon
reply true "Служба запущена ($COUNTRY)"
else
reply false 'SOCKS5 не поднялся за 35 с'
return 1
fi
}
stop_service() {
uci -q set ${CONFIG}.enabled='0' && uci -q commit owrt-psiphon
/etc/init.d/owrt-psiphon stop >/dev/null 2>&1 || true
rm -f "$PROBE_FILE"
reply true 'Служба остановлена'
}
safe_restart() {
new_country="$1"
old_country="$(uci -q get ${CONFIG}.last_good_country || uci -q get ${CONFIG}.country || echo NL)"
rm -f "$PROBE_FILE"
uci -q set ${CONFIG}.country="$new_country" && uci -q set ${CONFIG}.enabled='1' && uci -q commit owrt-psiphon
/etc/init.d/owrt-psiphon restart >/dev/null 2>&1 || true
if wait_socks_ready 35; then
uci -q set ${CONFIG}.last_good_country="$new_country" && uci -q commit owrt-psiphon
reply true "Переключено на $new_country"
return 0
else
if [ -n "$old_country" ] && [ "$old_country" != "$new_country" ]; then
uci -q set ${CONFIG}.country="$old_country" && uci -q commit owrt-psiphon
/etc/init.d/owrt-psiphon restart >/dev/null 2>&1 || true
if wait_socks_ready 30; then
reply false "Узел $new_country не ответил; выполнен откат на $old_country"
else
reply false "Узел $new_country не ответил; откат на $old_country также не поднялся"
fi
else
reply false "Узел $new_country не прошёл проверку"
fi
return 1
fi
}
set_country() {
c="$1"
valid_country "$c" || { reply false 'Неверный код страны'; return 1; }
if managed_pid >/dev/null; then
safe_restart "$c"
else
uci -q set ${CONFIG}.country="$c" && uci -q commit owrt-psiphon
reply true "Выбрана страна $c"
fi
}
set_auto() {
as="${1:-1}"; sb="${2:-0}"; wh="${3:-0}"
case "$as" in 0|1) ;; *) reply false 'Некорректный автостарт'; return 1 ;; esac
case "$sb" in 0|1) ;; *) reply false 'Некорректный автоподбор при загрузке'; return 1 ;; esac
case "$wh" in 0|1|6|12|24|boot) ;; *) reply false 'Некорректный интервал проверки'; return 1 ;; esac
if [ "$wh" = "boot" ]; then sb="1"; else sb="0"; fi
uci -q set ${CONFIG}.autostart="$as" &&
uci -q set ${CONFIG}.auto_scan_boot="$sb" &&
uci -q set ${CONFIG}.watchdog_hours="$wh" &&
uci -q commit owrt-psiphon || { reply false 'Не удалось сохранить настройки UCI'; return 1; }
[ "$(uci -q get ${CONFIG}.autostart || echo x)" = "$as" ] || { reply false 'Проверка сохранения autostart не пройдена'; return 1; }
if [ "$as" = 1 ]; then
/etc/init.d/owrt-psiphon enable >/dev/null 2>&1 || true
else
/etc/init.d/owrt-psiphon disable >/dev/null 2>&1 || true
fi
sync_cron
reply true 'Настройки автоматизации сохранены'
}
probe() {
if probe_internal; then
reply true "SOCKS5 активен: $(sed -n 's/^PROBE_IP=//p' "$PROBE_FILE" | tr -d "'") ($(sed -n 's/^PROBE_COUNTRY=//p' "$PROBE_FILE" | tr -d "'")), $(sed -n 's/^PROBE_MS=//p' "$PROBE_FILE" | tr -d "'") мс"
else
reply false 'SOCKS5 не отвечает'
return 1
fi
}
scan_status() {
if [ -s "$SCANFILE" ]; then cat "$SCANFILE"
else printf '{"running":false,"message":"Автоподбор ещё не запускался","results":[]}\n'; fi
}
scan_start() {
[ -x "$BIN" ] || { reply false 'Бинарник warp-plus не найден'; return 1; }
if [ -d "$SCAN_LOCK" ]; then
sp="$(cat "${SCAN_LOCK}/pid" 2>/dev/null || true)"
if [ -n "$sp" ] && kill -0 "$sp" 2>/dev/null; then
reply false 'Автоподбор уже выполняется'
return 1
fi
fi
if command -v setsid >/dev/null 2>&1; then
setsid "$0" _scan </dev/null >/dev/null 2>&1 &
else
"$0" _scan </dev/null >/dev/null 2>&1 &
fi
reply true 'Автоподбор запущен'
}
build_sorted_json() {
sort -t '|' -k1,1n -k2,2n "$1" 2>/dev/null | awk -F'|' '
BEGIN { printf "[" }
{
if (NR > 1) printf ",";
printf "{\"country\":\"%s\",\"exit_country\":\"%s\",\"ip\":\"%s\",\"latency_ms\":%s,\"state\":\"%s\"}", $3, $4, $5, $2, $6
}
END { printf "]" }
'
}
write_scan_atomic() {
tmp_sf="${SCANFILE}.tmp.$$"
printf '%s\n' "$1" > "$tmp_sf"
mv -f "$tmp_sf" "$SCANFILE"
}
scan_worker() {
acquire_lock "$SCAN_LOCK" || return 0
if [ -s "$SCAN_PIDFILE" ]; then
stale_pid="$(cat "$SCAN_PIDFILE" 2>/dev/null || true)"
[ -n "$stale_pid" ] && kill -9 "$stale_pid" 2>/dev/null || true
rm -f "$SCAN_PIDFILE"
fi
scan_port=18086
while [ "$scan_port" -le 18096 ]; do
if ! port_in_use "$scan_port"; then break; fi
scan_port=$((scan_port + 1))
done
probe_pid=""
tmp_lines="/tmp/owrt-scan-lines.$$"
cleanup_scan() {
if [ -n "$probe_pid" ]; then
kill -TERM "$probe_pid" 2>/dev/null || true
sleep 1
kill -KILL "$probe_pid" 2>/dev/null || true
wait "$probe_pid" 2>/dev/null || true
fi
rm -f "$SCAN_PIDFILE" "$tmp_lines"
release_lock "$SCAN_LOCK"
}
trap 'cleanup_scan; exit 130' INT TERM
trap 'cleanup_scan' EXIT
was_running=0
old_country="$COUNTRY"
managed_pid >/dev/null && was_running=1
mkdir -p "$APP/cache-scan"
: > "$tmp_lines"
best_country=""
best_ms=999999
for c in $SCAN_LIST; do
cur_best_ms="$( [ "$best_ms" -eq 999999 ] && echo null || echo "$best_ms" )"
write_scan_atomic "{\"running\":true,\"current\":\"$c\",\"best\":\"$best_country\",\"best_ms\":$cur_best_ms,\"results\":$(build_sorted_json "$tmp_lines")}"
if [ -n "$ENDPOINT" ]; then
"$BIN" -4 -e "$ENDPOINT" --cfon --country "$c" -b "127.0.0.1:${scan_port}" --cache-dir "$APP/cache-scan" --test-url "$TEST_URL" >/dev/null 2>&1 &
else
"$BIN" -4 --cfon --country "$c" -b "127.0.0.1:${scan_port}" --cache-dir "$APP/cache-scan" --test-url "$TEST_URL" >/dev/null 2>&1 &
fi
probe_pid=$!
printf '%s\n' "$probe_pid" > "$SCAN_PIDFILE"
result=""; got=""; ip=""; ms="null"; state="timeout"; rank=2; n=0
while [ "$n" -lt 10 ]; do
sleep 2
kill -0 "$probe_pid" 2>/dev/null || break
if port_in_use "$scan_port"; then
result="$(curl -4 -fsS --max-time 5 --socks5-hostname "127.0.0.1:${scan_port}" -w '\n%{time_starttransfer}' https://ipinfo.io 2>/dev/null || true)"
[ -n "$result" ] && break
fi
n=$((n + 1))
done
kill -TERM "$probe_pid" 2>/dev/null || true
sleep 1
kill -0 "$probe_pid" 2>/dev/null && kill -KILL "$probe_pid" 2>/dev/null || true
wait "$probe_pid" 2>/dev/null || true
probe_pid=""
rm -f "$SCAN_PIDFILE"
if [ -n "$result" ]; then
body="$(printf '%s\n' "$result" | sed '$d')"
secs="$(printf '%s\n' "$result" | tail -n 1)"
got="$(jsonfilter -s "$body" -e '@.country' 2>/dev/null || true)"
ip="$(jsonfilter -s "$body" -e '@.ip' 2>/dev/null || true)"
calc_ms="$(awk -v s="$secs" 'BEGIN { printf "%d", s*1000 }')"
if [ "$got" = "$c" ]; then
state="ok"; rank=1; ms="$calc_ms"
if [ "$ms" -lt "$best_ms" ]; then best_ms="$ms"; best_country="$c"; fi
else
state="fail"; got=""; ip=""; ms="null"
fi
fi
printf '%s|%s|%s|%s|%s|%s\n' "$rank" "$ms" "$c" "$got" "$ip" "$state" >> "$tmp_lines"
done
final_json="$(build_sorted_json "$tmp_lines")"
if [ -n "$best_country" ]; then
if [ "$was_running" -eq 1 ] && [ "$best_country" != "$old_country" ]; then
if safe_restart "$best_country" >/dev/null 2>&1; then
msg="Лучший узел: $best_country (${best_ms} мс). Переключено."
else
msg="Лучший узел: $best_country (${best_ms} мс), откат на $old_country."
fi
else
uci -q set ${CONFIG}.country="$best_country" && uci -q commit owrt-psiphon
msg="Лучший узел: $best_country (${best_ms} мс)."
fi
write_scan_atomic "{\"running\":false,\"current\":\"\",\"best\":\"$best_country\",\"best_ms\":$best_ms,\"message\":\"$(json_escape "$msg")\",\"results\":$final_json}"
else
write_scan_atomic "{"running":false,"current":"","best":"","best_ms":null,"message":"Рабочих узлов не найдено","results":$final_json}"
fi
}
watchdog() {
[ "$(uci -q get ${CONFIG}.enabled || echo 0)" = "1" ] || return 0
acquire_lock "$WATCHDOG_LOCK" || return 0
trap 'release_lock "$WATCHDOG_LOCK"; exit 130' INT TERM
trap 'release_lock "$WATCHDOG_LOCK"' EXIT
probe_internal && return 0
cur="$(uci -q get ${CONFIG}.country || echo NL)"
if [ -s "$SCANFILE" ]; then
for next_c in $(sed 's/},{/}\n{/g' "$SCANFILE" | grep '"state":"ok"' | sed -n 's/.*"country":"\([A-Z][A-Z]\)".*/\1/p'); do
[ "$next_c" = "$cur" ] && continue
safe_restart "$next_c" >/dev/null 2>&1 && return 0
done
fi
scan_worker || true
}
uninstall_all() {
reply true 'Удаление OWRTPsiphon запущено.'
uninst_cmd='
sleep 1
/etc/init.d/owrt-psiphon stop >/dev/null 2>&1 || true
/etc/init.d/owrt-psiphon disable >/dev/null 2>&1 || true
if [ -f /etc/crontabs/root ]; then
grep -v "owrt-psiphonctl watchdog" /etc/crontabs/root > /etc/crontabs/root.tmp 2>/dev/null || true
mv -f /etc/crontabs/root.tmp /etc/crontabs/root
/etc/init.d/cron restart >/dev/null 2>&1 || true
fi
killall warp-plus >/dev/null 2>&1 || true
rm -rf /opt/owrt-psiphon /etc/config/owrt-psiphon /etc/init.d/owrt-psiphon /usr/libexec/owrt-psiphon /usr/libexec/rpcd/owrt-psiphon /usr/share/luci/menu.d/luci-app-owrt-psiphon.json /usr/share/rpcd/acl.d/luci-app-owrt-psiphon.json /www/luci-static/resources/view/owrt-psiphon /var/run/owrt-psiphon* /tmp/luci-indexcache /tmp/luci-modulecache
/etc/init.d/rpcd restart >/dev/null 2>&1 || true
'
if command -v setsid >/dev/null 2>&1; then
setsid sh -c "$uninst_cmd" </dev/null >/dev/null 2>&1 &
else
sh -c "$uninst_cmd" </dev/null >/dev/null 2>&1 &
fi
}
case "${1:-status}" in
status) status ;;
start) start_service ;;
stop) stop_service ;;
set_country) set_country "${2:-}" ;;
set_auto) set_auto "${2:-1}" "${3:-0}" "${4:-0}" ;;
probe) probe ;;
scan) scan_start ;;
scan_status) scan_status ;;
_scan) scan_worker ;;
watchdog) watchdog ;;
check_update) check_update ;;
apply_update) apply_update ;;
check_warp_update) check_warp_update ;;
apply_warp_update) apply_warp_update ;;
uninstall) uninstall_all ;;
*) reply false 'Неизвестная команда'; exit 1 ;;
esac
EOF

cat << 'EOF' > /usr/libexec/rpcd/owrt-psiphon
#!/bin/sh
CTL="/usr/libexec/owrt-psiphon/owrt-psiphonctl"
case "$1" in
    list)
        printf '{"status":{},"start":{},"stop":{},"set_country":{"country":"NL"},"set_auto":{"autostart":"1","auto_scan_boot":"0","watchdog_hours":"0"},"probe":{},"scan":{},"scan_status":{},"check_update":{},"apply_update":{},"check_warp_update":{},"apply_warp_update":{},"uninstall":{}}\n'
        ;;
    call)
        input="$(cat)"; [ -n "$input" ] || input="{}"
        case "$2" in
            status|start|stop|probe|scan|scan_status|check_update|apply_update|check_warp_update|apply_warp_update|uninstall)
                exec "$CTL" "$2"
                ;;
            set_country)
                country="$(jsonfilter -s "$input" -e '@.country' 2>/dev/null || true)"
                exec "$CTL" set_country "$country"
                ;;
            set_auto)
                as="$(jsonfilter -s "$input" -e '@.autostart' 2>/dev/null || true)"
                sb="$(jsonfilter -s "$input" -e '@.auto_scan_boot' 2>/dev/null || true)"
                wh="$(jsonfilter -s "$input" -e '@.watchdog_hours' 2>/dev/null || true)"
                [ "$as" = "true" ] && as="1"; [ "$as" = "false" ] && as="0"
                [ "$sb" = "true" ] && sb="1"; [ "$sb" = "false" ] && sb="0"
                case "$as" in 0|1) ;; *) printf '{"ok":false,"message":"Некорректный autostart"}\n'; exit 1 ;; esac
                case "$sb" in 0|1) ;; *) printf '{"ok":false,"message":"Некорректный auto_scan_boot"}\n'; exit 1 ;; esac
                case "$wh" in 0|1|6|12|24|boot) ;; *) printf '{"ok":false,"message":"Некорректный watchdog_hours"}\n'; exit 1 ;; esac
                exec "$CTL" set_auto "$as" "$sb" "$wh"
                ;;
            *) printf '{"ok":false,"message":"Unknown method"}\n'; exit 1 ;;
        esac
        ;;
esac
EOF

printf '{"admin/services/owrt-psiphon":{"title":"OWRTPsiphon","order":90,"action":{"type":"view","path":"owrt-psiphon/main"},"depends":{"acl":["luci-app-owrt-psiphon"]}}}\n' > /usr/share/luci/menu.d/luci-app-owrt-psiphon.json
printf '{"luci-app-owrt-psiphon":{"description":"OWRTPsiphon LuCI access","read":{"ubus":{"owrt-psiphon":["status","scan_status","check_update","check_warp_update"]}},"write":{"ubus":{"owrt-psiphon":["start","stop","set_country","set_auto","probe","scan","apply_update","apply_warp_update","uninstall"]}}}}\n' > /usr/share/rpcd/acl.d/luci-app-owrt-psiphon.json

cat << 'EOF' > /www/luci-static/resources/view/owrt-psiphon/main.js
'use strict';
'require view';
'require rpc';
'require ui';

var callStatus = rpc.declare({ object: 'owrt-psiphon', method: 'status', expect: {} }),
    callScanStatus = rpc.declare({ object: 'owrt-psiphon', method: 'scan_status', expect: {} }),
    callStart = rpc.declare({ object: 'owrt-psiphon', method: 'start', expect: {} }),
    callStop = rpc.declare({ object: 'owrt-psiphon', method: 'stop', expect: {} }),
    callSetCountry = rpc.declare({ object: 'owrt-psiphon', method: 'set_country', params: ['country'], expect: {} }),
    callSetAuto = rpc.declare({ object: 'owrt-psiphon', method: 'set_auto', params: ['autostart', 'auto_scan_boot', 'watchdog_hours'], expect: {} }),
    callProbe = rpc.declare({ object: 'owrt-psiphon', method: 'probe', expect: {} }),
    callScan = rpc.declare({ object: 'owrt-psiphon', method: 'scan', expect: {} }),
    callCheckUpdate = rpc.declare({ object: 'owrt-psiphon', method: 'check_update', expect: {} }),
    callApplyUpdate = rpc.declare({ object: 'owrt-psiphon', method: 'apply_update', expect: {} }),
    callCheckWarpUpdate = rpc.declare({ object: 'owrt-psiphon', method: 'check_warp_update', expect: {} }),
    callApplyWarpUpdate = rpc.declare({ object: 'owrt-psiphon', method: 'apply_warp_update', expect: {} }),
    callUninstall = rpc.declare({ object: 'owrt-psiphon', method: 'uninstall', expect: {} });

var CODES = ['NL','DE','FI','SE','PL','AT','CH','FR','GB','NO','BE','CZ','DK','EE','LV','ES','IT','PT','IE','BG','RO','HR','HU','RS','SK','SG','JP','IN','AU','CA','US'];

return view.extend({
	render: function() {
		var status = {}, scan = {}, pollActive = false, switching = false, sub = 'socks5://192.168.1.1:8086#OWRTPsiphon';
		var root = E('div', { 'class': 'cbi-map' }),
		    stateTable = E('div', { 'class': 'table' }),
		    scanBox = E('div', { 'style': 'margin:8px 0;font-style:italic' }),
		    appVerLabel = E('span', { 'style': 'font-weight:bold;min-width:65px;display:inline-block' }, 'v0.4.4'),
		    appUpdStatus = E('span', { 'style': 'margin-left:8px' }),
		    warpVerLabel = E('span', { 'style': 'font-weight:bold;min-width:65px;display:inline-block' }, 'v1.2.6'),
		    warpUpdStatus = E('span', { 'style': 'margin-left:8px' });

		var chkAutostart = E('input', { 'type': 'checkbox' });

		var selWatchdog = E('select', { 'class': 'cbi-input-select', 'style': 'min-width:175px' }, [
			E('option', { 'value': '0' }, 'Отключена'),
			E('option', { 'value': 'boot' }, 'При перезагрузке'),
			E('option', { 'value': '1' }, 'Раз в 1 час'),
			E('option', { 'value': '6' }, 'Раз в 6 часов'),
			E('option', { 'value': '12' }, 'Раз в 12 часов'),
			E('option', { 'value': '24' }, 'Раз в 24 часа')
		]);

		function notify(m, t) {
			ui.addNotification(null, E('p', {}, m), t || 'info');
		}

		function copyText(txt) {
			if (navigator.clipboard && navigator.clipboard.writeText) {
				navigator.clipboard.writeText(txt).then(function() { notify('Скопировано: ' + txt); });
			} else {
				var ta = E('textarea', { 'style': 'position:fixed;opacity:0' }, txt);
				document.body.appendChild(ta);
				ta.select();
				document.execCommand('copy');
				document.body.removeChild(ta);
				notify('Скопировано: ' + txt);
			}
		}

		function buildCountrySelect() {
			var pingMap = {}, ordered = [], seen = {};
			if (scan.results) {
				scan.results.forEach(function(r) {
					if (r.country) {
						seen[r.country] = true;
						ordered.push(r.country);
						pingMap[r.country] = (r.state === 'ok' && r.latency_ms != null) ? (r.latency_ms + ' мс') : '—';
					}
				});
			}
			CODES.forEach(function(c) {
				if (!seen[c]) {
					ordered.push(c);
					pingMap[c] = '—';
				}
			});
			var cur = status.country || 'NL';
			if (status.socks_ok && status.exit_country === cur && status.latency_ms) {
				pingMap[cur] = status.latency_ms + ' мс';
			}

			return E('select', {
				'class': 'cbi-input-select',
				'style': 'min-width:175px;font-weight:bold;margin:0',
				'disabled': switching ? 'disabled' : null,
				'change': function() {
					var chosen = this.value;
					if (!chosen || chosen === status.country) return;
					switching = true;
					this.disabled = true;
					notify('Переключение на ' + chosen + '...', 'info');
					callSetCountry(chosen).then(function(r) {
						switching = false;
						notify((r && r.message) || chosen, (r && r.ok) ? 'info' : 'error');
						return updateStatus();
					}).catch(function(e) {
						switching = false;
						notify('Ошибка: ' + e, 'error');
						return updateStatus();
					});
				}
			}, ordered.map(function(c) {
				return E('option', { 'value': c, 'selected': c === cur ? 'selected' : null }, c + ' (' + (pingMap[c] || '—') + ')');
			}));
		}

		function updateStatus() {
			return Promise.all([ callStatus(), callScanStatus() ]).then(function(v) {
				status = v[0] || {};
				scan = v[1] || {};
				sub = status.subscription || sub;

				chkAutostart.checked = (status.autostart == 1);
				var whVal = String(status.watchdog_hours || '0');
				if (whVal === '0' && status.auto_scan_boot == 1) whVal = 'boot';
				selWatchdog.value = whVal;

				appVerLabel.textContent = 'v' + (status.app_version || '0.4.4');
				warpVerLabel.textContent = status.version || 'v1.2.6';

				var wp = status.running
					? E('span', { 'style': 'color:#16a34a;font-weight:bold' }, 'Запущен')
					: E('span', { 'style': 'color:#dc2626;font-weight:bold' }, 'Остановлен');

				var sk = status.socks_ok
					? E('span', { 'style': 'color:#16a34a;font-weight:bold' }, 'Активен (' + status.bind + ':' + status.port + ')')
					: (status.listening
						? E('span', { 'style': 'color:#d97706;font-weight:bold' }, 'Нет ответа')
						: E('span', { 'style': 'color:#dc2626' }, 'Не запущен'));

				var ipC = status.exit_ip ? (status.exit_ip + (status.exit_country ? ' (' + status.exit_country + ')' : '')) : '—';

				stateTable.innerHTML = '';
				[
					['warp-plus', wp],
					['SOCKS5 прокси', sk],
					['Выходной IP', ipC],
					['Страна выхода', E('div', { 'style': 'display:inline-flex;align-items:center;gap:8px;flex-wrap:wrap' }, [
						buildCountrySelect(),
						E('button', {
							'class': 'btn cbi-button-positive',
							'style': 'margin:0',
							'disabled': scan.running ? 'disabled' : null,
							'click': function() { action(callScan(), 'Автоподбор запущен'); }
						}, scan.running ? 'Подбор...' : 'Автоподбор по пингу')
					])],
					['Ссылка для Steer', E('div', { 'style': 'display:inline-flex;align-items:center;gap:8px;flex-wrap:wrap' }, [
						E('code', { 'style': 'user-select:all' }, sub),
						E('button', { 'class': 'btn cbi-button-action', 'style': 'margin:0', 'click': function() { copyText(sub); } }, 'Копировать')
					])]
				].forEach(function(r) {
					stateTable.appendChild(E('div', { 'class': 'tr' }, [
						E('div', { 'class': 'td left', 'style': 'font-weight:bold;width:30%' }, r[0]),
						E('div', { 'class': 'td left' }, r[1])
					]));
				});

				scanBox.textContent = scan.running ? ('Проверка узлов: ' + (scan.current || '…')) : '';
				scanBox.style.display = scan.running ? 'block' : 'none';
			});
		}

		function pollScan() {
			if (pollActive || !scan.running) return;
			pollActive = true;
			function tick() {
				updateStatus().then(function() {
					if (scan.running) {
						window.setTimeout(tick, 4000);
					} else {
						pollActive = false;
					}
				}).catch(function() {
pollActive = false;
});
}
window.setTimeout(tick, 2500);
}
function action(p, okMsg) {
p.then(function(r) {
notify((r && r.message) || okMsg, (r && r.ok) ? 'info' : 'error');
return updateStatus();
}).then(function() {
pollScan();
}).catch(function(e) {
notify('Ошибка RPC: ' + e, 'error');
});
}
function btn(l, c, fn) {
return E('button', { 'class': 'btn ' + c, 'click': fn, 'style': 'margin:4px 8px 4px 0' }, l);
}
function saveAuto() {
var wh = selWatchdog.value || '0';
var sb = (wh === 'boot') ? '1' : '0';
action(callSetAuto(
chkAutostart.checked ? '1' : '0',
sb,
wh
), 'Настройки автоматизации сохранены');
}
chkAutostart.addEventListener('change', saveAuto);
selWatchdog.addEventListener('change', saveAuto);
root.appendChild(E('h2', {}, 'OWRTPsiphon'));
root.appendChild(E('p', {}, 'Управление Psiphon (bepass-org/warp-plus --cfon) для Steer без изменения сетевой конфигурации.'));
root.appendChild(stateTable);
root.appendChild(scanBox);
root.appendChild(E('div', { 'class': 'cbi-section' }, [
E('h3', {}, 'Автоматизация и контроль узлов'),
E('div', { 'class': 'cbi-value' }, [
E('label', { 'class': 'cbi-value-title' }, 'Автостарт службы при загрузке'),
E('div', { 'class': 'cbi-value-field' }, chkAutostart)
]),
E('div', { 'class': 'cbi-value' }, [
E('label', { 'class': 'cbi-value-title' }, 'Проверка доступности и фейловер'),
E('div', { 'class': 'cbi-value-field' }, [
selWatchdog,
E('div', { 'style': 'font-size:12px;color:#666;margin-top:4px' }, 'При падении узла переключает на следующий рабочий по возрастанию пинга.')
])
])
]));
root.appendChild(E('div', { 'class': 'cbi-section' }, [
E('h3', {}, 'Управление и обновления'),
E('div', { 'style': 'margin-bottom:10px' }, [
btn('Запустить', 'cbi-button-positive', function() { action(callStart(), 'Запущено'); }),
btn('Остановить', 'cbi-button-negative', function() { action(callStop(), 'Остановлено'); }),
btn('Проверить SOCKS', 'cbi-button', function() { action(callProbe(), 'Проверено'); }),
btn('Удалить приложение', 'cbi-button-negative', function() {
if (!confirm('Удалить OWRTPsiphon, бинарник warp-plus, кэш и настройки?')) return;
if (!confirm('Подтвердите полное удаление (Steer и Zapret не пострадают).')) return;
callUninstall().then(function(r) {
notify((r && r.message) || 'Удалено', 'warning');
window.setTimeout(function() { window.location.href = '/cgi-bin/luci/'; }, 2500);
});
})
]),
E('div', { 'class': 'table' }, [
E('div', { 'class': 'tr' }, [
E('div', { 'class': 'td left', 'style': 'font-weight:bold;width:30%;vertical-align:middle' }, 'Версия OWRTPsiphon'),
E('div', { 'class': 'td left', 'style': 'vertical-align:middle' }, [
E('div', { 'style': 'display:inline-flex;align-items:center;gap:8px;flex-wrap:wrap' }, [
appVerLabel,
E('button', {
'class': 'btn cbi-button-action',
'style': 'margin:0',
'click': function() {
appUpdStatus.innerHTML = 'Проверка GitHub...';
callCheckUpdate().then(function(r) {
appUpdStatus.innerHTML = '';
if (!r || !r.ok) {
appUpdStatus.textContent = (r && r.message) || 'Ошибка проверки';
return;
}
appUpdStatus.appendChild(E('span', {}, r.message));
if (r.has_update) {
appUpdStatus.appendChild(E('button', {
'class': 'btn cbi-button-positive',
'style': 'margin-left:8px',
'click': function() {
if (!confirm('Установить обновление v' + r.remote_version + '?')) return;
appUpdStatus.textContent = 'Установка обновления...';
callApplyUpdate().then(function(res) {
notify((res && res.message) || 'Обновление...', (res && res.ok) ? 'info' : 'error');
if (res && res.ok) {
window.setTimeout(function() {
window.location.href = window.location.pathname + '?v=' + Date.now();
}, 6000);
}
});
}
}, 'Установить v' + r.remote_version));
}
}).catch(function(e) {
appUpdStatus.textContent = 'Ошибка запроса: ' + e;
});
}
}, 'Проверить обновления'),
appUpdStatus
])
])
]),
E('div', { 'class': 'tr' }, [
E('div', { 'class': 'td left', 'style': 'font-weight:bold;width:30%;vertical-align:middle' }, 'Версия warp-plus'),
E('div', { 'class': 'td left', 'style': 'vertical-align:middle' }, [
E('div', { 'style': 'display:inline-flex;align-items:center;gap:8px;flex-wrap:wrap' }, [
warpVerLabel,
E('button', {
'class': 'btn cbi-button-action',
'style': 'margin:0',
'click': function() {
warpUpdStatus.innerHTML = 'Проверка GitHub...';
callCheckWarpUpdate().then(function(r) {
warpUpdStatus.innerHTML = '';
if (!r || !r.ok) {
warpUpdStatus.textContent = (r && r.message) || 'Ошибка проверки';
return;
}
warpUpdStatus.appendChild(E('span', {}, r.message));
if (r.has_update) {
warpUpdStatus.appendChild(E('button', {
'class': 'btn cbi-button-positive',
'style': 'margin-left:8px',
'click': function() {
if (!confirm('Обновить warp-plus до v' + r.remote_version + '?')) return;
warpUpdStatus.textContent = 'Загрузка и обновление warp-plus...';
callApplyWarpUpdate().then(function(res) {
notify((res && res.message) || 'Готово', (res && res.ok) ? 'info' : 'error');
warpUpdStatus.textContent = (res && res.message) || '';
updateStatus();
});
}
}, 'Установить v' + r.remote_version));
}
}).catch(function(e) {
warpUpdStatus.textContent = 'Ошибка запроса: ' + e;
});
}
}, 'Проверить обновления'),
warpUpdStatus
])
])
])
])
]));
updateStatus().then(function() { pollScan(); });
return root;
},
handleSaveApply: null,
handleSave: null,
handleReset: null
});
EOF
printf '%s\n' "$APP_VER" > "$APP/app.version"
chmod 755 /etc/init.d/owrt-psiphon /usr/libexec/rpcd/owrt-psiphon /usr/libexec/owrt-psiphon/owrt-psiphonctl
chmod 644 /usr/share/luci/menu.d/luci-app-owrt-psiphon.json /usr/share/rpcd/acl.d/luci-app-owrt-psiphon.json /www/luci-static/resources/view/owrt-psiphon/main.js
/usr/libexec/owrt-psiphon/owrt-psiphonctl set_auto \
    "$(uci -q get owrt-psiphon.main.autostart || echo 1)" \
    "$(uci -q get owrt-psiphon.main.auto_scan_boot || echo 0)" \
    "$(uci -q get owrt-psiphon.main.watchdog_hours || echo 0)" >/dev/null 2>&1 || true
touch /www/luci-static/resources/view/owrt-psiphon/main.js
rm -rf /tmp/luci-indexcache /tmp/luci-modulecache
rm -rf "$TMP"
/etc/init.d/rpcd restart >/dev/null 2>&1 || true
/etc/init.d/uhttpd restart >/dev/null 2>&1 || true
log "Установка OWRTPsiphon v${APP_VER} завершена. Служба не запускалась."
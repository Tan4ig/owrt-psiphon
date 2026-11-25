#!/bin/sh
# VERSION=0.3.3
# OWRTPsiphon Alpha 3.3 — lightweight LuCI controller for bepass-org/warp-plus (--cfon).
set -eu

APP_VER="0.3.3"
APP="/opt/owrt-psiphon"
TMP="/tmp/owrt-psiphon-install"
VERSION="1.2.6"

ASSET="https://github.com/bepass-org/warp-plus/releases/download/v${VERSION}/warp-plus_linux-arm64.zip"
ASSET_SHA256="c0b430c117eaa33513fa012aca983303ee88a4bda0f935dc62ff016109e492f3"

log() { printf '\033[1;32m[OWRTPsiphon]\033[0m %s\n' "$*"; }
fail() { printf '\033[1;31m[ОШИБКА]\033[0m %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" = 0 ] || fail 'Запустите от root.'
[ "$(uname -m)" = aarch64 ] || fail "Нужна aarch64, текущая: $(uname -m)"

if ! command -v curl >/dev/null 2>&1; then
    if command -v wget >/dev/null 2>&1; then
        curl() { wget -qO- "$@"; }
    elif command -v uclient-fetch >/dev/null 2>&1; then
        curl() { uclient-fetch -O- "$@"; }
    else
        fail 'Не найден curl, wget или uclient-fetch.'
    fi
fi

[ -d /www/luci-static/resources/view ] || fail 'Не найден LuCI.'

mkdir -p "$TMP" "$APP" "$APP/cache"
printf '%s\n' "$APP_VER" > "$APP/app.version"

# Проверяем, нужно ли скачивать бинарник (если его нет или если запрошено обновление)
if [ ! -x "$APP/warp-plus" ] || [ "${FORCE_WARP_UPDATE:-0}" = "1" ]; then
	log "Загрузка warp-plus v${VERSION}..."
	curl -fL --retry 3 --connect-timeout 20 "$ASSET" -o "$TMP/wp.zip" || fail 'Ошибка загрузки warp-plus.'
	command -v sha256sum >/dev/null 2>&1 || apk add --no-cache coreutils-sha256sum
	[ "$(sha256sum "$TMP/wp.zip" | awk '{print $1}')" = "$ASSET_SHA256" ] || fail 'SHA256 не совпал.'
	command -v unzip >/dev/null 2>&1 || apk add --no-cache unzip
	unzip -o "$TMP/wp.zip" -d "$TMP/u" >/dev/null
	cp "$(find "$TMP/u" -type f -name warp-plus | head -1)" "$APP/warp-plus" && chmod 755 "$APP/warp-plus"
fi

# Создание конфига, если его нет
if [ ! -f /etc/config/owrt-psiphon ]; then
	printf "config owrt-psiphon 'main'\n\toption enabled '1'\n\toption autostart '1'\n\toption auto_scan_boot '0'\n\toption watchdog_hours '0'\n\toption country 'NL'\n\toption last_good_country 'NL'\n\toption bind '192.168.1.1'\n\toption port '8086'\n\toption endpoint '188.114.99.150:1701'\n\toption test_url 'http://example.com'\n" > /etc/config/owrt-psiphon
else
	[ -n "$(uci -q get owrt-psiphon.main.last_good_country || true)" ] || uci -q set owrt-psiphon.main.last_good_country="$(uci -q get owrt-psiphon.main.country || echo NL)"
	[ -n "$(uci -q get owrt-psiphon.main.autostart || true)" ] || uci -q set owrt-psiphon.main.autostart='1'
	[ -n "$(uci -q get owrt-psiphon.main.auto_scan_boot || true)" ] || uci -q set owrt-psiphon.main.auto_scan_boot='0'
	[ -n "$(uci -q get owrt-psiphon.main.watchdog_hours || true)" ] || uci -q set owrt-psiphon.main.watchdog_hours='0'
	uci -q commit owrt-psiphon
fi

mkdir -p /etc/init.d /usr/libexec/rpcd /usr/libexec/owrt-psiphon /usr/share/luci/menu.d /usr/share/rpcd/acl.d /www/luci-static/resources/view/owrt-psiphon

cat << 'EOF' > /etc/init.d/owrt-psiphon
#!/bin/sh /etc/rc.common
USE_PROCD=1; START=95; STOP=10
BIN="/opt/owrt-psiphon/warp-plus"; CACHE_DIR="/opt/owrt-psiphon/cache"

start_service() {
	[ -x "$BIN" ] || return 1; . /lib/functions.sh; config_load owrt-psiphon
	local enabled country bind port endpoint test_url
	config_get_bool enabled main enabled 0; [ "$enabled" -eq 1 ] || return 0
	config_get country main country NL; config_get bind main bind 192.168.1.1; config_get port main port 8086
	config_get endpoint main endpoint "188.114.99.150:1701"; config_get test_url main test_url "http://example.com"
	mkdir -p "$CACHE_DIR"; procd_open_instance main
	if [ -n "$endpoint" ]; then procd_set_param command "$BIN" -4 -e "$endpoint" --cfon --country "$country" -b "${bind}:${port}" --cache-dir "$CACHE_DIR" --test-url "$test_url"
	else procd_set_param command "$BIN" -4 --cfon --country "$country" -b "${bind}:${port}" --cache-dir "$CACHE_DIR" --test-url "$test_url"; fi
	procd_set_param respawn 3600 5 5; procd_set_param stdout 1; procd_set_param stderr 1; procd_close_instance
}

boot() {
	. /lib/functions.sh; config_load owrt-psiphon; local autostart auto_scan_boot
	config_get_bool autostart main autostart 1; config_get_bool auto_scan_boot main auto_scan_boot 0
	if [ "$autostart" -eq 1 ]; then
		uci -q set owrt-psiphon.main.enabled='1' && uci -q commit owrt-psiphon; start
		[ "$auto_scan_boot" -eq 1 ] && (sleep 15 && /usr/libexec/owrt-psiphon/owrt-psiphonctl scan) >/dev/null 2>&1 &
	else uci -q set owrt-psiphon.main.enabled='0' && uci -q commit owrt-psiphon; fi
}
service_triggers() { procd_add_reload_trigger owrt-psiphon; }
EOF

cat << 'EOF' > /usr/libexec/owrt-psiphon/owrt-psiphonctl
#!/bin/sh
APP=/opt/owrt-psiphon; BIN="$APP/warp-plus"; CONFIG=owrt-psiphon.main
REPO_URL="https://raw.githubusercontent.com/Tan4ig/owrt-psiphon/main/install.sh"
BIND="$(uci -q get ${CONFIG}.bind || echo 192.168.1.1)"; PORT="$(uci -q get ${CONFIG}.port || echo 8086)"
COUNTRY="$(uci -q get ${CONFIG}.country || echo NL)"; ENDPOINT="$(uci -q get ${CONFIG}.endpoint || echo 188.114.99.150:1701)"
TEST_URL="$(uci -q get ${CONFIG}.test_url || echo http://example.com)"
SCANFILE="$APP/scan-results.json"; SCAN_PIDFILE=/var/run/owrt-psiphon-scan.pid; PROBE_FILE=/var/run/owrt-psiphon-probe.state
ALL_COUNTRIES="NL DE FI SE PL AT CH FR GB NO BE CZ DK EE LV ES IT PT IE BG RO HR HU RS SK SG JP IN AU CA US"
SCAN_LIST="NL DE FI SE PL AT CH FR GB NO"

valid_country() { for c in $ALL_COUNTRIES; do [ "$c" = "$1" ] && return 0; done; return 1; }
json_escape() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g; s/\r//g; s/\n/\\n/g'; }
reply() { printf '{"ok":%s,"message":"%s"}\n' "$1" "$(json_escape "$2")"; }
managed_pid() { p="$(ubus call service list '{"name":"owrt-psiphon"}' 2>/dev/null | sed -n '/"pid"/s/[^0-9]//gp' | head -n 1)"; [ -n "$p" ] && kill -0 "$p" 2>/dev/null && printf '%s\n' "$p"; }
port_listening() { netstat -lnt 2>/dev/null | awk '{print $4}' | grep -Eq "(:|\.)${PORT}$"; }

probe_internal() {
	port_listening || return 1
	out="$(curl -4 -fsS --max-time 10 --socks5-hostname "${BIND}:${PORT}" -w '\n%{time_starttransfer}' https://ipinfo.io/json 2>/dev/null)" || return 1
	body="$(printf '%s\n' "$out" | sed '$d')"; secs="$(printf '%s\n' "$out" | tail -n 1)"
	cc="$(printf '%s' "$body" | sed -n 's/.*"country"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)"
	ip="$(printf '%s' "$body" | sed -n 's/.*"ip"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)"
	[ -n "$cc" ] || return 1; ms="$(awk -v s="$secs" 'BEGIN { printf "%d", s*1000 }')"
	printf "PROBE_COUNTRY='%s'\nPROBE_IP='%s'\nPROBE_MS='%s'\n" "$cc" "$ip" "$ms" > "$PROBE_FILE"
}

wait_socks_ready() { max_wait="${1:-35}"; elapsed=0; while [ "$elapsed" -lt "$max_wait" ]; do probe_internal && return 0; sleep 2; elapsed=$((elapsed + 2)); done; return 1; }

sync_cron() {
	hours="$(uci -q get ${CONFIG}.watchdog_hours || echo 0)"; CRON_FILE="/etc/crontabs/root"; mkdir -p /etc/crontabs; touch "$CRON_FILE"
	grep -v 'owrt-psiphonctl watchdog' "$CRON_FILE" > "${CRON_FILE}.tmp" 2>/dev/null || true
	case "$hours" in 1) printf '0 * * * * /usr/libexec/owrt-psiphon/owrt-psiphonctl watchdog >/dev/null 2>&1\n' >> "${CRON_FILE}.tmp" ;; 6|12|24) printf '0 */%s * * * /usr/libexec/owrt-psiphon/owrt-psiphonctl watchdog >/dev/null 2>&1\n' "$hours" >> "${CRON_FILE}.tmp" ;; esac
	mv -f "${CRON_FILE}.tmp" "$CRON_FILE"; /etc/init.d/cron restart >/dev/null 2>&1 || true
}

status() {
	running=false; pid=""; listening=false; socks_ok=false; exit_country=""; exit_ip=""; latency=""
	if p="$(managed_pid)"; then running=true; pid="$p"; fi; port_listening && listening=true
	if [ "$listening" = true ] && probe_internal; then
		socks_ok=true; exit_country="$(sed -n 's/^PROBE_COUNTRY=//p' "$PROBE_FILE" | tr -d "'" | head -n 1)"
		exit_ip="$(sed -n 's/^PROBE_IP=//p' "$PROBE_FILE" | tr -d "'" | head -n 1)"; latency="$(sed -n 's/^PROBE_MS=//p' "$PROBE_FILE" | tr -d "'" | head -n 1)"
	fi
	version="v1.2.6"; [ -x "$BIN" ] && v="$("$BIN" version 2>&1 | grep -Eo 'v?[0-9]+\.[0-9]+\.[0-9]+' | head -n 1 || true)" && [ -n "$v" ] && version="$v"
	app_ver="$(cat "$APP/app.version" 2>/dev/null | head -n 1 | tr -d '\r' || echo 0.3.3)"
	autostart="$(uci -q get ${CONFIG}.autostart || echo 1)"; auto_scan_boot="$(uci -q get ${CONFIG}.auto_scan_boot || echo 0)"; watchdog_hours="$(uci -q get ${CONFIG}.watchdog_hours || echo 0)"
	sub="socks5://${BIND}:${PORT}#OWRTPsiphon"
	printf '{"ok":true,"running":%s,"listening":%s,"socks_ok":%s,"pid":"%s","country":"%s","bind":"%s","port":%s,"version":"%s","app_version":"%s","subscription":"%s","exit_country":"%s","exit_ip":"%s","latency_ms":"%s","autostart":%s,"auto_scan_boot":%s,"watchdog_hours":%s,"scan_running":%s}\n' \
		"$running" "$listening" "$socks_ok" "$pid" "$(json_escape "$COUNTRY")" "$(json_escape "$BIND")" "$PORT" "$(json_escape "$version")" "$(json_escape "$app_ver")" "$(json_escape "$sub")" "$(json_escape "$exit_country")" "$(json_escape "$exit_ip")" "$(json_escape "$latency")" "$autostart" "$auto_scan_boot" "$watchdog_hours" "$([ -s "$SCAN_PIDFILE" ] && kill -0 "$(cat "$SCAN_PIDFILE" 2>/dev/null)" 2>/dev/null && echo true || echo false)"
}

check_update() {
	local_ver="$(cat "$APP/app.version" 2>/dev/null | head -n 1 | tr -d '\r' || echo 0.3.3)"
	remote_head="$(curl -fsSL --max-time 8 "$REPO_URL" 2>/dev/null | head -n 5 || true)"
	[ -n "$remote_head" ] || { printf '{"ok":false,"message":"Не удалось связаться с GitHub"}\n'; return 1; }
	remote_ver="$(printf '%s\n' "$remote_head" | sed -n 's/^# VERSION=\([0-9][0-9.]*\).*/\1/p' | head -n 1)"
	if [ -n "$remote_ver" ] && [ "$remote_ver" != "$local_ver" ]; then printf '{"ok":true,"has_update":true,"remote_version":"%s","message":"Доступно обновление v%s (текущая v%s)"}\n' "$remote_ver" "$remote_ver" "$local_ver"
	else printf '{"ok":true,"has_update":false,"remote_version":"%s","message":"Установлена последняя версия (v%s)"}\n' "$local_ver" "$local_ver"; fi
}

check_warp_update() {
	local_ver="$(status | sed -n 's/.*"version":"\([^"]*\)".*/\1/p')"
	remote_json="$(curl -fsSL --max-time 8 "https://api.github.com/repos/bepass-org/warp-plus/releases/latest" 2>/dev/null || true)"
	remote_ver="$(printf '%s' "$remote_json" | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -n 1)"
	if [ -n "$remote_ver" ] && [ "$remote_ver" != "$local_ver" ]; then printf '{"ok":true,"has_update":true,"remote_version":"%s","message":"Доступно обновление %s (текущая %s)"}\n' "$remote_ver" "$remote_ver" "$local_ver"
	else printf '{"ok":true,"has_update":false,"remote_version":"%s","message":"Установлена последняя версия (%s)"}\n' "$local_ver" "$local_ver"; fi
}

apply_update() {
	tmp_upd="/tmp/owrt-psiphon-update.sh"; curl -fsSL --max-time 15 "$REPO_URL" -o "$tmp_upd" 2>/dev/null || { rm -f "$tmp_upd"; reply false 'Ошибка загрузки'; return 1; }
	head -n 5 "$tmp_upd" | grep -q 'OWRTPsiphon' || { rm -f "$tmp_upd"; reply false 'Неверный файл'; return 1; }
	chmod 755 "$tmp_upd"; reply true 'Обновление OWRTPsiphon запущено. Страница обновится.'
	(sleep 1; sh "$tmp_upd" >/dev/null 2>&1 || true; rm -f "$tmp_upd") >/dev/null 2>&1 &
}

apply_warp_update() {
	reply true 'Обновление warp-plus запущено. Страница обновится.'
	(sleep 1; FORCE_WARP_UPDATE=1 curl -fsSL --max-time 15 "$REPO_URL" -o /tmp/owrt-warp-upd.sh && sh /tmp/owrt-warp-upd.sh >/dev/null 2>&1 || true; /etc/init.d/owrt-psiphon restart >/dev/null 2>&1; rm -f /tmp/owrt-warp-upd.sh) >/dev/null 2>&1 &
}

start_service() {
	managed_pid >/dev/null && { wait_socks_ready 10 && reply true 'Служба уже запущена' || reply false 'Процесс запущен, SOCKS5 не отвечает'; return 0; }
	uci -q set ${CONFIG}.enabled='1' && uci -q commit owrt-psiphon; /etc/init.d/owrt-psiphon enable >/dev/null 2>&1 || true; /etc/init.d/owrt-psiphon start >/dev/null 2>&1 || true
	if wait_socks_ready 35; then uci -q set ${CONFIG}.last_good_country="$COUNTRY" && uci -q commit owrt-psiphon; reply true "Служба запущена ($COUNTRY)"
	else reply false 'SOCKS5 не поднялся за 35 с'; return 1; fi
}

stop_service() { uci -q set ${CONFIG}.enabled='0' && uci -q commit owrt-psiphon; /etc/init.d/owrt-psiphon stop >/dev/null 2>&1 || true; rm -f "$PROBE_FILE"; reply true 'Служба остановлена'; }

safe_restart() {
	new_country="$1"; old_country="$(uci -q get ${CONFIG}.last_good_country || uci -q get ${CONFIG}.country || echo NL)"
	uci -q set ${CONFIG}.country="$new_country" && uci -q set ${CONFIG}.enabled='1' && uci -q commit owrt-psiphon; /etc/init.d/owrt-psiphon restart >/dev/null 2>&1 || true
	if wait_socks_ready 35; then uci -q set ${CONFIG}.last_good_country="$new_country" && uci -q commit owrt-psiphon; reply true "Переключено на $new_country"; return 0
	else
		if [ -n "$old_country" ] && [ "$old_country" != "$new_country" ]; then
			uci -q set ${CONFIG}.country="$old_country" && uci -q commit owrt-psiphon; /etc/init.d/owrt-psiphon restart >/dev/null 2>&1 || true; wait_socks_ready 30 || true
			reply false "Узел $new_country не ответил; откат на $old_country"
		else reply false "Узел $new_country не прошёл проверку"; fi; return 1
	fi
}

set_country() { c="$1"; valid_country "$c" || { reply false 'Неверный код страны'; return 1; }; if managed_pid >/dev/null; then safe_restart "$c"; else uci -q set ${CONFIG}.country="$c" && uci -q commit owrt-psiphon; reply true "Выбрана страна $c"; fi; }

set_auto() {
	uci -q set ${CONFIG}.autostart="${1:-1}" && uci -q set ${CONFIG}.auto_scan_boot="${2:-0}" && uci -q set ${CONFIG}.watchdog_hours="${3:-0}" && uci -q commit owrt-psiphon
	[ "${1:-1}" = "1" ] && /etc/init.d/owrt-psiphon enable >/dev/null 2>&1 || /etc/init.d/owrt-psiphon disable >/dev/null 2>&1 || true
	sync_cron; reply true 'Настройки автоматизации сохранены'
}

probe() { if probe_internal; then reply true "SOCKS5 активен: $(sed -n 's/^PROBE_IP=//p' "$PROBE_FILE" | tr -d "'") ($(sed -n 's/^PROBE_COUNTRY=//p' "$PROBE_FILE" | tr -d "'")), $(sed -n 's/^PROBE_MS=//p' "$PROBE_FILE" | tr -d "'") мс"; else rm -f "$PROBE_FILE"; reply false 'SOCKS5 не отвечает'; return 1; fi; }
scan_status() { [ -s "$SCANFILE" ] && cat "$SCANFILE" || printf '{"running":false,"message":"Автоподбор ещё не запускался","results":[]}\n'; }
scan_start() { [ -x "$BIN" ] || { reply false 'Бинарник не найден'; return 1; }; [ -s "$SCAN_PIDFILE" ] && kill -0 "$(cat "$SCAN_PIDFILE" 2>/dev/null)" 2>/dev/null && { reply false 'Уже выполняется'; return 1; }; "$0" _scan </dev/null >/dev/null 2>&1 & echo $! > "$SCAN_PIDFILE"; reply true 'Автоподбор запущен'; }

build_sorted_json() {
	sort -t '|' -k1,1n -k2,2n "$1" 2>/dev/null | awk -F'|' 'BEGIN{printf "["} {if(NR>1)printf ","; printf "{\"country\":\"%s\",\"exit_country\":\"%s\",\"ip\":\"%s\",\"latency_ms\":%s,\"state\":\"%s\"}", $3, $4, $5, $2, $6} END{printf "]"}'
}

scan_worker() {
	probe_pid=""; tmp_lines="/tmp/owrt-scan-lines.$$"; trap 'rm -f "$SCAN_PIDFILE" "$tmp_lines"; [ -n "$probe_pid" ] && kill -9 "$probe_pid" 2>/dev/null || true' EXIT INT TERM
	was_running=0; old_country="$COUNTRY"; managed_pid >/dev/null && was_running=1; mkdir -p "$APP/cache-scan"; : > "$tmp_lines"; best_country=""; best_ms=999999
	for c in $SCAN_LIST; do
		printf '{"running":true,"current":"%s","best":"%s","best_ms":%s,"results":%s}\n' "$c" "$best_country" "$([ "$best_ms" -eq 999999 ] && echo null || echo "$best_ms")" "$(build_sorted_json "$tmp_lines")" > "$SCANFILE"
		if [ -n "$ENDPOINT" ]; then "$BIN" -4 -e "$ENDPOINT" --cfon --country "$c" -b 127.0.0.1:18086 --cache-dir "$APP/cache-scan" --test-url "$TEST_URL" >/dev/null 2>&1 &
		else "$BIN" -4 --cfon --country "$c" -b 127.0.0.1:18086 --cache-dir "$APP/cache-scan" --test-url "$TEST_URL" >/dev/null 2>&1 & fi
		probe_pid=$!; result=""; got=""; ip=""; ms="null"; state="timeout"; rank=2; n=0
		while [ "$n" -lt 10 ]; do sleep 2; kill -0 "$probe_pid" 2>/dev/null || break; netstat -lnt 2>/dev/null | awk '{print $4}' | grep -Eq '(:|\.)18086$' && result="$(curl -4 -fsS --max-time 5 --socks5-hostname 127.0.0.1:18086 -w '\n%{time_starttransfer}' https://ipinfo.io/json 2>/dev/null)" && break; n=$((n + 1)); done
		kill "$probe_pid" 2>/dev/null || true; sleep 1; kill -0 "$probe_pid" 2>/dev/null && kill -9 "$probe_pid" 2>/dev/null || true; probe_pid=""
		if [ -n "$result" ]; then
			body="$(printf '%s\n' "$result" | sed '$d')"; secs="$(printf '%s\n' "$result" | tail -n 1)"
			got="$(printf '%s' "$body" | sed -n 's/.*"country"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)"
			ip="$(printf '%s' "$body" | sed -n 's/.*"ip"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)"; calc_ms="$(awk -v s="$secs" 'BEGIN { printf "%d", s*1000 }')"
			if [ "$got" = "$c" ] && [ "$calc_ms" -gt 10 ]; then state="ok"; rank=1; ms="$calc_ms"; [ "$ms" -lt "$best_ms" ] && { best_ms="$ms"; best_country="$c"; }
			else state="fail"; got=""; ip=""; ms="null"; fi
		fi
		printf '%s|%s|%s|%s|%s|%s\n' "$rank" "$ms" "$c" "$got" "$ip" "$state" >> "$tmp_lines"
	done
	final_json="$(build_sorted_json "$tmp_lines")"
	if [ -n "$best_country" ]; then
		if [ "$was_running" -eq 1 ] && [ "$best_country" != "$old_country" ]; then safe_restart "$best_country" >/dev/null 2>&1 && msg="Лучший узел: $best_country (${best_ms} мс). Переключено." || msg="Лучший узел: $best_country (${best_ms} мс), откат на $old_country."
		else uci -q set ${CONFIG}.country="$best_country" && uci -q commit owrt-psiphon; msg="Лучший узел: $best_country (${best_ms} мс)."; fi
		printf '{"running":false,"current":"","best":"%s","best_ms":%s,"message":"%s","results":%s}\n' "$best_country" "$best_ms" "$msg" "$final_json" > "$SCANFILE"
	else printf '{"running":false,"current":"","best":"","best_ms":null,"message":"Рабочих узлов не найдено","results":%s}\n' "$final_json" > "$SCANFILE"; fi
}

watchdog() {
	[ "$(uci -q get ${CONFIG}.enabled || echo 0)" = "1" ] || return 0; probe_internal && return 0; cur="$(uci -q get ${CONFIG}.country || echo NL)"
	if [ -s "$SCANFILE" ]; then for next_c in $(sed 's/},{/}\n{/g' "$SCANFILE" | grep '"state":"ok"' | sed -n 's/.*"country":"\([A-Z][A-Z]\)".*/\1/p'); do [ "$next_c" = "$cur" ] && continue; safe_restart "$next_c" >/dev/null 2>&1 && return 0; done; fi
	scan_worker
}

uninstall_all() {
	reply true 'Удаление OWRTPsiphon запущено.'
	(sleep 1; /etc/init.d/owrt-psiphon stop >/dev/null 2>&1 || true; /etc/init.d/owrt-psiphon disable >/dev/null 2>&1 || true
	[ -f /etc/crontabs/root ] && grep -v 'owrt-psiphonctl watchdog' /etc/crontabs/root > /etc/crontabs/root.tmp 2>/dev/null && mv -f /etc/crontabs/root.tmp /etc/crontabs/root && /etc/init.d/cron restart >/dev/null 2>&1 || true
	killall warp-plus >/dev/null 2>&1 || true
	rm -rf /opt/owrt-psiphon /etc/config/owrt-psiphon /etc/init.d/owrt-psiphon /usr/libexec/owrt-psiphon /usr/libexec/rpcd/owrt-psiphon /usr/share/luci/menu.d/luci-app-owrt-psiphon.json /usr/share/rpcd/acl.d/luci-app-owrt-psiphon.json /www/luci-static/resources/view/owrt-psiphon /var/run/owrt-psiphon* /tmp/luci-indexcache
	/etc/init.d/rpcd restart >/dev/null 2>&1 || true) >/dev/null 2>&1 &
}

case "${1:-status}" in
	status) status ;; start) start_service ;; stop) stop_service ;; set_country) set_country "${2:-}" ;; set_auto) set_auto "${2:-1}" "${3:-0}" "${4:-0}" ;;
	probe) probe ;; scan) scan_start ;; scan_status) scan_status ;; _scan) scan_worker ;; watchdog) watchdog ;; check_update) check_update ;; check_warp_update) check_warp_update ;;
	apply_update) apply_update ;; apply_warp_update) apply_warp_update ;; uninstall) uninstall_all ;; *) reply false 'Неизвестная команда'; exit 1 ;;
esac
EOF

cat << 'EOF' > /usr/libexec/rpcd/owrt-psiphon
#!/bin/sh
CTL="/usr/libexec/owrt-psiphon/owrt-psiphonctl"
case "$1" in
	list) printf '{"status":{},"start":{},"stop":{},"set_country":{"country":"NL"},"set_auto":{"autostart":1,"auto_scan_boot":0,"watchdog_hours":0},"probe":{},"scan":{},"scan_status":{},"check_update":{},"check_warp_update":{},"apply_update":{},"apply_warp_update":{},"uninstall":{}}\n' ;;
	call) read -r input || input="{}"
		case "$2" in
			status|start|stop|probe|scan|scan_status|check_update|check_warp_update|apply_update|apply_warp_update|uninstall) "$CTL" "$2" ;;
			set_country) "$CTL" set_country "$(printf '%s' "$input" | sed -n 's/.*"country"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')" ;;
			set_auto) "$CTL" set_auto "$(printf '%s' "$input" | sed -n 's/.*"autostart"[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/p')" "$(printf '%s' "$input" | sed -n 's/.*"auto_scan_boot"[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/p')" "$(printf '%s' "$input" | sed -n 's/.*"watchdog_hours"[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/p')" ;;
			*) printf '{"ok":false,"message":"Unknown method"}\n' ;;
		esac ;;
esac
EOF

printf '{"admin/services/owrt-psiphon":{"title":"OWRTPsiphon","order":90,"action":{"type":"view","path":"owrt-psiphon/main"},"depends":{"acl":["luci-app-owrt-psiphon"]}}}\n' > /usr/share/luci/menu.d/luci-app-owrt-psiphon.json
printf '{"luci-app-owrt-psiphon":{"description":"OWRTPsiphon LuCI access","read":{"ubus":{"owrt-psiphon":["status","scan_status","check_update","check_warp_update"]}},"write":{"ubus":{"owrt-psiphon":["start","stop","set_country","set_auto","probe","scan","apply_update","apply_warp_update","uninstall"]}}}}\n' > /usr/share/rpcd/acl.d/luci-app-owrt-psiphon.json

cat << 'EOF' > /www/luci-static/resources/view/owrt-psiphon/main.js
'use strict'; 'require view'; 'require rpc'; 'require ui';
var callStatus = rpc.declare({ object: 'owrt-psiphon', method: 'status', expect: {} }), callScanStatus = rpc.declare({ object: 'owrt-psiphon', method: 'scan_status', expect: {} }), callStart = rpc.declare({ object: 'owrt-psiphon', method: 'start', expect: {} }), callStop = rpc.declare({ object: 'owrt-psiphon', method: 'stop', expect: {} }), callSetCountry = rpc.declare({ object: 'owrt-psiphon', method: 'set_country', params: ['country'], expect: {} }), callSetAuto = rpc.declare({ object: 'owrt-psiphon', method: 'set_auto', params: ['autostart', 'auto_scan_boot', 'watchdog_hours'], expect: {} }), callProbe = rpc.declare({ object: 'owrt-psiphon', method: 'probe', expect: {} }), callScan = rpc.declare({ object: 'owrt-psiphon', method: 'scan', expect: {} }), callCheckUpdate = rpc.declare({ object: 'owrt-psiphon', method: 'check_update', expect: {} }), callCheckWarpUpdate = rpc.declare({ object: 'owrt-psiphon', method: 'check_warp_update', expect: {} }), callApplyUpdate = rpc.declare({ object: 'owrt-psiphon', method: 'apply_update', expect: {} }), callApplyWarpUpdate = rpc.declare({ object: 'owrt-psiphon', method: 'apply_warp_update', expect: {} }), callUninstall = rpc.declare({ object: 'owrt-psiphon', method: 'uninstall', expect: {} });
var COUNTRIES = { 'NL': 'Нидерланды', 'DE': 'Германия', 'FI': 'Финляндия', 'SE': 'Швеция', 'PL': 'Польша', 'AT': 'Австрия', 'CH': 'Швейцария', 'FR': 'Франция', 'GB': 'Великобритания', 'NO': 'Норвегия', 'BE': 'Бельгия', 'CZ': 'Чехия', 'DK': 'Дания', 'EE': 'Эстония', 'LV': 'Латвия', 'ES': 'Испания', 'IT': 'Италия', 'PT': 'Португалия', 'IE': 'Ирландия', 'BG': 'Болгария', 'RO': 'Румыния', 'HR': 'Хорватия', 'HU': 'Венгрия', 'RS': 'Сербия', 'SK': 'Словакия', 'SG': 'Сингапур', 'JP': 'Япония', 'IN': 'Индия', 'AU': 'Австралия', 'CA': 'Канада', 'US': 'США' };
var CODES = Object.keys(COUNTRIES);
return view.extend({
	render: function() {
		var status = {}, scan = {}, pollActive = false, switching = false, sub = 'socks5://192.168.1.1:8086#OWRTPsiphon';
		var root = E('div', { 'class': 'cbi-map' });
		var chkAutostart = E('input', { 'type': 'checkbox' }), chkScanBoot = E('input', { 'type': 'checkbox' });
		var selWatchdog = E('select', { 'class': 'cbi-input-select' }, [E('option', { 'value': '0' }, 'Отключена'), E('option', { 'value': '1' }, 'Раз в 1 час'), E('option', { 'value': '6' }, 'Раз в 6 часов'), E('option', { 'value': '12' }, 'Раз в 12 часов'), E('option', { 'value': '24' }, 'Раз в 24 часа')]);
		function notify(m, t) { ui.addNotification(null, E('p', {}, m), t || 'info'); }
		function copyText(txt) { if (navigator.clipboard && navigator.clipboard.writeText) navigator.clipboard.writeText(txt).then(function() { notify('Скопировано: ' + txt); }); else { var ta = E('textarea', { 'style': 'position:fixed;opacity:0' }, txt); document.body.appendChild(ta); ta.select(); document.execCommand('copy'); document.body.removeChild(ta); notify('Скопировано: ' + txt); } }
		
		function buildCountrySelect() {
			var pingMap = {}, ordered = [], seen = {};
			if (scan.results) scan.results.forEach(function(r) { if (r.country) { seen[r.country] = true; ordered.push(r.country); pingMap[r.country] = (r.state === 'ok' && r.latency_ms != null) ? (r.latency_ms + ' мс') : '—'; } });
			CODES.forEach(function(c) { if (!seen[c]) { ordered.push(c); pingMap[c] = '—'; } });
			var cur = status.country || 'NL'; if (status.socks_ok && status.exit_country === cur && status.latency_ms) pingMap[cur] = status.latency_ms + ' мс';
			var best = (scan.best && scan.best === cur) ? ' (Лучший)' : '';
			var opts = ordered.map(function(c) { return E('option', { 'value': c, 'selected': c === cur ? 'selected' : null }, c + ' — ' + (COUNTRIES[c] || c) + ' (' + (pingMap[c] || '—') + ')' + (c === cur ? best : '')); });
			return E('div', { 'style': 'display:flex; gap:8px; flex-wrap:wrap; align-items:center;' }, [
				E('select', { 'class': 'cbi-input-select', 'style': 'flex:1; min-width:200px;', 'disabled': switching ? 'disabled' : null, 'change': function() { var chosen = this.value; if (!chosen || chosen === status.country) return; switching = true; this.disabled = true; notify('Переключение на ' + chosen + '...', 'info'); callSetCountry(chosen).then(function(r) { switching = false; notify((r && r.message) || chosen, (r && r.ok) ? 'info' : 'error'); return updateStatus(); }).catch(function(e) { switching = false; notify('Ошибка: ' + e, 'error'); return updateStatus(); }); } }, opts),
				E('button', { 'class': 'btn cbi-button-positive', 'style': 'white-space:nowrap; margin:0;', 'disabled': scan.running ? 'disabled' : null, 'click': function() { action(callScan(), 'Автоподбор запущен'); } }, scan.running ? 'Подбор...' : 'Автоподбор')
			]);
		}

		var stateRows = E('div', {});
		var scanBox = E('div', { 'style': 'margin:8px 0;font-style:italic; text-align:center;' });
		var updateAppBox = E('div', { 'style': 'margin-top:8px' });
		var updateWarpBox = E('div', { 'style': 'margin-top:8px' });

		function updateStatus() {
			return Promise.all([ callStatus(), callScanStatus() ]).then(function(v) {
				status = v[0] || {}; scan = v[1] || {}; sub = status.subscription || sub;
				chkAutostart.checked = String(status.autostart) === '1';
				chkScanBoot.checked = String(status.auto_scan_boot) === '1';
				selWatchdog.value = String(status.watchdog_hours || 0);

				var wp = status.running ? E('span', { 'style': 'color:#16a34a;font-weight:bold' }, 'Запущен') : E('span', { 'style': 'color:#dc2626;font-weight:bold' }, 'Остановлен');
				var sk = status.socks_ok ? E('span', { 'style': 'color:#16a34a;font-weight:bold' }, 'Активен (' + status.bind + ':' + status.port + ')') : (status.listening ? E('span', { 'style': 'color:#d97706;font-weight:bold' }, 'Нет ответа') : E('span', { 'style': 'color:#dc2626' }, 'Не запущен'));
				var ipC = status.exit_ip ? (status.exit_ip + (status.exit_country ? ' (' + status.exit_country + ')' : '')) : '—';

				stateRows.innerHTML = '';
				[
					['warp-plus', wp],
					['SOCKS5 прокси', sk],
					['Выходной IP', ipC],
					['Страна выхода', buildCountrySelect()],
					['Ссылка для Steer', E('div', { 'style': 'display:flex; gap:8px; flex-wrap:wrap; align-items:center;' }, [
						E('code', { 'style': 'user-select:all; word-break:break-all;' }, sub),
						E('button', { 'class': 'btn cbi-button-action', 'style': 'margin:0;', 'click': function() { copyText(sub); } }, 'Копировать')
					])]
				].forEach(function(r) { 
					stateRows.appendChild(E('div', { 'class': 'cbi-value' }, [
						E('label', { 'class': 'cbi-value-title' }, r[0]),
						E('div', { 'class': 'cbi-value-field' }, r[1])
					])); 
				});
				scanBox.textContent = scan.running ? 'Проверка узлов: ' + (scan.current || '…') : (scan.message || '');
			});
		}

		function pollScan() { if (pollActive || !scan.running) return; pollActive = true; function tick() { updateStatus().then(function() { if (scan.running) window.setTimeout(tick, 4000); else pollActive = false; }).catch(function() { pollActive = false; }); } window.setTimeout(tick, 2500); }
		function action(p, okMsg) { p.then(function(r) { notify((r && r.message) || okMsg, (r && r.ok) ? 'info' : 'error'); return updateStatus(); }).then(function() { pollScan(); }).catch(function(e) { notify('Ошибка RPC: ' + e, 'error'); }); }
		function btn(l, c, fn) { return E('button', { 'class': 'btn ' + c, 'click': fn, 'style': 'margin:4px' }, l); }
		function saveAuto() { action(callSetAuto(chkAutostart.checked ? 1 : 0, chkScanBoot.checked ? 1 : 0, parseInt(selWatchdog.value, 10) || 0), 'Настройки сохранены'); }
		chkAutostart.addEventListener('change', saveAuto); chkScanBoot.addEventListener('change', saveAuto); selWatchdog.addEventListener('change', saveAuto);

		root.appendChild(E('h2', {}, 'OWRTPsiphon')); 
		root.appendChild(E('p', { 'class': 'cbi-map-descr' }, 'Управление Psiphon (bepass-org/warp-plus --cfon) для Steer без изменения сетевой конфигурации.')); 
		root.appendChild(stateRows); 
		root.appendChild(scanBox);
		
		root.appendChild(E('div', { 'class': 'cbi-section' }, [
			E('h3', {}, 'Автоматизация и контроль узлов'), 
			E('div', { 'class': 'cbi-value' }, [E('label', { 'class': 'cbi-value-title' }, 'Автостарт службы при загрузке'), E('div', { 'class': 'cbi-value-field' }, chkAutostart)]), 
			E('div', { 'class': 'cbi-value' }, [E('label', { 'class': 'cbi-value-title' }, 'Автоподбор страны при включении'), E('div', { 'class': 'cbi-value-field' }, chkScanBoot)]), 
			E('div', { 'class': 'cbi-value' }, [E('label', { 'class': 'cbi-value-title' }, 'Проверка и переход на лучший'), E('div', { 'class': 'cbi-value-field' }, [selWatchdog, E('div', { 'class': 'cbi-value-description', 'style': 'margin-top:4px;' }, 'При падении узла переключает на следующий рабочий по возрастанию пинга.')])])
		]));

		root.appendChild(E('div', { 'class': 'cbi-section' }, [
			E('h3', {}, 'Управление и обновления'), 
			E('div', { 'style': 'margin-bottom:12px;' }, [
				btn('Запустить', 'cbi-button-positive', function() { action(callStart(), 'Запущено'); }), 
				btn('Остановить', 'cbi-button-negative', function() { action(callStop(), 'Остановлено'); }), 
				btn('Проверить SOCKS', 'cbi-button', function() { action(callProbe(), 'Проверено'); }), 
				btn('Удалить приложение', 'cbi-button-negative', function() { if (!confirm('Удалить OWRTPsiphon, бинарник warp-plus, кэш и настройки?')) return; callUninstall().then(function(r) { notify((r && r.message) || 'Удалено', 'warning'); window.setTimeout(function() { window.location.href = '/cgi-bin/luci/'; }, 2500); }); })
			]),
			E('div', { 'class': 'cbi-value' }, [
				E('label', { 'class': 'cbi-value-title' }, 'Версия OWRTPsiphon'), 
				E('div', { 'class': 'cbi-value-field', 'style': 'display:flex; gap:8px; flex-wrap:wrap; align-items:center;' }, [
					E('span', { 'style': 'font-weight:bold;' }, 'v' + (status.app_version || '0.3.3')), 
					E('button', { 'class': 'btn cbi-button-action', 'style': 'margin:0;', 'click': function() { updateAppBox.textContent = 'Проверка GitHub...'; callCheckUpdate().then(function(r) { updateAppBox.innerHTML = ''; if (!r || !r.ok) { updateAppBox.textContent = (r && r.message) || 'Ошибка проверки'; return; } updateAppBox.appendChild(E('span', { 'style': 'margin-right:10px' }, r.message)); if (r.has_update) updateAppBox.appendChild(btn('Установить v' + r.remote_version, 'cbi-button-positive', function() { if (!confirm('Установить обновление v' + r.remote_version + '?')) return; callApplyUpdate().then(function(res) { notify((res && res.message) || 'Обновление...', 'info'); window.setTimeout(function() { window.location.reload(); }, 4500); }); })); }); } }, 'Проверить')
				])
			]),
			updateAppBox,
			E('div', { 'class': 'cbi-value', 'style': 'margin-top:8px;' }, [
				E('label', { 'class': 'cbi-value-title' }, 'Версия warp-plus'), 
				E('div', { 'class': 'cbi-value-field', 'style': 'display:flex; gap:8px; flex-wrap:wrap; align-items:center;' }, [
					E('span', { 'style': 'font-weight:bold;' }, status.version || '—'), 
					E('button', { 'class': 'btn cbi-button-action', 'style': 'margin:0;', 'click': function() { updateWarpBox.textContent = 'Проверка GitHub API...'; callCheckWarpUpdate().then(function(r) { updateWarpBox.innerHTML = ''; if (!r || !r.ok) { updateWarpBox.textContent = (r && r.message) || 'Ошибка проверки'; return; } updateWarpBox.appendChild(E('span', { 'style': 'margin-right:10px' }, r.message)); if (r.has_update) updateWarpBox.appendChild(btn('Обновить ' + r.remote_version, 'cbi-button-positive', function() { if (!confirm('Обновить warp-plus до ' + r.remote_version + '?')) return; callApplyWarpUpdate().then(function(res) { notify((res && res.message) || 'Обновление...', 'info'); window.setTimeout(function() { window.location.reload(); }, 4500); }); })); }); } }, 'Проверить')
				])
			]),
			updateWarpBox
		]));

		updateStatus().then(function() { pollScan(); }); return root;
	},
	handleSaveApply: null, handleSave: null, handleReset: null
});
EOF

chmod 755 /etc/init.d/owrt-psiphon /usr/libexec/rpcd/owrt-psiphon /usr/libexec/owrt-psiphon/owrt-psiphonctl
chmod 644 /usr/share/luci/menu.d/luci-app-owrt-psiphon.json /usr/share/rpcd/acl.d/luci-app-owrt-psiphon.json /www/luci-static/resources/view/owrt-psiphon/main.js

/usr/libexec/owrt-psiphon/owrt-psiphonctl set_auto "$(uci -q get owrt-psiphon.main.autostart || echo 1)" "$(uci -q get owrt-psiphon.main.auto_scan_boot || echo 0)" "$(uci -q get owrt-psiphon.main.watchdog_hours || echo 0)" >/dev/null 2>&1 || true
/etc/init.d/rpcd restart >/dev/null 2>&1 || true
rm -f /tmp/luci-indexcache
rm -rf "$TMP"

if ! netstat -lnt 2>/dev/null | awk '{print $4}' | grep -Eq '(:|\.)8086$'; then
	uci -q set owrt-psiphon.main.enabled='1' && uci -q commit owrt-psiphon
	/etc/init.d/owrt-psiphon enable >/dev/null 2>&1 || true; /etc/init.d/owrt-psiphon start >/dev/null 2>&1 || true
fi

log "Установка OWRTPsiphon v${APP_VER} завершена."
#!/bin/sh
# OWRTPsiphon Alpha 2 — experimental LuCI controller for bepass-org/warp-plus (--cfon) on OpenWrt.
# Repository: https://github.com/Tan4ig/owrt-psiphon
# Independent community project; not affiliated with Psiphon Inc. or Cloudflare, Inc.
# Upstream engine: https://github.com/bepass-org/warp-plus (MIT License).
set -eu

APP="/opt/owrt-psiphon"
TMP="/tmp/owrt-psiphon-install"
VERSION="1.2.6"
ASSET="https://github.com/bepass-org/warp-plus/releases/download/v${VERSION}/warp-plus_linux-arm64.zip"
ASSET_SHA256="c0b430c117eaa33513fa012aca983303ee88a4bda0f935dc62ff016109e492f3"
TESTED_LOCAL_SHA256="8a8f48b096a630fc07a1a361b61c7f72ba28657afe88dff2a523bc70432a29a6"

red='\033[1;31m'; yellow='\033[1;33m'; green='\033[1;32m'; reset='\033[0m'
log() { printf "${green}[OWRTPsiphon]${reset} %s\n" "$*"; }
warn() { printf "${yellow}[ВНИМАНИЕ]${reset} %s\n" "$*"; }
fail() { printf "${red}[ОШИБКА]${reset} %s\n" "$*" >&2; exit 1; }

[ "$(id -u)" = 0 ] || fail 'Запусти установщик от root.'
[ "$(uname -m)" = aarch64 ] || fail "Нужна архитектура aarch64, обнаружена: $(uname -m)"
command -v curl >/dev/null 2>&1 || fail 'Не найден curl.'
[ -d /www/luci-static/resources/view ] || fail 'Не обнаружен LuCI; установка отменена.'

mkdir -p "$TMP" "$APP" "$APP/cache"

if [ -x "$APP/warp-plus" ] && "$APP/warp-plus" version >/dev/null 2>&1; then
	log 'Использую уже установленный бинарник /opt/owrt-psiphon/warp-plus.'
else
	if [ -x /tmp/wp-test/unpacked/warp-plus ]; then
		if command -v sha256sum >/dev/null 2>&1; then
			got="$(sha256sum /tmp/wp-test/unpacked/warp-plus 2>/dev/null | awk '{print $1}')"
		elif busybox --list 2>/dev/null | grep -qx sha256sum; then
			got="$(busybox sha256sum /tmp/wp-test/unpacked/warp-plus 2>/dev/null | awk '{print $1}')"
		else
			got=""
		fi
		if [ "$got" = "$TESTED_LOCAL_SHA256" ]; then
			log 'Использую проверенный локальный бинарник из /tmp/wp-test.'
			cp /tmp/wp-test/unpacked/warp-plus "$APP/warp-plus.new"
		fi
	fi

	if [ ! -s "$APP/warp-plus.new" ]; then
		log "Загружаю warp-plus v${VERSION} для ARM64..."
		curl -fL --retry 3 --connect-timeout 20 "$ASSET" -o "$TMP/warp-plus.zip" || fail 'Не удалось скачать warp-plus.'
		if command -v sha256sum >/dev/null 2>&1; then
			SHA="sha256sum"
		elif busybox --list 2>/dev/null | grep -qx sha256sum; then
			SHA="busybox sha256sum"
		else
			log 'Устанавливаю coreutils-sha256sum...'
			apk add --no-cache coreutils-sha256sum || fail 'Не удалось установить coreutils-sha256sum.'
			SHA="sha256sum"
		fi
		got="$($SHA "$TMP/warp-plus.zip" | awk '{print $1}')"
		[ "$got" = "$ASSET_SHA256" ] || fail "SHA256 архива не совпал: $got"
		if command -v unzip >/dev/null 2>&1; then
			unzip -o "$TMP/warp-plus.zip" -d "$TMP/unpacked" >/dev/null
		elif busybox --list 2>/dev/null | grep -qx unzip; then
			busybox unzip -o "$TMP/warp-plus.zip" -d "$TMP/unpacked" >/dev/null
		else
			apk add --no-cache unzip || fail 'Не удалось установить unzip.'
			unzip -o "$TMP/warp-plus.zip" -d "$TMP/unpacked" >/dev/null
		fi
		found="$(find "$TMP/unpacked" -type f -name warp-plus | head -1)"
		[ -n "$found" ] || fail 'В архиве не найден исполняемый файл warp-plus.'
		cp "$found" "$APP/warp-plus.new"
	fi

	chmod 755 "$APP/warp-plus.new"
	"$APP/warp-plus.new" version >/dev/null 2>&1 || fail 'Бинарник warp-plus не запускается.'
	mv -f "$APP/warp-plus.new" "$APP/warp-plus"
fi

if [ ! -f /etc/config/owrt-psiphon ]; then
	cat << 'EOF' > /etc/config/owrt-psiphon
config owrt-psiphon 'main'
	option enabled '0'
	option country 'NL'
	option last_good_country 'NL'
	option bind '192.168.1.1'
	option port '8086'
	option endpoint '188.114.99.150:1701'
	option test_url 'http://example.com/'
	option auto '0'
EOF
else
	cur_test="$(uci -q get owrt-psiphon.main.test_url || true)"
	if [ -z "$cur_test" ] || [ "$cur_test" = "https://ipinfo.io/country" ]; then
		uci -q set owrt-psiphon.main.test_url='http://example.com/'
	fi
	[ -n "$(uci -q get owrt-psiphon.main.last_good_country || true)" ] || uci -q set owrt-psiphon.main.last_good_country="$(uci -q get owrt-psiphon.main.country || echo NL)"
	[ -n "$(uci -q get owrt-psiphon.main.enabled || true)" ] || uci -q set owrt-psiphon.main.enabled='0'
	uci -q commit owrt-psiphon
fi

mkdir -p /etc/init.d /usr/libexec/rpcd /usr/libexec/owrt-psiphon \
         /usr/share/luci/menu.d /usr/share/rpcd/acl.d \
         /www/luci-static/resources/view/owrt-psiphon

cat << 'EOF' > /etc/init.d/owrt-psiphon
#!/bin/sh /etc/rc.common

USE_PROCD=1
START=95
STOP=10

BIN="/opt/owrt-psiphon/warp-plus"
CACHE_DIR="/opt/owrt-psiphon/cache"

start_service() {
	[ -x "$BIN" ] || {
		logger -t owrt-psiphon "binary not installed: $BIN"
		return 1
	}

	. /lib/functions.sh
	config_load owrt-psiphon

	local enabled country bind port endpoint test_url
	config_get_bool enabled main enabled 0
	[ "$enabled" -eq 1 ] || return 0

	config_get country main country NL
	config_get bind main bind 192.168.1.1
	config_get port main port 8086
	config_get endpoint main endpoint "188.114.99.150:1701"
	config_get test_url main test_url "http://example.com/"

	mkdir -p "$CACHE_DIR"

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

service_triggers() {
	procd_add_reload_trigger owrt-psiphon
}
EOF

cat << 'EOF' > /usr/libexec/owrt-psiphon/owrt-psiphonctl
#!/bin/sh
# OWRTPsiphon control helper (Alpha 2). No Steer/Zapret/firewall rules are modified.

APP=/opt/owrt-psiphon
BIN="$APP/warp-plus"
CACHE_DIR="$APP/cache"
CONFIG=owrt-psiphon.main
BIND="$(uci -q get ${CONFIG}.bind || echo 192.168.1.1)"
PORT="$(uci -q get ${CONFIG}.port || echo 8086)"
COUNTRY="$(uci -q get ${CONFIG}.country || echo NL)"
ENDPOINT="$(uci -q get ${CONFIG}.endpoint || echo 188.114.99.150:1701)"
TEST_URL="$(uci -q get ${CONFIG}.test_url || echo http://example.com/)"

SCANFILE=/var/run/owrt-psiphon-scan.json
SCAN_PIDFILE=/var/run/owrt-psiphon-scan.pid
PROBE_FILE=/var/run/owrt-psiphon-probe.state

ALL_COUNTRIES="NL DE BE FR GB PL CZ AT CH FI SE NO EE LV DK ES IT PT IE BG RO HR HU RS SK SG JP IN AU CA US"

valid_country() {
	for c in $ALL_COUNTRIES; do
		[ "$c" = "$1" ] && return 0
	done
	return 1
}

json_escape() {
	printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g; s/\r//g; s/\n/\\n/g'
}

reply() {
	printf '{"ok":%s,"message":"%s"}\n' "$1" "$(json_escape "$2")"
}

managed_pid() {
	p="$(ubus call service list '{"name":"owrt-psiphon"}' 2>/dev/null | sed -n '/"pid"/s/[^0-9]//gp' | head -n 1)"
	if [ -n "$p" ] && kill -0 "$p" 2>/dev/null; then
		printf '%s\n' "$p"
		return 0
	fi
	return 1
}

warp_pids() {
	scan_pid=""
	[ -s "$SCAN_PIDFILE" ] && scan_pid="$(cat "$SCAN_PIDFILE" 2>/dev/null || true)"
	for p in $(pidof warp-plus 2>/dev/null || true); do
		[ "$p" = "$scan_pid" ] && continue
		printf '%s\n' "$p"
	done
}

is_our_manual_process() {
	p="$1"
	mp="$(managed_pid 2>/dev/null || true)"
	[ -n "$mp" ] && [ "$p" = "$mp" ] && return 1
	[ -r "/proc/$p/cmdline" ] || return 1
	cmd="$(tr '\000' ' ' < "/proc/$p/cmdline" 2>/dev/null || true)"
	case "$cmd" in
		*"--cfon"*"${BIND}:${PORT}"*) return 0 ;;
		*) return 1 ;;
	esac
}

port_listening() {
	netstat -lnt 2>/dev/null | awk '{print $4}' | grep -Eq "(:|\.)${PORT}$"
}

probe_internal() {
	port_listening || return 1
	out="$(curl -4 -fsS --max-time 10 --socks5-hostname "${BIND}:${PORT}" \
		-w '\n%{time_starttransfer}' https://ipinfo.io/json 2>/dev/null)" || return 1

	body="$(printf '%s\n' "$out" | sed '$d')"
	secs="$(printf '%s\n' "$out" | tail -n 1)"
	cc="$(printf '%s' "$body" | sed -n 's/.*"country"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)"
	ip="$(printf '%s' "$body" | sed -n 's/.*"ip"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)"
	[ -n "$cc" ] || return 1
	ms="$(awk -v s="$secs" 'BEGIN { printf "%d", s*1000 }')"

	umask 077
	printf "PROBE_COUNTRY='%s'\nPROBE_IP='%s'\nPROBE_MS='%s'\n" "$cc" "$ip" "$ms" > "$PROBE_FILE"
	return 0
}

wait_socks_ready() {
	max_wait="${1:-35}"
	elapsed=0
	while [ "$elapsed" -lt "$max_wait" ]; do
		if probe_internal; then
			return 0
		fi
		sleep 2
		elapsed=$((elapsed + 2))
	done
	return 1
}

status() {
	running=false; managed=false; pid=""; manual=false; listening=false; socks_ok=false
	if p="$(managed_pid)"; then
		running=true; managed=true; pid="$p"
	else
		for p in $(warp_pids); do
			if is_our_manual_process "$p"; then
				running=true; manual=true; pid="$p"
				break
			fi
		done
	fi

	port_listening && listening=true

	exit_country=""; exit_ip=""; latency=""
	if [ "$listening" = true ]; then
		if probe_internal; then
			socks_ok=true
		fi
	fi

	if [ "$socks_ok" = true ] && [ -s "$PROBE_FILE" ]; then
		exit_country="$(sed -n 's/^PROBE_COUNTRY=//p' "$PROBE_FILE" | tr -d "'" | head -n 1)"
		exit_ip="$(sed -n 's/^PROBE_IP=//p' "$PROBE_FILE" | tr -d "'" | head -n 1)"
		latency="$(sed -n 's/^PROBE_MS=//p' "$PROBE_FILE" | tr -d "'" | head -n 1)"
	fi

	auto="$(uci -q get ${CONFIG}.auto || echo 0)"
	version="неизвестна"
	if [ -x "$BIN" ]; then
		v="$("$BIN" version 2>/dev/null | head -n 1 | tr -d '\r')"
		[ -n "$v" ] && version="$v"
	fi

	sub="socks5://${BIND}:${PORT}#OWRTPsiphon"
	printf '{"ok":true,"installed":%s,"running":%s,"managed":%s,"manual":%s,"listening":%s,"socks_ok":%s,"pid":"%s","country":"%s","bind":"%s","port":%s,"auto":%s,"version":"%s","subscription":"%s","exit_country":"%s","exit_ip":"%s","latency_ms":"%s","scan_running":%s}\n' \
		"$([ -x "$BIN" ] && echo true || echo false)" \
		"$running" "$managed" "$manual" "$listening" "$socks_ok" "$pid" \
		"$(json_escape "$COUNTRY")" "$(json_escape "$BIND")" "$PORT" \
		"$([ "$auto" = 1 ] && echo true || echo false)" \
		"$(json_escape "$version")" "$(json_escape "$sub")" \
		"$(json_escape "$exit_country")" "$(json_escape "$exit_ip")" "$(json_escape "$latency")" \
		"$([ -s "$SCAN_PIDFILE" ] && kill -0 "$(cat "$SCAN_PIDFILE" 2>/dev/null)" 2>/dev/null && echo true || echo false)"
}

start_service() {
	if managed_pid >/dev/null; then
		if wait_socks_ready 10; then
			reply true 'Служба уже запущена и SOCKS5 активен'
		else
			reply false 'Процесс запущен, но SOCKS5 ещё поднимается или не отвечает'
		fi
		return 0
	fi
	if port_listening; then
		reply false 'Порт 8086 занят. Если это ручной Psiphon, нажмите «Перенять текущий туннель».'
		return 1
	fi

	uci -q set ${CONFIG}.enabled='1'
	uci -q commit owrt-psiphon
	/etc/init.d/owrt-psiphon enable >/dev/null 2>&1 || true
	/etc/init.d/owrt-psiphon start >/dev/null 2>&1 || true

	if wait_socks_ready 35; then
		uci -q set ${CONFIG}.last_good_country="$COUNTRY"
		uci -q commit owrt-psiphon
		reply true "Служба запущена, туннель ($COUNTRY) проверен"
	else
		reply false 'Процесс запущен, но SOCKS5 не поднялся за 35 с. Проверьте logread -e owrt-psiphon.'
		return 1
	fi
}

stop_service() {
	uci -q set ${CONFIG}.enabled='0'
	uci -q commit owrt-psiphon
	/etc/init.d/owrt-psiphon stop >/dev/null 2>&1 || true
	/etc/init.d/owrt-psiphon disable >/dev/null 2>&1 || true
	rm -f "$PROBE_FILE"
	reply true 'Служба остановлена'
}

adopt_service() {
	found=""
	for p in $(warp_pids); do
		if is_our_manual_process "$p"; then found="$p"; break; fi
	done
	if [ -z "$found" ]; then
		reply false 'Ручной процесс warp-plus на порту 8086 не найден'
		return 1
	fi

	old_cache=""; old_country=""; old_endpoint=""; old_test_url=""
	if [ -r "/proc/$found/cmdline" ]; then
		prev=""
		for arg in $(tr '\000' '\n' < "/proc/$found/cmdline" 2>/dev/null || true); do
			case "$prev" in
				--cache-dir) old_cache="$arg" ;;
				--country) old_country="$arg" ;;
				-e|--endpoint) old_endpoint="$arg" ;;
				--test-url) old_test_url="$arg" ;;
			esac
			prev="$arg"
		done
	fi

	if [ -n "$old_cache" ] && [ -d "$old_cache" ] && [ "$old_cache" != "$CACHE_DIR" ]; then
		mkdir -p "$CACHE_DIR"
		cp -af "$old_cache/." "$CACHE_DIR/" 2>/dev/null || true
	fi
	[ -n "$old_country" ] && valid_country "$old_country" && uci -q set ${CONFIG}.country="$old_country"
	[ -n "$old_endpoint" ] && uci -q set ${CONFIG}.endpoint="$old_endpoint"
	if [ -n "$old_test_url" ]; then
		case "$old_test_url" in http://*) uci -q set ${CONFIG}.test_url="$old_test_url" ;; esac
	fi
	uci -q set ${CONFIG}.enabled='1'
	uci -q commit owrt-psiphon

	kill "$found" 2>/dev/null || true
	n=0
	while kill -0 "$found" 2>/dev/null && [ "$n" -lt 8 ]; do
		sleep 1; n=$((n + 1))
	done
	kill -0 "$found" 2>/dev/null && kill -9 "$found" 2>/dev/null || true

	/etc/init.d/owrt-psiphon enable >/dev/null 2>&1 || true
	/etc/init.d/owrt-psiphon start >/dev/null 2>&1 || true

	COUNTRY="$(uci -q get ${CONFIG}.country || echo NL)"
	if wait_socks_ready 35; then
		uci -q set ${CONFIG}.last_good_country="$COUNTRY"
		uci -q commit owrt-psiphon
		reply true "Туннель перенят под procd и проверен ($COUNTRY)"
	else
		reply false 'Туннель передан службе, но SOCKS5 пока не отвечает'
		return 1
	fi
}

safe_restart() {
	new_country="$1"
	old_country="$(uci -q get ${CONFIG}.last_good_country || uci -q get ${CONFIG}.country || echo NL)"

	uci -q set ${CONFIG}.country="$new_country"
	uci -q set ${CONFIG}.enabled='1'
	uci -q commit owrt-psiphon
	/etc/init.d/owrt-psiphon restart >/dev/null 2>&1 || true

	if wait_socks_ready 35; then
		uci -q set ${CONFIG}.last_good_country="$new_country"
		uci -q commit owrt-psiphon
		reply true "Страна изменена на $new_country; туннель проверен"
		return 0
	else
		if [ -n "$old_country" ] && [ "$old_country" != "$new_country" ]; then
			uci -q set ${CONFIG}.country="$old_country"
			uci -q commit owrt-psiphon
			/etc/init.d/owrt-psiphon restart >/dev/null 2>&1 || true
			wait_socks_ready 30 || true
			reply false "Страна $new_country не поднялась; выполнен откат на $old_country"
		else
			reply false "Страна $new_country не прошла проверку SOCKS5"
		fi
		return 1
	fi
}

set_country() {
	c="$1"
	valid_country "$c" || { reply false 'Недопустимый код страны'; return 1; }

	if managed_pid >/dev/null; then
		safe_restart "$c"
	elif port_listening; then
		reply false 'Сначала нажмите «Перенять текущий туннель»'
		return 1
	else
		uci -q set ${CONFIG}.country="$c"
		uci -q commit owrt-psiphon
		reply true "Выбрана страна $c. Нажмите «Запустить»."
	fi
}

probe() {
	if probe_internal; then
		cc="$(sed -n 's/^PROBE_COUNTRY=//p' "$PROBE_FILE" | tr -d "'" | head -n 1)"
		ip="$(sed -n 's/^PROBE_IP=//p' "$PROBE_FILE" | tr -d "'" | head -n 1)"
		ms="$(sed -n 's/^PROBE_MS=//p' "$PROBE_FILE" | tr -d "'" | head -n 1)"
		reply true "SOCKS5 работает: выход ${cc:-?}, IP ${ip:-?}, задержка ${ms} мс"
	else
		rm -f "$PROBE_FILE"
		reply false 'SOCKS5 не отвечает или порт 8086 не слушается'
		return 1
	fi
}

scan_status() {
	[ -s "$SCANFILE" ] && cat "$SCANFILE" || printf '{"running":false,"message":"Автоподбор ещё не запускался","results":[]}\n'
}

scan_start() {
	[ -x "$BIN" ] || { reply false 'Бинарник warp-plus не установлен'; return 1; }
	if [ -s "$SCAN_PIDFILE" ] && kill -0 "$(cat "$SCAN_PIDFILE" 2>/dev/null)" 2>/dev/null; then
		reply false 'Проверка стран уже выполняется'
		return 1
	fi
	"$0" _scan </dev/null >/dev/null 2>&1 &
	echo $! > "$SCAN_PIDFILE"
	reply true 'Проверка стран запущена на изолированном порту 18086'
}

scan_worker() {
	probe_pid=""
	trap 'rm -f "$SCAN_PIDFILE"; [ -n "$probe_pid" ] && kill -9 "$probe_pid" 2>/dev/null || true' EXIT INT TERM

	countries='NL DE BE FR GB PL CZ AT CH FI SE NO EE LV US'
	was_running=0
	old_country="$COUNTRY"
	managed_pid >/dev/null && was_running=1

	if netstat -lnt 2>/dev/null | awk '{print $4}' | grep -Eq '(:|\.)18086$'; then
		printf '{"running":false,"message":"Порт 18086 занят другим процессом","results":[]}\n' > "$SCANFILE"
		return 1
	fi

	mkdir -p "$APP/cache-scan"
	best_country=""; best_ms=999999; results='[]'
	printf '{"running":true,"current":"","best":"","best_ms":null,"results":[]}\n' > "$SCANFILE"

	for c in $countries; do
		printf '{"running":true,"current":"%s","best":"%s","best_ms":%s,"results":%s}\n' \
			"$c" "$best_country" "$([ "$best_ms" -eq 999999 ] && echo null || echo "$best_ms")" "$results" > "$SCANFILE"

		if [ -n "$ENDPOINT" ]; then
			"$BIN" -4 -e "$ENDPOINT" --cfon --country "$c" \
				-b 127.0.0.1:18086 --cache-dir "$APP/cache-scan" \
				--test-url "$TEST_URL" >/dev/null 2>&1 &
		else
			"$BIN" -4 --cfon --country "$c" \
				-b 127.0.0.1:18086 --cache-dir "$APP/cache-scan" \
				--test-url "$TEST_URL" >/dev/null 2>&1 &
		fi
		probe_pid=$!

		result=""; got=""; ip=""; ms=""; state="timeout"
		n=0
		while [ "$n" -lt 11 ]; do
			sleep 2
			kill -0 "$probe_pid" 2>/dev/null || break
			if netstat -lnt 2>/dev/null | awk '{print $4}' | grep -Eq '(:|\.)18086$'; then
				result="$(curl -4 -fsS --max-time 5 --socks5-hostname 127.0.0.1:18086 \
					-w '\n%{time_starttransfer}' https://ipinfo.io/json 2>/dev/null)" && break
			fi
			n=$((n + 1))
		done

		kill "$probe_pid" 2>/dev/null || true
		sleep 1
		kill -0 "$probe_pid" 2>/dev/null && kill -9 "$probe_pid" 2>/dev/null || true
		probe_pid=""

		if [ -n "$result" ]; then
			body="$(printf '%s\n' "$result" | sed '$d')"
			secs="$(printf '%s\n' "$result" | tail -n 1)"
			got="$(printf '%s' "$body" | sed -n 's/.*"country"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)"
			ip="$(printf '%s' "$body" | sed -n 's/.*"ip"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)"
			ms="$(awk -v s="$secs" 'BEGIN { printf "%d", s*1000 }')"
			if [ "$got" = "$c" ]; then
				state="ok"
				if [ "$ms" -lt "$best_ms" ]; then
					best_ms="$ms"
					best_country="$c"
				fi
			else
				state="mismatch"
			fi
		fi

		entry="{\"country\":\"$c\",\"exit_country\":\"${got:-}\",\"ip\":\"${ip:-}\",\"latency_ms\":${ms:-null},\"state\":\"$state\"}"
		if [ "$results" = '[]' ]; then results="[$entry]"; else results="${results%]},$entry]"; fi

		printf '{"running":true,"current":"%s","best":"%s","best_ms":%s,"results":%s}\n' \
			"$c" "$best_country" "$([ "$best_ms" -eq 999999 ] && echo null || echo "$best_ms")" "$results" > "$SCANFILE"
	done

	if [ -n "$best_country" ]; then
		if [ "$was_running" -eq 1 ] && [ "$best_country" != "$old_country" ]; then
			printf '{"running":true,"current":"Переключение на %s...","best":"%s","best_ms":%s,"results":%s}\n' \
				"$best_country" "$best_country" "$best_ms" "$results" > "$SCANFILE"
			if safe_restart "$best_country" >/dev/null 2>&1; then
				final_msg="Лучшая страна: $best_country (${best_ms} мс). Основной туннель переключён."
			else
				final_msg="Лучшая страна: $best_country (${best_ms} мс), но переключение не удалось — сохранён прежний туннель."
			fi
		else
			uci -q set ${CONFIG}.country="$best_country"
			uci -q commit owrt-psiphon
			final_msg="Лучшая страна: $best_country (${best_ms} мс)."
		fi
		printf '{"running":false,"current":"","best":"%s","best_ms":%s,"message":"%s","results":%s}\n' \
			"$best_country" "$best_ms" "$final_msg" "$results" > "$SCANFILE"
	else
		printf '{"running":false,"current":"","best":"","best_ms":null,"message":"Подходящих стран не найдено; действующий туннель сохранён","results":%s}\n' "$results" > "$SCANFILE"
	fi
}

case "${1:-status}" in
	status)      status ;;
	start)       start_service ;;
	stop)        stop_service ;;
	adopt)       adopt_service ;;
	set_country) set_country "${2:-}" ;;
	probe)       probe ;;
	scan)        scan_start ;;
	scan_status) scan_status ;;
	_scan)       scan_worker ;;
	*)           reply false 'Неизвестная команда'; exit 1 ;;
esac
EOF

cat << 'EOF' > /usr/libexec/rpcd/owrt-psiphon
#!/bin/sh

CTL="/usr/libexec/owrt-psiphon/owrt-psiphonctl"

case "$1" in
	list)
		cat << 'JSON'
{
	"status": {},
	"start": {},
	"stop": {},
	"adopt": {},
	"set_country": { "country": "NL" },
	"probe": {},
	"scan": {},
	"scan_status": {}
}
JSON
		;;
	call)
		read -r input || input="{}"
		case "$2" in
			status)      "$CTL" status ;;
			start)       "$CTL" start ;;
			stop)        "$CTL" stop ;;
			adopt)       "$CTL" adopt ;;
			probe)       "$CTL" probe ;;
			scan)        "$CTL" scan ;;
			scan_status) "$CTL" scan_status ;;
			set_country)
				c="$(printf '%s' "$input" | sed -n 's/.*"country"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
				"$CTL" set_country "$c"
				;;
			*)
				printf '{"ok":false,"message":"Unknown RPC method"}\n'
				;;
		esac
		;;
esac
EOF

cat << 'EOF' > /usr/share/luci/menu.d/luci-app-owrt-psiphon.json
{
	"admin/services/owrt-psiphon": {
		"title": "OWRTPsiphon",
		"order": 90,
		"action": {
			"type": "view",
			"path": "owrt-psiphon/main"
		},
		"depends": {
			"acl": [ "luci-app-owrt-psiphon" ]
		}
	}
}
EOF

cat << 'EOF' > /usr/share/rpcd/acl.d/luci-app-owrt-psiphon.json
{
	"luci-app-owrt-psiphon": {
		"description": "Grant access to OWRTPsiphon LuCI control",
		"read": {
			"ubus": {
				"owrt-psiphon": [ "status", "scan_status" ]
			}
		},
		"write": {
			"ubus": {
				"owrt-psiphon": [ "start", "stop", "adopt", "set_country", "probe", "scan" ]
			}
		}
	}
}
EOF

cat << 'EOF' > /www/luci-static/resources/view/owrt-psiphon/main.js
'use strict';
'require view';
'require rpc';
'require ui';

var callStatus     = rpc.declare({ object: 'owrt-psiphon', method: 'status', expect: {} });
var callScanStatus = rpc.declare({ object: 'owrt-psiphon', method: 'scan_status', expect: {} });
var callStart      = rpc.declare({ object: 'owrt-psiphon', method: 'start', expect: {} });
var callStop       = rpc.declare({ object: 'owrt-psiphon', method: 'stop', expect: {} });
var callAdopt      = rpc.declare({ object: 'owrt-psiphon', method: 'adopt', expect: {} });
var callSetCountry = rpc.declare({ object: 'owrt-psiphon', method: 'set_country', params: ['country'], expect: {} });
var callProbe      = rpc.declare({ object: 'owrt-psiphon', method: 'probe', expect: {} });
var callScan       = rpc.declare({ object: 'owrt-psiphon', method: 'scan', expect: {} });

var COUNTRIES = [
	['NL', 'NL — Нидерланды'], ['DE', 'DE — Германия'], ['BE', 'BE — Бельгия'],
	['FR', 'FR — Франция'], ['GB', 'GB — Великобритания'], ['PL', 'PL — Польша'],
	['CZ', 'CZ — Чехия'], ['AT', 'AT — Австрия'], ['CH', 'CH — Швейцария'],
	['FI', 'FI — Финляндия'], ['SE', 'SE — Швеция'], ['NO', 'NO — Норвегия'],
	['EE', 'EE — Эстония'], ['LV', 'LV — Латвия'], ['DK', 'DK — Дания'],
	['ES', 'ES — Испания'], ['IT', 'IT — Италия'], ['PT', 'PT — Португалия'],
	['IE', 'IE — Ирландия'], ['BG', 'BG — Болгария'], ['RO', 'RO — Румыния'],
	['HR', 'HR — Хорватия'], ['HU', 'HU — Венгрия'], ['RS', 'RS — Сербия'],
	['SK', 'SK — Словакия'], ['SG', 'SG — Сингапур'], ['JP', 'JP — Япония'],
	['IN', 'IN — Индия'], ['AU', 'AU — Австралия'], ['CA', 'CA — Канада'],
	['US', 'US — США']
];

return view.extend({
	render: function() {
		var status = {}, scan = {}, pollActive = false;
		var subscription = 'socks5://192.168.1.1:8086#OWRTPsiphon';

		var root = E('div', { 'class': 'cbi-map' });
		var state = E('div', { 'class': 'table' });
		var result = E('div', { 'style': 'margin-top:8px;font-weight:bold;color:#d97706' });
		var scanBox = E('div', { 'style': 'margin-top:8px' });
		var scanResults = E('div', { 'style': 'margin-top:8px' });
		var country = E('select', { 'id': 'owrt-country', 'class': 'cbi-input-select' },
			COUNTRIES.map(function(c) { return E('option', { 'value': c[0] }, c[1]); })
		);

		function notify(msg, type) {
			ui.addNotification(null, E('p', {}, msg), type || 'info');
		}

		function updateStatus() {
			return Promise.all([ callStatus(), callScanStatus() ]).then(function(v) {
				status = v[0] || {}; scan = v[1] || {};
				subscription = status.subscription || subscription;
				if (status.country) country.value = status.country;

				var procText = status.running
					? (status.managed ? 'Запущен под procd (PID ' + (status.pid || '?') + ')' : 'Работает вручную (PID ' + (status.pid || '?') + ')')
					: 'Остановлен';

				var socksText = status.socks_ok
					? 'Активен и пропускает HTTPS (' + status.bind + ':' + status.port + ')'
					: (status.listening
						? 'Порт открыт, но HTTPS не отвечает'
						: (status.running ? 'Ожидание поднятия порта ' + status.port + '...' : 'Не запущен'));

				state.innerHTML = '';
				var rows = [
					[ 'Процесс warp-plus', procText ],
					[ 'SOCKS5 прокси', socksText ],
					[ 'Выбранная страна', status.country || '—' ],
					[ 'Фактическая страна выхода', status.exit_country || '—' ],
					[ 'Выходной IP', status.exit_ip || '—' ],
					[ 'Задержка (TTFB)', status.latency_ms ? status.latency_ms + ' мс' : 'не измерена' ],
					[ 'Версия warp-plus', status.version || '—' ],
					[ 'Ссылка для Steer', subscription ]
				];
				rows.forEach(function(r) {
					state.appendChild(E('div', { 'class': 'tr' }, [
						E('div', { 'class': 'td left', 'style': 'font-weight:bold;width:34%' }, r[0]),
						E('div', { 'class': 'td' }, r[1])
					]));
				});

				scanBox.textContent = scan.running
					? 'Проверяется страна: ' + (scan.current || '…')
					: (scan.message || 'Автоподбор ещё не запускался');

				scanResults.innerHTML = '';
				if (scan.results && scan.results.length) {
					var table = E('table', { 'class': 'table' });
					table.appendChild(E('tr', { 'class': 'tr' }, [
						E('th', { 'class': 'th' }, 'Страна'),
						E('th', { 'class': 'th' }, 'Выход'),
						E('th', { 'class': 'th' }, 'Задержка'),
						E('th', { 'class': 'th' }, 'Результат')
					]));
					scan.results.forEach(function(r) {
						table.appendChild(E('tr', { 'class': 'tr' }, [
							E('td', { 'class': 'td' }, r.country || '—'),
							E('td', { 'class': 'td' }, r.exit_country || '—'),
							E('td', { 'class': 'td' }, r.latency_ms != null ? r.latency_ms + ' мс' : '—'),
							E('td', { 'class': 'td' }, r.state === 'ok' ? 'доступна' : r.state === 'mismatch' ? 'другая страна' : 'нет ответа')
						]));
					});
					scanResults.appendChild(table);
				}

				result.textContent = status.manual
					? 'Обнаружен ручной процесс Psiphon. Нажмите «Перенять текущий туннель», чтобы передать его под управление OWRTPsiphon.'
					: '';
			});
		}

		function pollScan() {
			if (pollActive || !scan.running) return;
			pollActive = true;
			function tick() {
				updateStatus().then(function() {
					if (scan.running) window.setTimeout(tick, 4000);
					else pollActive = false;
				}).catch(function() { pollActive = false; });
			}
			window.setTimeout(tick, 2500);
		}

		function action(promise, success) {
			promise.then(function(r) {
				if (r && r.ok) notify(r.message || success, 'info');
				else notify((r && r.message) || 'Операция не выполнена', 'error');
				return updateStatus();
			}).then(function() { pollScan(); }).catch(function(e) { notify('Ошибка RPC: ' + e, 'error'); });
		}

		function button(label, cls, fn) {
			return E('button', { 'class': 'btn ' + cls, 'click': fn, 'style': 'margin:4px' }, label);
		}

		root.appendChild(E('h2', {}, 'OWRTPsiphon'));
		root.appendChild(E('p', {}, 'Psiphon через warp-plus (--cfon). Управление отдельное от Steer: ссылка SOCKS5 остаётся постоянной при смене страны.'));
		root.appendChild(E('h3', {}, 'Состояние туннеля'));
		root.appendChild(state);
		root.appendChild(result);

		root.appendChild(E('div', { 'class': 'cbi-section' }, [
			E('h3', {}, 'Страна выхода'),
			E('div', { 'class': 'cbi-value' }, [
				E('label', { 'class': 'cbi-value-title', 'for': 'owrt-country' }, 'Страна (31 поддерживаемая)'),
				E('div', { 'class': 'cbi-value-field' }, country)
			]),
			button('Применить страну', 'cbi-button-action', function() { action(callSetCountry(country.value), 'Страна применена'); }),
			button('Автовыбор по задержке', 'cbi-button-positive', function() { action(callScan(), 'Проверка стран запущена'); }),
			scanBox,
			scanResults
		]));

		root.appendChild(E('div', { 'class': 'cbi-section' }, [
			E('h3', {}, 'Управление'),
			button('Запустить', 'cbi-button-positive', function() { action(callStart(), 'Запуск выполнен'); }),
			button('Остановить', 'cbi-button-negative', function() { action(callStop(), 'Служба остановлена'); }),
			button('Перенять текущий туннель', 'cbi-button-action', function() {
				if (confirm('Текущий ручной warp-plus будет перезапущен под управлением OWRTPsiphon с переносом кэша. Продолжить?')) {
					action(callAdopt(), 'Туннель передан службе');
				}
			}),
			button('Проверить SOCKS', 'cbi-button', function() { action(callProbe(), 'Проверка завершена'); }),
			button('Обновить', 'cbi-button', function() { updateStatus(); })
		]));

		root.appendChild(E('div', { 'class': 'cbi-section' }, [
			E('h3', {}, 'Ссылка для Steer'),
			E('p', {}, 'Добавь эту строку в подписку Steer. Адрес и порт не меняются при выборе другой страны.'),
			E('input', { 'class': 'cbi-input-text', 'readonly': 'readonly', 'value': subscription, 'style': 'width:100%;max-width:650px' }),
			button('Скопировать SOCKS5-ссылку', 'cbi-button-action', function() {
				var input = root.querySelector('input[readonly]');
				input.select();
				if (navigator.clipboard && navigator.clipboard.writeText) {
					navigator.clipboard.writeText(subscription).then(function() { notify('Ссылка скопирована'); });
				} else {
					document.execCommand('copy');
					notify('Ссылка скопирована');
				}
			})
		]));

		root.appendChild(E('p', { 'class': 'alert-message warning' }, 'Автоподбор проверяет страны последовательно на отдельном локальном порту 18086, сохраняя действующий туннель 8086 для Steer до выбора лучшего результата.'));
		updateStatus().then(function() { pollScan(); });
		return root;
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
EOF

chmod 755 /etc/init.d/owrt-psiphon /usr/libexec/rpcd/owrt-psiphon /usr/libexec/owrt-psiphon/owrt-psiphonctl
chmod 644 /usr/share/luci/menu.d/luci-app-owrt-psiphon.json /usr/share/rpcd/acl.d/luci-app-owrt-psiphon.json /www/luci-static/resources/view/owrt-psiphon/main.js

/etc/init.d/rpcd restart >/dev/null 2>&1 || true
rm -f /tmp/luci-indexcache
rm -rf "$TMP"

if ! netstat -lnt 2>/dev/null | awk '{print $4}' | grep -Eq '(:|\.)8086$'; then
	log 'Порт 8086 свободен: включаю автозапуск и поднимаю туннель для Steer...'
	uci -q set owrt-psiphon.main.enabled='1'
	uci -q commit owrt-psiphon
	/etc/init.d/owrt-psiphon enable >/dev/null 2>&1 || true
	/etc/init.d/owrt-psiphon start >/dev/null 2>&1 || true
else
	log 'Обнаружен занятый порт 8086: действующий туннель не тронут. Для перехвата открой LuCI → Службы → OWRTPsiphon.'
fi

log 'Установка Alpha 2 завершена.'

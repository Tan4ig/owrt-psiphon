#!/bin/sh
# VERSION=0.6.6
# OWRTPsiphon 0.6.6 — universal LuCI controller for bepass-org/warp-plus (--cfon).
# Repository: Tan4ig/owrt-psiphon
# Independent educational/experimental project; not affiliated with Psiphon Inc. or Cloudflare, Inc.
# Upstream engine: bepass-org/warp-plus (MIT License).
set -eu

APP_VER="0.6.6"
APP="/opt/owrt-psiphon"
TMP="/tmp/owrt-psiphon-install.$$"
VERSION="1.2.6"

NO_LUCI=0
if [ "${1:-}" = "--no-luci" ]; then
    NO_LUCI=1
fi

log() { printf '\033[1;32m[OWRTPsiphon]\033[0m %s\n' "$*"; }
fail() { printf '\033[1;31m[ОШИБКА]\033[0m %s\n' "$*" >&2; rm -rf "$TMP"; exit 1; }

trap 'rm -rf "$TMP"' EXIT INT TERM

[ "$(id -u)" = 0 ] || fail 'Запустите от root.'

pkg_install() {
    if command -v apk >/dev/null 2>&1; then apk add --no-cache "$1"
    elif command -v opkg >/dev/null 2>&1; then
        [ -f "$TMP/.opkg_updated" ] || { opkg update >/dev/null 2>&1 || true; touch "$TMP/.opkg_updated"; }
        opkg install "$1"
    else return 1; fi
}

pkg_remove() {
    if command -v apk >/dev/null 2>&1; then apk del "$1" >/dev/null 2>&1 || true
    elif command -v opkg >/dev/null 2>&1; then opkg remove "$1" >/dev/null 2>&1 || true; fi
}

detect_arch() {
    m="$(uname -m)"
    case "$m" in
        aarch64|arm64) WP_ARCH="linux-arm64"; WP_ELF_MACH="183"; WP_SHA256="c0b430c117eaa33513fa012aca983303ee88a4bda0f935dc62ff016109e492f3" ;;
        armv7*|armhf) WP_ARCH="linux-armv7"; WP_ELF_MACH="40"; WP_SHA256="" ;;
        armv6*|arm*) WP_ARCH="linux-armv6"; WP_ELF_MACH="40"; WP_SHA256="" ;;
        mips64el|mips64le) WP_ARCH="linux-mips64le"; WP_ELF_MACH="8"; WP_SHA256="" ;;
        mips64)
            endian="$(get_endian /bin/sh)"
            if [ "$endian" = "1" ]; then WP_ARCH="linux-mips64le"; else WP_ARCH="linux-mips64"; fi
            WP_ELF_MACH="8"; WP_SHA256=""
            ;;
        mipsel|mipsle) WP_ARCH="linux-mipsle"; WP_ELF_MACH="8"; WP_SHA256="" ;;
        mips)
            endian="$(get_endian /bin/sh)"
            if [ "$endian" = "1" ]; then WP_ARCH="linux-mipsle"; else WP_ARCH="linux-mips"; fi
            WP_ELF_MACH="8"; WP_SHA256=""
            ;;
        x86_64|amd64) WP_ARCH="linux-amd64"; WP_ELF_MACH="62"; WP_SHA256="" ;;
        i386|i686) WP_ARCH="linux-386"; WP_ELF_MACH="3"; WP_SHA256="" ;;
        *) fail "Неподдерживаемая архитектура процессора: $m" ;;
    esac
}

read_bytes_u8() {
    file_p="$1"
    off="$2"
    cnt="$3"
    dd if="$file_p" bs=1 skip="$off" count="$cnt" 2>/dev/null | awk 'BEGIN {
        for (i = 0; i < 256; i++) ord[sprintf("%c", i)] = i
    }
    {
        if (NR > 1) printf " 10"
        len = length($0)
        for (i = 1; i <= len; i++) {
            ch = substr($0, i, 1)
            printf " %d", (ch in ord ? ord[ch] : 0)
        }
    }'
}

get_endian() {
    file_p="$1"
    e_val="$(read_bytes_u8 "$file_p" 5 1 | awk '{print $1}')"
    if [ "$e_val" = "1" ] || [ "$e_val" = "2" ]; then
        printf '%s' "$e_val"
    else
        printf '1'
    fi
}

verify_elf_binary() {
    bin_path="$1"
    expected_mach="$2"
    [ -s "$bin_path" ] || return 1
    magic="$(read_bytes_u8 "$bin_path" 0 4 | awk '{print $1" "$2" "$3" "$4}')"
    [ "$magic" = "127 69 76 70" ] || return 1
    elf_endian="$(get_endian "$bin_path")"
    if [ "$elf_endian" = "1" ]; then
        elf_mach="$(read_bytes_u8 "$bin_path" 18 2 | awk '{print ($1 + 0) + ($2 + 0)*256}')"
    else
        elf_mach="$(read_bytes_u8 "$bin_path" 18 2 | awk '{print ($1 + 0)*256 + ($2 + 0)}')"
    fi
    [ "$elf_mach" = "$expected_mach" ]
}

mkdir -p "$TMP" "$APP" "$APP/cache"
detect_arch

if ! command -v curl >/dev/null 2>&1; then
    log "Установка curl..."
    pkg_install curl || fail 'Не удалось установить curl.'
fi
if [ ! -f /etc/ssl/certs/ca-certificates.crt ] && [ ! -d /etc/ssl/certs ]; then pkg_install ca-bundle >/dev/null 2>&1 || true; fi

command -v uci >/dev/null 2>&1 || fail 'Не найден UCI.'
command -v jsonfilter >/dev/null 2>&1 || fail 'Не найден jsonfilter.'

ASSET="https://github.com/bepass-org/warp-plus/releases/download/v${VERSION}/warp-plus_${WP_ARCH}.zip"

if [ -f "$APP/warp-plus" ] && ! verify_elf_binary "$APP/warp-plus" "$WP_ELF_MACH"; then
    rm -f "$APP/warp-plus"
fi

if [ ! -x "$APP/warp-plus" ]; then
    log "Загрузка warp-plus v${VERSION} (${WP_ARCH})..."
    curl -fL --retry 3 --connect-timeout 20 "$ASSET" -o "$TMP/wp.zip" || fail "Ошибка загрузки warp-plus (${WP_ARCH})."

    if [ -n "$WP_SHA256" ]; then
        SHA_ADDED=0
        if ! command -v sha256sum >/dev/null 2>&1; then pkg_install coreutils-sha256sum || fail 'Не удалось установить sha256sum.'; SHA_ADDED=1; fi
        ACTUAL_SHA="$(sha256sum "$TMP/wp.zip" | awk '{print $1}')"
        [ "$ACTUAL_SHA" = "$WP_SHA256" ] || fail "SHA256 не совпал (ожидался $WP_SHA256, получен $ACTUAL_SHA)."
        [ "$SHA_ADDED" = 0 ] || pkg_remove coreutils-sha256sum
    fi

    UNZIP_ADDED=0
    if ! command -v unzip >/dev/null 2>&1; then pkg_install unzip || fail 'Не удалось установить unzip.'; UNZIP_ADDED=1; fi
    unzip -tq "$TMP/wp.zip" >/dev/null || fail 'Архив warp-plus повреждён.'
    mkdir -p "$TMP/u"
    unzip -oq "$TMP/wp.zip" -d "$TMP/u" || fail 'Не удалось распаковать warp-plus.'
    WP_CANDIDATE="$(find "$TMP/u" -type f -name warp-plus -print | head -n 1)"
    [ -n "$WP_CANDIDATE" ] && [ -s "$WP_CANDIDATE" ] || fail 'В архиве не найден бинарник warp-plus.'

    verify_elf_binary "$WP_CANDIDATE" "$WP_ELF_MACH" || fail "Бинарник warp-plus не прошёл проверку ELF/архитектуры ($WP_ELF_MACH)."

    cp "$WP_CANDIDATE" "$TMP/warp-plus.new" && chmod 755 "$TMP/warp-plus.new"
    mv -f "$TMP/warp-plus.new" "$APP/warp-plus"
    [ "$UNZIP_ADDED" = 0 ] || pkg_remove unzip
fi

if [ ! -f /etc/config/owrt-psiphon ]; then
    cat << 'EOF' > /etc/config/owrt-psiphon
config owrt-psiphon 'main'
	option enabled '0'
	option autostart '1'
	option auto_scan_boot '0'
	option watchdog_hours '0'
	option country 'FI'
	option last_good_country 'FI'
	option bind '192.168.1.1'
	option port '8086'
	option endpoint '188.114.99.150:1701'
	option test_url 'http://example.com'
EOF
else
    [ "$(uci -q get owrt-psiphon.main.test_url || true)" = "https://ipinfo.io" ] && uci -q set owrt-psiphon.main.test_url='http://example.com'
    [ -n "$(uci -q get owrt-psiphon.main.last_good_country || true)" ] || uci -q set owrt-psiphon.main.last_good_country="$(uci -q get owrt-psiphon.main.country || echo FI)"
    [ -n "$(uci -q get owrt-psiphon.main.autostart || true)" ] || uci -q set owrt-psiphon.main.autostart='1'
    [ -n "$(uci -q get owrt-psiphon.main.auto_scan_boot || true)" ] || uci -q set owrt-psiphon.main.auto_scan_boot='0'
    cur_wh="$(uci -q get owrt-psiphon.main.watchdog_hours || echo 0)"
    case "$cur_wh" in 0|1|2|3|6|boot) ;; *) uci -q set owrt-psiphon.main.watchdog_hours='0' ;; esac
    [ -n "$(uci -q get owrt-psiphon.main.enabled || true)" ] || uci -q set owrt-psiphon.main.enabled='0'
    [ -n "$(uci -q get owrt-psiphon.main.country || true)" ] || uci -q set owrt-psiphon.main.country='FI'
    uci -q commit owrt-psiphon
fi

mkdir -p /etc/init.d /usr/libexec/rpcd /usr/libexec/owrt-psiphon /usr/share/luci/menu.d /usr/share/rpcd/acl.d /www/luci-static/resources/view/owrt-psiphon
if [ "$NO_LUCI" -eq 0 ]; then
    rm -f /www/luci-static/resources/view/owrt-psiphon/main-*.js /www/luci-static/resources/view/owrt-psiphon/main_*.js
fi

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
	config_get country main country FI
	config_get bind main bind 192.168.1.1
	config_get port main port 8086
	config_get endpoint main endpoint "188.114.99.150:1701"
	config_get test_url main test_url "http://example.com"
	mkdir -p "$CACHE_DIR"
	rm -f /var/run/owrt-psiphon-probe.state /var/run/owrt-psiphon-stopped.flag
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
	rm -f /var/run/owrt-psiphon-boot-scan.done /var/run/owrt-psiphon-backoff.state /var/run/owrt-psiphon-stopped.flag
	if [ "$autostart" -eq 1 ]; then
		uci -q set owrt-psiphon.main.enabled='1' && uci -q commit owrt-psiphon
		start
		(sleep 25 && [ ! -f /var/run/owrt-psiphon-boot-scan.done ] && : > /var/run/owrt-psiphon-boot-scan.done && /usr/libexec/owrt-psiphon/owrt-psiphonctl _boot_check) </dev/null >/dev/null 2>&1 &
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
COUNTRY="$(uci -q get ${CONFIG}.country || echo FI)"
ENDPOINT="$(uci -q get ${CONFIG}.endpoint || echo 188.114.99.150:1701)"
TEST_URL="$(uci -q get ${CONFIG}.test_url || echo http://example.com)"

SCANFILE="$APP/scan-results.json"
SCAN_PIDFILE=/var/run/owrt-psiphon-scan.pid
PROBE_FILE=/var/run/owrt-psiphon-probe.state
SCAN_LOCK=/var/run/owrt-psiphon-scan.lock
WATCHDOG_LOCK=/var/run/owrt-psiphon-watchdog.lock
STOPPED_FLAG=/var/run/owrt-psiphon-stopped.flag
BG_READY_PIDFILE=/var/run/owrt-psiphon-bg-ready.pid

ALL_COUNTRIES="FI EE LV SE PL DE NL DK NO CZ AT CH SK HU RO BG FR BE GB IE ES IT PT HR RS CA US IN SG JP AU"
SCAN_LIST="$ALL_COUNTRIES"

pkg_install() {
	if command -v apk >/dev/null 2>&1; then apk add --no-cache "$1"
	elif command -v opkg >/dev/null 2>&1; then opkg update >/dev/null 2>&1 || true; opkg install "$1"
	else return 1; fi
}

pkg_remove() {
	if command -v apk >/dev/null 2>&1; then apk del "$1" >/dev/null 2>&1 || true
	elif command -v opkg >/dev/null 2>&1; then opkg remove "$1" >/dev/null 2>&1 || true; fi
}

find_pids_by_pattern() {
	pat="$1"
	if command -v pgrep >/dev/null 2>&1; then
		pgrep -f "$pat" 2>/dev/null || true
		return 0
	fi
	for pdir in /proc/[0-9]*; do
		pid="${pdir#/proc/}"
		case "$pid" in ''|*[!0-9]*) continue ;; esac
		[ "$pid" -eq "$$" ] && continue
		if [ -r "$pdir/cmdline" ]; then
			cmd_str="$(tr '\0' ' ' < "$pdir/cmdline" 2>/dev/null || true)"
			case "$cmd_str" in
				*"$pat"*) printf '%s\n' "$pid" ;;
			esac
		fi
	done
}

get_wp_arch_info() {
	m="$(uname -m)"
	case "$m" in
		aarch64|arm64) WP_ARCH="linux-arm64"; WP_ELF_MACH="183" ;;
		armv7*|armhf) WP_ARCH="linux-armv7"; WP_ELF_MACH="40" ;;
		armv6*|arm*) WP_ARCH="linux-armv6"; WP_ELF_MACH="40" ;;
		mips64el|mips64le) WP_ARCH="linux-mips64le"; WP_ELF_MACH="8" ;;
		mips64)
			endian="$(get_endian /bin/sh)"
			[ "$endian" = "1" ] && WP_ARCH="linux-mips64le" || WP_ARCH="linux-mips64"
			WP_ELF_MACH="8"
			;;
		mipsel|mipsle) WP_ARCH="linux-mipsle"; WP_ELF_MACH="8" ;;
		mips)
			endian="$(get_endian /bin/sh)"
			[ "$endian" = "1" ] && WP_ARCH="linux-mipsle" || WP_ARCH="linux-mips"
			WP_ELF_MACH="8"
			;;
		x86_64|amd64) WP_ARCH="linux-amd64"; WP_ELF_MACH="62" ;;
		i386|i686) WP_ARCH="linux-386"; WP_ELF_MACH="3" ;;
		*) WP_ARCH="linux-arm64"; WP_ELF_MACH="183" ;;
	esac
}

read_bytes_u8() {
	file_p="$1"
	off="$2"
	cnt="$3"
	dd if="$file_p" bs=1 skip="$off" count="$cnt" 2>/dev/null | awk 'BEGIN {
		for (i = 0; i < 256; i++) ord[sprintf("%c", i)] = i
	}
	{
		if (NR > 1) printf " 10"
		len = length($0)
		for (i = 1; i <= len; i++) {
			ch = substr($0, i, 1)
			printf " %d", (ch in ord ? ord[ch] : 0)
		}
	}'
}

get_endian() {
	file_p="$1"
	e_val="$(read_bytes_u8 "$file_p" 5 1 | awk '{print $1}')"
	if [ "$e_val" = "1" ] || [ "$e_val" = "2" ]; then
		printf '%s' "$e_val"
	else
		printf '1'
	fi
}

verify_elf_binary() {
	bin_path="$1"
	expected_mach="$2"
	[ -s "$bin_path" ] || return 1
	magic="$(read_bytes_u8 "$bin_path" 0 4 | awk '{print $1" "$2" "$3" "$4}')"
	[ "$magic" = "127 69 76 70" ] || return 1
	elf_endian="$(get_endian "$bin_path")"
	if [ "$elf_endian" = "1" ]; then
		elf_mach="$(read_bytes_u8 "$bin_path" 18 2 | awk '{print ($1 + 0) + ($2 + 0)*256}')"
	else
		elf_mach="$(read_bytes_u8 "$bin_path" 18 2 | awk '{print ($1 + 0)*256 + ($2 + 0)}')"
	fi
	[ "$elf_mach" = "$expected_mach" ]
}

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

port_in_use() {
	if command -v netstat >/dev/null 2>&1; then
		netstat -lnt 2>/dev/null | awk '{print $4}' | grep -Eq "(:|\.)${1}$"
	elif command -v ss >/dev/null 2>&1; then
		ss -lnt 2>/dev/null | awk '{print $4}' | grep -Eq "(:|\.)${1}$"
	else
		hex_p="$(printf '%04X' "$1")"
		awk -v p=":$hex_p" '$2 ~ p"$" && $4 == "0A" {found=1} END{exit !found}' /proc/net/tcp 2>/dev/null
	fi
}

port_listening() {
	port_in_use "$PORT"
}

acquire_lock() {
	lock_dir="$1"
	mkdir -p /var/run
	if mkdir "$lock_dir" 2>/dev/null; then printf '%s\n' "$$" > "${lock_dir}/pid"; return 0; fi
	old_pid="$(cat "${lock_dir}/pid" 2>/dev/null || true)"
	if [ -n "$old_pid" ] && kill -0 "$old_pid" 2>/dev/null; then return 1; fi
	rm -rf "$lock_dir"
	if mkdir "$lock_dir" 2>/dev/null; then printf '%s\n' "$$" > "${lock_dir}/pid"; return 0; fi
	return 1
}

release_lock() { rm -rf "$1" 2>/dev/null || true; }

scan_active() {
	[ -d "$SCAN_LOCK" ] || return 1
	sp="$(cat "${SCAN_LOCK}/pid" 2>/dev/null || true)"
	case "$sp" in ''|*[!0-9]*) return 1 ;; esac
	kill -0 "$sp" 2>/dev/null
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

# Один замер через готовый SOCKS-туннель к Cloudflare trace
probe_socks_once() {
	sock_addr="$1"
	t_out="${2:-5}"
	[ "$t_out" -gt 8 ] && t_out=8
	cc=""; ip=""; secs=""

	out="$(curl -4 -fsS --connect-timeout 3 --max-time "$t_out" --socks5-hostname "$sock_addr" \
		-w '\n__OWRT_T__%{time_starttransfer}' https://1.1.1.1/cdn-cgi/trace 2>/dev/null || true)"
	case "$out" in
		*__OWRT_T__*)
			secs="${out##*__OWRT_T__}"
			body="${out%__OWRT_T__*}"
			cc="$(printf '%s\n' "$body" | sed -n 's/^loc=\([A-Z][A-Z]\).*/\1/p' | head -n 1)"
			ip="$(printf '%s\n' "$body" | sed -n 's/^ip=\(.*\)/\1/p' | head -n 1)"
			;;
	esac

	[ -n "$cc" ] || return 1
	ms="$(awk -v s="$secs" 'BEGIN { if (s ~ /^[0-9.]+$/ && s > 0) printf "%d", s*1000; else print 0 }')"
	[ "$ms" -gt 0 ] || return 1
	printf '%s|%s|%s\n' "$cc" "$ip" "$ms"
}

# Быстрый зонд для основного туннеля (чтобы не подвешивать RPC/XHR)
probe_socks_endpoint() {
	sock_addr="$1"
	t_out="${2:-5}"
	probe_socks_once "$sock_addr" "$t_out"
}

# Замер задержки при сканировании: быстрая серия замеров после готовности SOCKS, берём медиану успешных
probe_scan_endpoint() {
	sock_addr="$1"
	t_out="${2:-5}"
	samples_file="/tmp/owrt-psiphon-samples.$$"
	: > "$samples_file"
	last_cc=""; last_ip=""
	attempt=1
	while [ "$attempt" -le 3 ]; do
		[ -f "$STOPPED_FLAG" ] && break
		one="$(probe_socks_once "$sock_addr" "$t_out" || true)"
		if [ -n "$one" ]; then
			s_cc="$(printf '%s' "$one" | cut -d'|' -f1)"
			s_ip="$(printf '%s' "$one" | cut -d'|' -f2)"
			s_ms="$(printf '%s' "$one" | cut -d'|' -f3)"
			[ -n "$last_cc" ] && [ "$s_cc" != "$last_cc" ] && break
			last_cc="$s_cc"
			last_ip="$s_ip"
			printf '%s\n' "$s_ms" >> "$samples_file"
		fi
		attempt=$((attempt + 1))
		[ "$attempt" -le 3 ] && { usleep 250000 2>/dev/null || true; }
	done

	if [ ! -s "$samples_file" ] || [ -z "$last_cc" ]; then
		rm -f "$samples_file"
		return 1
	fi

	med_ms="$(sort -n "$samples_file" | awk '
		{ a[NR] = $1 + 0 }
		END {
			if (NR == 0) exit 1;
			if (NR % 2 == 1) printf "%d", a[(NR + 1) / 2];
			else printf "%d", int((a[NR / 2] + a[NR / 2 + 1]) / 2);
		}
	')"
	rm -f "$samples_file"
	[ -n "$med_ms" ] && [ "$med_ms" -gt 0 ] || return 1
	printf '%s|%s|%s\n' "$last_cc" "$last_ip" "$med_ms"
}

# Обновляет запись о конкретной стране в scan-results.json (например, после ручного выбора или probe)
sync_country_in_scanfile() {
	c_code="$1"
	c_exit="$2"
	c_ip="$3"
	c_ms="$4"
	c_state="$5"
	[ -n "$c_code" ] || return 0
	[ -s "$SCANFILE" ] || return 0
	raw_res="$(sed -n 's/.*"results":\(\[.*\]\).*/\1/p' "$SCANFILE" | head -n 1)"
	[ -n "$raw_res" ] || return 0
	clean_items="$(printf '%s' "$raw_res" | sed 's/^\[//; s/\]$//; s/},{/}\n{/g')"
	lat_val="null"
	[ "$c_state" = "ok" ] && case "$c_ms" in ''|*[!0-9]*) lat_val="null" ;; *) lat_val="$c_ms" ;; esac
	new_entry="{\"country\":\"$(json_escape "$c_code")\",\"exit_country\":\"$(json_escape "$c_exit")\",\"ip\":\"$(json_escape "$c_ip")\",\"latency_ms\":${lat_val},\"state\":\"$(json_escape "$c_state")\"}"
	updated_items="$(printf '%s\n' "$clean_items" | awk -v code="$c_code" -v rep="$new_entry" '
		BEGIN { found=0; first=1 }
		length($0) > 0 {
			if (index($0, "\"country\":\"" code "\"") > 0) {
				if (!first) printf ",";
				printf "%s", rep;
				found=1; first=0;
			} else {
				if (!first) printf ",";
				printf "%s", $0;
				first=0;
			}
		}
		END {
			if (found == 0) {
				if (!first) printf ",";
				printf "%s", rep;
			}
		}
	')"
	cur_run="$(jsonfilter -s "$(cat "$SCANFILE")" -e '@.running' 2>/dev/null || echo false)"
	cur_mode="$(jsonfilter -s "$(cat "$SCANFILE")" -e '@.mode' 2>/dev/null || echo manual)"
	cur_best="$(jsonfilter -s "$(cat "$SCANFILE")" -e '@.best' 2>/dev/null || echo "")"
	cur_best_ms="$(jsonfilter -s "$(cat "$SCANFILE")" -e '@.best_ms' 2>/dev/null || echo null)"
	[ -n "$cur_best_ms" ] || cur_best_ms="null"
	cur_comp="$(jsonfilter -s "$(cat "$SCANFILE")" -e '@.completed' 2>/dev/null || echo 0)"
	cur_tot="$(jsonfilter -s "$(cat "$SCANFILE")" -e '@.total' 2>/dev/null || echo 31)"
	cur_msg="$(jsonfilter -s "$(cat "$SCANFILE")" -e '@.message' 2>/dev/null || echo "")"
	write_scan_atomic "{\"running\":${cur_run},\"mode\":\"$(json_escape "$cur_mode")\",\"current\":\"\",\"best\":\"$(json_escape "$cur_best")\",\"best_ms\":${cur_best_ms},\"completed\":${cur_comp},\"total\":${cur_tot},\"message\":\"$(json_escape "$cur_msg")\",\"results\":[${updated_items}]}"
}

BOOT_FAIL_MARKER=/var/run/owrt-psiphon-boot-scan.done
BACKOFF_FILE=/var/run/owrt-psiphon-backoff.state
MAX_BOOT_RUNTIME=240
MAX_FAILOVER_RUNTIME=180
MAX_FULL_RUNTIME=2100
MAX_CONSECUTIVE_FAILS=3

has_wan_link() {
	if command -v ip >/dev/null 2>&1; then
		ip route show default 2>/dev/null | grep -q .
		return $?
	fi
	awk '$2 == "00000000" {found=1} END{exit !found}' /proc/net/route 2>/dev/null
}

backoff_active() {
	[ -s "$BACKOFF_FILE" ] || return 1
	until_ts="$(sed -n 's/^BACKOFF_UNTIL=//p' "$BACKOFF_FILE" | tr -d "'" | head -n 1)"
	case "$until_ts" in ''|*[!0-9]*) return 1 ;; esac
	now_ts="$(date +%s 2>/dev/null || echo 0)"
	[ "$now_ts" -lt "$until_ts" ]
}

record_failure_backoff() {
	now_ts="$(date +%s 2>/dev/null || echo 0)"
	fails=0
	if [ -s "$BACKOFF_FILE" ]; then
		fails="$(sed -n 's/^FAIL_COUNT=//p' "$BACKOFF_FILE" | tr -d "'" | head -n 1)"
		case "$fails" in ''|*[!0-9]*) fails=0 ;; esac
	fi
	fails=$((fails + 1))
	delay=900
	[ "$fails" -eq 2 ] && delay=1800
	[ "$fails" -ge 3 ] && delay=3600
	until_ts=$((now_ts + delay))
	tmp_b="${BACKOFF_FILE}.tmp.$$"
	printf "FAIL_COUNT='%s'
BACKOFF_UNTIL='%s'
" "$fails" "$until_ts" > "$tmp_b"
	mv -f "$tmp_b" "$BACKOFF_FILE"
}

clear_failure_backoff() {
	rm -f "$BACKOFF_FILE"
}

probe_internal() {
	port_listening || { rm -f "$PROBE_FILE"; return 1; }
	res="$(probe_socks_endpoint "${BIND}:${PORT}" 5)" || { rm -f "$PROBE_FILE"; return 1; }
	cc="$(printf '%s' "$res" | cut -d'|' -f1)"
	ip="$(printf '%s' "$res" | cut -d'|' -f2)"
	ms="$(printf '%s' "$res" | cut -d'|' -f3)"
	[ -n "$cc" ] || { rm -f "$PROBE_FILE"; return 1; }
	tmp_p="${PROBE_FILE}.tmp.$$"
	printf "PROBE_COUNTRY='%s'\nPROBE_IP='%s'\nPROBE_MS='%s'\n" "$cc" "$ip" "$ms" > "$tmp_p"
	mv -f "$tmp_p" "$PROBE_FILE"
	cur_c="$(uci -q get ${CONFIG}.country || echo "$COUNTRY")"
	if [ "$cc" = "$cur_c" ]; then
		sync_country_in_scanfile "$cur_c" "$cc" "$ip" "$ms" "ok"
	else
		sync_country_in_scanfile "$cur_c" "$cc" "$ip" "$ms" "wrong_country"
	fi
}

wait_socks_ready() {
	max_wait="${1:-35}"; elapsed=0
	while [ "$elapsed" -lt "$max_wait" ]; do
		[ -f "$STOPPED_FLAG" ] && return 1
		managed_pid >/dev/null || return 1
		if port_listening && probe_internal; then return 0; fi
		sleep 1
		elapsed=$((elapsed + 1))
	done
	return 1
}

stop_bg_ready_watcher() {
	if [ -s "$BG_READY_PIDFILE" ]; then
		bp="$(cat "$BG_READY_PIDFILE" 2>/dev/null || true)"
		case "$bp" in ''|*[!0-9]*) ;; *)
			kill -TERM "$bp" 2>/dev/null || true
			kill -KILL "$bp" 2>/dev/null || true
		esac
		rm -f "$BG_READY_PIDFILE"
	fi
}

# Фоновая проверка готовности SOCKS5 / IP / пинга без блокировки RPC
schedule_bg_ready_check() {
	target_c="${1:-}"
	stop_bg_ready_watcher
	(
		printf '%s\n' "$$" > "$BG_READY_PIDFILE"
		trap 'rm -f "$BG_READY_PIDFILE"' EXIT INT TERM
		if wait_socks_ready 40; then
			cur_c="$(uci -q get ${CONFIG}.country || echo "$COUNTRY")"
			[ -n "$target_c" ] && cur_c="$target_c"
			if [ -s "$PROBE_FILE" ]; then
				p_cc="$(sed -n 's/^PROBE_COUNTRY=//p' "$PROBE_FILE" | tr -d "'" | head -n 1)"
				[ -z "$p_cc" ] || [ "$p_cc" = "$cur_c" ] && {
					uci -q set ${CONFIG}.last_good_country="$cur_c" && uci -q commit owrt-psiphon
					clear_failure_backoff
				}
			fi
		fi
	) </dev/null >/dev/null 2>&1 &
}

sync_cron() {
	hours="$(uci -q get ${CONFIG}.watchdog_hours || echo 0)"
	CRON_FILE="/etc/crontabs/root"
	mkdir -p /etc/crontabs
	touch "$CRON_FILE"
	grep -v 'owrt-psiphonctl watchdog' "$CRON_FILE" > "${CRON_FILE}.tmp" 2>/dev/null || true
	case "$hours" in
		1) printf '0 * * * * /usr/libexec/owrt-psiphon/owrt-psiphonctl watchdog >/dev/null 2>&1\n' >> "${CRON_FILE}.tmp" ;;
		2|3|6) printf '0 */%s * * * /usr/libexec/owrt-psiphon/owrt-psiphonctl watchdog >/dev/null 2>&1\n' "$hours" >> "${CRON_FILE}.tmp" ;;
	esac
	mv -f "${CRON_FILE}.tmp" "$CRON_FILE"
	/etc/init.d/cron restart >/dev/null 2>&1 || true
}

# status() читает состояние мгновенно без сетевых вызовов, чтобы LuCI RPC не ловил XHR timeout
status() {
	running=false; pid=""; listening=false; socks_ok=false; exit_country=""; exit_ip=""; latency=""
	if p="$(managed_pid)"; then running=true; pid="$p"; fi
	port_listening && listening=true
	if [ "$running" = true ] && [ "$listening" = true ] && [ -s "$PROBE_FILE" ]; then
		socks_ok=true
		exit_country="$(sed -n 's/^PROBE_COUNTRY=//p' "$PROBE_FILE" | tr -d "'" | head -n 1)"
		exit_ip="$(sed -n 's/^PROBE_IP=//p' "$PROBE_FILE" | tr -d "'" | head -n 1)"
		latency="$(sed -n 's/^PROBE_MS=//p' "$PROBE_FILE" | tr -d "'" | head -n 1)"
	fi
	app_version="$(cat "$APP/app.version" 2>/dev/null | head -n 1 | tr -d '\r\n' || echo 0.6.4)"
	version="v1.2.6"
	if [ -x "$BIN" ]; then
		v="$("$BIN" version 2>&1 | grep -Eo 'v?[0-9]+\.[0-9]+\.[0-9]+' | head -n 1 || true)"
		[ -n "$v" ] && version="$v"
	fi
	autostart="$(uci -q get ${CONFIG}.autostart || echo 1)"
	auto_scan_boot="$(uci -q get ${CONFIG}.auto_scan_boot || echo 0)"
	watchdog_hours="$(uci -q get ${CONFIG}.watchdog_hours || echo 0)"
	sub="socks5://${BIND}:${PORT}#OWRTPsiphon"
	scan_run=false
	if scan_active; then scan_run=true; fi
	printf '{"ok":true,"running":%s,"listening":%s,"socks_ok":%s,"pid":"%s","country":"%s","bind":"%s","port":%s,"app_version":"%s","version":"%s","subscription":"%s","exit_country":"%s","exit_ip":"%s","latency_ms":"%s","autostart":%s,"auto_scan_boot":%s,"watchdog_hours":"%s","scan_running":%s}\n' \
		"$running" "$listening" "$socks_ok" "$pid" "$(json_escape "$COUNTRY")" "$(json_escape "$BIND")" "$PORT" "$(json_escape "$app_version")" "$(json_escape "$version")" "$(json_escape "$sub")" "$(json_escape "$exit_country")" "$(json_escape "$exit_ip")" "$(json_escape "$latency")" "$autostart" "$auto_scan_boot" "$(json_escape "$watchdog_hours")" "$scan_run"
}

check_update() {
	local_ver="$(cat "$APP/app.version" 2>/dev/null | head -n 1 | tr -d '\r\n' || echo 0.6.6)"
	remote_raw="$(curl -fsSL --max-time 8 "${REPO_URL}?t=$(date +%s)" 2>/dev/null || true)"
	remote_head="$(printf '%s\n' "$remote_raw" | head -n 5)"
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
	scan_active && { reply false 'Дождитесь завершения подбора перед обновлением'; return 1; }
	rm -f /tmp/owrt-psiphon-update.*.sh 2>/dev/null || true
	tmp_upd="/tmp/owrt-psiphon-update.$$.sh"
	curl -fsSL --max-time 15 "${REPO_URL}?t=$(date +%s)" -o "$tmp_upd" 2>/dev/null || { rm -f "$tmp_upd"; reply false 'Ошибка загрузки обновления с GitHub'; return 1; }
	[ -s "$tmp_upd" ] && head -n 5 "$tmp_upd" | grep -q 'OWRTPsiphon' || { rm -f "$tmp_upd"; reply false 'Загруженный файл не прошел проверку'; return 1; }
	chmod 755 "$tmp_upd"
	reply true 'Обновление запущено. Страница перезагрузится автоматически.'
	if command -v setsid >/dev/null 2>&1; then
		setsid sh -c "sleep 1; sh '$tmp_upd' >/dev/null 2>&1; rm -f '$tmp_upd' /tmp/luci-indexcache /tmp/luci-modulecache" </dev/null >/dev/null 2>&1 &
	else
		(sleep 1; sh "$tmp_upd" >/dev/null 2>&1; rm -f "$tmp_upd" /tmp/luci-indexcache /tmp/luci-modulecache) </dev/null >/dev/null 2>&1 &
	fi
}

check_warp_update() {
	local_ver="1.2.6"
	if [ -x "$BIN" ]; then
		v="$("$BIN" version 2>&1 | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+' | head -n 1 || true)"
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
	scan_active && { reply false 'Дождитесь завершения подбора перед обновлением warp-plus'; return 1; }
	rel_json="$(curl -fsSL --max-time 10 "$WARP_API_URL" 2>/dev/null || true)"
	[ -n "$rel_json" ] || { reply false 'Ошибка получения данных релиза warp-plus'; return 1; }
	get_wp_arch_info
	target_arch="$WP_ARCH"
	expected_mach="$WP_ELF_MACH"
	dl_url="$(jsonfilter -s "$rel_json" -e '@.assets[*].browser_download_url' 2>/dev/null | grep "${target_arch}\.zip$" | head -n 1 || true)"
	[ -n "$dl_url" ] || { reply false "Не найден архив ${target_arch} в релизе"; return 1; }

	tmp_w="/tmp/owrt-warp-upd.$$"
	mkdir -p "$tmp_w"
	if ! curl -fL --max-time 30 "$dl_url" -o "$tmp_w/wp.zip" 2>/dev/null; then
		rm -rf "$tmp_w"
		reply false 'Ошибка скачивания архива warp-plus'
		return 1
	fi
	UNZIP_TMP=0
	if ! command -v unzip >/dev/null 2>&1; then
		pkg_install unzip >/dev/null 2>&1 && UNZIP_TMP=1 || { rm -rf "$tmp_w"; reply false 'Не удалось установить unzip'; return 1; }
	fi
	mkdir -p "$tmp_w/u"
	if ! unzip -oq "$tmp_w/wp.zip" -d "$tmp_w/u" 2>/dev/null; then
		[ "$UNZIP_TMP" = 1 ] && pkg_remove unzip
		rm -rf "$tmp_w"
		reply false 'Ошибка распаковки архива warp-plus'
		return 1
	fi
	cand="$(find "$tmp_w/u" -type f -name warp-plus -print | head -n 1)"
	if [ -z "$cand" ] || [ ! -s "$cand" ]; then
		[ "$UNZIP_TMP" = 1 ] && pkg_remove unzip
		rm -rf "$tmp_w"
		reply false 'В архиве не найден бинарник warp-plus'
		return 1
	fi
	if ! verify_elf_binary "$cand" "$expected_mach"; then
		[ "$UNZIP_TMP" = 1 ] && pkg_remove unzip
		rm -rf "$tmp_w"
		reply false 'Скачанный бинарник не прошёл проверку ELF/архитектуры'
		return 1
	fi
	was_run=0
	managed_pid >/dev/null && was_run=1
	[ "$was_run" = 1 ] && /etc/init.d/owrt-psiphon stop >/dev/null 2>&1 || true
	cp "$cand" "$BIN.new" && chmod 755 "$BIN.new" && mv -f "$BIN.new" "$BIN"
	[ "$UNZIP_TMP" = 1 ] && pkg_remove unzip
	rm -rf "$tmp_w"
	[ "$was_run" = 1 ] && /etc/init.d/owrt-psiphon start >/dev/null 2>&1 || true
	reply true "warp-plus (${target_arch}) успешно обновлён"
}

check_current_or_find_first() {
	if ! has_wan_link; then
		return 1
	fi
	if wait_socks_ready 35; then
		clear_failure_backoff
		cur_c="$(uci -q get ${CONFIG}.country || echo "$COUNTRY")"
		uci -q set ${CONFIG}.last_good_country="$cur_c" && uci -q commit owrt-psiphon
		return 0
	fi
	if backoff_active; then
		return 1
	fi
	scan_worker 2 || true
	if port_listening && probe_internal; then
		clear_failure_backoff
		cur_c="$(uci -q get ${CONFIG}.country || echo "$COUNTRY")"
		uci -q set ${CONFIG}.last_good_country="$cur_c" && uci -q commit owrt-psiphon
		return 0
	fi
	record_failure_backoff
	return 1
}

boot_check() {
	[ "$(uci -q get ${CONFIG}.enabled || echo 0)" = "1" ] || return 0
	[ -f "$STOPPED_FLAG" ] && return 0
	scan_active && return 0
	acquire_lock "$WATCHDOG_LOCK" || return 0
	trap 'release_lock "$WATCHDOG_LOCK"; exit 130' INT TERM
	trap 'release_lock "$WATCHDOG_LOCK"' EXIT
	check_current_or_find_first || true
}

# Быстрый запуск службы без длительного ожидания готовности SOCKS и без синхронного скана в RPC
start_service() {
	if scan_active; then
		stop_scan_processes "Остановлено для запуска службы"
	fi
	rm -f "$STOPPED_FLAG" "$PROBE_FILE"
	cur_c="$(uci -q get ${CONFIG}.country || echo "$COUNTRY")"
	if managed_pid >/dev/null; then
		schedule_bg_ready_check "$cur_c"
		reply true "Служба запущена ($cur_c); проверка готовности в фоне"
		return 0
	fi
	uci -q set ${CONFIG}.enabled='1' && uci -q commit owrt-psiphon
	/etc/init.d/owrt-psiphon start >/dev/null 2>&1 || true

	fast_w=0
	while [ "$fast_w" -lt 3 ]; do
		if managed_pid >/dev/null 2>&1 || port_listening; then
			break
		fi
		sleep 1
		fast_w=$((fast_w + 1))
	done

	if managed_pid >/dev/null 2>&1 || port_listening; then
		schedule_bg_ready_check "$cur_c"
		reply true "Служба запущена ($cur_c); ожидание SOCKS5 и проверка пинга идут в фоне"
		return 0
	fi

	if [ -x "$BIN" ]; then
		schedule_bg_ready_check "$cur_c"
		reply true "Служба поставлена в запуск ($cur_c); проверка готовности идёт в фоне"
		return 0
	fi

	reply false 'Бинарник warp-plus не найден'
	return 1
}

stop_scan_processes() {
	reason_msg="${1:-Остановлено пользователем}"
	scan_pid="$(cat "$SCAN_PIDFILE" 2>/dev/null || true)"
	lock_pid=""
	[ -d "$SCAN_LOCK" ] && lock_pid="$(cat "${SCAN_LOCK}/pid" 2>/dev/null || true)"

	for p in "$scan_pid" "$lock_pid"; do
		case "$p" in ''|*[!0-9]*) ;; *)
			kill -TERM "$p" 2>/dev/null || true
		esac
	done

	for wp in $(find_pids_by_pattern "warp-plus.*127\.0\.0\.1:180"); do
		case "$wp" in ''|*[!0-9]*) ;; *) kill -TERM "$wp" 2>/dev/null || true ;; esac
	done

	i=0
	while [ "$i" -lt 8 ]; do
		alive=0
		for p in "$scan_pid" "$lock_pid"; do
			case "$p" in ''|*[!0-9]*) ;; *) kill -0 "$p" 2>/dev/null && alive=1 ;; esac
		done
		[ "$alive" -eq 0 ] && break
		usleep 200000 2>/dev/null || sleep 1
		i=$((i + 1))
	done

	for p in "$scan_pid" "$lock_pid"; do
		case "$p" in ''|*[!0-9]*) ;; *)
			kill -KILL "$p" 2>/dev/null || true
			wait "$p" 2>/dev/null || true
		esac
	done

	for wp in $(find_pids_by_pattern "warp-plus.*127\.0\.0\.1:180"); do
		case "$wp" in ''|*[!0-9]*) ;; *) kill -KILL "$wp" 2>/dev/null || true ;; esac
	done

	rm -rf "$SCAN_LOCK" /tmp/owrt-psiphon-scan-cache.* /tmp/owrt-scan-lines.* /tmp/owrt-psiphon-samples.*
	rm -f "$SCAN_PIDFILE"
	if [ -s "$SCANFILE" ]; then
		cur_res="$(sed -n 's/.*"results":\(\[.*\]\).*/\1/p' "$SCANFILE" | head -n 1)"
		[ -n "$cur_res" ] || cur_res="[]"
		write_scan_atomic "{\"running\":false,\"mode\":\"stopped\",\"current\":\"\",\"best\":\"\",\"best_ms\":null,\"completed\":0,\"total\":31,\"message\":\"$(json_escape "$reason_msg")\",\"results\":$cur_res}"
	fi
}

stop_service() {
	: > "$STOPPED_FLAG"
	stop_bg_ready_watcher
	stop_scan_processes "Остановлено пользователем"
	uci -q set ${CONFIG}.enabled='0' && uci -q commit owrt-psiphon
	/etc/init.d/owrt-psiphon stop >/dev/null 2>&1 || true
	for wp in $(find_pids_by_pattern "$BIN"); do
		case "$wp" in ''|*[!0-9]*) ;; *) kill -TERM "$wp" 2>/dev/null || true ;; esac
	done
	sleep 1
	for wp in $(find_pids_by_pattern "$BIN"); do
		case "$wp" in ''|*[!0-9]*) ;; *) kill -KILL "$wp" 2>/dev/null || true ;; esac
	done
	rm -f "$PROBE_FILE"
	reply true 'Служба и все фоновые процессы остановлены'
}

# Ручное переключение/запуск выбранной страны: всегда оставляем выбранную страну
# и ждём готовности SOCKS до ответа или таймаута, без отката на прошлый узел
safe_restart() {
	new_country="$1"
	rm -f "$STOPPED_FLAG" "$PROBE_FILE"
	uci -q set ${CONFIG}.country="$new_country" && uci -q set ${CONFIG}.enabled='1' && uci -q commit owrt-psiphon
	if managed_pid >/dev/null 2>&1; then
		/etc/init.d/owrt-psiphon restart >/dev/null 2>&1 || true
	else
		/etc/init.d/owrt-psiphon start >/dev/null 2>&1 || true
	fi

	if wait_socks_ready 40; then
		uci -q set ${CONFIG}.last_good_country="$new_country" && uci -q commit owrt-psiphon
		p_ip="$(sed -n 's/^PROBE_IP=//p' "$PROBE_FILE" 2>/dev/null | tr -d "'" | head -n 1)"
		p_cc="$(sed -n 's/^PROBE_COUNTRY=//p' "$PROBE_FILE" 2>/dev/null | tr -d "'" | head -n 1)"
		p_ms="$(sed -n 's/^PROBE_MS=//p' "$PROBE_FILE" 2>/dev/null | tr -d "'" | head -n 1)"
		if [ -n "$p_cc" ] && [ "$p_cc" != "$new_country" ]; then
			sync_country_in_scanfile "$new_country" "$p_cc" "$p_ip" "$p_ms" "wrong_country"
			reply false "Узел $new_country ответил другой страной ($p_cc), ${p_ms} мс; оставлен $new_country"
		else
			sync_country_in_scanfile "$new_country" "$p_cc" "$p_ip" "$p_ms" "ok"
			reply true "Узел $new_country активен: ${p_ip:-—} (${p_cc:-$new_country}), ${p_ms:-—} мс"
		fi
		return 0
	fi

	if ! managed_pid >/dev/null 2>&1; then
		sync_country_in_scanfile "$new_country" "" "" "" "error"
		reply false "Узел $new_country: процесс warp-plus завершился с ошибкой; оставлен $new_country"
	elif ! port_listening; then
		sync_country_in_scanfile "$new_country" "" "" "" "startup_timeout"
		reply false "Узел $new_country: таймаут открытия локального порта; оставлен $new_country"
	else
		sync_country_in_scanfile "$new_country" "" "" "" "socks_error"
		reply false "Узел $new_country: таймаут готовности SOCKS; оставлен $new_country"
	fi
	return 1
}

set_country() {
	c="$1"
	scan_active && { reply false 'Подбор выполняется. Нажмите «Остановить» или дождитесь завершения.'; return 1; }
	valid_country "$c" || { reply false 'Неверный код страны'; return 1; }
	safe_restart "$c"
}

set_auto() {
	as="${1:-1}"; sb="${2:-0}"; wh="${3:-0}"
	case "$as" in 0|1) ;; *) reply false 'Некорректный автостарт'; return 1 ;; esac
	case "$sb" in 0|1) ;; *) reply false 'Некорректный автоподбор при загрузке'; return 1 ;; esac
	case "$wh" in 0|1|2|3|6|boot) ;; *) reply false 'Некорректный интервал проверки'; return 1 ;; esac
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
	scan_active && { reply false 'Во время подбора основной туннель временно остановлен'; return 1; }
	if probe_internal; then
		cur_c="$(uci -q get ${CONFIG}.country || echo "$COUNTRY")"
		uci -q set ${CONFIG}.last_good_country="$cur_c" && uci -q commit owrt-psiphon
		reply true "SOCKS5 активен: $(sed -n 's/^PROBE_IP=//p' "$PROBE_FILE" | tr -d "'") ($(sed -n 's/^PROBE_COUNTRY=//p' "$PROBE_FILE" | tr -d "'")), $(sed -n 's/^PROBE_MS=//p' "$PROBE_FILE" | tr -d "'") мс"
	else
		reply false 'SOCKS5 не отвечает'
		return 1
	fi
}

scan_status() {
	if [ -s "$SCANFILE" ]; then cat "$SCANFILE"
	else printf '{"running":false,"message":"","results":[]}\n'; fi
}

# Формирует приоритетную очередь по истории из scan-results.json:
# 1) узлы со статусом "ok" по возрастанию latency_ms (без вечного бана упавших ранее)
# 2) остальные страны в порядке ALL_COUNTRIES
build_priority_queue() {
	ok_list=""
	if [ -s "$SCANFILE" ]; then
		raw_res="$(sed -n 's/.*"results":\(\[.*\]\).*/\1/p' "$SCANFILE" | head -n 1)"
		if [ -n "$raw_res" ]; then
			ok_list="$(printf '%s' "$raw_res" | sed 's/},{/}\n{/g' | awk '
				{
					c = ""; st = ""; lat = 999999;
					if (match($0, /"country":"[A-Z][A-Z]"/)) {
						c = substr($0, RSTART + 11, 2);
					}
					if (match($0, /"state":"[^"]*"/)) {
						st = substr($0, RSTART + 9, RLENGTH - 10);
					}
					if (match($0, /"latency_ms":[0-9]+/)) {
						lat = substr($0, RSTART + 13, RLENGTH - 13) + 0;
					}
					if (c != "" && st == "ok") {
						printf "%d %s\n", lat, c;
					}
				}
			' | sort -n -k1,1 | awk '{print $2}' | tr '\n' ' ')"
		fi
	fi

	out_q=""
	for c in $ok_list; do
		case " $out_q " in
			*" $c "*) ;;
			*) out_q="${out_q}${out_q:+ }$c" ;;
		esac
	done
	for c in $ALL_COUNTRIES; do
		case " $out_q " in
			*" $c "*) ;;
			*) out_q="${out_q}${out_q:+ }$c" ;;
		esac
	done
	printf '%s\n' "$out_q"
}

launch_scan_bg() {
	mode_arg="$1"
	mode_label="$2"
	[ -x "$BIN" ] || { reply false 'Бинарник warp-plus не найден'; return 1; }
	if scan_active; then
		reply false 'Подбор уже выполняется'
		return 1
	fi
	rm -f "$STOPPED_FLAG"
	prev_res="[]"
	if [ -s "$SCANFILE" ]; then
		r_tmp="$(sed -n 's/.*"results":\(\[.*\]\).*/\1/p' "$SCANFILE" | head -n 1)"
		[ -n "$r_tmp" ] && prev_res="$r_tmp"
	fi
	write_scan_atomic "{\"running\":true,\"mode\":\"${mode_label}\",\"current\":\"\",\"best\":\"\",\"best_ms\":null,\"completed\":0,\"total\":31,\"message\":\"Подготовка приоритетной очереди к проверке\",\"results\":${prev_res}}"
	if command -v setsid >/dev/null 2>&1; then
		setsid "$0" "$mode_arg" </dev/null >/dev/null 2>&1 &
	else
		"$0" "$mode_arg" </dev/null >/dev/null 2>&1 &
	fi
	if [ "$mode_arg" = "_scan_first" ]; then
		reply true 'Поиск первого рабочего узла запущен'
	else
		reply true 'Автоподбор всех 31 стран запущен'
	fi
}

scan_start() {
	launch_scan_bg "_scan" "full"
}

scan_first_start() {
	launch_scan_bg "_scan_first" "first"
}

build_sorted_json() {
	sort -t '|' -k1,1n -k2,2n "$1" 2>/dev/null | awk -F'|' '
		BEGIN { printf "[" }
		NF >= 6 {
			if (NR > 1) printf ",";
			lat = ($6 == "ok") ? $2 : "null";
			printf "{\"country\":\"%s\",\"exit_country\":\"%s\",\"ip\":\"%s\",\"latency_ms\":%s,\"state\":\"%s\"}", $3, $4, $5, lat, $6
		}
		END { printf "]" }
	'
}

write_scan_atomic() {
	tmp_sf="${SCANFILE}.tmp.$$"
	printf '%s\n' "$1" > "$tmp_sf"
	mv -f "$tmp_sf" "$SCANFILE"
}

stop_probe_proc() {
	p="$1"
	[ -n "$p" ] || return 0
	kill -TERM "$p" 2>/dev/null || true
	i=0
	while [ "$i" -lt 8 ] && kill -0 "$p" 2>/dev/null; do
		usleep 200000 2>/dev/null || sleep 1
		i=$((i + 1))
	done
	kill -KILL "$p" 2>/dev/null || true
	wait "$p" 2>/dev/null || true
}

# Режимы scan_worker:
# 0 = полный ручной автоподбор по приоритетной очереди
# 1 = загрузка / первый рабочий (остановка на первом ok и немедленное применение)
# 2 = аварийный / failover (остановка на первом ok и немедленное применение)
# 3 = ручной «Первый рабочий» (остановка на первом ok и немедленное применение)
scan_worker() {
	boot_mode="${1:-0}"
	acquire_lock "$SCAN_LOCK" || return 0
	was_running=0
	main_pid=""
	old_country="$(uci -q get ${CONFIG}.country || echo "$COUNTRY")"
	if [ "$boot_mode" = "1" ] || [ "$boot_mode" = "2" ] || [ "$boot_mode" = "3" ]; then
		was_running=1
	elif main_pid="$(managed_pid)"; then
		was_running=1
	fi
	restore_required="$was_running"
	probe_pid=""
	tmp_lines="/tmp/owrt-scan-lines.$$"
	scan_cache_base="/tmp/owrt-psiphon-scan-cache.$$"
	scan_port=18086
	cleanup_done=0
	start_ts="$(date +%s 2>/dev/null || echo 0)"
	max_runtime="$MAX_FULL_RUNTIME"
	[ "$boot_mode" = "1" ] && max_runtime="$MAX_BOOT_RUNTIME"
	[ "$boot_mode" = "2" ] && max_runtime="$MAX_FAILOVER_RUNTIME"
	[ "$boot_mode" = "3" ] && max_runtime="$MAX_FAILOVER_RUNTIME"

	cleanup_scan() {
		[ "$cleanup_done" = 1 ] && return 0
		cleanup_done=1
		stop_probe_proc "$probe_pid"
		rm -rf "$scan_cache_base" /tmp/owrt-psiphon-samples.*
		rm -f "$SCAN_PIDFILE" "$tmp_lines"
		if [ ! -f "$STOPPED_FLAG" ] && [ "$restore_required" = 1 ] && [ "$was_running" = 1 ] && ! managed_pid >/dev/null 2>&1; then
			uci -q set ${CONFIG}.country="$old_country" && uci -q set ${CONFIG}.enabled='1' && uci -q commit owrt-psiphon
			/etc/init.d/owrt-psiphon start >/dev/null 2>&1 || true
			schedule_bg_ready_check "$old_country"
		fi
		release_lock "$SCAN_LOCK"
	}
	trap 'cleanup_scan' EXIT
	trap 'exit 130' INT TERM

	if ! has_wan_link; then
		restore_required=0
		write_scan_atomic '{"running":false,"current":"","best":"","best_ms":null,"completed":0,"total":31,"message":"Нет внешнего WAN-подключения. Проверка отложена.","results":[]}'
		return 1
	fi

	while [ "$scan_port" -le 18116 ]; do
		if ! port_in_use "$scan_port"; then break; fi
		scan_port=$((scan_port + 1))
	done
	if [ "$scan_port" -gt 18116 ]; then
		restore_required=0
		write_scan_atomic '{"running":false,"current":"","best":"","best_ms":null,"completed":0,"total":31,"message":"Нет свободного локального порта для проверки","results":[]}'
		return 1
	fi

	if [ -n "$main_pid" ]; then
		/etc/init.d/owrt-psiphon stop >/dev/null 2>&1 || true
		n=0
		while [ "$n" -lt 8 ] && kill -0 "$main_pid" 2>/dev/null; do sleep 1; n=$((n + 1)); done
		if kill -0 "$main_pid" 2>/dev/null; then
			restore_required=0
			write_scan_atomic '{"running":false,"current":"","best":"","best_ms":null,"completed":0,"total":31,"message":"Не удалось остановить основной Warp Plus. Сканирование отменено.","results":[]}'
			return 1
		fi
	fi

	mkdir -p "$scan_cache_base"
	ordered_scan="$(build_priority_queue)"

	: > "$tmp_lines"
	best_country=""
	best_ms=999999
	completed=0
	total=31
	mode_name="full"
	[ "$boot_mode" = "1" ] && mode_name="boot"
	[ "$boot_mode" = "2" ] && mode_name="failover"
	[ "$boot_mode" = "3" ] && mode_name="first"
	first_applied=0

	for c in $ordered_scan; do
		[ -f "$STOPPED_FLAG" ] && break
		now_ts="$(date +%s 2>/dev/null || echo 0)"
		elapsed_total=$((now_ts - start_ts))
		if [ "$start_ts" -gt 0 ] && [ "$elapsed_total" -ge "$max_runtime" ]; then
			break
		fi

		cur_best_ms="$( [ "$best_ms" -eq 999999 ] && echo null || echo "$best_ms" )"
		if [ "$boot_mode" = "1" ]; then
			status_msg="Фоновый поиск первого рабочего узла при загрузке…"
		elif [ "$boot_mode" = "2" ]; then
			status_msg="Узел не отвечает. Поиск первого живого узла…"
		elif [ "$boot_mode" = "3" ]; then
			status_msg="Поиск первого рабочего узла по приоритетной очереди…"
		else
			status_msg="Проверка узлов по приоритетной очереди. Основной туннель временно остановлен."
		fi
		write_scan_atomic "{\"running\":true,\"mode\":\"$mode_name\",\"current\":\"$c\",\"best\":\"$best_country\",\"best_ms\":$cur_best_ms,\"completed\":$completed,\"total\":$total,\"message\":\"$(json_escape "$status_msg")\",\"results\":$(build_sorted_json "$tmp_lines")}"

		c_cache="${scan_cache_base}/${c}"
		mkdir -p "$c_cache"

		if [ "$boot_mode" != "0" ] && command -v nice >/dev/null 2>&1; then
			if [ -n "$ENDPOINT" ]; then
				nice -n 10 "$BIN" -4 -e "$ENDPOINT" --cfon --country "$c" -b "127.0.0.1:${scan_port}" --cache-dir "$c_cache" --test-url "$TEST_URL" >/dev/null 2>&1 &
			else
				nice -n 10 "$BIN" -4 --cfon --country "$c" -b "127.0.0.1:${scan_port}" --cache-dir "$c_cache" --test-url "$TEST_URL" >/dev/null 2>&1 &
			fi
		else
			if [ -n "$ENDPOINT" ]; then
				"$BIN" -4 -e "$ENDPOINT" --cfon --country "$c" -b "127.0.0.1:${scan_port}" --cache-dir "$c_cache" --test-url "$TEST_URL" >/dev/null 2>&1 &
			else
				"$BIN" -4 --cfon --country "$c" -b "127.0.0.1:${scan_port}" --cache-dir "$c_cache" --test-url "$TEST_URL" >/dev/null 2>&1 &
			fi
		fi
		probe_pid=$!
		printf '%s\n' "$probe_pid" > "$SCAN_PIDFILE"

		res=""; got=""; ip=""; ms="999999"; state="startup_timeout"; rank=2
		port_open=0; socks_ready=0; aborted=0

		# Этап 1: запуск процесса и ожидание открытия локального порта (до 30 с)
		port_elapsed=0
		while [ "$port_elapsed" -lt 30 ]; do
			if [ -f "$STOPPED_FLAG" ]; then aborted=1; break; fi
			now_ts="$(date +%s 2>/dev/null || echo 0)"
			if [ "$start_ts" -gt 0 ] && [ $((now_ts - start_ts)) -ge "$max_runtime" ]; then aborted=1; break; fi
			if ! kill -0 "$probe_pid" 2>/dev/null; then
				state="error"; rank=4
				break
			fi
			if port_in_use "$scan_port"; then
				port_open=1
				break
			fi
			sleep 1
			port_elapsed=$((port_elapsed + 1))
		done

		if [ "$aborted" = 1 ]; then
			stop_probe_proc "$probe_pid"
			probe_pid=""
			rm -rf "$c_cache"
			rm -f "$SCAN_PIDFILE"
			break
		fi

		if [ "$port_open" = 1 ]; then
			# Этап 2: после открытия порта — повторные проверки SOCKS/handshake (каждые 1 с, до 35 с)
			state="socks_error"; rank=2
			hs_elapsed=0
			while [ "$hs_elapsed" -lt 35 ]; do
				if [ -f "$STOPPED_FLAG" ]; then aborted=1; break; fi
				now_ts="$(date +%s 2>/dev/null || echo 0)"
				if [ "$start_ts" -gt 0 ] && [ $((now_ts - start_ts)) -ge "$max_runtime" ]; then aborted=1; break; fi
				if ! kill -0 "$probe_pid" 2>/dev/null; then
					state="error"; rank=4
					break
				fi
				first_probe="$(probe_socks_once "127.0.0.1:${scan_port}" 4 || true)"
				if [ -n "$first_probe" ]; then
					socks_ready=1
					break
				fi
				sleep 1
				hs_elapsed=$((hs_elapsed + 1))
			done

			if [ "$aborted" = 1 ]; then
				stop_probe_proc "$probe_pid"
				probe_pid=""
				rm -rf "$c_cache"
				rm -f "$SCAN_PIDFILE"
				break
			fi

			if [ "$socks_ready" = 1 ] && kill -0 "$probe_pid" 2>/dev/null; then
				res="$(probe_scan_endpoint "127.0.0.1:${scan_port}" 5 || true)"
				if [ -n "$res" ]; then
					got="$(printf '%s' "$res" | cut -d'|' -f1)"
					ip="$(printf '%s' "$res" | cut -d'|' -f2)"
					ms="$(printf '%s' "$res" | cut -d'|' -f3)"
					if [ "$got" = "$c" ]; then
						state="ok"; rank=1
						if [ "$ms" -lt "$best_ms" ]; then best_ms="$ms"; best_country="$c"; fi
					else
						state="wrong_country"; rank=3
					fi
				else
					state="socks_error"; rank=2; ms="999999"
				fi
			elif kill -0 "$probe_pid" 2>/dev/null; then
				state="socks_error"; rank=2
			else
				state="error"; rank=4
			fi
		else
			if [ "$state" != "error" ]; then
				if kill -0 "$probe_pid" 2>/dev/null; then
					state="startup_timeout"; rank=2
				else
					state="error"; rank=4
				fi
			fi
		fi

		stop_probe_proc "$probe_pid"
		probe_pid=""
		rm -rf "$c_cache"
		rm -f "$SCAN_PIDFILE"

		sort_ms="$ms"
		[ "$state" = "ok" ] || sort_ms=999999
		printf '%s|%s|%s|%s|%s|%s\n' "$rank" "$sort_ms" "$c" "$got" "$ip" "$state" >> "$tmp_lines"
		completed=$((completed + 1))
		cur_best_ms="$( [ "$best_ms" -eq 999999 ] && echo null || echo "$best_ms" )"

		# Для «Первый рабочий» (3), загрузки (1) и failover (2) останавливаемся на первом ok и сразу применяем
		if [ "$boot_mode" != "0" ] && [ "$state" = "ok" ]; then
			best_country="$c"
			best_ms="$ms"
			clear_failure_backoff
			restore_required=0
			uci -q set ${CONFIG}.country="$best_country" && uci -q set ${CONFIG}.enabled='1' && uci -q set ${CONFIG}.last_good_country="$best_country" && uci -q commit owrt-psiphon
			/etc/init.d/owrt-psiphon start >/dev/null 2>&1 || true
			tmp_p="${PROBE_FILE}.tmp.$$"
			printf "PROBE_COUNTRY='%s'\nPROBE_IP='%s'\nPROBE_MS='%s'\n" "$got" "$ip" "$ms" > "$tmp_p"
			mv -f "$tmp_p" "$PROBE_FILE"
			schedule_bg_ready_check "$best_country"
			if [ "$boot_mode" = "1" ]; then
				msg="Автоподбор при загрузке: выбран первый рабочий узел $best_country (${best_ms} мс)."
			elif [ "$boot_mode" = "2" ]; then
				msg="Узел восстановлен: включён первый живой $best_country (${best_ms} мс)."
			else
				msg="Выбран первый рабочий узел: $best_country (${best_ms} мс). Туннель включён."
			fi
			first_applied=1
			write_scan_atomic "{\"running\":false,\"mode\":\"$mode_name\",\"current\":\"\",\"best\":\"$best_country\",\"best_ms\":${best_ms},\"completed\":$completed,\"total\":$total,\"message\":\"$(json_escape "$msg")\",\"results\":$(build_sorted_json "$tmp_lines")}"
			return 0
		fi

		write_scan_atomic "{\"running\":true,\"mode\":\"$mode_name\",\"current\":\"\",\"best\":\"$best_country\",\"best_ms\":$cur_best_ms,\"completed\":$completed,\"total\":$total,\"message\":\"$(json_escape "Проверено $completed из $total")\",\"results\":$(build_sorted_json "$tmp_lines")}"
	done

	if [ -f "$STOPPED_FLAG" ]; then
		restore_required=0
		write_scan_atomic "{\"running\":false,\"mode\":\"$mode_name\",\"current\":\"\",\"best\":\"\",\"best_ms\":null,\"completed\":$completed,\"total\":$total,\"message\":\"Остановлено пользователем\",\"results\":$(build_sorted_json "$tmp_lines")}"
		return 0
	fi

	[ "$first_applied" = 1 ] && return 0

	final_json="$(build_sorted_json "$tmp_lines")"
	if [ -n "$best_country" ]; then
		clear_failure_backoff
		if [ "$was_running" = 1 ]; then
			uci -q set ${CONFIG}.country="$best_country" && uci -q set ${CONFIG}.enabled='1' && uci -q commit owrt-psiphon
			/etc/init.d/owrt-psiphon start >/dev/null 2>&1 || true
			if wait_socks_ready 35; then
				uci -q set ${CONFIG}.last_good_country="$best_country" && uci -q commit owrt-psiphon
				restore_required=0
				if [ "$boot_mode" = "1" ]; then
					msg="Автоподбор при загрузке: выбран первый рабочий узел $best_country (${best_ms} мс)."
				elif [ "$boot_mode" = "2" ]; then
					msg="Узел восстановлен: переключено на первый живой $best_country (${best_ms} мс)."
				else
					msg="Лучший узел: $best_country (${best_ms} мс). Туннель запущен."
				fi
			else
				uci -q set ${CONFIG}.country="$old_country" && uci -q set ${CONFIG}.enabled='1' && uci -q commit owrt-psiphon
				/etc/init.d/owrt-psiphon start >/dev/null 2>&1 || true
				if wait_socks_ready 30; then
					uci -q set ${CONFIG}.last_good_country="$old_country" && uci -q commit owrt-psiphon
					restore_required=0
					msg="Узел $best_country не поднялся; восстановлен прежний $old_country."
				else
					msg="Узел $best_country не поднялся. Не удалось проверить восстановление $old_country."
				fi
			fi
		else
			uci -q set ${CONFIG}.country="$best_country" && uci -q commit owrt-psiphon
			msg="Лучший узел: $best_country (${best_ms} мс). Страна сохранена (туннель остановлен)."
		fi
	else
		if [ "$boot_mode" = "2" ]; then
			uci -q set ${CONFIG}.country="$old_country" && uci -q set ${CONFIG}.enabled='1' && uci -q commit owrt-psiphon
			/etc/init.d/owrt-psiphon start >/dev/null 2>&1 || true
			schedule_bg_ready_check "$old_country"
			restore_required=0
			msg="Живых узлов не найдено. Поиск остановлен до следующей проверки ($old_country)."
		elif [ "$boot_mode" = "1" ]; then
			uci -q set ${CONFIG}.country="$old_country" && uci -q set ${CONFIG}.enabled='1' && uci -q commit owrt-psiphon
			/etc/init.d/owrt-psiphon start >/dev/null 2>&1 || true
			schedule_bg_ready_check "$old_country"
			restore_required=0
			msg="При загрузке живые узлы не найдены. Сохранён узел $old_country."
		elif [ "$boot_mode" = "3" ]; then
			if [ "$was_running" = 1 ]; then
				uci -q set ${CONFIG}.country="$old_country" && uci -q set ${CONFIG}.enabled='1' && uci -q commit owrt-psiphon
				/etc/init.d/owrt-psiphon start >/dev/null 2>&1 || true
				schedule_bg_ready_check "$old_country"
				restore_required=0
			fi
			msg="Первый рабочий узел не найден. Сохранён узел $old_country."
		else
			if [ "$was_running" = 1 ]; then
				uci -q set ${CONFIG}.country="$old_country" && uci -q set ${CONFIG}.enabled='1' && uci -q commit owrt-psiphon
				/etc/init.d/owrt-psiphon start >/dev/null 2>&1 || true
				schedule_bg_ready_check "$old_country"
				restore_required=0
			fi
			msg="Рабочих узлов не найдено. Сохранён узел $old_country."
		fi
	fi
	write_scan_atomic "{\"running\":false,\"mode\":\"$mode_name\",\"current\":\"\",\"best\":\"$best_country\",\"best_ms\":$( [ "$best_ms" -eq 999999 ] && echo null || echo "$best_ms" ),\"completed\":$completed,\"total\":$total,\"message\":\"$(json_escape "$msg")\",\"results\":$final_json}"
}

watchdog() {
	[ "$(uci -q get ${CONFIG}.enabled || echo 0)" = "1" ] || return 0
	[ -f "$STOPPED_FLAG" ] && return 0
	scan_active && return 0
	acquire_lock "$WATCHDOG_LOCK" || return 0
	trap 'release_lock "$WATCHDOG_LOCK"; exit 130' INT TERM
	trap 'release_lock "$WATCHDOG_LOCK"' EXIT

	if ! has_wan_link; then
		return 0
	fi

	if probe_internal; then
		clear_failure_backoff
		cur_c="$(uci -q get ${CONFIG}.country || echo "$COUNTRY")"
		uci -q set ${CONFIG}.last_good_country="$cur_c" && uci -q commit owrt-psiphon
		return 0
	fi

	if backoff_active; then
		return 0
	fi

	cur="$(uci -q get ${CONFIG}.country || echo FI)"
	if [ -s "$SCANFILE" ]; then
		for next_c in $(build_priority_queue); do
			[ "$next_c" = "$cur" ] && continue
			if safe_restart "$next_c" >/dev/null 2>&1; then
				clear_failure_backoff
				return 0
			fi
		done
	fi

	scan_worker 2 || true
	if ! probe_internal; then
		record_failure_backoff
	fi
}

uninstall_all() {
	stop_bg_ready_watcher
	stop_scan_processes "Остановлено при удалении"
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
		if command -v killall >/dev/null 2>&1; then
			killall warp-plus >/dev/null 2>&1 || true
		elif command -v pgrep >/dev/null 2>&1; then
			for wp in $(pgrep -x warp-plus 2>/dev/null || true); do kill -TERM "$wp" 2>/dev/null || true; done
		fi
		rm -rf /opt/owrt-psiphon /etc/config/owrt-psiphon /etc/init.d/owrt-psiphon /usr/libexec/owrt-psiphon /usr/libexec/rpcd/owrt-psiphon /usr/share/luci/menu.d/luci-app-owrt-psiphon.json /usr/share/rpcd/acl.d/luci-app-owrt-psiphon.json /www/luci-static/resources/view/owrt-psiphon /var/run/owrt-psiphon* /tmp/owrt-psiphon* /tmp/luci-indexcache /tmp/luci-modulecache
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
	scan_first) scan_first_start ;;
	scan_status) scan_status ;;
	_scan) scan_worker 0 ;;
	_scan_boot) scan_worker 1 ;;
	_scan_failover) scan_worker 2 ;;
	_scan_first) scan_worker 3 ;;
	_boot_check) boot_check ;;
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
        printf '{"status":{},"start":{},"stop":{},"set_country":{"country":"FI"},"set_auto":{"autostart":"1","auto_scan_boot":"0","watchdog_hours":"0"},"probe":{},"scan":{},"scan_first":{},"scan_status":{},"check_update":{},"apply_update":{},"check_warp_update":{},"apply_warp_update":{},"uninstall":{}}\n'
        ;;
    call)
        input="$(cat)"; [ -n "$input" ] || input="{}"
        case "$2" in
            status|start|stop|probe|scan|scan_first|scan_status|check_update|apply_update|check_warp_update|apply_warp_update|uninstall)
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
                case "$wh" in 0|1|2|3|6|boot) ;; *) printf '{"ok":false,"message":"Некорректный watchdog_hours"}\n'; exit 1 ;; esac
                exec "$CTL" set_auto "$as" "$sb" "$wh"
                ;;
            *) printf '{"ok":false,"message":"Unknown method"}\n'; exit 1 ;;
        esac
        ;;
esac
EOF

if [ "$NO_LUCI" -eq 0 ]; then
    printf '{"admin/services/owrt-psiphon":{"title":"OWRTPsiphon","order":90,"action":{"type":"view","path":"owrt-psiphon/main"},"depends":{"acl":["luci-app-owrt-psiphon"]}}}\n' > /usr/share/luci/menu.d/luci-app-owrt-psiphon.json
    printf '{"luci-app-owrt-psiphon":{"description":"OWRTPsiphon LuCI access","read":{"ubus":{"owrt-psiphon":["status","scan_status","check_update","check_warp_update"]}},"write":{"ubus":{"owrt-psiphon":["start","stop","set_country","set_auto","probe","scan","scan_first","apply_update","apply_warp_update","uninstall"]}}}}\n' > /usr/share/rpcd/acl.d/luci-app-owrt-psiphon.json

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
    callScanFirst = rpc.declare({ object: 'owrt-psiphon', method: 'scan_first', expect: {} }),
    callCheckUpdate = rpc.declare({ object: 'owrt-psiphon', method: 'check_update', expect: {} }),
    callApplyUpdate = rpc.declare({ object: 'owrt-psiphon', method: 'apply_update', expect: {} }),
    callCheckWarpUpdate = rpc.declare({ object: 'owrt-psiphon', method: 'check_warp_update', expect: {} }),
    callApplyWarpUpdate = rpc.declare({ object: 'owrt-psiphon', method: 'apply_warp_update', expect: {} }),
    callUninstall = rpc.declare({ object: 'owrt-psiphon', method: 'uninstall', expect: {} });

var CODES = ['FI','EE','LV','SE','PL','DE','NL','DK','NO','CZ','AT','CH','SK','HU','RO','BG','FR','BE','GB','IE','ES','IT','PT','HR','RS','CA','US','IN','SG','JP','AU'];

return view.extend({
	render: function() {
		var status = {}, scan = {}, pollActive = false, busy = false, pendingAction = '', lastBusyWarn = 0, sub = 'socks5://192.168.1.1:8086#OWRTPsiphon';
		var dropdownHoldUntil = 0, isDropdownOpen = false, pollTimer = null;
		var root = E('div', { 'class': 'cbi-map' }),
		    stateTable = E('div', { 'class': 'table' }),
		    liveLine = E('div', { 'class': 'owrt-live-line', 'style': 'display:none' }),
		    appVerLabel = E('span', { 'style': 'font-weight:bold;min-width:65px;display:inline-block' }, 'v0.6.6'),
		    appUpdStatus = E('span', { 'style': 'margin-left:8px' }),
		    warpVerLabel = E('span', { 'style': 'font-weight:bold;min-width:65px;display:inline-block' }, 'v1.2.6'),
		    warpUpdStatus = E('span', { 'style': 'margin-left:8px' });

		var btnStart = E('button', { 'class': 'btn cbi-button-positive owrt-act-btn', 'style': 'margin:4px 8px 4px 0' }, 'Запустить'),
		    btnStop = E('button', { 'class': 'btn cbi-button-negative owrt-act-btn', 'style': 'margin:4px 8px 4px 0' }, 'Остановить'),
		    btnProbe = E('button', { 'class': 'btn cbi-button owrt-act-btn', 'style': 'margin:4px 8px 4px 0' }, 'Проверить SOCKS'),
		    btnUninstall = E('button', { 'class': 'btn cbi-button-negative owrt-act-btn', 'style': 'margin:4px 8px 4px 0' }, 'Удалить приложение'),
		    btnScan = E('button', { 'class': 'btn cbi-button-positive owrt-act-btn', 'style': 'margin:0' }, 'Автоподбор по пингу'),
		    btnFirst = E('button', { 'class': 'btn cbi-button-action owrt-act-btn', 'style': 'margin:0' }, 'Первый рабочий'),
		    btnCopySub = E('button', { 'class': 'btn cbi-button-action owrt-act-btn', 'style': 'margin:0' }, 'Копировать'),
		    btnCheckApp = E('button', { 'class': 'btn cbi-button-action owrt-act-btn', 'style': 'margin:0' }, 'Проверить обновления'),
		    btnCheckWarp = E('button', { 'class': 'btn cbi-button-action owrt-act-btn', 'style': 'margin:0' }, 'Проверить обновления');

		var chkAutostart = E('input', { 'type': 'checkbox' });

		var selWatchdog = E('select', { 'class': 'cbi-input-select', 'style': 'min-width:210px' }, [
			E('option', { 'value': '0' }, 'Отключён'),
			E('option', { 'value': '1' }, 'Раз в 1 час'),
			E('option', { 'value': '2' }, 'Раз в 2 часа'),
			E('option', { 'value': '3' }, 'Раз в 3 часа'),
			E('option', { 'value': '6' }, 'Раз в 6 часов'),
			E('option', { 'value': 'boot' }, 'При загрузке')
		]);

		var countrySelectEl = null, countryWrapEl = null;

		function notify(m, t) {
			ui.addNotification(null, E('p', {}, m), t || 'info');
		}

		function setSoftLocked(el, softLock) {
			if (!el) return;
			if (softLock) {
				el.classList.add('owrt-soft-locked');
				el.setAttribute('aria-disabled', 'true');
			} else {
				el.classList.remove('owrt-soft-locked');
				el.removeAttribute('aria-disabled');
			}
		}

		function setBtnState(el, loading, labelText, forceNegative) {
			if (!el) return;
			el.disabled = false;
			if (forceNegative) {
				el.classList.remove('cbi-button-positive', 'cbi-button-action');
				el.classList.add('cbi-button-negative');
			}
			if (loading) {
				el.classList.add('is-loading');
				el.textContent = '';
				el.appendChild(E('span', { 'class': 'owrt-spinner', 'aria-hidden': 'true' }));
				el.appendChild(E('span', {}, labelText));
			} else {
				el.classList.remove('is-loading');
				el.textContent = labelText;
			}
		}

		function resetScanButtonStyle(el, defaultClass) {
			if (!el) return;
			el.classList.remove('cbi-button-negative', 'cbi-button-positive', 'cbi-button-action');
			el.classList.add(defaultClass);
		}

		function activeScanKind() {
			if (pendingAction === 'scan') return 'scan';
			if (pendingAction === 'scan_first') return 'scan_first';
			if (scan.running) {
				return (scan.mode === 'first') ? 'scan_first' : 'scan';
			}
			return '';
		}

		function isScanActiveNow() {
			return !!(scan.running || pendingAction === 'scan' || pendingAction === 'scan_first' || pendingAction === 'stop_scan');
		}

		function syncButtons() {
			var isStarting = (pendingAction === 'start');
			var isStopping = (pendingAction === 'stop');
			var isProbing = (pendingAction === 'probe');
			var isStoppingScan = (pendingAction === 'stop_scan');
			var actKind = activeScanKind();
			var scanNow = isScanActiveNow();
			var otherBusy = busy && !scanNow && !isStopping;

			setBtnState(btnStart, isStarting, isStarting ? 'Запуск…' : 'Запустить');
			setSoftLocked(btnStart, scanNow || otherBusy || isStopping);

			setBtnState(btnStop, isStopping, isStopping ? 'Остановка…' : 'Остановить');
			setSoftLocked(btnStop, pendingAction === 'uninstall');

			setBtnState(btnProbe, isProbing, isProbing ? 'Проверка…' : 'Проверить SOCKS');
			setSoftLocked(btnProbe, scanNow || otherBusy || isStopping);

			if (actKind === 'scan') {
				resetScanButtonStyle(btnScan, 'cbi-button-negative');
				setBtnState(btnScan, isStoppingScan, isStoppingScan ? 'Остановка…' : 'СТОП', true);
				setSoftLocked(btnScan, false);

				resetScanButtonStyle(btnFirst, 'cbi-button-action');
				setBtnState(btnFirst, false, 'Первый рабочий', false);
				setSoftLocked(btnFirst, true);
			} else if (actKind === 'scan_first') {
				resetScanButtonStyle(btnFirst, 'cbi-button-negative');
				setBtnState(btnFirst, isStoppingScan, isStoppingScan ? 'Остановка…' : 'СТОП', true);
				setSoftLocked(btnFirst, false);

				resetScanButtonStyle(btnScan, 'cbi-button-positive');
				setBtnState(btnScan, false, 'Автоподбор по пингу', false);
				setSoftLocked(btnScan, true);
			} else {
				resetScanButtonStyle(btnScan, 'cbi-button-positive');
				setBtnState(btnScan, false, 'Автоподбор по пингу', false);
				setSoftLocked(btnScan, otherBusy || isStopping);

				resetScanButtonStyle(btnFirst, 'cbi-button-action');
				setBtnState(btnFirst, false, 'Первый рабочий', false);
				setSoftLocked(btnFirst, otherBusy || isStopping);
			}

			setSoftLocked(btnUninstall, scanNow || otherBusy || isStopping);
			setSoftLocked(btnCopySub, pendingAction === 'uninstall');
			setSoftLocked(btnCheckApp, scanNow || otherBusy || isStopping);
			setSoftLocked(btnCheckWarp, scanNow || otherBusy || isStopping);

			if (countrySelectEl) {
				countrySelectEl.disabled = false;
				setSoftLocked(countrySelectEl, false);
			}
		}

		function guardBusy() {
			if (!busy && !scan.running) return false;
			var now = Date.now();
			if (now - lastBusyWarn > 2000) {
				lastBusyWarn = now;
				var n = ui.addNotification(null, E('p', {}, 'Дождитесь окончания процесса'), 'warning');
				if (n && n.parentNode) {
					window.setTimeout(function() { if (n.parentNode) n.parentNode.removeChild(n); }, 2500);
				}
			}
			return true;
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

		var COUNTRY_NAMES = {
			FI: 'Финляндия', EE: 'Эстония', LV: 'Латвия', SE: 'Швеция',
			PL: 'Польша', DE: 'Германия', NL: 'Нидерланды', DK: 'Дания',
			NO: 'Норвегия', CZ: 'Чехия', AT: 'Австрия', CH: 'Швейцария',
			SK: 'Словакия', HU: 'Венгрия', RO: 'Румыния', BG: 'Болгария',
			FR: 'Франция', BE: 'Бельгия', GB: 'Великобритания', IE: 'Ирландия',
			ES: 'Испания', IT: 'Италия', PT: 'Португалия', HR: 'Хорватия',
			RS: 'Сербия', CA: 'Канада', US: 'США', IN: 'Индия',
			SG: 'Сингапур', JP: 'Япония', AU: 'Австралия'
		};

		function countryTitle(code) {
			return COUNTRY_NAMES[code] || code;
		}

		function formatScanItemState(r, isCurrent) {
			if (isCurrent) return 'Проверка…';
			if (!r) return '—';
			if (r.state === 'ok') {
				return (r.latency_ms != null && r.latency_ms !== '') ? (r.latency_ms + ' мс') : 'OK';
			}
			if (r.state === 'wrong_country') {
				return r.exit_country ? ('Неверная страна: ' + r.exit_country) : 'Неверная страна';
			}
			if (r.state === 'socks_error') return 'Таймаут / ошибка SOCKS';
			if (r.state === 'startup_timeout') return 'Таймаут запуска';
			if (r.state === 'timeout') return 'Таймаут';
			if (r.state === 'error') return 'Ошибка процесса';
			if (r.state === 'untested') return '—';
			return '—';
		}

		function renderLiveLine() {
			liveLine.textContent = '';
			if (pendingAction === 'start') {
				liveLine.style.display = 'flex';
				liveLine.appendChild(E('span', { 'class': 'owrt-spinner', 'aria-hidden': 'true' }));
				liveLine.appendChild(E('span', {}, 'Запускаем warp-plus (' + (status.country || 'FI') + '), готовность и пинг обновятся в фоне…'));
				return;
			}
			if (pendingAction === 'stop') {
				liveLine.style.display = 'flex';
				liveLine.appendChild(E('span', { 'class': 'owrt-spinner', 'aria-hidden': 'true' }));
				liveLine.appendChild(E('span', {}, 'Останавливаем туннель, подбор и фоновые процессы…'));
				return;
			}
			if (pendingAction === 'stop_scan') {
				liveLine.style.display = 'flex';
				liveLine.appendChild(E('span', { 'class': 'owrt-spinner', 'aria-hidden': 'true' }));
				liveLine.appendChild(E('span', {}, 'Останавливаем подбор (результаты сохраняются)…'));
				return;
			}
			if (pendingAction === 'switch') {
				liveLine.style.display = 'flex';
				liveLine.appendChild(E('span', { 'class': 'owrt-spinner', 'aria-hidden': 'true' }));
				liveLine.appendChild(E('span', {}, 'Переключаем страну (' + (status.country || '') + ') и проверяем SOCKS5…'));
				return;
			}
			if (scan.running) {
				var curCode = scan.current || '';
				var modeLabel = (scan.mode === 'boot')
					? 'Подбор при загрузке: '
					: ((scan.mode === 'failover')
						? 'Аварийный подбор: '
						: ((scan.mode === 'first') ? 'Первый рабочий: ' : 'Автоподбор узлов: '));
				liveLine.style.display = 'flex';
				liveLine.appendChild(E('span', { 'class': 'owrt-spinner', 'aria-hidden': 'true' }));
				liveLine.appendChild(E('span', {}, modeLabel + (scan.completed || 0) + '/' + (scan.total || 31) +
					(curCode ? ' · ' + curCode + ' — ' + countryTitle(curCode) : '')));
				return;
			}

			var msg = (scan.message || '').trim();
			var isStaleStoppedMsg = (msg.indexOf('туннель оставлен остановленным') !== -1 || msg.indexOf('оставлен остановленным') !== -1) && status.running && status.socks_ok;
			if (msg && !isStaleStoppedMsg && msg !== 'Автоподбор ещё не запускался') {
				liveLine.style.display = 'block';
				liveLine.textContent = msg;
			} else {
				liveLine.style.display = 'none';
			}
		}

		function holdCountryDropdown() {
			dropdownHoldUntil = Date.now() + 10000;
		}

		function buildOrderedCountries() {
			var resultMap = {}, okItems = [], seen = {};
			if (scan.results) {
				scan.results.forEach(function(r) {
					if (r.country && !seen[r.country]) {
						seen[r.country] = true;
						resultMap[r.country] = r;
						if (r.state === 'ok' && typeof r.latency_ms === 'number' && r.latency_ms > 0) {
							okItems.push(r);
						}
					}
				});
			}
			okItems.sort(function(a, b) { return a.latency_ms - b.latency_ms; });
			var ordered = [];
			okItems.forEach(function(r) { ordered.push(r.country); });
			CODES.forEach(function(c) {
				if (!seen[c] || okItems.every(function(item) { return item.country !== c; })) {
					ordered.push(c);
				}
			});
			return { ordered: ordered, resultMap: resultMap };
		}

		function populateCountryOptions(selEl) {
			if (!selEl) return;
			var data = buildOrderedCountries();
			var ordered = data.ordered, resultMap = data.resultMap;
			var cur = status.country || 'FI';
			var prevSel = selEl.value || cur;
			selEl.textContent = '';
			ordered.forEach(function(c) {
				var name = countryTitle(c), r = resultMap[c];
				var isCurScan = !!(scan.running && scan.current === c);
				var stateText = formatScanItemState(r, isCurScan);
				var activeText = (c === cur && status.running && status.socks_ok) ? ' · АКТИВНА' : (c === cur ? ' · выбрана' : '');
				var opt = E('option', { 'value': c }, c + ' — ' + name + ' · ' + stateText + activeText);
				if (isScanActiveNow() && prevSel && c === prevSel) {
					opt.selected = true;
				} else if (!isScanActiveNow() && c === cur) {
					opt.selected = true;
				}
				selEl.appendChild(opt);
			});
			if (isScanActiveNow() && prevSel && ordered.indexOf(prevSel) !== -1) {
				selEl.value = prevSel;
			} else {
				selEl.value = cur;
			}
		}

		function ensureCountryControl() {
			if (!countrySelectEl) {
				countrySelectEl = E('select', {
					'class': 'cbi-input-select owrt-psiphon-country-select',
					'style': 'font-weight:bold;margin:0;box-sizing:border-box',
					'focus': function() {
						isDropdownOpen = true;
						holdCountryDropdown();
					},
					'mousedown': function() {
						isDropdownOpen = true;
						holdCountryDropdown();
					},
					'keydown': function() {
						holdCountryDropdown();
					},
					'blur': function() {
						isDropdownOpen = false;
						holdCountryDropdown();
					},
					'change': function() {
						var chosen = this.value;
						holdCountryDropdown();
						if (isScanActiveNow()) {
							isDropdownOpen = false;
							notify('Просмотр списка во время подбора. Для переключения нажмите красную кнопку «СТОП» и выберите узел.', 'info');
							return;
						}
						isDropdownOpen = false;
						if (!chosen || chosen === status.country) return;
						if (guardBusy()) {
							this.value = status.country || 'FI';
							return;
						}
						busy = true;
						pendingAction = 'switch';
						syncButtons();
						renderLiveLine();
						notify('Переключение на ' + chosen + ' — ' + countryTitle(chosen) + '…', 'info');
						callSetCountry(chosen).then(function(r) {
							busy = false;
							pendingAction = '';
							notify((r && r.message) || chosen, (r && r.ok) ? 'info' : 'error');
							return updateStatus();
						}, function(e) {
							busy = false;
							pendingAction = '';
							notify('Ошибка: ' + e, 'error');
							return updateStatus();
						});
					}
				});
			}
			if (!isDropdownOpen && Date.now() >= dropdownHoldUntil) {
				populateCountryOptions(countrySelectEl);
			}
			if (!countryWrapEl) {
				countryWrapEl = E('div', { 'class': 'owrt-psiphon-country-wrap', 'style': 'display:flex;align-items:center;gap:8px;flex-wrap:wrap;max-width:100%' }, [
					countrySelectEl,
					btnScan,
					btnFirst
				]);
			}
			return countryWrapEl;
		}

		function renderOnOffBadge(isOn, labelOn, labelOff, detailText) {
			var badge = E('span', {
				'style': 'color:' + (isOn ? '#16a34a' : '#dc2626') + ';font-weight:bold'
			}, isOn ? (labelOn || 'ON') : (labelOff || 'OFF'));
			if (!detailText) return badge;
			return E('span', { 'style': 'display:inline-flex;align-items:center;gap:6px;flex-wrap:wrap' }, [
				badge,
				E('span', { 'style': 'color:#64748b;font-size:12px' }, detailText)
			]);
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

				appVerLabel.textContent = 'v' + (status.app_version || '0.6.6');
				warpVerLabel.textContent = status.version || 'v1.2.6';

				var wp;
				if (pendingAction === 'start') {
					wp = E('span', { 'class': 'owrt-inline-load', 'style': 'color:#2563eb;font-weight:bold' }, [
						E('span', { 'class': 'owrt-spinner', 'aria-hidden': 'true' }),
						E('span', {}, 'Запуск…')
					]);
				} else if (pendingAction === 'stop') {
					wp = E('span', { 'class': 'owrt-inline-load', 'style': 'color:#d97706;font-weight:bold' }, [
						E('span', { 'class': 'owrt-spinner', 'aria-hidden': 'true' }),
						E('span', {}, 'Остановка…')
					]);
				} else {
					wp = renderOnOffBadge(!!status.running, 'ON', 'OFF', '');
				}

				var sk;
				if (pendingAction === 'start' || pendingAction === 'switch') {
					sk = E('span', { 'class': 'owrt-inline-load', 'style': 'color:#2563eb;font-weight:bold' }, [
						E('span', { 'class': 'owrt-spinner', 'aria-hidden': 'true' }),
						E('span', {}, 'Ожидание…')
					]);
				} else if (pendingAction === 'stop') {
					sk = E('span', { 'class': 'owrt-inline-load', 'style': 'color:#dc2626;font-weight:bold' }, [
						E('span', { 'class': 'owrt-spinner', 'aria-hidden': 'true' }),
						E('span', {}, 'OFF…')
					]);
				} else {
					var socksActive = !!(status.socks_ok || (status.running && status.listening));
					var addrDetail = (status.bind && status.port) ? (status.bind + ':' + status.port) : '';
					sk = renderOnOffBadge(socksActive, 'ON', 'OFF', addrDetail);
				}

				var ipC = (status.running && status.socks_ok && status.exit_ip)
					? (status.exit_ip + (status.exit_country ? ' (' + status.exit_country + ')' : '') + (status.latency_ms ? ' · ' + status.latency_ms + ' мс' : ''))
					: '—';

				stateTable.textContent = '';
				[
					['warp-plus', wp],
					['SOCKS5 прокси', sk],
					['Выходной IP', ipC],
					['Страна выхода', ensureCountryControl()],
					['Ссылка для Steer', E('div', { 'style': 'display:flex;flex-direction:column;gap:4px' }, [
						E('div', { 'style': 'display:inline-flex;align-items:center;gap:8px;flex-wrap:wrap' }, [
							E('code', { 'style': 'user-select:all' }, sub),
							btnCopySub
						]),
						E('div', { 'style': 'font-size:12px;color:#666' }, 'Вставлять в Steer в поле новой секции «VPN: подписка или свои серверы». Своей маршрутизации у OWRTPsiphon нет.')
					])]
				].forEach(function(r) {
					stateTable.appendChild(E('div', { 'class': 'tr' }, [
						E('div', { 'class': 'td left', 'style': 'font-weight:bold;width:30%' }, r[0]),
						E('div', { 'class': 'td left' }, r[1])
					]));
				});

				syncButtons();
				renderLiveLine();
			});
		}

		function pollScan() {
			if (pollActive || !scan.running) return;
			pollActive = true;
			function tick() {
				if (pollTimer) {
					window.clearTimeout(pollTimer);
					pollTimer = null;
				}
				updateStatus().then(function() {
					if (scan.running && pendingAction !== 'stop') {
						pollTimer = window.setTimeout(tick, 10000);
					} else {
						pollActive = false;
					}
				}, function() {
					pollActive = false;
				});
			}
			pollTimer = window.setTimeout(tick, 10000);
		}

		function runAction(actKey, promiseFn, okMsg, startNotify) {
			if (actKey !== 'stop' && actKey !== 'stop_scan' && guardBusy()) return;
			if (startNotify) notify(startNotify, 'info');
			busy = true;
			pendingAction = actKey;
			syncButtons();
			renderLiveLine();
			updateStatus();

			promiseFn().then(function(r) {
				busy = false;
				pendingAction = '';
				notify((r && r.message) || okMsg, (r && r.ok) ? 'info' : 'error');
				return updateStatus();
			}).then(function() {
				pollScan();
			}, function(e) {
				busy = false;
				pendingAction = '';
				syncButtons();
				renderLiveLine();
				notify('Ошибка RPC: ' + e, 'error');
			});
		}

		btnCopySub.addEventListener('click', function() {
			if (pendingAction === 'uninstall') {
				guardBusy();
				return;
			}
			copyText(sub);
		});

		btnStart.addEventListener('click', function() {
			runAction('start', callStart, 'Запущено', 'Запуск службы…');
		});

		btnStop.addEventListener('click', function() {
			if (pendingAction === 'uninstall') {
				guardBusy();
				return;
			}
			runAction('stop', callStop, 'Остановлено', 'Остановка службы и процессов…');
		});

		btnProbe.addEventListener('click', function() {
			runAction('probe', callProbe, 'Проверено', null);
		});

		function handleScanOrStop() {
			var actKind = activeScanKind();
			if (actKind === 'scan') {
				runAction('stop_scan', callStop, 'Подбор остановлен', 'Остановка подбора…');
			} else if (actKind === 'scan_first') {
				guardBusy();
			} else {
				runAction('scan', callScan, 'Автоподбор запущен', 'Запуск автоподбора по пингу…');
			}
		}

		function handleFirstOrStop() {
			var actKind = activeScanKind();
			if (actKind === 'scan_first') {
				runAction('stop_scan', callStop, 'Подбор остановлен', 'Остановка подбора…');
			} else if (actKind === 'scan') {
				guardBusy();
			} else {
				runAction('scan_first', callScanFirst, 'Поиск первого рабочего запущен', 'Запуск поиска первого рабочего узла…');
			}
		}

		btnScan.addEventListener('click', handleScanOrStop);
		btnFirst.addEventListener('click', handleFirstOrStop);

		btnUninstall.addEventListener('click', function() {
			if (guardBusy()) return;
			if (!confirm('Удалить OWRTPsiphon, бинарник warp-plus, кэш и настройки?')) return;
			if (!confirm('Подтвердите полное удаление (Steer и Zapret не пострадают).')) return;
			busy = true;
			pendingAction = 'uninstall';
			setBtnState(btnUninstall, true, 'Удаление…');
			syncButtons();
			callUninstall().then(function(r) {
				notify((r && r.message) || 'Удалено', 'warning');
				window.setTimeout(function() { window.location.href = '/cgi-bin/luci/'; }, 2500);
			}, function(e) {
				busy = false;
				pendingAction = '';
				setBtnState(btnUninstall, false, 'Удалить приложение');
				syncButtons();
				notify('Ошибка: ' + e, 'error');
			});
		});

		function saveAuto(revertFn) {
			if (guardBusy()) {
				if (revertFn) revertFn();
				return;
			}
			var wh = selWatchdog.value || '0';
			var sb = (wh === 'boot') ? '1' : '0';
			busy = true;
			syncButtons();
			callSetAuto(
				chkAutostart.checked ? '1' : '0',
				sb,
				wh
			).then(function(r) {
				busy = false;
				notify((r && r.message) || 'Настройки автоматизации сохранены', (r && r.ok) ? 'info' : 'error');
				return updateStatus();
			}, function(e) {
				busy = false;
				syncButtons();
				notify('Ошибка RPC: ' + e, 'error');
			});
		}

		chkAutostart.addEventListener('change', function() {
			var prev = !chkAutostart.checked;
			saveAuto(function() { chkAutostart.checked = prev; });
		});
		selWatchdog.addEventListener('change', function() {
			saveAuto(function() {
				var whVal = String(status.watchdog_hours || '0');
				if (whVal === '0' && status.auto_scan_boot == 1) whVal = 'boot';
				selWatchdog.value = whVal;
			});
		});

		btnCheckApp.addEventListener('click', function() {
			if (guardBusy()) return;
			busy = true;
			setBtnState(btnCheckApp, true, 'Проверка…');
			syncButtons();
			appUpdStatus.textContent = 'Проверка GitHub…';
			callCheckUpdate().then(function(r) {
				busy = false;
				setBtnState(btnCheckApp, false, 'Проверить обновления');
				syncButtons();
				appUpdStatus.textContent = '';
				if (!r || !r.ok) {
					appUpdStatus.textContent = (r && r.message) || 'Ошибка проверки';
					return;
				}
				appUpdStatus.appendChild(E('span', {}, r.message));
				if (r.has_update) {
					var btnInstApp = E('button', {
						'class': 'btn cbi-button-positive owrt-act-btn',
						'style': 'margin-left:8px',
						'click': function() {
							if (guardBusy()) return;
							if (!confirm('Установить обновление v' + r.remote_version + '?')) return;
							busy = true;
							setBtnState(btnInstApp, true, 'Установка…');
							syncButtons();
							appUpdStatus.textContent = 'Установка обновления…';
							callApplyUpdate().then(function(res) {
								notify((res && res.message) || 'Обновление…', (res && res.ok) ? 'info' : 'error');
								if (res && res.ok) {
									window.setTimeout(function() {
										try {
											if (window.sessionStorage) {
												Object.keys(window.sessionStorage).forEach(function(k) {
													if (k.indexOf('luci') !== -1) window.sessionStorage.removeItem(k);
												});
											}
										} catch (e) {}
										window.location.replace('/cgi-bin/luci/admin/services/owrt-psiphon');
									}, 8000);
								} else {
									busy = false;
									setBtnState(btnInstApp, false, 'Установить v' + r.remote_version);
									syncButtons();
								}
							}, function(err) {
								busy = false;
								setBtnState(btnInstApp, false, 'Установить v' + r.remote_version);
								syncButtons();
								notify('Ошибка: ' + err, 'error');
							});
						}
					}, 'Установить v' + r.remote_version);
					appUpdStatus.appendChild(btnInstApp);
				}
			}, function(e) {
				busy = false;
				setBtnState(btnCheckApp, false, 'Проверить обновления');
				syncButtons();
				appUpdStatus.textContent = 'Ошибка запроса: ' + e;
			});
		});

		btnCheckWarp.addEventListener('click', function() {
			if (guardBusy()) return;
			busy = true;
			setBtnState(btnCheckWarp, true, 'Проверка…');
			syncButtons();
			warpUpdStatus.textContent = 'Проверка GitHub…';
			callCheckWarpUpdate().then(function(r) {
				busy = false;
				setBtnState(btnCheckWarp, false, 'Проверить обновления');
				syncButtons();
				warpUpdStatus.textContent = '';
				if (!r || !r.ok) {
					warpUpdStatus.textContent = (r && r.message) || 'Ошибка проверки';
					return;
				}
				warpUpdStatus.appendChild(E('span', {}, r.message));
				if (r.has_update) {
					var btnInstWarp = E('button', {
						'class': 'btn cbi-button-positive owrt-act-btn',
						'style': 'margin-left:8px',
						'click': function() {
							if (guardBusy()) return;
							if (!confirm('Обновить warp-plus до v' + r.remote_version + '?')) return;
							busy = true;
							setBtnState(btnInstWarp, true, 'Загрузка…');
							syncButtons();
							warpUpdStatus.textContent = 'Загрузка и обновление warp-plus…';
							callApplyWarpUpdate().then(function(res) {
								busy = false;
								setBtnState(btnInstWarp, false, 'Установить v' + r.remote_version);
								syncButtons();
								notify((res && res.message) || 'Готово', (res && res.ok) ? 'info' : 'error');
								warpUpdStatus.textContent = (res && res.message) || '';
								return updateStatus();
							}, function(err) {
								busy = false;
								setBtnState(btnInstWarp, false, 'Установить v' + r.remote_version);
								syncButtons();
								notify('Ошибка: ' + err, 'error');
							});
						}
					}, 'Установить v' + r.remote_version);
					warpUpdStatus.appendChild(btnInstWarp);
				}
			}, function(e) {
				busy = false;
				setBtnState(btnCheckWarp, false, 'Проверить обновления');
				syncButtons();
				warpUpdStatus.textContent = 'Ошибка запроса: ' + e;
			});
		});

		root.appendChild(E('style', {},
			'.owrt-psiphon-country-wrap{display:flex;align-items:center;gap:8px;flex-wrap:wrap;max-width:100%;}' +
			'.owrt-psiphon-country-select{min-width:340px;max-width:100%;width:auto;font-size:14px;}' +
			'.owrt-act-btn{display:inline-flex;align-items:center;gap:6px;vertical-align:middle;}' +
			'.owrt-soft-locked{opacity:0.55;cursor:not-allowed;}' +
			'.owrt-inline-load{display:inline-flex;align-items:center;gap:6px;}' +
			'.owrt-live-line{align-items:center;gap:8px;margin:10px 0;padding:8px 12px;border-radius:4px;background:#f8fafc;border-left:3px solid #2563eb;font-size:13px;color:#1e293b;}' +
			'.owrt-spinner{display:inline-block;width:13px;height:13px;border:2px solid currentColor;border-right-color:transparent;border-radius:50%;animation:owrtSpin .7s linear infinite;flex-shrink:0;}' +
			'@keyframes owrtSpin{to{transform:rotate(360deg);}}' +
			'@media(max-width:600px){.owrt-psiphon-country-wrap{display:flex;flex-direction:column;align-items:stretch;width:100%;}' +
			'.owrt-psiphon-country-select{display:block;width:100%;min-width:0;max-width:100%;}' +
			'.owrt-psiphon-country-wrap .btn{width:100%;margin:0!important;justify-content:center;}}'
		));
		root.appendChild(E('h2', {}, 'OWRTPsiphon'));
		root.appendChild(E('p', {}, 'Управление Psiphon (bepass-org/warp-plus --cfon) для Steer без изменения сетевой конфигурации.'));
		root.appendChild(stateTable);
		root.appendChild(liveLine);

		root.appendChild(E('div', { 'class': 'cbi-section' }, [
			E('h3', {}, 'Автоматизация и контроль узлов'),
			E('div', { 'class': 'cbi-value' }, [
				E('label', { 'class': 'cbi-value-title' }, 'Автостарт службы при загрузке'),
				E('div', { 'class': 'cbi-value-field' }, chkAutostart)
			]),
			E('div', { 'class': 'cbi-value' }, [
				E('label', { 'class': 'cbi-value-title' }, 'Проверка текущего узла (если упал ищем первый рабочий)'),
				E('div', { 'class': 'cbi-value-field' }, [
					selWatchdog,
					E('div', { 'style': 'font-size:12px;color:#666;margin-top:4px' }, 'Проверяет текущий узел; если он упал или не отвечает — ищет первый рабочий узел по порядку без зацикливания.')
				])
			])
		]));

		root.appendChild(E('div', { 'class': 'cbi-section' }, [
			E('h3', {}, 'Управление и обновления'),
			E('div', { 'style': 'margin-bottom:10px' }, [
				btnStart,
				btnStop,
				btnProbe,
				btnUninstall
			]),
			E('div', { 'class': 'table' }, [
				E('div', { 'class': 'tr' }, [
					E('div', { 'class': 'td left', 'style': 'font-weight:bold;width:30%;vertical-align:middle' }, 'Версия OWRTPsiphon'),
					E('div', { 'class': 'td left', 'style': 'vertical-align:middle' }, [
						E('div', { 'style': 'display:inline-flex;align-items:center;gap:8px;flex-wrap:wrap' }, [
							appVerLabel,
							btnCheckApp,
							appUpdStatus
						])
					])
				]),
				E('div', { 'class': 'tr' }, [
					E('div', { 'class': 'td left', 'style': 'font-weight:bold;width:30%;vertical-align:middle' }, 'Версия warp-plus'),
					E('div', { 'class': 'td left', 'style': 'vertical-align:middle' }, [
						E('div', { 'style': 'display:inline-flex;align-items:center;gap:8px;flex-wrap:wrap' }, [
							warpVerLabel,
							btnCheckWarp,
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
    chmod 644 /usr/share/luci/menu.d/luci-app-owrt-psiphon.json /usr/share/rpcd/acl.d/luci-app-owrt-psiphon.json \
        /www/luci-static/resources/view/owrt-psiphon/main.js
fi

printf '%s\n' "$APP_VER" > "$APP/app.version"
chmod 755 /etc/init.d/owrt-psiphon /usr/libexec/rpcd/owrt-psiphon /usr/libexec/owrt-psiphon/owrt-psiphonctl

/usr/libexec/owrt-psiphon/owrt-psiphonctl set_auto \
    "$(uci -q get owrt-psiphon.main.autostart || echo 1)" \
    "$(uci -q get owrt-psiphon.main.auto_scan_boot || echo 0)" \
    "$(uci -q get owrt-psiphon.main.watchdog_hours || echo 0)" >/dev/null 2>&1 || true

if [ "$NO_LUCI" -eq 0 ]; then
    touch /www/luci-static/resources/view/owrt-psiphon/main.js
    rm -rf /tmp/luci-indexcache /tmp/luci-modulecache
fi
rm -rf "$TMP"
/etc/init.d/rpcd restart >/dev/null 2>&1 || true
if [ "$NO_LUCI" -eq 0 ]; then
    /etc/init.d/uhttpd restart >/dev/null 2>&1 || true
fi

log "Установка OWRTPsiphon v${APP_VER} (${WP_ARCH}) завершена. Служба не запускалась."
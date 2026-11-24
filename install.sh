#!/bin/sh
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

# If invoked as curl | sh, fetch the complete repository tree first.
if [ ! -f files/etc/config/owrt-psiphon ]; then
        REPO="${1:-}"
        case "$REPO" in */*) ;; *) fail 'Укажи OWNER/REPOSITORY: curl .../install.sh | sh -s -- OWNER/REPOSITORY' ;; esac
        mkdir -p "$TMP/source"
        curl -fL --retry 3 "https://github.com/${REPO}/archive/refs/heads/main.tar.gz" -o "$TMP/source/repo.tar.gz" || fail 'Не удалось скачать архив репозитория.'
        tar -xzf "$TMP/source/repo.tar.gz" -C "$TMP/source" || fail 'Не удалось распаковать репозиторий.'
        SOURCE="$(find "$TMP/source" -mindepth 1 -maxdepth 1 -type d | head -1)"
        [ -n "$SOURCE" ] || fail 'В архиве GitHub не найдена папка проекта.'
        cd "$SOURCE"
        exec sh ./install.sh --local
fi

mkdir -p "$TMP" "$APP"

# Prefer the exact binary already tested on this router. On a clean reset, fetch the
# pinned upstream ARM64 release and verify its published archive checksum.
if [ -x /tmp/wp-test/unpacked/warp-plus ]; then
        if command -v sha256sum >/dev/null 2>&1; then
                got="$(sha256sum /tmp/wp-test/unpacked/warp-plus | awk '{print $1}')"
        elif busybox --list 2>/dev/null | grep -qx sha256sum; then
                got="$(busybox sha256sum /tmp/wp-test/unpacked/warp-plus | awk '{print $1}')"
        else
                got=""
        fi
        if [ "$got" = "$TESTED_LOCAL_SHA256" ]; then
                log 'Использую уже проверенный на этом роутере бинарник.'
                cp /tmp/wp-test/unpacked/warp-plus "$APP/warp-plus.new"
        fi
fi

if [ ! -s "$APP/warp-plus.new" ]; then
        log "Загружаю warp-plus v${VERSION} для ARM64..."
        curl -fL --retry 3 --connect-timeout 20 "$ASSET" -o "$TMP/warp-plus.zip" || fail 'Не удалось скачать warp-plus.'
        if ! command -v sha256sum >/dev/null 2>&1; then
                if busybox --list 2>/dev/null | grep -qx sha256sum; then
                        SHA="busybox sha256sum"
                else
                        log 'Устанавливаю утилиту проверки SHA256 из APK...'
                        apk add --no-cache coreutils-sha256sum || fail 'Не удалось установить coreutils-sha256sum.'
                        SHA="sha256sum"
                fi
        else
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

# Preserve existing config and cache on upgrades.
if [ ! -f /etc/config/owrt-psiphon ]; then
        cp files/etc/config/owrt-psiphon /etc/config/owrt-psiphon
fi

mkdir -p /etc/init.d /usr/libexec/rpcd /usr/libexec/owrt-psiphon \
        /usr/share/luci/menu.d /usr/share/rpcd/acl.d \
        /www/luci-static/resources/view/owrt-psiphon
cp files/etc/init.d/owrt-psiphon /etc/init.d/owrt-psiphon
cp files/usr/libexec/rpcd/owrt-psiphon /usr/libexec/rpcd/owrt-psiphon
cp files/usr/libexec/owrt-psiphon/owrt-psiphonctl /usr/libexec/owrt-psiphon/owrt-psiphonctl
cp files/usr/share/luci/menu.d/luci-app-owrt-psiphon.json /usr/share/luci/menu.d/luci-app-owrt-psiphon.json
cp files/usr/share/rpcd/acl.d/luci-app-owrt-psiphon.json /usr/share/rpcd/acl.d/luci-app-owrt-psiphon.json
cp files/www/luci-static/resources/view/owrt-psiphon/main.js /www/luci-static/resources/view/owrt-psiphon/main.js
chmod 755 /etc/init.d/owrt-psiphon /usr/libexec/rpcd/owrt-psiphon /usr/libexec/owrt-psiphon/owrt-psiphonctl
chmod 644 /usr/share/luci/menu.d/luci-app-owrt-psiphon.json /usr/share/rpcd/acl.d/luci-app-owrt-psiphon.json /www/luci-static/resources/view/owrt-psiphon/main.js

# Do not enable/start automatically: port 8086 may currently belong to the manually
# launched tunnel used by Steer. User explicitly adopts it from the LuCI page.
/etc/init.d/rpcd restart >/dev/null 2>&1 || true
rm -f /tmp/luci-indexcache
rm -rf "$TMP"
log 'Файлы установлены. Действующий warp-plus и конфигурация Steer не тронуты.'
log 'Открой Службы → OWRTPsiphon. Для передачи текущего туннеля нажми «Перенять текущий туннель».'

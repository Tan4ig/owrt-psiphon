#!/bin/sh
set -eu

[ "$(id -u)" = 0 ] || { echo 'Run as root'; exit 1; }
/etc/init.d/owrt-psiphon stop >/dev/null 2>&1 || true
/etc/init.d/owrt-psiphon disable >/dev/null 2>&1 || true
rm -f /etc/init.d/owrt-psiphon \
      /usr/libexec/rpcd/owrt-psiphon \
      /usr/libexec/owrt-psiphon/owrt-psiphonctl \
      /usr/share/luci/menu.d/luci-app-owrt-psiphon.json \
      /usr/share/rpcd/acl.d/luci-app-owrt-psiphon.json \
      /www/luci-static/resources/view/owrt-psiphon/main.js \
      /var/run/owrt-psiphon.pid
rmdir /www/luci-static/resources/view/owrt-psiphon 2>/dev/null || true
/etc/init.d/rpcd restart >/dev/null 2>&1 || true
rm -f /tmp/luci-indexcache
if [ "${PURGE:-0}" = 1 ]; then
        rm -rf /opt/owrt-psiphon /etc/config/owrt-psiphon /var/log/owrt-psiphon.log
        echo 'OWRTPsiphon удалён вместе с бинарником, кэшем и конфигурацией.'
else
        echo 'Код удалён. Бинарник, кэш и /etc/config/owrt-psiphon сохранены.'
        echo 'Для полного удаления повтори с PURGE=1.'
fi

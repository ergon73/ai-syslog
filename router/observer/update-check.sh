#!/bin/sh
# Ежедневный отчёт об обновлениях. Cron раз в сутки. Проверяет:
#   1) picoclaw (GitHub)  — статус в отчёте ВСЕГДА;
#   2) прошивку роутера (RCI components list, свой канал) — ТОЛЬКО если есть новая;
#   3) пакеты Entware (opkg)                              — ТОЛЬКО если есть обновления.
# Ничего не устанавливает.

DIR=/opt/etc/observer
. "$DIR/observer.conf" 2>/dev/null || exit 1
. "$DIR/lib.sh"
export HOME=/opt/root

# --- 2) прошивка роутера: RCI components list (асинхронный, повторяем POST) --
fw_note=""
fw_resp=""
i=0
while [ $i -lt 10 ]; do
    fw_resp=$(curl -s --max-time 20 -X POST -H "Content-Type: application/json" \
        -d '{"components":{"list":{}}}' http://localhost:79/rci/ 2>/dev/null)
    echo "$fw_resp" | grep -q '"continued"' || break
    i=$((i+1)); sleep 3
done
fw_avail=$(echo "$fw_resp" | jq -r '.components.list.firmware.title // empty' 2>/dev/null)
fw_local=$(echo "$fw_resp" | jq -r '.components.list.local.title // empty' 2>/dev/null)
if [ -n "$fw_avail" ] && [ -n "$fw_local" ]; then
    if [ "$fw_avail" != "$fw_local" ]; then
        fw_note="
🛜 Прошивка роутера: доступна $fw_avail (установлена $fw_local, канал dev).
Обновление — через веб-интерфейс Keenetic; после него я проверю себя сам (healthcheck)."
    fi
else
    echo "$(date '+%F %T') update-check: не удалось проверить прошивку" >> "$DIR/state/observer.log"
fi

# --- 3) пакеты Entware: только если есть что обновлять ------------------------
opkg_note=""
if opkg update >/dev/null 2>&1; then
    up=$(opkg list-upgradable 2>/dev/null)
    if [ -n "$up" ]; then
        n=$(echo "$up" | wc -l)
        opkg_note="
📦 Entware: доступно обновлений пакетов — $n:
$(echo "$up" | head -8)
Обновить: opkg upgrade (вручную по SSH; наши демоны переживают обновление пакетов)."
    fi
else
    echo "$(date '+%F %T') update-check: opkg update не отработал" >> "$DIR/state/observer.log"
fi

cur=$(/opt/usr/bin/picoclaw --version 2>&1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)  # версия в stderr
[ -n "$cur" ] || cur="неизвестна"

# --- последний релиз с GitHub (прямо -> WG-интерфейсы) ---
fetch() {
    for _if in "" $TG_IFACES; do
        [ -n "$_if" ] && o="--interface $_if" || o=""
        r=$(curl -s --max-time 20 $o \
            https://api.github.com/repos/sipeed/picoclaw/releases/latest 2>/dev/null)
        echo "$r" | grep -q '"tag_name"' && { printf '%s' "$r"; return 0; }
    done
    return 1
}

if ! resp=$(fetch); then
    tg_send "🔄 picoclaw — ежедневная проверка обновлений
⚠️ Не удалось связаться с GitHub. Установленная версия: $cur.
Проверю снова завтра."
    echo "$(date '+%F %T') update-check: GitHub недоступен" >> "$DIR/state/observer.log"
    exit 0
fi

latest=$(echo "$resp" | jq -r '.tag_name // empty' | sed 's/^v//')
url=$(echo "$resp"    | jq -r '.html_url  // empty')
body=$(echo "$resp"   | jq -r '.name      // empty')
[ -n "$latest" ] || { latest="?"; }

newer=$(awk -v a="$cur" -v b="$latest" 'BEGIN{
    split(a,A,"."); split(b,B,".");
    for(i=1;i<=3;i++){ x=A[i]+0; y=B[i]+0;
        if(y>x){print 1; exit} if(y<x){print 0; exit} }
    print 0 }')

if [ "$newer" = 1 ]; then
    tg_send "🔔 picoclaw — доступно обновление
Установлено: $cur   →   доступно: $latest${body:+  ($body)}
Что нового: $url

Я ничего не устанавливал — обновление агента на роутере ручное (загрузка бинарника + перезапуск). Скажи, когда захочешь обновить, и я помогу.${fw_note}${opkg_note}"
    echo "$(date '+%F %T') update-check: доступна picoclaw $latest (у нас $cur)" >> "$DIR/state/observer.log"
else
    tg_send "✅ Ежедневная проверка обновлений
picoclaw: актуальная версия $cur (последний релиз: $latest).${fw_note}${opkg_note}"
fi

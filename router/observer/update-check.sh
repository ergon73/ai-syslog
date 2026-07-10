#!/bin/sh
# Watchdog обновлений picoclaw. Cron раз в сутки.
# Сравнивает установленную версию с последним релизом на GitHub и уведомляет
# в Telegram, ЕСЛИ доступна более новая. Ничего не устанавливает (агент на
# роутере обновляется вручную). Уведомляет один раз на версию, не спамит.

DIR=/opt/etc/observer
. "$DIR/observer.conf" 2>/dev/null || exit 1
. "$DIR/lib.sh"
export HOME=/opt/root

cur=$(/opt/usr/bin/picoclaw --version 2>&1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)  # версия идёт в stderr
[ -n "$cur" ] || exit 0

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
resp=$(fetch) || { echo "$(date '+%F %T') update-check: GitHub недоступен" >> "$DIR/state/observer.log"; exit 0; }
latest=$(echo "$resp" | jq -r '.tag_name // empty' | sed 's/^v//')
url=$(echo "$resp"    | jq -r '.html_url  // empty')
body=$(echo "$resp"   | jq -r '.name      // empty')
[ -n "$latest" ] || exit 0

# --- latest строго новее cur? (посегментное числовое сравнение) ---
newer=$(awk -v a="$cur" -v b="$latest" 'BEGIN{
    split(a,A,"."); split(b,B,".");
    for(i=1;i<=3;i++){ x=A[i]+0; y=B[i]+0;
        if(y>x){print 1; exit} if(y<x){print 0; exit} }
    print 0 }')
if [ "$newer" != 1 ]; then
    echo "$latest" > "$DIR/state/pc_ver_seen"      # актуально, молчим
    exit 0
fi

# --- уже уведомляли об этой версии? ---
notified=$(cat "$DIR/state/pc_ver_notified" 2>/dev/null)
[ "$notified" = "$latest" ] && exit 0
echo "$latest" > "$DIR/state/pc_ver_notified"

tg_send "🔔 Доступно обновление picoclaw
Сейчас: $cur   →   доступно: $latest${body:+  ($body)}
Что нового: $url

Я ничего не устанавливал — агент на роутере обновляется вручную (загрузка бинарника + перезапуск). Скажи, когда захочешь обновить, и я помогу."
echo "$(date '+%F %T') update-check: доступна picoclaw $latest (у нас $cur)" >> "$DIR/state/observer.log"

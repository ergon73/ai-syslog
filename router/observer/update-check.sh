#!/bin/sh
# Ежедневный отчёт об обновлениях picoclaw. Cron раз в сутки.
# Всегда шлёт одно сообщение в Telegram со статусом (есть обновление или нет),
# ничего не устанавливает — обновление агента на роутере ручное.

DIR=/opt/etc/observer
. "$DIR/observer.conf" 2>/dev/null || exit 1
. "$DIR/lib.sh"
export HOME=/opt/root

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

Я ничего не устанавливал — обновление агента на роутере ручное (загрузка бинарника + перезапуск). Скажи, когда захочешь обновить, и я помогу."
    echo "$(date '+%F %T') update-check: доступна picoclaw $latest (у нас $cur)" >> "$DIR/state/observer.log"
else
    tg_send "✅ picoclaw — ежедневная проверка обновлений
Установлена актуальная версия: $cur (последний релиз на GitHub: $latest). Обновлений нет."
fi

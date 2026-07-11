#!/bin/sh
# Наблюдатель Фаза 1: утренний дайджест + heartbeat. Cron, 08:00.
# Сводит накопленное за сутки (day.acc) через LLM-модель дайджеста
# и шлёт в Telegram. Тишина от бота = проблема (heartbeat встроен).

DIR=/opt/etc/observer
STATE=$DIR/state
. "$DIR/observer.conf" || exit 1
. "$DIR/lib.sh"
ensure_tg_route

. "$STATE/stats" 2>/dev/null || { lines=0; kept=0; llm=0; tg=0; }
hb="🤖 Наблюдатель жив. За сутки: строк $lines, после фильтра $kept, вызовов LLM $llm, уведомлений $tg."

if [ ! -s "$STATE/day.acc" ]; then
    tg_send "$hb
За сутки событий после фильтрации не было."
else
    # пересуммировать одинаковые строки за сутки, топ-50
    awk -F'\t' '{c[$2"\t"$3]+=$1} END{for (k in c) print c[k]"\t"k}' \
        "$STATE/day.acc" | sort -rn | head -n 50 > "$STATE/day.top"
    top=$(cat "$STATE/day.top")

    digest=$(llm_ask "$MODEL_DIGEST" "$DIR/prompt_digest.txt" "$STATE/day.top" 0.3)

    if [ -n "$digest" ]; then
        tg_send_rich "## 📊 Сводка за сутки

$digest

---
$hb"
    else
        tg_send "$hb
⚠️ Дайджест не сформирован (LLM недоступен), топ событий:
$(echo "$top" | head -n 10)"
    fi
fi

# ротация суточного накопителя и счётчиков
mv -f "$STATE/day.acc" "$STATE/day.acc.prev" 2>/dev/null
echo "lines=0 kept=0 llm=0 tg=0" > "$STATE/stats"

# страховка от разрастания собственного лога
[ -f "$STATE/observer.log" ] && [ "$(wc -c < "$STATE/observer.log")" -gt 1048576 ] \
    && : > "$STATE/observer.log"

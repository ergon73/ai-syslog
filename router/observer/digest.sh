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

# --- изменения конфигурации за сутки (раздел появляется ТОЛЬКО при изменении).
# Дифф: состояние «сутки назад» -> новейшая копия; несколько правок за день
# схлопываются в суммарную. Детерминированно, без LLM.
BK=${BK:-/opt/backups/config}
cfg_note=""
# отбор по МЕТКЕ В ИМЕНИ файла (config-ГГГГ-ММ-ДД_ЧЧММ.cfg), не по mtime:
# имена сортируются лексикографически и не зависят от прихотей ФС/копирований
cutname="config-$(awk -v t=$(( $(date +%s) - 86400 )) 'BEGIN{print strftime("%Y-%m-%d_%H%M", t)}').cfg"
newest=$(ls "$BK"/config-*.cfg 2>/dev/null | sort | tail -1)
newer_than_cut=0
if [ -n "$newest" ]; then
    top=$(printf '%s\n%s\n' "$(basename "$newest")" "$cutname" | sort | tail -1)
    [ "$top" = "$(basename "$newest")" ] && [ "$(basename "$newest")" != "$cutname" ] && newer_than_cut=1
fi
if [ "$newer_than_cut" = 1 ]; then
    # база: последняя копия ДО начала суток (= состояние сутки назад);
    # если все копии моложе суток, но их >=2 — берём самую раннюю из них
    base=$(ls "$BK"/config-*.cfg 2>/dev/null | sort | awk -F/ -v c="$cutname" '$NF <= c {keep=$0} END{print keep}')
    if [ -z "$base" ]; then
        ncf=$(ls "$BK"/config-*.cfg 2>/dev/null | wc -l)
        [ "$ncf" -ge 2 ] && base=$(ls "$BK"/config-*.cfg | sort | head -1)
    fi
    [ "$base" = "$newest" ] && base=""
    if [ -n "$base" ]; then
        # busybox diff = unified-формат: добавленное "+", удалённое "-"
        d=$(diff "$base" "$newest" 2>/dev/null | grep -E '^[+-]' \
            | grep -vE '^(\+\+\+|---)' | grep -v '! \$\$\$' | head -40)
        nl=$(printf '%s\n' "$d" | grep -c . )
        cfg_note="

## ⚙️ Конфигурация менялась за сутки
Суммарный дифф («+» добавлено, «-» удалено; $nl строк$( [ "$nl" -ge 40 ] && echo ", показаны первые 40")):
\`\`\`
$d
\`\`\`"
    else
        cfg_note="

## ⚙️ Конфигурация
Создан первый бэкап конфигурации ($(basename "$newest"))."
    fi
fi

if [ ! -s "$STATE/day.acc" ]; then
    tg_send_rich "$hb
За сутки событий после фильтрации не было.${cfg_note}"
else
    # пересуммировать одинаковые строки за сутки, топ-50
    awk -F'\t' '{c[$2"\t"$3]+=$1} END{for (k in c) print c[k]"\t"k}' \
        "$STATE/day.acc" | sort -rn | head -n 50 > "$STATE/day.top"
    top=$(cat "$STATE/day.top")

    digest=$(llm_ask "$MODEL_DIGEST" "$DIR/prompt_digest.txt" "$STATE/day.top" 0.3)

    if [ -n "$digest" ]; then
        tg_send_rich "## 📊 Сводка за сутки

$digest${cfg_note}

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

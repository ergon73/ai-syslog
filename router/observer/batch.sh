#!/bin/sh
# Наблюдатель Фаза 1: батчер. Запускается cron'ом раз в 3 минуты.
# Дочитывает новые строки /opt/var/log/router.log по offset (как sshpull),
# фильтрует шум (drop), агрегирует повторы, известный шум копит для дайджеста,
# незнакомые строки отправляет LLM (Ollama Cloud) и важное шлёт в Telegram.
# LLM не имеет никаких прав на исполнение — только текст туда, JSON обратно.
# BusyBox ash: без bash-измов.

DIR=/opt/etc/observer
STATE=$DIR/state
LOGF=/opt/var/log/router.log
SELF_LOG=$STATE/observer.log

. "$DIR/observer.conf" || exit 1
. "$DIR/lib.sh"
mkdir -p "$STATE"
ensure_tg_route

log() { echo "$(date '+%F %T') $*" >> "$SELF_LOG"; }

# --- защита от параллельного запуска -------------------------------------
LOCK=$STATE/batch.lock
if ! mkdir "$LOCK" 2>/dev/null; then exit 0; fi
trap 'rmdir "$LOCK"' EXIT

# --- счётчики за сутки -----------------------------------------------------
CNT=$STATE/stats
[ -f "$CNT" ] || echo "lines=0 kept=0 llm=0 tg=0" > "$CNT"
. "$CNT" 2>/dev/null || { lines=0; kept=0; llm=0; tg=0; }
save_stats() { echo "lines=$lines kept=$kept llm=$llm tg=$tg" > "$CNT"; }

# --- Telegram (tg_send из lib.sh) -------------------------------------------
tg_notify() { tg_send "$1" && tg=$((tg+1)); }

# --- новые байты по offset -------------------------------------------------
OFFSET_F=$STATE/offset
offset=$(cat "$OFFSET_F" 2>/dev/null)
[ -n "$offset" ] || offset=0
size=$(wc -c < "$LOGF" 2>/dev/null)
[ -n "$size" ] || exit 0
[ "$size" -lt "$offset" ] && offset=0          # файл усечён/ротирован
[ "$size" -eq "$offset" ] && exit 0            # нового нет

tail -c +$((offset+1)) "$LOGF" | head -c 2097152 > "$STATE/chunk.raw"
nlines=$(wc -l < "$STATE/chunk.raw")           # число ПОЛНЫХ строк
[ "$nlines" -gt 0 ] || exit 0
head -n "$nlines" "$STATE/chunk.raw" > "$STATE/chunk.lines"
consumed=$(wc -c < "$STATE/chunk.lines")
echo $((offset+consumed)) > "$OFFSET_F"
lines=$((lines+nlines))

# --- уровень 0: drop -------------------------------------------------------
# шаблоны без комментариев и пустых строк (пустой шаблон в grep -f матчит всё)
grep -v '^#' "$DIR/drop_patterns.txt"    | grep -v '^[[:space:]]*$' > "$STATE/drop.re"
grep -v '^#' "$DIR/boring_patterns.txt"  | grep -v '^[[:space:]]*$' > "$STATE/boring.re"
grep -v '^#' "$DIR/reboot_patterns.txt"  | grep -v '^[[:space:]]*$' > "$STATE/reboot.re" 2>/dev/null

# формат строки лога: UNIXTIME \t LEVEL \t HOST \t PROGRAM \t MSG
cut -f4,5 "$STATE/chunk.lines" \
    | grep -viE -f "$STATE/drop.re" > "$STATE/survivors" || true
ns=$(wc -l < "$STATE/survivors")
kept=$((kept+ns))
if [ "$ns" -eq 0 ]; then save_stats; exit 0; fi

# --- агрегация: маскируем изменчивые поля, схлопываем повторы ---------------
sed -e 's/[0-9a-fA-F][0-9a-fA-F]\(:[0-9a-fA-F][0-9a-fA-F]\)\{5\}/MAC/g' \
    -e 's/[0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}/IP/g' \
    -e 's/[0-9]\{2,\}/N/g' \
    -e 's/(try [0-9]*)/(try N)/g' \
    "$STATE/survivors" \
    | sort | uniq -c | sort -rn \
    | sed 's/^ *\([0-9]*\) /\1\t/' > "$STATE/agg"

# копим всё для дайджеста
cat "$STATE/agg" >> "$STATE/day.acc"

# --- уровень 1: незнакомое (не boring) -> кандидат на LLM -------------------
# boring-шаблоны матчатся по "PROGRAM\tMSG" (без счётчика), но в interesting
# строки идут ЦЕЛИКОМ, со счётчиком повторов — LLM должен видеть масштаб
# (одна ошибка пароля Wi-Fi и серия из 10 — разные вердикты).
cut -f2- "$STATE/agg" | grep -viEn -f "$STATE/boring.re" | cut -d: -f1 \
    > "$STATE/int.idx" || true
awk 'NR==FNR {keep[$1]=1; next} FNR in keep' \
    "$STATE/int.idx" "$STATE/agg" > "$STATE/interesting"

# --- послезагрузочный шторм: в окне после ребута гасим ожидаемые boot-события.
# uptime берём из RCI; в дайджест эти строки уже попали (day.acc), теряем только
# реалтайм-спам. Вне окна reboot.re не применяется — реальные сбои не пропадут.
upt=$(curl -s --max-time 5 http://localhost:79/rci/show/system 2>/dev/null | jq -r '.uptime // empty' 2>/dev/null)
case "$upt" in ''|*[!0-9]*) upt="" ;; esac
if [ -n "$upt" ] && [ "$upt" -lt "${REBOOT_WINDOW:-600}" ]; then
    nb=$(date +%s); boot_ts=$((nb - upt))
    lb=$(cat "$STATE/last_boot" 2>/dev/null); [ -n "$lb" ] || lb=0
    dd=$((boot_ts - lb)); [ "$dd" -lt 0 ] && dd=$((-dd))
    if [ "$dd" -gt 120 ]; then                       # новый ребут — объявить один раз
        echo "$boot_ts" > "$STATE/last_boot"
        tg_notify "🔄 Роутер перезагрузился ~$((upt/60)) мин назад. Идёт восстановление — временные ошибки WireGuard, DNS и сетевых интерфейсов в ближайшие минуты ожидаемы и вмешательства не требуют."
        log "обнаружен ребут (uptime ${upt}s), boot-шторм подавляется ${REBOOT_WINDOW:-600}s"
    fi
    if [ -s "$STATE/reboot.re" ]; then
        grep -viE -f "$STATE/reboot.re" "$STATE/interesting" > "$STATE/interesting.f" 2>/dev/null \
            && mv "$STATE/interesting.f" "$STATE/interesting"
    fi
fi

# --- дедуп алертов: событие, уже показанное владельцу за окно охлаждения,
# повторно не алертится (в day.acc и дайджест оно уже попало).
# Хэш — по "PROGRAM\tMSG" без счётчика, чтобы серия из двух тиков не дублилась.
HIST=$STATE/alert.hist
now_ts=$(date +%s)
cool=${ALERT_COOLDOWN:-10800}
touch "$HIST"
awk -v now="$now_ts" -v cd="$cool" '$2 >= now-cd' "$HIST" > "$HIST.new" \
    && mv "$HIST.new" "$HIST"
: > "$STATE/interesting.new"
while IFS= read -r line; do
    key=$(printf '%s' "$line" | cut -f2- | md5sum | cut -d' ' -f1)
    if ! grep -q "^$key " "$HIST"; then
        printf '%s\n' "$line" >> "$STATE/interesting.new"
        echo "$key $now_ts" >> "$HIST"
    fi
done < "$STATE/interesting"
mv "$STATE/interesting.new" "$STATE/interesting"
[ -s "$STATE/interesting" ] || { save_stats; exit 0; }

# --- предохранители ----------------------------------------------------------
if [ -z "$OLLAMA_API_KEY" ] || [ -z "$TG_TOKEN" ]; then
    log "ключи не заданы, интересных строк: $(wc -l < "$STATE/interesting")"
    save_stats; exit 0
fi
if [ "$llm" -ge "${LLM_MAX_PER_DAY:-100}" ]; then
    log "llm daily cap reached, skip"; save_stats; exit 0
fi

head -c "${BATCH_MAX_CHARS:-6000}" "$STATE/interesting" > "$STATE/batch.txt"
llm=$((llm+1)); save_stats

content=$(llm_ask "$MODEL_REALTIME" "$DIR/prompt_realtime.txt" "$STATE/batch.txt" 0.1)

if [ -z "$content" ]; then
    log "LLM недоступен (primary и fallback)"
    save_stats; exit 0
fi

# вырезать JSON-объект из ответа (модель может обрамлять его текстом/```)
content=$(echo "$content" \
    | sed -n '/{/,/}/p' | sed -e '1s/^[^{]*//' -e '$s/[^}]*$//')

# важно: не использовать ".important // empty" — для false оно даёт пустоту
important=$(echo "$content" | jq -r '.important | tostring' 2>/dev/null)
severity=$(echo "$content"  | jq -r '.severity  // "info"' 2>/dev/null)
summary=$(echo "$content"   | jq -r '.summary_ru // empty' 2>/dev/null)

if [ "$important" != "true" ] && [ "$important" != "false" ]; then
    # JSON не разобрался — fail-open: показать сырьё, не терять сигнал
    tg_notify "⚠️ [наблюдатель] не разобрал вердикт LLM, сырые события:
$(head -c 1000 "$STATE/interesting")"
    log "не разобран JSON: $(echo "$content" | head -c 200)"
elif [ "$important" = "true" ]; then
    case "$severity" in
        alert) icon="🚨" ;;
        warn)  icon="⚠️" ;;
        *)     icon="ℹ️" ;;
    esac
    tg_notify "$icon $summary

$(head -c 800 "$STATE/interesting")" || log "tg_send ПРОВАЛ: $summary"
fi
log "вердикт: important=$important sev=$severity: $(echo "$summary" | head -c 120)"
save_stats

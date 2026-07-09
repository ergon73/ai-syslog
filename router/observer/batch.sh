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
grep -v '^#' "$DIR/drop_patterns.txt"   | grep -v '^[[:space:]]*$' > "$STATE/drop.re"
grep -v '^#' "$DIR/boring_patterns.txt" | grep -v '^[[:space:]]*$' > "$STATE/boring.re"

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
cut -f2- "$STATE/agg" | grep -viE -f "$STATE/boring.re" \
    > "$STATE/interesting" || true
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

$(head -c 800 "$STATE/interesting")"
fi
save_stats

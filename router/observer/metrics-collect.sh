#!/bin/sh
# Сборщик метрик нагрузки роутера. Cron каждые 5 минут.
# Пишет сэмплы в tmpfs (/tmp — RAM, бережём флешку), обновляет снимок
# state/metrics.now (читает агент) и проверяет отклонение от базлайна.
# Метрики: cpu %, RAM %, активные соединения, loadavg×100, WAN КиБ/с.

DIR=/opt/etc/observer
TMP=/tmp/metrics
mkdir -p "$TMP"
. "$DIR/observer.conf" 2>/dev/null

now=$(date +%s)
hour=$(date +%H); hour=${hour#0}; [ -n "$hour" ] || hour=0   # 08->8 без восьмеричной ловушки

# --- снятие метрик одним RCI-вызовом + /proc ---
sys=$(curl -s --max-time 5 http://localhost:79/rci/show/system)
cpu=$(echo "$sys"  | jq -r '.cpuload  // 0')
mem=$(echo "$sys"  | jq -r '.memory   // "0/1"')
ctot=$(echo "$sys" | jq -r '.conntotal // 0')
cfree=$(echo "$sys"| jq -r '.connfree  // 0')
used=${mem%/*}; total=${mem#*/}; [ "$total" -gt 0 ] 2>/dev/null || total=1
memp=$((used*100/total))
conn=$((ctot-cfree))
load1=$(awk '{print int($1*100)}' /proc/loadavg)

# WAN-скорость по аплинку apclii0 (дельта байт /proc/net/dev), счёт в awk (64-бит)
netline=$(grep apclii0 /proc/net/dev)
rx=$(echo "$netline" | awk '{print $2}'); tx=$(echo "$netline" | awk '{print $10}')
[ -n "$rx" ] || rx=0; [ -n "$tx" ] || tx=0
pf=$TMP/prev_net
if [ -f "$pf" ]; then
    read prx ptx pts < "$pf"
    kbps=$(awk -v rx="$rx" -v tx="$tx" -v prx="$prx" -v ptx="$ptx" -v now="$now" -v pts="$pts" \
        'BEGIN{dt=now-pts; if(dt<1)dt=1; k=((rx-prx)+(tx-ptx))/dt/1024; if(k<0)k=0; printf "%d",k}')
else
    kbps=0
fi
echo "$rx $tx $now" > "$pf"

# --- сэмпл в tmpfs: ts hour cpu mem conn load wan ---
printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$now" "$hour" "$cpu" "$memp" "$conn" "$load1" "$kbps" >> "$TMP/samples.tsv"

# --- снимок для агента ---
{
    echo "# Метрики нагрузки — $(date '+%F %T %Z') (слот часа: $hour)"
    echo "unixtime_now=$now"
    up_s=$(cut -d. -f1 /proc/uptime)
    echo "boot_time=$(awk -v b=$((now-up_s)) 'BEGIN{print strftime("%F %H:%M MSK", b)}')   (последняя загрузка роутера, uptime $((up_s/3600)) ч)"
    echo "cpu_pct=$cpu"
    echo "mem_pct=$memp   (использовано $((used/1024)) из $((total/1024)) МиБ)"
    echo "conn_active=$conn   (из $ctot максимум)"
    echo "loadavg1=$load1   (в сотых: $load1 = $(awk -v l=$load1 'BEGIN{printf "%.2f",l/100}'))"
    echo "wan_kbps=$kbps"
} > "$DIR/state/metrics.now"

# --- проверка аномалий против базлайна текущего часа ---
BL="$DIR/state/baseline.tsv"
[ -f "$BL" ] || exit 0

AN_TXT=$TMP/anom.txt; AN_KEY=$TMP/anom.key
: > "$AN_TXT"; : > "$AN_KEY"

check() {   # имя значение мин-абс-порог
    m=$1; v=$2; floor=$3
    row=$(awk -F'\t' -v m="$m" -v s="$hour" '$1==m&&$2==s{print $3" "$4" "$5}' "$BL")
    [ -n "$row" ] || return
    set -- $row; n=$1; mean=$2; mad=$3
    [ "$n" -ge 2 ] || return               # базлайн прогрет: слот прошёл ≥2 суток
    # нижняя граница разброса: 10% от нормы — молодой базлайн даёт нереально
    # узкий σ (напр. ±6 при норме 234), из-за чего утренний рост = «аномалия»
    f10=$((mean/10)); [ "$mad" -lt "$f10" ] && mad=$f10
    [ "$mad" -ge 1 ] || mad=1
    dev=$((v-mean)); [ "$dev" -lt 0 ] && dev=$((-dev))
    # аномалия: отклонение больше 4×разброса И больше абсолютного порога
    if [ "$dev" -gt $((4*mad)) ] && [ "$dev" -gt "$floor" ]; then
        if [ "$v" -gt "$mean" ]; then d="выше"; else d="ниже"; fi
        echo "$m: сейчас $v, $d нормы (~$mean ±$mad для этого часа)" >> "$AN_TXT"
        echo "$m:$d" >> "$AN_KEY"          # отпечаток БЕЗ значения: метрика+направление
    fi
}

check cpu  "$cpu"   20
check mem  "$memp"  15
check conn "$conn"  50
check wan  "$kbps"  256

# фильтр стойкости: алертим метрику, только если она аномальна ДВА замера
# подряд (10 минут). Одиночные всплески (короткая закачка, наш же дайджест
# в 08:00 грузит CPU) — не повод будить владельца.
PREV=$TMP/anom.prev
prev_keys=$(cat "$PREV" 2>/dev/null)
cp "$AN_KEY" "$PREV" 2>/dev/null || : > "$PREV"
if [ -s "$AN_TXT" ]; then
    : > "$AN_TXT.f"; : > "$AN_KEY.f"
    n=0
    while IFS= read -r k; do
        n=$((n+1))
        if printf '%s\n' "$prev_keys" | grep -qx "$k"; then
            sed -n "${n}p" "$AN_TXT" >> "$AN_TXT.f"
            echo "$k" >> "$AN_KEY.f"
        fi
    done < "$AN_KEY"
    mv "$AN_TXT.f" "$AN_TXT"; mv "$AN_KEY.f" "$AN_KEY"
fi
[ -s "$AN_TXT" ] || exit 0

# троттлинг: та же аномалия (метрика+направление, БЕЗ часа и БЕЗ значения)
# не чаще cooldown — затяжное отклонение не должно алертить каждый час
HIST=$DIR/state/metrics.alert.hist
touch "$HIST"
cool=${ALERT_COOLDOWN:-10800}
awk -v now="$now" -v cd="$cool" '$2>=now-cd' "$HIST" > "$HIST.new" && mv "$HIST.new" "$HIST"
key=$(md5sum < "$AN_KEY" | cut -c1-12)
grep -q "^$key " "$HIST" && exit 0
echo "$key $now" >> "$HIST"
anom=$(cat "$AN_TXT")

. "$DIR/lib.sh"
tg_send "📈 Отклонение нагрузки роутера от нормы:
$anom"
echo "$(date '+%F %T') metrics-anom: $anom" >> "$DIR/state/observer.log"

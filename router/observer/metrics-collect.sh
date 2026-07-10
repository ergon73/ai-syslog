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
    echo "cpu_pct=$cpu"
    echo "mem_pct=$memp   (использовано $((used/1024)) из $((total/1024)) МиБ)"
    echo "conn_active=$conn   (из $ctot максимум)"
    echo "loadavg1=$load1   (в сотых: $load1 = $(awk -v l=$load1 'BEGIN{printf "%.2f",l/100}'))"
    echo "wan_kbps=$kbps"
} > "$DIR/state/metrics.now"

# --- проверка аномалий против базлайна текущего часа ---
BL="$DIR/state/baseline.tsv"
[ -f "$BL" ] || exit 0

check() {   # имя значение мин-абс-порог
    m=$1; v=$2; floor=$3
    row=$(awk -F'\t' -v m="$m" -v s="$hour" '$1==m&&$2==s{print $3" "$4" "$5}' "$BL")
    [ -n "$row" ] || return
    set -- $row; n=$1; mean=$2; mad=$3
    [ "$n" -ge 5 ] || return               # базлайн ещё не прогрет (нужно ~сутки)
    [ "$mad" -ge 1 ] || mad=1
    dev=$((v-mean)); [ "$dev" -lt 0 ] && dev=$((-dev))
    # аномалия: отклонение больше 4×MAD И больше абсолютного порога метрики
    if [ "$dev" -gt $((4*mad)) ] && [ "$dev" -gt "$floor" ]; then
        if [ "$v" -gt "$mean" ]; then d="выше"; else d="ниже"; fi
        echo "$m: сейчас $v, $d нормы (~$mean ±$mad для этого часа)"
    fi
}

anom=$(
    check cpu  "$cpu"   20
    check mem  "$memp"  15
    check conn "$conn"  50
    check wan  "$kbps"  256
)
[ -n "$anom" ] || exit 0

# троттлинг: одна и та же аномалия не чаще ALERT_COOLDOWN
HIST=$DIR/state/metrics.alert.hist
touch "$HIST"
cool=${ALERT_COOLDOWN:-10800}
awk -v now="$now" -v cd="$cool" '$2>=now-cd' "$HIST" > "$HIST.new" && mv "$HIST.new" "$HIST"
key=$(printf '%s' "$hour:$anom" | md5sum | cut -c1-12)
grep -q "^$key " "$HIST" && exit 0
echo "$key $now" >> "$HIST"

. "$DIR/lib.sh"
tg_send "📈 Отклонение нагрузки роутера от нормы:
$anom"
echo "$(date '+%F %T') metrics-anom: $anom" >> "$DIR/state/observer.log"

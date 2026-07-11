#!/bin/sh
# Бенчмарк DoT/DoH напрямую, без прописывания в конфиг.
# Дополнительно помечает, какие кандидаты СЕЙЧАС настроены на роутере
# (столбец "конф": + = в конфиге, - = резерв), читая RCI dns-proxy.
# Запуск: sh dnsbench.sh [раундов]   (по умолчанию 2)
ROUNDS=${1:-2}; TIMEOUT=2
DOMAINS="google.com wikipedia.org github.com amazon.com microsoft.com apple.com reddit.com bbc.com"
# Кандидаты: Метка|режим(dot/doh)|сервер|маркер-для-поиска-в-конфиге
CANDIDATES="
Cloudflare|dot|1.1.1.1|1.1.1.1
Cloudflare|doh|cloudflare-dns.com|cloudflare-dns.com
Google|dot|8.8.8.8|8.8.8.8
Google|doh|dns.google|dns.google
Quad9|doh|dns.quad9.net|dns.quad9.net
AdGuard|dot|94.140.14.14|94.140.14.14
AdGuard|doh|dns.adguard-dns.com|dns.adguard-dns.com
Mullvad|dot|194.242.2.2|194.242.2.2
Yandex|dot|77.88.8.8|77.88.8.8
"

# --- активная конфигурация DNS роутера (RCI, локально, без авторизации) ---
CFG=$(curl -s --max-time 5 "http://localhost:79/rci/show/dns-proxy" 2>/dev/null)
echo "# Настроены сейчас на роутере (из RCI dns-proxy):"
echo "$CFG" | grep -oE '#[[:space:]]*[^"\\]+@[^"\\]+' | sed 's/^#[[:space:]]*/  - /' \
    | sort -u
echo "# ( + = используется сейчас, - = резерв, только для сравнения )"
echo

printf "%-14s %-4s | %-4s | %4s | %7s\n" "Сервер" "прот" "конф" "усп%" "ср.мс"
echo "-------------------------------------------------"

# Кандидаты меряются ПАРАЛЛЕЛЬНО (свой фоновый процесс на каждого):
# последовательный прогон занимал ~20 с, параллельный — ~4-6 с, что позволяет
# агенту получать результат за один ход (опросом файла), без «спроси ещё раз».
TDIR=$(mktemp -d /tmp/dnsb.XXXXXX)
i=0
# без пайпа: while в пайпе = подоболочка, wait не увидел бы фоновые процессы
for line in $CANDIDATES; do
  IFS="|"; set -- $line; unset IFS
  L=$1; M=$2; S=$3; MARK=$4
  [ -z "$L" ] && continue
  i=$((i+1))
  (
    if echo "$CFG" | grep -q "$MARK"; then inuse="+"; else inuse="-"; fi
    ok=0; tot=0; sm=0; r=0
    while [ $r -lt $ROUNDS ]; do
      for d in $DOMAINS; do
        tot=$((tot+1))
        [ "$M" = dot ] && o=$(dig +tls +timeout=$TIMEOUT +tries=1 @$S $d A 2>/dev/null) || o=$(dig +https +timeout=$TIMEOUT +tries=1 @$S $d A 2>/dev/null)
        echo "$o" | grep -q "status: NOERROR" && { ok=$((ok+1)); q=$(echo "$o"|sed -n "s/.*Query time: \([0-9]*\).*/\1/p"); sm=$((sm+${q:-0})); }
      done
      r=$((r+1))
    done
    pct=$((ok*100/tot)); [ $ok -gt 0 ] && a=$((sm/ok)) || a=0
    printf "%-14s %-4s | %-4s | %3d%% | %6dms\n" "$L" "$M" "$inuse" "$pct" "$a" > "$TDIR/$(printf %02d $i).row"
  ) &
done
wait
cat "$TDIR"/*.row 2>/dev/null
rm -rf "$TDIR"

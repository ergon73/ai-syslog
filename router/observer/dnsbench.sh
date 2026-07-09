#!/bin/sh
# Бенчмарк DoT/DoH напрямую, без прописывания в конфиг.
# Запуск: sh dnsbench.sh [раундов]   (по умолчанию 2)
ROUNDS=${1:-2}; TIMEOUT=2
DOMAINS="google.com wikipedia.org github.com amazon.com microsoft.com apple.com reddit.com bbc.com"
# Кандидаты: Метка|режим(dot/doh)|сервер  — редактируйте список под себя
CANDIDATES="
Cloudflare|dot|1.1.1.1
Cloudflare|doh|cloudflare-dns.com
Google|dot|8.8.8.8
Google|doh|dns.google
Quad9|doh|dns.quad9.net
AdGuard|dot|94.140.14.14
AdGuard|doh|dns.adguard-dns.com
Mullvad|dot|194.242.2.2
Yandex|dot|77.88.8.8
"
printf "%-14s %-4s | %4s | %7s\n" "Сервер" "прот" "усп%" "ср.мс"
echo "----------------------------------------"
echo "$CANDIDATES" | while IFS="|" read L M S; do
  [ -z "$L" ] && continue
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
  printf "%-14s %-4s | %3d%% | %6dms\n" "$L" "$M" "$pct" "$a"
done

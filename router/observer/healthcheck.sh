#!/bin/sh
# Проверка целостности наблюдателя и агента (после ребута/обновления прошивки).
# Запуск на роутере: sh /opt/etc/observer/healthcheck.sh
# Печатает OK/FAIL по каждому пункту.

ok()   { echo "OK    $*"; }
fail() { echo "FAIL  $*"; RC=1; }
RC=0

# --- демоны ---
for p in "picoclaw gateway" "richsend.sh" "actiond.sh" "syslog-ng" "crond|cron -s"; do
    if ps w | grep -vE "grep" | grep -qE "$p"; then ok "процесс: $p"; else fail "процесс НЕ найден: $p"; fi
done

# --- cron-задания наблюдателя ---
grep -q "observer/batch.sh" /opt/etc/crontab && ok "cron: batch.sh" || fail "cron: batch.sh отсутствует"

# --- RCI-форматы, на которые мы завязаны ---
sys=$(curl -s --max-time 5 http://localhost:79/rci/show/system)
for f in cpuload memory conntotal connfree; do
    echo "$sys" | grep -q "\"$f\"" && ok "RCI show/system: поле $f" || fail "RCI show/system: НЕТ поля $f"
done
curl -s --max-time 5 http://localhost:79/rci/show/dns-proxy | grep -q "dns_server" \
    && ok "RCI show/dns-proxy: dns_server" || fail "RCI show/dns-proxy: формат изменился"

# --- формат syslog (5 полей через таб) ---
last=$(tail -1 /opt/var/log/router.log)
nf=$(echo "$last" | awk -F'\t' '{print NF}')
[ "$nf" = 5 ] && ok "формат router.log: 5 полей" || fail "формат router.log изменился (полей: $nf)"

# --- наблюдатель дочитывает лог ---
off=$(cat /opt/etc/observer/state/offset 2>/dev/null); sz=$(wc -c < /opt/var/log/router.log)
[ -n "$off" ] && ok "offset наблюдателя: $off (size $sz)" || fail "offset наблюдателя потерян"

echo "---"
[ $RC = 0 ] && echo "ИТОГ: всё в порядке" || echo "ИТОГ: есть проблемы (см. FAIL выше)"
exit $RC

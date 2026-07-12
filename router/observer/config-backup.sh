#!/bin/sh
# Ежедневный бэкап конфигурации роутера на флешку (cron 03:40).
# Источник: RCI show running-config (полный текстовый конфиг, пароли в нём
# хранятся в зашифрованном виде самим NDM).
# Логика истории: новый датированный файл создаётся ТОЛЬКО при изменении
# конфига (сравнение по телу без волатильной шапки "! $$$ ..."), при
# изменении — уведомление в Telegram со сводкой диффа. latest.cfg — всегда
# актуальная копия. Хранение: 365 дней.

DIR=/opt/etc/observer
BK=/opt/backups/config
. "$DIR/observer.conf" 2>/dev/null || exit 1
. "$DIR/lib.sh"

mkdir -p "$BK" && chmod 700 "$BK"

new="$BK/.new.$$"
curl -s --max-time 30 -X POST -H "Content-Type: application/json" \
    -d '{"show":{"running-config":{}}}' http://localhost:79/rci/ \
    | jq -r '.show."running-config".message[]?' > "$new" 2>/dev/null

if [ ! -s "$new" ] || ! grep -q "^! \$\$\$ Model" "$new"; then
    rm -f "$new"
    echo "$(date '+%F %T') config-backup: RCI не отдал конфиг" >> "$DIR/state/observer.log"
    exit 1
fi
chmod 600 "$new"

# тело без волатильной шапки (Last change / Md5 / Agent меняются сами)
body_hash() { grep -v '^! \$\$\$' "$1" | md5sum | cut -d' ' -f1; }

latest="$BK/latest.cfg"
if [ -f "$latest" ] && [ "$(body_hash "$new")" = "$(body_hash "$latest")" ]; then
    rm -f "$new"                                   # изменений нет — историю не плодим
    echo "$(date '+%F %T') config-backup: без изменений" >> "$DIR/state/observer.log"
    exit 0
fi

stamp=$(date '+%Y-%m-%d_%H%M')
dated="$BK/config-$stamp.cfg"
if [ -f "$latest" ]; then
    # busybox diff = unified-формат (+/-), не классический (</>)
    add=$(diff "$latest" "$new" 2>/dev/null | grep -Ec '^\+[^+]|^\+$')
    del=$(diff "$latest" "$new" 2>/dev/null | grep -Ec '^-[^-]|^-$')
    note="Конфигурация роутера изменилась (+$add/−$del строк относительно прошлой копии)."
else
    note="Первый бэкап конфигурации роутера сохранён."
fi
mv "$new" "$dated" && cp "$dated" "$latest" && chmod 600 "$dated" "$latest"

tg_send "💾 $note
Файл: $dated ($(wc -c < "$dated") байт). История: $(ls "$BK"/config-*.cfg 2>/dev/null | wc -l) копий."
echo "$(date '+%F %T') config-backup: сохранён $dated" >> "$DIR/state/observer.log"

# ротация истории: старше 365 дней — удалить
find "$BK" -name 'config-*.cfg' -mtime +365 -exec rm -f {} \; 2>/dev/null

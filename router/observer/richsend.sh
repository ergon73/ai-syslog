#!/bin/sh
# Демон отправки rich-сообщений (Bot API 10.1 sendRichMessage) из outbox агента.
# Агент picoclaw пишет markdown-файл в workspace/outbox/ (у него нет прав
# на отправку и shell) — демон отправляет владельцу и удаляет файл.
# Telegram сам конвертирует markdown в rich-блоки, включая таблицы.

DIR=/opt/etc/observer
OUTBOX=/opt/root/.picoclaw/workspace/outbox

. "$DIR/observer.conf" || exit 1
. "$DIR/lib.sh"
mkdir -p "$OUTBOX"
ensure_tg_route

send_rich() {
    jq -n --arg cid "$TG_CHAT_ID" --rawfile md "$1" \
        '{chat_id: ($cid|tonumber), rich_message: {markdown: $md}}' \
        > "$STATE_DIR/rich.json" 2>/dev/null || return 1
    for _if in "" $TG_IFACES; do
        [ -n "$_if" ] && _io="--interface $_if" || _io=""
        _resp=$(curl -sS --max-time 20 $_io -H "Content-Type: application/json" \
            -d @"$STATE_DIR/rich.json" \
            "https://api.telegram.org/bot$TG_TOKEN/sendRichMessage" 2>/dev/null)
        printf '%s' "$_resp" | grep -q '"ok":true' && return 0
    done
    echo "$(date '+%F %T') rich send failed: $(printf '%s' "$_resp" | head -c 200)" \
        >> "$STATE_DIR/observer.log"
    return 1
}

while :; do
    for f in "$OUTBOX"/*.md; do
        [ -f "$f" ] || continue
        # ждём, пока агент допишет файл (размер стабилен 1 сек)
        s1=$(wc -c < "$f"); sleep 1; s2=$(wc -c < "$f")
        [ "$s1" = "$s2" ] || continue
        if send_rich "$f"; then rm -f "$f"; else mv "$f" "$f.failed"; fi
    done
    sleep 2
done

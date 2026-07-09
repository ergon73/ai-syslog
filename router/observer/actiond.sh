#!/bin/sh
# Демон доверенных действий (прототип механики Фазы 2).
# Исполняет ТОЛЬКО действия из фиксированного allowlist, ВЫБИРАЯ их
# по ИМЕНИ файла-запроса. Содержимое файла-запроса НИКОГДА не читается
# и не исполняется — это ключевая защита: даже если агента обманут
# prompt-инъекцией и он создаст запрос, максимум произойдёт запуск
# безобидного read-only действия из списка ниже.
#
# Контракт с агентом (через workspace, где у него есть доступ):
#   агент пишет  workspace/requests/<action>.req   (write_file, содержимое любое)
#   демон кладёт workspace/results/<action>.txt     (агент читает)

DIR=/opt/etc/observer
WS=/opt/root/.picoclaw/workspace
REQ=$WS/requests
RES=$WS/results
mkdir -p "$REQ" "$RES"

run_action() {
    case "$1" in
        dnsbench)
            # сразу пометить «выполняется», чтобы агент не прочитал
            # устаревший результат (устраняет гонку read-до-завершения)
            echo "# RUNNING — бенчмарк DNS запущен $(date '+%F %T %Z'), готово через ~20 сек" \
                > "$RES/dnsbench.txt"
            {
                echo "# Бенчмарк DNS — $(date '+%F %T %Z')"
                sh "$DIR/dnsbench.sh" 2
            } > "$RES/dnsbench.txt.tmp" 2>&1
            mv "$RES/dnsbench.txt.tmp" "$RES/dnsbench.txt"
            ;;
        *)
            # неизвестное действие — не исполняем, фиксируем факт
            echo "# Действие '$1' не в allowlist ($(date '+%F %T'))" \
                > "$RES/rejected.txt"
            echo "$(date '+%F %T') actiond: отклонено действие '$1'" \
                >> "$DIR/state/observer.log"
            ;;
    esac
}

while :; do
    for f in "$REQ"/*.req; do
        [ -f "$f" ] || continue
        action=$(basename "$f" .req)
        rm -f "$f"                 # снять запрос ДО выполнения — не зациклиться
        run_action "$action"
    done
    sleep 2
done

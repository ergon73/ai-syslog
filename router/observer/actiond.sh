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
    # $1 = имя действия, $2 = файл с содержимым заявки (для параметризованных)
    case "$1" in
        loggrep)
            # Поиск по router.log. Параметры из заявки, СТРОГО валидируются:
            #   строка 1 — искомая ПОДСТРОКА (не regex): белый список символов,
            #              максимум 64; поиск через awk index() — инъекция
            #              синтаксисом невозможна;
            #   строка 2 — необязательно "hours=N" (1..168), по умолчанию 24.
            pat=$(head -1 "$2" 2>/dev/null | tr -cd 'A-Za-z0-9 .:_()"/@-' | cut -c1-64)
            hrs=$(sed -n 2p "$2" 2>/dev/null | grep -oE '^hours=[0-9]{1,3}' | cut -d= -f2)
            [ -n "$hrs" ] && [ "$hrs" -ge 1 ] && [ "$hrs" -le 168 ] || hrs=24
            since=$(( $(date +%s) - hrs*3600 ))
            if [ -z "$pat" ]; then
                echo "# loggrep: пустой или невалидный запрос" > "$RES/loggrep.txt"
            else
                tmpm="$RES/.lg.$$"
                awk -F'\t' -v s="$since" -v p="$pat" \
                    '$1 >= s && index($0, p) {
                        print strftime("%Y-%m-%d %H:%M", $1) " | " $0 }' \
                    /opt/var/log/router.log > "$tmpm" 2>/dev/null
                nm=$(wc -l < "$tmpm")
                {
                    echo "# Поиск: \"$pat\" за последние ${hrs}ч — $(date '+%F %T %Z')"
                    echo "# ВСЕГО СОВПАДЕНИЙ: $nm (показаны последние 200; для счёта бери ЭТО число)"
                    echo "# Каждая строка начинается с ГОТОВОГО местного времени (MSK)."
                    # strftime здесь, а не в LLM: модель ошибается в конвертации epoch
                    tail -200 "$tmpm"
                } > "$RES/loggrep.txt.tmp" 2>&1
                rm -f "$tmpm"
                mv "$RES/loggrep.txt.tmp" "$RES/loggrep.txt"
            fi
            ;;
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
        body="$RES/.req.$$"
        cp "$f" "$body" 2>/dev/null
        rm -f "$f"                 # снять запрос ДО выполнения — не зациклиться
        run_action "$action" "$body"
        rm -f "$body"
    done
    sleep 1
done

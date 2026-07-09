# Общие функции наблюдателя. Подключается: . /opt/etc/observer/lib.sh
# (после observer.conf — использует ключи, модели, TG_*).

# Сетевые обходы (выяснено при развёртывании):
#  - api.telegram.org и openrouter.ai блокируются/режутся для трафика
#    самого роутера, но доступны через WG-интерфейсы (LAN-клиенты ходят
#    через VPN-политику Keenetic);
#  - на случай мёртвого DNS каждый успешно разрезолвленный IP кэшируется
#    (state/ip.<host>) и при неудаче пробуется через curl --resolve.
#    Именно кэш, а не /etc/hosts: протухший IP не окривляет систему навсегда.

STATE_DIR=/opt/etc/observer/state
TG_NETS="149.154.160.0/20 91.108.4.0/22"
TG_IFACES="${TG_IFACES:-nwg2 nwg0 nwg1}"

ensure_tg_route() {
    main_if=$(echo $TG_IFACES | cut -d' ' -f1)
    ip link show "$main_if" >/dev/null 2>&1 || return 0
    for net in $TG_NETS; do
        ip route | grep -q "^$net " || ip route add "$net" dev "$main_if" 2>/dev/null
    done
}

_cache_ip() { [ -n "$2" ] && echo "$2" > "$STATE_DIR/ip.$1"; }
_res_opt()  { [ -s "$STATE_DIR/ip.$1" ] && echo "--resolve $1:443:$(cat "$STATE_DIR/ip.$1")"; }

# HTTPS POST с обходами: прямо -> WG-интерфейсы, второй круг с кэшем IP.
# Успех = только HTTP 2xx: блокировки провайдера/Cloudflare возвращают
# тело с ошибкой, его нельзя принимать за ответ — перебор продолжается.
# $1 url, $2 bearer-ключ, $3 файл payload; тело ответа в stdout.
http_post() {
    _host=${1#https://}; _host=${_host%%/*}
    for _res in "" "$(_res_opt "$_host")"; do
        for _if in "" $TG_IFACES; do
            [ -n "$_if" ] && _io="--interface $_if" || _io=""
            _out=$(curl -sS --max-time 90 $_io $_res -w "\n%{http_code} %{remote_ip}" \
                -H "Authorization: Bearer $2" -H "Content-Type: application/json" \
                -d @"$3" "$1" 2>/dev/null) || continue
            _meta=$(printf '%s' "$_out" | tail -n1)
            _code=${_meta%% *}
            _ip=${_meta#* }
            _body=$(printf '%s' "$_out" | sed '$d')
            case "$_code" in 2*) ;; *) continue ;; esac
            [ -n "$_body" ] || continue
            _cache_ip "$_host" "$_ip"
            printf '%s' "$_body"
            return 0
        done
        # второй круг имеет смысл только при наличии кэша
        [ -n "$(_res_opt "$_host")" ] || break
    done
    return 1
}

# Запрос к LLM с цепочкой fallback-провайдеров (пустой ключ = ступень выключена):
#   1) Ollama Cloud (модель передаётся аргументом),
#   2) FALLBACK1 (CloseRouter — доступен с роутера напрямую),
#   3) FALLBACK2 (OpenRouter — только через WG-интерфейсы).
# $1 модель primary, $2 файл system-промпта, $3 файл запроса, $4 temperature.
# Content в stdout; rc=1 если не ответил никто.
llm_ask() {
    _pl=$STATE_DIR/payload.json
    for _try in 1 2 3; do
        case "$_try" in
            1) _mm=$1; _base=$OLLAMA_API_BASE; _key=$OLLAMA_API_KEY ;;
            2) _mm=$FALLBACK1_MODEL; _base=$FALLBACK1_API_BASE; _key=$FALLBACK1_API_KEY ;;
            3) _mm=$FALLBACK2_MODEL; _base=$FALLBACK2_API_BASE; _key=$FALLBACK2_API_KEY ;;
        esac
        [ -n "$_key" ] || continue
        jq -n --arg m "$_mm" --rawfile s "$2" --rawfile b "$3" \
            --argjson t "${4:-0.1}" \
            '{model:$m, stream:false, temperature:$t,
              messages:[{role:"system",content:$s},{role:"user",content:$b}]}' \
            > "$_pl" 2>/dev/null || continue
        _resp=$(http_post "$_base/chat/completions" "$_key" "$_pl") || continue
        _c=$(printf '%s' "$_resp" | jq -r '.choices[0].message.content // empty' 2>/dev/null)
        [ -n "$_c" ] && { printf '%s' "$_c"; return 0; }
    done
    return 1
}

# Отправка в Telegram: прямо -> WG-интерфейсы, второй круг с кэшем IP.
tg_send() {
    _text=$1
    for _res in "" "$(_res_opt api.telegram.org)"; do
        for _if in "" $TG_IFACES; do
            [ -n "$_if" ] && _io="--interface $_if" || _io=""
            _out=$(curl -sS --max-time 20 $_io $_res -w "\n%{remote_ip}" \
                --data-urlencode "text=$_text" \
                "https://api.telegram.org/bot$TG_TOKEN/sendMessage?chat_id=$TG_CHAT_ID" \
                2>/dev/null) || continue
            if printf '%s' "$_out" | grep -q '"ok":true'; then
                _cache_ip api.telegram.org "$(printf '%s' "$_out" | tail -n1)"
                return 0
            fi
        done
        [ -n "$(_res_opt api.telegram.org)" ] || break
    done
    return 1
}

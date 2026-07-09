#!/bin/sh
# Одноразовое применение секретов наблюдателя и picoclaw.
# Использование: apply-keys.sh <OLLAMA_API_KEY> <TG_BOT_TOKEN> <TG_USER_ID>
# 1) заполняет /opt/etc/observer/observer.conf
# 2) включает Telegram-канал и облачные модели Ollama в конфиге picoclaw
# 3) включает и запускает picoclaw gateway
# 4) шлёт тестовое сообщение в Telegram

set -e
[ $# -eq 3 ] || { echo "usage: $0 OLLAMA_KEY TG_TOKEN TG_USER_ID"; exit 1; }
KEY=$1; TOK=$2; TGUID=$3

CONF=/opt/etc/observer/observer.conf
PC=/opt/root/.picoclaw/config.json

# --- observer.conf -----------------------------------------------------------
sed -i \
    -e "s|^OLLAMA_API_KEY=.*|OLLAMA_API_KEY=\"$KEY\"|" \
    -e "s|^TG_TOKEN=.*|TG_TOKEN=\"$TOK\"|" \
    -e "s|^TG_CHAT_ID=.*|TG_CHAT_ID=\"$TGUID\"|" \
    "$CONF"
chmod 600 "$CONF"

# --- picoclaw: telegram + модели Ollama Cloud --------------------------------
# ВАЖНО (v0.3.1): секреты в config.json запрещены — токен и api_key
# живут в .security.yml, config.json хранит только несекретные поля.
SEC=/opt/root/.picoclaw/.security.yml
cp "$PC" "$PC.bak"
jq --arg uid "$TGUID" '
  .channel_list.telegram.enabled = true
  | .channel_list.telegram.allow_from = [$uid]
  | .model_list = ([.model_list[] | select(.model_name != "qwen-cloud" and .model_name != "digest-cloud")]
      + [{model_name:"qwen-cloud",   provider:"ollama", model:"qwen3.5:397b",
          api_base:"https://ollama.com/v1"},
         {model_name:"digest-cloud", provider:"ollama", model:"deepseek-v4-flash",
          api_base:"https://ollama.com/v1"}])
  | .agents.defaults.model_name = "qwen-cloud"
' "$PC.bak" > "$PC"
chmod 600 "$PC"

# ВАЖНО: поле называется api_keys (список!) — единственное api_key
# молча игнорируется, а существующая запись модели в .security.yml
# перезаписывает пустотой ключи из config.json (см. SecureModelList).
cp "$SEC" "$SEC.bak"
awk -v tok="$TOK" -v key="$KEY" '
  /^  telegram:/ {print; getline; print "    settings:"; print "      token: " tok; next}
  /^model_list:/ {print;
                  print "  qwen-cloud:0:";   print "    api_keys:"; print "      - " key;
                  print "  digest-cloud:0:"; print "    api_keys:"; print "      - " key; next}
  {print}' "$SEC.bak" > "$SEC"
chmod 600 "$SEC"

# --- запуск gateway ----------------------------------------------------------
sed -i 's/^ENABLED=no/ENABLED=yes/' /opt/etc/init.d/S99picoclaw
/opt/etc/init.d/S99picoclaw restart

# --- тест --------------------------------------------------------------------
sleep 2
curl -sS --data-urlencode "text=✅ Наблюдатель настроен: батчер и дайджест активны, picoclaw gateway запущен." \
    "https://api.telegram.org/bot$TOK/sendMessage?chat_id=$TGUID" >/dev/null \
    && echo "TG OK" || echo "TG FAIL"
echo "Готово. Проверка моделей:"
curl -sS -H "Authorization: Bearer $KEY" https://ollama.com/v1/models 2>/dev/null \
    | jq -r '.data[].id' 2>/dev/null | head -30

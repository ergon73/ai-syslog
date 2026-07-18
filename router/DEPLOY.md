# Runbook: разворачивание наблюдателя на новом роутере Keenetic (Фаза 5)

Первое тиражирование схемы Peak (KN-2710) на запасной домашний роутер.
Порядок проверен на Peak; здесь обобщён и адаптирован под второй роутер.

## Целевой роутер: Keenetic Ultra/Titan KN-1811

- CPU: **MediaTek MT7622BV, ARM Cortex-A53** → архитектура **aarch64**
  (та же, что у Peak KN-2710) — с высокой вероятностью тот же бинарник
  picoclaw `arm64`. НО: userland на MT7622 у Keenetic бывает 32-битным —
  ПРОВЕРИТЬ на месте (см. шаг B1); если armv7 — взять `armv7`-бинарник.
- RAM: **512 МБ** (как у Peak) → полный стек, включая gateway, помещается.
- Flash: 256 МБ, dual-image (безопасный откат прошивки).
- Флешка USB пустая → **Entware ставим с нуля** (шаг A).

## Что переносится КАК ЕСТЬ (из репо router/)

- observer/*.sh (batch, digest, metrics-collect, metrics-baseline, actiond,
  richsend, dnsbench, config-backup, update-check, lib, healthcheck),
  init-скрипты S96/S97/S99, prompt_*.txt, *_patterns.txt.
- picoclaw-workspace/ целиком (AGENT.md, SOUL.md — правится, USER.md, skills/).

## Что per-router (customize)

| Параметр | Где | Значение для KN-1811 |
|---|---|---|
| API-ключи Ollama/CloseRouter/OpenRouter | observer.conf | ТЕ ЖЕ (account-level) |
| Telegram bot token | observer.conf + .security.yml | **НОВЫЙ бот** (@keenetic_home_…) |
| TG user id (allow_from) | observer.conf + config.json | ТОТ ЖЕ (1892810553) |
| WAN_IF (метрика скорости) | observer.conf | определить (шаг B3), НЕ apclii0 |
| TG_IFACES (доставка в TG) | observer.conf | скорее пусто (шаг B4) |
| Факты устройства/сети/устройств | SOUL.md | переписать под дом |
| SSH-алиас | ~/.ssh/config | добавить `keenetic-home` |

---

## Шаг A. Prerequisites (веб-интерфейс Keenetic + SSH)

A1. Веб-интерфейс → Общие настройки → **Изменить набор компонентов** →
    включить **OPKG** (менеджер пакетов) и **SSH-сервер** (если нет).
A2. Вставить пустую USB-флешку, отформатировать через веб-интерфейс (ext4).
A3. Установить Entware: веб-интерфейс → Приложения → OPKG → выбрать флешку →
    установить. (Либо стандартная процедура Keenetic для OPKG.)
A4. Настроить доступ по SSH-ключу: добавить `entware_rsa.pub` в авторизацию,
    прописать алиас `keenetic-home` в ~/.ssh/config (Port обычно 22, у Peak был 222).
A5. syslog-ng: поставить и настроить приём локального syslog в файл —
    за основу docs/syslog-ng.conf (тот же template из 5 полей — КОНТРАКТ,
    его менять нельзя, на нём завязаны все скрипты).
    Проверить: `head -1 /opt/var/log/router.log` → 5 полей через таб.

## Шаг B. Разведка на месте (SSH)

B1. Архитектура: `uname -m` и `opkg print-architecture`
    → aarch64 → бинарник picoclaw `arm64`; armv7l → `armv7`.
B2. RAM/место: `free` (ждём ~512 МБ), `df -h /opt`.
B3. WAN-интерфейс: `ip route get 8.8.8.8` → `dev XXX` (домашний проводной WAN,
    напр. eth3). Это значение → WAN_IF в observer.conf.
B4. Доступность Telegram НАПРЯМУЮ (дома провайдер обычно НЕ блокирует):
    `curl -s -o /dev/null -w '%{http_code}\n' https://api.telegram.org`
    → 302/200 = прямой доступ есть → **TG_IFACES=""** (упрощение, без WG).
    Если таймаут — как на Peak, через WG (перечислить `ip -o addr | grep nwg`).
B5. Есть ли WireGuard/VPN-политики (`ip -o addr | grep -E 'nwg|wg'`) — для SOUL.md.
B6. RCI работает так же: `curl -s http://localhost:79/rci/show/version`.

## Шаг C. Секреты

C1. Новый бот: @BotFather → /newbot → имя (напр. KeeneticHomeObserver) → токен.
C2. LLM-ключи — те же, что на Peak (лежат в observer.conf Peak, можно скопировать).
C3. TG user id — тот же (1892810553).

## Шаг D. Установка picoclaw

D1. Скачать НА ПК нужный бинарник (arm64 или armv7) с релиза v0.3.1, сверить
    sha256 по checksums.txt, залить `scp -O` на роутер в /opt/usr/bin/picoclaw,
    `chmod +x`. (Прямая загрузка с GitHub на роутер медленная — качать на ПК.)
D2. `HOME=/opt/root /opt/usr/bin/picoclaw onboard` → создаст ~/.picoclaw/.
    HOME=/opt/root — на флешке (внутренняя память мала).
D3. Поставить зависимости: `opkg update && opkg install jq cron` (bind-dig,
    curl, ca-bundle обычно тянутся; проверить `which jq dig curl crond`).

## Шаг E. Деплой наших файлов

E1. Портируемое (scp -O из router/):
    - observer/* → /opt/etc/observer/ (chmod 700 на *.sh, 600 на lib.sh)
    - S96/S97/S99 → /opt/etc/init.d/ (chmod 755)
    - picoclaw-workspace/* → /opt/root/.picoclaw/workspace/ (SOUL/USER/AGENT + skills/)
    - ВСЕ файлы после заливки: `sed -i 's/\r$//'` (CRLF→LF).
E2. observer.conf: скопировать observer.conf.example → observer.conf, вписать
    WAN_IF (B3), TG_IFACES (B4). Ключи применит apply-keys.sh.
E3. SOUL.md: переписать раздел «Моё устройство» и «Сеть» под KN-1811
    (модель, прошивка, домашняя подсеть, WAN-интерфейс, WG если есть),
    «Заметки об устройствах» — под домашнюю технику (заполнится и сама по DHCP).
E4. Cron: добавить в /opt/etc/crontab (как на Peak):
    ```
    */3 * * * * root /opt/etc/observer/batch.sh
    0 8 * * * root /opt/etc/observer/digest.sh
    */5 * * * * root /opt/etc/observer/metrics-collect.sh
    9 * * * * root /opt/etc/observer/metrics-baseline.sh
    30 8 * * * root /opt/etc/observer/update-check.sh
    40 3 * * * root /opt/etc/observer/config-backup.sh
    ```
    `/opt/etc/init.d/S10cron restart`

## Шаг F. Применить ключи и запустить

F1. `apply-keys.sh <OLLAMA_KEY> <TG_TOKEN> <TG_USER_ID>` — заполнит observer.conf,
    .security.yml (api_keys — СПИСОК!), config.json (allow_from, модели kimi/deepseek),
    включит telegram-канал, поднимет gateway, пришлёт тест в бот.
    ВНИМАНИЕ по факту Peak: модель по умолчанию — kimi-k2.7-code; провайдер
    облачных моделей — тип "openai" (не "ollama"); heartbeat отключить;
    exec/spawn/subagent = false; max_tool_iterations = 80; tools.allow_read_paths
    = router.log + /opt/etc/observer/state + /opt/backups/config + шаблоны;
    TZ=Europe/Moscow + ZONEINFO=/opt/share/zoneinfo в S99picoclaw
    (пакет zoneinfo-europe: `opkg install zoneinfo-europe`).
F2. Fallback-ключи CloseRouter/OpenRouter в observer.conf (FALLBACK1/2_*).
F3. Демоны: `S96actiond start`, `S97tgrich start` (S99 поднял apply-keys).

## Шаг G. Верификация (ОБЯЗАТЕЛЬНО)

G1. `sh /opt/etc/observer/healthcheck.sh` → все OK (демоны, cron, RCI-поля,
    формат лога 5 полей, offset движется).
G2. Синтетика: `printf ...авторизация admin...` в router.log → через ≤3 мин
    алерт в бот. DNS: `проверь скорость DNS` → таблица + конфиг.
G3. Прогнать eval-подсет (router/agent-eval.md) через `picoclaw agent -m`:
    время, «когда перезагружался», MIC-differs счёт, «нагрузка в норме»,
    отказ на «перезагрузи wifi», отказ на инъекцию из hostname.
G4. Отметить: базлайн начнёт с нуля — первые сутки копит, автодетект
    аномалий через ~2 суток (как было на Peak).

## Отличия от Peak — на что смотреть особо

1. **WAN проводной** → WAN_IF ≠ apclii0 (шаг B3). Без этого метрика wan = 0.
2. **Telegram скорее напрямую** → TG_IFACES="" (шаг B4). Проще, чем WG на Peak.
3. **Отдельный бот** → в чате будет ясно, какой это роутер (домашний vs Peak).
   (Позже, при желании — оба бота в один групповой чат: адресный + общая лента.)
4. **Свои устройства/подсеть** в SOUL.md — не копировать факты Peak вслепую.
5. Если userland 32-бит (B1) → armv7-бинарник, всё остальное идентично.

## После деплоя — обновить в репо

- Отразить второй роутер в docs/picoclaw-plan.md (Фаза 5 — начата).
- Если нашлись новые per-router параметры — вынести в observer.conf.example.
- Обновить память проекта (keenetic-observer-setup) про второй роутер.

#!/bin/bash

# Скрипт установки MTProxy (Docker-версия)
# Использует alexbers/mtprotoproxy в Docker-контейнере
# Поддерживает Fake TLS, рекламные каналы (AD_TAG), красивый UI
#
# Использование:
#   curl -sL <URL> | bash      - Установить MTProxy
#   ./mtproxy.sh                - Установить MTProxy
#   ./mtproxy.sh uninstall      - Полностью удалить MTProxy

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

CONTAINER_NAME="mtproto-proxy"
IMAGE_NAME="mtproxy-image"
INSTALL_DIR="/opt/MTProxy"
DEFAULT_PORT=443
DEFAULT_CHANNEL="prsta_live"

# ─── Функции UI ──────────────────────────────────────────────────────────────

print_header() {
    local title="$1"
    local color="${2:-$BLUE}"
    echo -e "${color}╔════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${color}║$(printf '%*s' $(( (60 - ${#title}) / 2 )) '')${BOLD}${title}${NC}${color}$(printf '%*s' $(( (60 - ${#title} + 1) / 2 )) '')║${NC}"
    echo -e "${color}╚════════════════════════════════════════════════════════════╝${NC}"
}

print_step() {
    local number="$1"
    local title="$2"
    echo -e "\n${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}${BOLD}ЭТАП ${number}.${NC} ${BOLD}${title}${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

ask_with_default() {
    local prompt="$1"
    local default_value="$2"
    local result
    read -p "${prompt} [Enter = ${default_value}]: " result </dev/tty
    echo "${result:-$default_value}"
}

# ─── Проверка доступности сети ───────────────────────────────────────────────

check_connectivity() {
    print_header "ПРОВЕРКА ДОСТУПНОСТИ СЕТИ" "$CYAN"
    
    local telegram_status=0
    local ru_success_count=0
    local total_ru_services=5
    
    echo -e "${YELLOW}Проверка доступности серверов Telegram...${NC}"
    if curl -s -I --connect-timeout 5 "https://api.telegram.org" >/dev/null 2>&1; then
        echo -e "${GREEN}✅ Telegram (api.telegram.org) доступен${NC}"
        telegram_status=1
    else
        echo -e "${RED}❌ Telegram (api.telegram.org) недоступен${NC}"
    fi

    echo ""

    echo -e "${YELLOW}Проверка доступности сервисов РФ ($total_ru_services шт.)...${NC}"
    
    local services=("https://ya.ru" "https://mail.ru" "https://vk.com" "https://ok.ru" "https://www.rambler.ru")
    
    for service in "${services[@]}"; do
        local domain=$(echo "$service" | awk -F/ '{print $3}')
        echo -ne "Проверка $domain ... "
        
        if curl -s --connect-timeout 5 "$service" >/dev/null 2>&1; then
            echo -e "${GREEN}OK${NC}"
            ((ru_success_count++))
        else
            echo -e "${RED}FAIL${NC}"
        fi
    done

    echo ""
    echo -e "${CYAN}Итог по РФ: $ru_success_count из $total_ru_services доступны${NC}"

    if [[ $telegram_status -eq 0 ]] || [[ $ru_success_count -lt 3 ]]; then
        echo -e "\n${RED}⚠️  ВНИМАНИЕ: Обнаружены проблемы с сетью!${NC}"
        
        if [[ $telegram_status -eq 0 ]]; then
            echo -e "${RED}- Серверы Telegram недоступны. Прокси может не работать корректно.${NC}"
        fi
        
        if [[ $ru_success_count -lt 3 ]]; then
             echo -e "${RED}- Большинство сервисов РФ недоступно (вероятно, IP заблокирован РКН).${NC}"
             echo -e "${RED}- Это критично для MTProxy, который должен быть доступен из РФ.${NC}"
        fi
        
        echo ""
        echo -e "${YELLOW}Вы можете остановить скрипт или продолжить принудительно.${NC}"
        read -p "Продолжить установку? (yes/no) [no]: " CONFIRM </dev/tty
        CONFIRM=${CONFIRM:-no}
        
        if [[ "$CONFIRM" != "yes" ]]; then
            echo -e "${RED}Установка отменена пользователем.${NC}"
            exit 1
        fi
        echo -e "${YELLOW}Принудительное продолжение...${NC}"
    else
        echo -e "${GREEN}✅ Все проверки пройдены успешно (Telegram + РФ доступ).${NC}"
    fi
    echo ""
}

# ─── Динамический лог ────────────────────────────────────────────────────────

run_live_log() {
    local cmd="$1"
    local log_file=$(mktemp)
    local cols=$(tput cols 2>/dev/null || echo 80)
    
    eval "export DEBIAN_FRONTEND=noninteractive; $cmd" > "$log_file" 2>&1 &
    local pid=$!
    
    for i in {1..10}; do echo; done
    
    while kill -0 "$pid" 2>/dev/null; do
        echo -ne "\033[10A"
        
        local lines_content=$(tail -n 10 "$log_file")
        
        local i=0
        while IFS= read -r line; do
            ((i++))
            printf "\033[K%s\n" "${line:0:$cols}"
        done <<< "$lines_content"
        
        for ((j=i; j<10; j++)); do
            echo -e "\033[K"
        done
        
        sleep 0.1
    done
    
    wait "$pid"
    local ret=$?
    
    echo -ne "\033[10A"
    tail -n 10 "$log_file" | while IFS= read -r line; do
        printf "\033[K%s\n" "${line:0:$cols}"
    done
    local lines_count=$(tail -n 10 "$log_file" | wc -l)
    for ((j=lines_count; j<10; j++)); do
        echo -e "\033[K"
    done
    
    rm -f "$log_file"
    return $ret
}

# ─── Проверка занятости порта ─────────────────────────────────────────────────

check_port_available() {
    local port="$1"
    if ss -tulpn 2>/dev/null | grep -q ":${port} "; then
        local process=$(ss -tulpn 2>/dev/null | grep ":${port} " | head -1 | sed 's/.*users:(("\([^"]*\)".*/\1/')
        echo -e "${RED}⚠️  Порт $port уже занят процессом: $process${NC}"
        echo -e "${YELLOW}Для работы Fake TLS рекомендуется порт 443.${NC}"
        echo -e "${YELLOW}Можно остановить процесс: ${BOLD}systemctl stop $process${NC}"
        echo ""
        read -p "Продолжить с портом $port? (yes/no) [no]: " CONFIRM </dev/tty
        CONFIRM=${CONFIRM:-no}
        if [[ "$CONFIRM" != "yes" ]]; then
            echo -e "${RED}Установка остановлена. Освободите порт $port и запустите снова.${NC}"
            exit 1
        fi
    else
        echo -e "${GREEN}✅ Порт $port свободен${NC}"
    fi
}

# ══════════════════════════════════════════════════════════════════════════════
# НАЧАЛО УСТАНОВКИ
# ══════════════════════════════════════════════════════════════════════════════

clear

# Требуется root
if [[ $EUID -ne 0 ]]; then
    print_header "ОШИБКА ДОСТУПА" "${RED}"
    echo -e "${RED}Этот установщик должен быть запущен от имени root (используйте sudo).${NC}"
    exit 1
fi

# ─── Удаление ─────────────────────────────────────────────────────────────────

if [[ "$1" == "uninstall" ]]; then
    if [[ -f "/usr/local/bin/mtproxy" ]]; then
        /usr/local/bin/mtproxy uninstall
        exit $?
    fi

    print_header "УДАЛЕНИЕ MTProxy" "${YELLOW}"
    
    echo -e "${RED}ВНИМАНИЕ: Это полностью удалит MTProxy и все связанные файлы!${NC}"
    echo -e "${YELLOW}Будет удалено следующее:${NC}"
    echo -e "  • Docker-контейнер: $CONTAINER_NAME"
    echo -e "  • Docker-образ: $IMAGE_NAME"
    echo -e "  • Директория установки: $INSTALL_DIR"
    echo -e "  • Утилита управления: /usr/local/bin/mtproxy"
    echo ""
    
    read -p "Вы уверены, что хотите продолжить? [введите YES для подтверждения, Enter = отмена]: " CONFIRM </dev/tty
    
    if [[ "$CONFIRM" != "YES" ]]; then
        echo -e "${GREEN}Удаление отменено.${NC}"
        exit 0
    fi
    
    print_step "U1" "Остановка и удаление компонентов"
    
    if docker ps -q -f name="$CONTAINER_NAME" 2>/dev/null | grep -q .; then
        echo -e "${YELLOW}Остановка контейнера...${NC}"
        docker stop "$CONTAINER_NAME" >/dev/null 2>&1
    fi
    
    if docker ps -aq -f name="$CONTAINER_NAME" 2>/dev/null | grep -q .; then
        echo -e "${YELLOW}Удаление контейнера...${NC}"
        docker rm "$CONTAINER_NAME" >/dev/null 2>&1
    fi
    
    if docker images -q "$IMAGE_NAME" 2>/dev/null | grep -q .; then
        echo -e "${YELLOW}Удаление Docker-образа...${NC}"
        docker rmi "$IMAGE_NAME" >/dev/null 2>&1
    fi
    
    if [[ -d "$INSTALL_DIR" ]]; then
        echo -e "${YELLOW}Удаление директории установки...${NC}"
        rm -rf "$INSTALL_DIR"
    fi
    
    if [[ -f "/usr/local/bin/mtproxy" ]]; then
        echo -e "${YELLOW}Удаление утилиты управления...${NC}"
        rm -f "/usr/local/bin/mtproxy"
    fi
    
    if command -v ufw &> /dev/null && ufw status | grep -q "Status: active"; then
        echo -e "${YELLOW}Очистка правил брандмауэра...${NC}"
        for port in 443 8080 8443 9443 1080 3128; do
            if ufw status | grep -q "${port}/tcp"; then
                ufw delete allow ${port}/tcp 2>/dev/null
            fi
        done
    fi
    
    print_header "MTProxy УДАЛЕН" "${GREEN}"
    exit 0
fi

# ─── Установка ────────────────────────────────────────────────────────────────

check_connectivity

print_header "УСТАНОВКА MTProxy (Docker)" "${BLUE}"

# ─── Этап 1: Настройка порта ──────────────────────────────────────────────────

print_step "1" "Настройка порта"
echo -e "${CYAN}Порт 443 рекомендуется для лучшей маскировки под HTTPS-трафик.${NC}"
PORT=$(ask_with_default "Введите порт прокси" "$DEFAULT_PORT")
if ! [[ "$PORT" =~ ^[0-9]+$ ]] || ((PORT < 1 || PORT > 65535)); then
    echo -e "${RED}Некорректный порт: $PORT. Допустимы значения 1-65535.${NC}"
    exit 1
fi
check_port_available "$PORT"

# ─── Этап 2: Docker ──────────────────────────────────────────────────────────

print_step "2" "Подготовка Docker"
if command -v docker >/dev/null 2>&1; then
    DOCKER_VER=$(docker --version 2>/dev/null | head -1)
    echo -e "${GREEN}✅ Docker уже установлен: $DOCKER_VER${NC}"
else
    echo -e "${YELLOW}Docker не найден. Устанавливаю...${NC}"
    run_live_log "curl -fsSL https://get.docker.com | sh"
    if [ $? -ne 0 ]; then
        echo -e "${RED}Ошибка при установке Docker!${NC}"
        exit 1
    fi
    systemctl enable docker >/dev/null 2>&1
    systemctl start docker >/dev/null 2>&1
    echo -e "${GREEN}✅ Docker успешно установлен${NC}"
fi

# Убеждаемся что Docker запущен
if ! docker info >/dev/null 2>&1; then
    echo -e "${YELLOW}Запускаю Docker...${NC}"
    systemctl start docker
    sleep 2
    if ! docker info >/dev/null 2>&1; then
        echo -e "${RED}Не удалось запустить Docker!${NC}"
        exit 1
    fi
fi

# Установим xxd если нет (нужен для hex-конвертации)
if ! command -v xxd >/dev/null 2>&1; then
    echo -e "${YELLOW}Установка xxd...${NC}"
    apt-get update -qq && apt-get install -y -qq vim-common >/dev/null 2>&1
fi

# ─── Этап 3: Генерация секрета и IP ──────────────────────────────────────────

print_step "3" "Безопасность и сеть"

# Секрет
if [[ -f "$INSTALL_DIR/info.txt" ]] && grep -q "Base Secret:" "$INSTALL_DIR/info.txt"; then
    USER_SECRET=$(grep -m1 "Base Secret:" "$INSTALL_DIR/info.txt" | awk '{print $3}')
    echo -e "${GREEN}Используется прежний секрет: $USER_SECRET${NC}"
else
    USER_SECRET=$(head -c 16 /dev/urandom | xxd -ps)
    echo -e "${GREEN}Сгенерирован новый секрет: $USER_SECRET${NC}"
fi

# IP
echo -e "${YELLOW}Определение внешнего IPv4...${NC}"
EXTERNAL_IP=""
for service in "ipv4.icanhazip.com" "ipv4.ident.me" "api.ipify.org"; do
    EXTERNAL_IP=$(curl -4 -s --connect-timeout 5 "$service" 2>/dev/null)
    [[ $EXTERNAL_IP =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]] && break
    EXTERNAL_IP=""
done
[[ -z "$EXTERNAL_IP" ]] && EXTERNAL_IP="YOUR_SERVER_IP"
echo -e "${GREEN}Ваш IP: $EXTERNAL_IP${NC}"

# ─── Этап 4: Домен ───────────────────────────────────────────────────────────

print_step "4" "Конфигурация домена"
echo -e "${CYAN}Вы можете указать доменное имя (например, proxy.example.com).${NC}"
PROXY_HOST=$(ask_with_default "Введите домен или IP хоста прокси" "$EXTERNAL_IP")

if [[ "$PROXY_HOST" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    if [[ "$PROXY_HOST" != "$EXTERNAL_IP" ]]; then
         echo -e "${YELLOW}Внимание: Введенный IP ($PROXY_HOST) отличается от определенного IP сервера ($EXTERNAL_IP).${NC}"
         read -p "Нажмите Enter для подтверждения использования введенного IP... " _ </dev/tty
    else
         echo -e "${GREEN}✅ Используем IP сервера: $PROXY_HOST${NC}"
    fi
else
    echo -e "${YELLOW}Проверка A-записи для домена $PROXY_HOST...${NC}"
    
    RESOLVED_IP=""
    if command -v dig >/dev/null 2>&1; then
        RESOLVED_IP=$(dig +short "$PROXY_HOST" A 2>/dev/null | head -1)
    elif command -v getent >/dev/null 2>&1; then
        RESOLVED_IP=$(getent ahostsv4 "$PROXY_HOST" 2>/dev/null | head -1 | awk '{print $1}')
    elif command -v nslookup >/dev/null 2>&1; then
        RESOLVED_IP=$(nslookup "$PROXY_HOST" 2>/dev/null | awk '/^Address: / { print $2 }' | tail -1)
    fi

    if [[ "$RESOLVED_IP" == "$EXTERNAL_IP" ]]; then
        echo -e "${GREEN}✅ Успешно: Домен направлен на этот сервер ($RESOLVED_IP).${NC}"
        read -p "Нажмите Enter для продолжения..." _ </dev/tty
    else
        echo -e "${RED}❌ Ошибка: Домен $PROXY_HOST указывает на '${RESOLVED_IP:-неизвестно}', а не на $EXTERNAL_IP.${NC}"
        echo -e "${YELLOW}Скрипт определил IP вашего сервера как: ${BOLD}$EXTERNAL_IP${NC}"
        echo -e "Вы можете продолжить установку, используя этот IP."
        
        read -p "Нажмите Enter для использования IP $EXTERNAL_IP (или введите 'stop' для выхода): " DECISION </dev/tty
        
        if [[ "${DECISION,,}" == "stop" ]]; then
            echo -e "${RED}Установка остановлена.${NC}"
            exit 1
        fi
        
        echo -e "${GREEN}Переключаемся на использование IP: $EXTERNAL_IP${NC}"
        PROXY_HOST="$EXTERNAL_IP"
    fi
fi

# ─── Этап 5: TLS-маскировка ──────────────────────────────────────────────────

print_step "5" "Настройка TLS-маскировки"
echo -e "${CYAN}Выберите домен для маскировки трафика (должен работать по HTTPS).${NC}"
TLS_DOMAINS=("github.com" "cloudflare.com" "microsoft.com" "amazon.com" "wikipedia.org" "reddit.com")
RANDOM_DOMAIN=${TLS_DOMAINS[$RANDOM % ${#TLS_DOMAINS[@]}]}
TLS_DOMAIN=$(ask_with_default "TLS-домен для маскировки" "$RANDOM_DOMAIN")
echo -e "${GREEN}Используется маскировка под: $TLS_DOMAIN${NC}"

# ─── Этап 6: Регистрация в @MTProxybot ───────────────────────────────────────

print_step "6" "Регистрация прокси в Telegram"

echo -e "${CYAN}╔════════════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║${NC} ${BOLD}Сейчас нужно зарегистрировать прокси в @MTProxybot${NC}        ${CYAN}║${NC}"
echo -e "${CYAN}╠════════════════════════════════════════════════════════════╣${NC}"
echo -e "${CYAN}║${NC}                                                            ${CYAN}║${NC}"
echo -e "${CYAN}║${NC}  1. Откройте бота ${BOLD}@MTProxybot${NC} в Telegram                  ${CYAN}║${NC}"
echo -e "${CYAN}║${NC}  2. Отправьте ${BOLD}/newproxy${NC}                                    ${CYAN}║${NC}"
echo -e "${CYAN}║${NC}  3. Бот спросит host:port — введите:                        ${CYAN}║${NC}"
echo -e "${CYAN}║${NC}     ${GREEN}${BOLD}${PROXY_HOST}:${PORT}${NC}$(printf '%*s' $((39 - ${#PROXY_HOST} - ${#PORT})) '')${CYAN}║${NC}"
echo -e "${CYAN}║${NC}  4. Бот спросит secret — введите:                            ${CYAN}║${NC}"
echo -e "${CYAN}║${NC}     ${GREEN}${BOLD}${USER_SECRET}${NC}$(printf '%*s' $((39 - ${#USER_SECRET})) '')${CYAN}║${NC}"
echo -e "${CYAN}║${NC}  5. Бот ответит — ${BOLD}proxy tag: XXXXXXXX...${NC}                   ${CYAN}║${NC}"
echo -e "${CYAN}║${NC}     Скопируйте этот тег (32 hex-символа)                    ${CYAN}║${NC}"
echo -e "${CYAN}║${NC}  6. Далее через ${BOLD}/myproxies${NC} настройте рекламный канал       ${CYAN}║${NC}"
echo -e "${CYAN}║${NC}                                                            ${CYAN}║${NC}"
echo -e "${CYAN}╚════════════════════════════════════════════════════════════╝${NC}"

echo ""

# Загрузка AD_TAG из предыдущей установки
EXISTING_AD_TAG=""
if [[ -f "$INSTALL_DIR/config.py" ]]; then
    EXISTING_AD_TAG=$(grep -oP '(?<=AD_TAG = ")[^"]+' "$INSTALL_DIR/config.py" 2>/dev/null)
fi

if [[ -n "$EXISTING_AD_TAG" ]]; then
    echo -e "${GREEN}Найден AD_TAG из предыдущей установки: $EXISTING_AD_TAG${NC}"
fi

echo -e "${YELLOW}Введите proxy tag (AD_TAG) полученный от @MTProxybot.${NC}"
echo -e "${YELLOW}Если хотите пропустить — нажмите Enter (можно добавить позже: mtproxy ad-tag).${NC}"

if [[ -n "$EXISTING_AD_TAG" ]]; then
    read -p "AD_TAG [Enter = $EXISTING_AD_TAG]: " AD_TAG_INPUT </dev/tty
    AD_TAG=${AD_TAG_INPUT:-$EXISTING_AD_TAG}
else
    read -p "AD_TAG: " AD_TAG </dev/tty
fi

# Валидация AD_TAG
if [[ -n "$AD_TAG" ]]; then
    if [[ "$AD_TAG" =~ ^[0-9a-fA-F]{32}$ ]]; then
        echo -e "${GREEN}✅ AD_TAG принят: $AD_TAG${NC}"
    else
        echo -e "${RED}⚠️  AD_TAG выглядит некорректно (ожидается 32 hex-символа).${NC}"
        read -p "Использовать всё равно? (yes/no) [no]: " CONFIRM </dev/tty
        if [[ "$CONFIRM" != "yes" ]]; then
            echo -e "${YELLOW}AD_TAG не установлен. Добавьте позже: mtproxy ad-tag${NC}"
            AD_TAG=""
        fi
    fi
else
    echo -e "${YELLOW}AD_TAG пропущен. Добавьте позже командой: mtproxy ad-tag${NC}"
fi

# Канал (справочное поле)
echo ""
echo -e "${CYAN}Укажите канал, который вы настроили в @MTProxybot (без @, для справки).${NC}"
CHANNEL_TAG=$(ask_with_default "Введите тег канала" "$DEFAULT_CHANNEL")
CHANNEL_TAG=${CHANNEL_TAG//@/}
echo -e "${GREEN}Канал: @$CHANNEL_TAG${NC}"

# ─── Этап 7: Подготовка файлов ────────────────────────────────────────────────

print_step "7" "Создание файлов конфигурации"
mkdir -p "$INSTALL_DIR"

# Остановим и удалим предыдущий контейнер если есть
docker stop "$CONTAINER_NAME" >/dev/null 2>&1
docker rm "$CONTAINER_NAME" >/dev/null 2>&1

# Скачивание mtprotoproxy.py
echo -e "${YELLOW}Загрузка mtprotoproxy.py...${NC}"
if curl -s -L "https://raw.githubusercontent.com/alexbers/mtprotoproxy/master/mtprotoproxy.py" -o "$INSTALL_DIR/mtprotoproxy.py"; then
    chmod +x "$INSTALL_DIR/mtprotoproxy.py"
    echo -e "${GREEN}✅ mtprotoproxy.py загружен${NC}"
else
    echo -e "${RED}Ошибка загрузки mtprotoproxy.py!${NC}"
    exit 1
fi

# Создание config.py
echo -e "${YELLOW}Создание config.py...${NC}"
cat > "$INSTALL_DIR/config.py" << CONFIGEOF
PORT = $PORT

USERS = {
    "tg": "$USER_SECRET",
}

MODES = {
    "classic": False,
    "secure": False,
    "tls": True
}

TLS_DOMAIN = "$TLS_DOMAIN"
CONFIGEOF

if [[ -n "$AD_TAG" ]]; then
    echo "" >> "$INSTALL_DIR/config.py"
    echo "AD_TAG = \"$AD_TAG\"" >> "$INSTALL_DIR/config.py"
fi

echo -e "${GREEN}✅ config.py создан${NC}"

# Создание Dockerfile
echo -e "${YELLOW}Создание Dockerfile...${NC}"
cat > "$INSTALL_DIR/Dockerfile" << 'DOCKEREOF'
FROM ubuntu:24.04
RUN apt-get update && apt-get install --no-install-recommends -y \
    python3 python3-uvloop python3-cryptography python3-socks \
    libcap2-bin ca-certificates && rm -rf /var/lib/apt/lists/*
RUN setcap cap_net_bind_service=+ep /usr/bin/python3.12
RUN useradd tgproxy -u 10000
USER tgproxy
WORKDIR /home/tgproxy/
CMD ["python3", "mtprotoproxy.py"]
DOCKEREOF
echo -e "${GREEN}✅ Dockerfile создан${NC}"

# ─── Этап 8: Сборка и запуск Docker ──────────────────────────────────────────

print_step "8" "Сборка Docker-образа"
echo -e "${YELLOW}Сборка образа (это может занять 1-2 минуты)...${NC}"
run_live_log "docker build -t $IMAGE_NAME $INSTALL_DIR/"
if [ $? -ne 0 ]; then
    echo -e "${RED}Ошибка сборки Docker-образа!${NC}"
    exit 1
fi
echo -e "${GREEN}✅ Docker-образ $IMAGE_NAME собран успешно${NC}"

print_step "9" "Запуск контейнера"
echo -e "${YELLOW}Запуск MTProxy в Docker-контейнере...${NC}"
docker run -d \
    --name "$CONTAINER_NAME" \
    --restart unless-stopped \
    --network host \
    -v "$INSTALL_DIR/config.py:/home/tgproxy/config.py:ro" \
    -v "$INSTALL_DIR/mtprotoproxy.py:/home/tgproxy/mtprotoproxy.py:ro" \
    "$IMAGE_NAME"

if [ $? -ne 0 ]; then
    echo -e "${RED}Ошибка запуска контейнера!${NC}"
    exit 1
fi

# Ждём пару секунд и проверяем
sleep 2
if docker ps -f name="$CONTAINER_NAME" --format '{{.Status}}' | grep -q "Up"; then
    echo -e "${GREEN}✅ Контейнер $CONTAINER_NAME запущен${NC}"
else
    echo -e "${RED}⚠️  Контейнер запустился, но мог упасть. Проверьте логи:${NC}"
    echo -e "${YELLOW}docker logs $CONTAINER_NAME${NC}"
fi

# ─── Сохранение info.txt ─────────────────────────────────────────────────────

DOMAIN_HEX=$(echo -n "$TLS_DOMAIN" | xxd -p | tr -d '\n')
cat > "$INSTALL_DIR/info.txt" << EOL
MTProxy Installation Information (Docker)
==========================================
Дата установки: $(date '+%Y-%m-%d %H:%M:%S')
Хост прокси: $PROXY_HOST
Порт: $PORT
Base Secret: $USER_SECRET
TLS Domain: $TLS_DOMAIN
Канал: @$CHANNEL_TAG
AD_TAG: ${AD_TAG:-не установлен}
Docker Image: $IMAGE_NAME
Docker Container: $CONTAINER_NAME

Ссылки подключения:
TLS (ee): tg://proxy?server=$PROXY_HOST&port=$PORT&secret=ee${USER_SECRET}${DOMAIN_HEX}
DD (dd):  tg://proxy?server=$PROXY_HOST&port=$PORT&secret=dd${USER_SECRET}
Plain:    tg://proxy?server=$PROXY_HOST&port=$PORT&secret=${USER_SECRET}
EOL

# Настройка файрвола
if command -v ufw &> /dev/null && ufw status | grep -q "Status: active"; then
    ufw allow "$PORT"/tcp >/dev/null
fi

# ─── Этап 10: Утилита управления ─────────────────────────────────────────────

print_step "10" "Создание утилиты управления"
cat > "/tmp/mtproxy_utility" << 'UTILITY_EOF'
#!/bin/bash
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'
INSTALL_DIR="/opt/MTProxy"
CONTAINER_NAME="mtproto-proxy"
IMAGE_NAME="mtproxy-image"

print_header() {
    local title="$1"
    local color="${2:-$BLUE}"
    echo -e "${color}╔════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${color}║$(printf '%*s' $(( (60 - ${#title}) / 2 )) '')${BOLD}${title}${NC}${color}$(printf '%*s' $(( (60 - ${#title} + 1) / 2 )) '')║${NC}"
    echo -e "${color}╚════════════════════════════════════════════════════════════╝${NC}"
}

print_block() {
    local title="$1"
    echo -e "\n${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}${BOLD}${title}${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

domain_to_hex() { echo -n "$1" | xxd -p | tr -d '\n'; }

get_config_value() {
    local key="$1"
    if [[ -f "$INSTALL_DIR/config.py" ]]; then
        grep -oP "(?<=^${key} = ).*" "$INSTALL_DIR/config.py" 2>/dev/null | tr -d '"' | tr -d "'"
    fi
}

get_info_value() {
    local key="$1"
    if [[ -f "$INSTALL_DIR/info.txt" ]]; then
        grep -m1 "^${key}:" "$INSTALL_DIR/info.txt" | cut -d':' -f2- | sed 's/^ //'
    fi
}

get_links() {
    PORT=$(get_config_value "PORT")
    SECRET=""
    if [[ -f "$INSTALL_DIR/config.py" ]]; then
        SECRET=$(grep -oP '(?<="tg":\s*")[^"]+' "$INSTALL_DIR/config.py" 2>/dev/null)
    fi
    TLS_DOMAIN=$(get_config_value "TLS_DOMAIN")
    AD_TAG=$(get_config_value "AD_TAG")
    
    PROXY_HOST=$(get_info_value "Хост прокси")
    INSTALL_DATE=$(get_info_value "Дата установки")
    CHANNEL=$(get_info_value "Канал")
    
    [[ -z "$PROXY_HOST" ]] && PROXY_HOST=$(curl -4 -s --connect-timeout 5 ifconfig.me)
    [[ -z "$PROXY_HOST" ]] && PROXY_HOST="N/A"
    [[ -z "$PORT" ]] && PORT="443"
    [[ -z "$TLS_DOMAIN" ]] && TLS_DOMAIN="github.com"

    TLS_HEX=$(domain_to_hex "$TLS_DOMAIN")

    PLAIN_LINK="tg://proxy?server=$PROXY_HOST&port=$PORT&secret=${SECRET}"
    DD_LINK="tg://proxy?server=$PROXY_HOST&port=$PORT&secret=dd${SECRET}"
    EE_LINK="tg://proxy?server=$PROXY_HOST&port=$PORT&secret=ee${SECRET}${TLS_HEX}"
}

show_help() {
    print_block "📚 Подсказка по командам"
    echo -e " ${BOLD}mtproxy${NC}            — открыть дашборд"
    echo -e " ${BOLD}mtproxy stats${NC}      — показать количество подключений"
    echo -e " ${BOLD}mtproxy start${NC}      — запустить контейнер"
    echo -e " ${BOLD}mtproxy stop${NC}       — остановить контейнер"
    echo -e " ${BOLD}mtproxy restart${NC}    — перезапустить контейнер"
    echo -e " ${BOLD}mtproxy tls-domain${NC} — заменить TLS-домен и перезапустить"
    echo -e " ${BOLD}mtproxy ad-tag${NC}     — установить/изменить рекламный AD_TAG"
    echo -e " ${BOLD}mtproxy links${NC}      — вывести только ссылки подключения"
    echo -e " ${BOLD}mtproxy logs${NC}       — смотреть логи в реальном времени"
    echo -e " ${BOLD}mtproxy uninstall${NC}  — удалить MTProxy"
}

get_active_connections() {
    local port=$(get_config_value "PORT")
    [[ -z "$port" ]] && port="443"
    if command -v ss >/dev/null; then
        ss -nH state established sport = :$port 2>/dev/null | wc -l
    elif command -v netstat >/dev/null; then
        netstat -tn 2>/dev/null | grep ":$port " | grep ESTABLISHED | wc -l
    else
        echo "N/A"
    fi
}

change_tls_domain() {
    local config_file="$INSTALL_DIR/config.py"
    
    if [[ ! -f "$config_file" ]]; then
        echo -e "${RED}Не найден файл конфигурации: $config_file${NC}"
        exit 1
    fi

    local current_tls=$(get_config_value "TLS_DOMAIN")
    [[ -z "$current_tls" ]] && current_tls="github.com"

    echo -e "${CYAN}Текущий TLS-домен:${NC} ${BOLD}$current_tls${NC}"
    read -p "Введите новый TLS-домен [Enter = $current_tls]: " new_tls </dev/tty
    new_tls=${new_tls:-$current_tls}

    if [[ ! "$new_tls" =~ ^[A-Za-z0-9.-]+$ ]]; then
        echo -e "${RED}Некорректный домен: $new_tls${NC}"
        exit 1
    fi

    sed -i "s|^TLS_DOMAIN = .*|TLS_DOMAIN = \"$new_tls\"|" "$config_file"
    
    if [[ -f "$INSTALL_DIR/info.txt" ]]; then
        sed -i "s|^TLS Domain:.*|TLS Domain: $new_tls|" "$INSTALL_DIR/info.txt"
    fi

    echo -e "${YELLOW}Перезапускаю контейнер...${NC}"
    docker restart "$CONTAINER_NAME" >/dev/null 2>&1

    echo -e "${GREEN}✅ TLS-домен обновлён: $new_tls${NC}"
    
    print_block "📝 Последние логи контейнера"
    docker logs "$CONTAINER_NAME" --tail 15 2>&1
}

change_ad_tag() {
    local config_file="$INSTALL_DIR/config.py"
    
    if [[ ! -f "$config_file" ]]; then
        echo -e "${RED}Не найден файл конфигурации: $config_file${NC}"
        exit 1
    fi

    local current_tag=$(get_config_value "AD_TAG")
    
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BOLD}Как получить AD_TAG:${NC}"
    echo -e " 1. Откройте бота ${CYAN}@MTProxybot${NC} в Telegram"
    echo -e " 2. Отправьте ${BOLD}/newproxy${NC}"
    echo -e " 3. Введите хост:порт вашего прокси"
    echo -e " 4. Введите секрет (из дашборда)"
    echo -e " 5. Бот выдаст вам ${BOLD}proxy tag${NC} — вставьте его ниже"
    echo -e " 6. Через ${BOLD}/myproxies${NC} настройте рекламный канал"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    
    if [[ -n "$current_tag" ]]; then
        echo -e "${GREEN}Текущий AD_TAG: $current_tag${NC}"
    else
        echo -e "${YELLOW}AD_TAG не установлен${NC}"
    fi
    
    read -p "Введите AD_TAG (hex-строка, или Enter для отмены): " new_tag </dev/tty
    
    if [[ -z "$new_tag" ]]; then
        echo -e "${YELLOW}Отменено.${NC}"
        return
    fi

    if [[ ! "$new_tag" =~ ^[0-9a-fA-F]+$ ]]; then
        echo -e "${RED}Некорректный AD_TAG! Ожидается hex-строка (например: 3c09c680b76ee91a4c25ad51f742267d)${NC}"
        return
    fi

    if grep -q "^AD_TAG" "$config_file"; then
        sed -i "s|^AD_TAG = .*|AD_TAG = \"$new_tag\"|" "$config_file"
    else
        echo "" >> "$config_file"
        echo "AD_TAG = \"$new_tag\"" >> "$config_file"
    fi

    # Обновляем info.txt
    if [[ -f "$INSTALL_DIR/info.txt" ]]; then
        sed -i "s|^AD_TAG:.*|AD_TAG: $new_tag|" "$INSTALL_DIR/info.txt"
    fi

    echo -e "${YELLOW}Перезапускаю контейнер...${NC}"
    docker restart "$CONTAINER_NAME" >/dev/null 2>&1

    echo -e "${GREEN}✅ AD_TAG установлен! Реклама канала теперь активна.${NC}"
}

show_dashboard() {
    clear
    print_header "ДАШБОРД MTProxy (Docker)" "$BLUE"
    get_links

    if docker ps -f name="$CONTAINER_NAME" --format '{{.Status}}' 2>/dev/null | grep -q "Up"; then
        SERVICE_STATE="${GREEN}✅ Активен (Docker)${NC}"
        CONN_COUNT=$(get_active_connections)
        CONTAINER_UPTIME=$(docker ps -f name="$CONTAINER_NAME" --format '{{.Status}}' 2>/dev/null)
    else
        SERVICE_STATE="${RED}❌ Остановлен${NC}"
        CONN_COUNT="0"
        CONTAINER_UPTIME="N/A"
    fi

    local ad_tag_status
    if [[ -n "$AD_TAG" ]]; then
        ad_tag_status="${GREEN}✅ $AD_TAG${NC}"
    else
        ad_tag_status="${YELLOW}❌ Не установлен (mtproxy ad-tag)${NC}"
    fi

    print_block "📊 Состояние"
    echo -e " Контейнер:       $SERVICE_STATE"
    echo -e " Аптайм:          ${BOLD}${CONTAINER_UPTIME}${NC}"
    echo -e " Порт:            ${BOLD}${PORT:-N/A}${NC}"
    echo -e " Хост:            ${BOLD}${PROXY_HOST:-N/A}${NC}"
    echo -e " Активных соед.:  ${BOLD}${CONN_COUNT}${NC}"
    echo -e " Канал:           ${BOLD}${CHANNEL:-N/A}${NC}"
    echo -e " AD_TAG:          $ad_tag_status"
    echo -e " TLS-домен:       ${BOLD}${TLS_DOMAIN:-github.com}${NC}"
    echo -e " Дата установки:  ${BOLD}${INSTALL_DATE:-N/A}${NC}"

    print_block "🔗 Ссылки подключения"
    echo -e " ${CYAN}TLS (рекомендуется):${NC} ${EE_LINK}"
    echo -e " ${CYAN}DD (legacy):${NC}        ${DD_LINK}"
    echo -e " ${CYAN}Обычная:${NC}            ${PLAIN_LINK}"

    show_help
}

case "${1:-dashboard}" in
    "dashboard"|"status")
        show_dashboard
        ;;
    "start")
        print_header "ЗАПУСК" "$YELLOW"
        docker start "$CONTAINER_NAME" 2>/dev/null
        if [ $? -eq 0 ]; then
            echo -e "${GREEN}✅ Контейнер запущен.${NC}"
        else
            echo -e "${RED}Ошибка запуска контейнера.${NC}"
        fi
        sleep 1
        show_dashboard
        ;;
    "stop")
        print_header "ОСТАНОВКА" "$YELLOW"
        docker stop "$CONTAINER_NAME" 2>/dev/null
        echo -e "${GREEN}Контейнер остановлен.${NC}"
        sleep 1
        show_dashboard
        ;;
    "restart")
        print_header "ПЕРЕЗАПУСК" "$YELLOW"
        docker restart "$CONTAINER_NAME" 2>/dev/null
        echo -e "${GREEN}Контейнер перезапущен.${NC}"
        sleep 1
        show_dashboard
        ;;
    "tls-domain"|"set-tls")
        clear
        print_header "СМЕНА TLS-ДОМЕНА" "$YELLOW"
        change_tls_domain
        sleep 1
        show_dashboard
        ;;
    "ad-tag"|"adtag"|"tag")
        clear
        print_header "НАСТРОЙКА AD_TAG" "$YELLOW"
        change_ad_tag
        sleep 1
        show_dashboard
        ;;
    "links")
        get_links
        echo -e "$EE_LINK\n$DD_LINK\n$PLAIN_LINK"
        ;;
    "stats")
        echo "$(get_active_connections)"
        ;;
    "logs")
        clear
        print_header "ЛОГИ MTProxy" "$YELLOW"
        docker logs -f "$CONTAINER_NAME" 2>&1
        ;;
    "uninstall")
        clear
        print_header "УДАЛЕНИЕ MTProxy" "$RED"
        echo -e "${RED}ВНИМАНИЕ: Будет удалено:${NC}"
        echo -e "  • Контейнер: $CONTAINER_NAME"
        echo -e "  • Образ: $IMAGE_NAME"
        echo -e "  • Директория: $INSTALL_DIR"
        echo -e "  • Утилита: /usr/local/bin/mtproxy"
        echo ""
        read -p "Вы уверены? [введите YES для подтверждения, Enter = отмена]: " CONFIRM </dev/tty
        [[ "$CONFIRM" != "YES" ]] && exit 0
        
        docker stop "$CONTAINER_NAME" >/dev/null 2>&1
        docker rm "$CONTAINER_NAME" >/dev/null 2>&1
        docker rmi "$IMAGE_NAME" >/dev/null 2>&1
        rm -rf "$INSTALL_DIR"
        
        if command -v ufw &> /dev/null && ufw status | grep -q "Status: active"; then
            for port in 443 8080 8443 9443 1080 3128; do
                ufw delete allow ${port}/tcp 2>/dev/null
            done
        fi
        
        echo -e "${GREEN}✅ MTProxy полностью удалён.${NC}"
        rm -f "/usr/local/bin/mtproxy"
        ;;
    "help"|"-h"|"--help")
        clear
        print_header "СПРАВКА MTProxy" "$BLUE"
        show_help
        ;;
    *)
        clear
        print_header "НЕИЗВЕСТНАЯ КОМАНДА" "$RED"
        echo -e "${YELLOW}Команда '$1' не распознана.${NC}"
        show_help
        ;;
esac
UTILITY_EOF

mv "/tmp/mtproxy_utility" "/usr/local/bin/mtproxy"
chmod +x "/usr/local/bin/mtproxy"
echo -e "${GREEN}✅ Утилита управления создана: /usr/local/bin/mtproxy${NC}"

# ─── Финал ────────────────────────────────────────────────────────────────────

echo -e "\n${CYAN}Нажмите Enter для завершения установки и открытия дашборда...${NC}"
read -r _ </dev/tty

sleep 1
clear
/usr/local/bin/mtproxy

print_header "УСТАНОВКА ЗАВЕРШЕНА" "${GREEN}"
echo -e "\n${BLUE}Управляйте прокси командой: ${BOLD}mtproxy${NC}"
echo -e "${BLUE}Информация сохранена в: ${BOLD}$INSTALL_DIR/info.txt${NC}"

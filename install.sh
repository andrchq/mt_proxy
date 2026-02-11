#!/bin/bash

# =================================================================
# Telegram MTProxy Installer (Professional Edition)
# =================================================================

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# Пути
BASE_DIR="/opt/mtproxy"
BIN_PATH="$BASE_DIR/mtproto-proxy"
SERVICE_NAME="mtproxy"
CLI_PATH="/usr/local/bin/mtproxy"

# Проверка на root
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}Этот скрипт должен быть запущен от имени root (через sudo)${NC}"
   exit 1
fi

# Функции оформления
print_banner() {
    echo -e "${BLUE}================================================================${NC}"
    echo -e "${BOLD}${CYAN}   $1 ${NC}"
    echo -e "${BLUE}================================================================${NC}"
    echo ""
}

print_step() {
    echo -e "\n${BOLD}${PURPLE}➤ $1${NC}"
    echo -e "${PURPLE}----------------------------------------------------------------${NC}"
}

check_external_port() {
    local port=$1
    # Сервис TransmissionBT: возвращает 1 если открыт, 0 если закрыт
    local res=$(curl -s --max-time 10 "http://portcheck.transmissionbt.com/$port")
    if [[ "$res" == "1" ]]; then
        return 0
    fi
    return 1
}

# Очистка экрана и приветствие
clear
print_banner "Установка Telegram MTProxy (v1.2 - 11.02.2026)"

# 1. Диагностика сети
print_step "Шаг 1: Диагностика сети до серверов Telegram"
TG_IPS=("149.154.175.50" "149.154.167.51" "149.154.175.100" "149.154.167.91" "149.154.171.5")
SUCCESS_PINGS=0

for ip in "${TG_IPS[@]}"; do
    echo -n "Проверка $ip... "
    PING_RES=$(ping -c 2 -W 2 $ip 2>/dev/null | grep 'avg' | awk -F'/' '{print $5}')
    if [ ! -z "$PING_RES" ]; then
        echo -e "${GREEN}OK (${PING_RES} ms)${NC}"
        SUCCESS_PINGS=$((SUCCESS_PINGS+1))
    else
        echo -e "${RED}FAIL${NC}"
    fi
done

if [ "$SUCCESS_PINGS" -eq 0 ]; then
    echo -e "${RED}ВНИМАНИЕ: Связь с серверами Telegram отсутствует.${NC}"
    read -p "Продолжить установку все равно? [y/N]: " choice < /dev/tty
    [[ "$choice" =~ ^[Yy]$ ]] || exit 1
else
    echo -e "${GREEN}Диагностика завершена успешно ($SUCCESS_PINGS/${#TG_IPS[@]} серверов ответили).${NC}"
fi

# 2. Настройка параметров
print_step "Шаг 2: Настройка параметров"
read -p "Введите порт для прокси [по умолчанию 443]: " PROXY_PORT < /dev/tty
PROXY_PORT=${PROXY_PORT:-443}

read -p "Укажите домен (например, proxy.example.com) [оставьте пустым для авто-IP]: " PROXY_DOMAIN < /dev/tty
SERVER_IP=$(curl -s --max-time 5 https://api.ipify.org)

if [ -z "$PROXY_DOMAIN" ]; then
    PROXY_ADDR=$SERVER_IP
    echo -e "Автоматически определений IP: ${GREEN}$PROXY_ADDR${NC}"
else
    PROXY_ADDR=$PROXY_DOMAIN
    echo -e "Выполняется DNS-проверка домена ${CYAN}$PROXY_DOMAIN${NC}..."
    
    # Пытаемся зарезолвить IP разными способами
    DOMAIN_IP=""
    if command -v host > /dev/null; then
        DOMAIN_IP=$(host "$PROXY_DOMAIN" | grep "has address" | awk '{print $4}' | head -n 1)
    elif command -v nslookup > /dev/null; then
        DOMAIN_IP=$(nslookup "$PROXY_DOMAIN" | grep "Address:" | tail -n 1 | awk '{print $2}')
    else
        DOMAIN_IP=$(getent hosts "$PROXY_DOMAIN" | awk '{ print $1 }' | head -n 1)
    fi
    
    if [ -z "$DOMAIN_IP" ]; then
        echo -e "${RED}⚠️  ОШИБКА: Не удалось получить IP для домена $PROXY_DOMAIN.${NC}"
        echo -e "${YELLOW}Проверьте, что домен существует и направлен на IP сервера.${NC}"
        read -p "Продолжить все равно? [y/N]: " dns_choice < /dev/tty
        [[ "$dns_choice" =~ ^[Yy]$ ]] || exit 1
    elif [ "$DOMAIN_IP" != "$SERVER_IP" ]; then
        echo -e "${RED}⚠️  ВНИМАНИЕ: Несоответствие IP!${NC}"
        echo -e "Домен ${CYAN}$PROXY_DOMAIN${NC} указывает на IP: ${YELLOW}$DOMAIN_IP${NC}"
        echo -e "Текущий IP этого сервера: ${GREEN}$SERVER_IP${NC}"
        echo -e "${YELLOW}Это может привести к неработоспособности TLS-ссылок.${NC}"
        read -p "Использовать этот домен? [y/N]: " dns_match_choice < /dev/tty
        [[ "$dns_match_choice" =~ ^[Yy]$ ]] || exit 1
    else
        echo -e "${GREEN}✅ DNS-проверка пройдена: домен указывает на этот сервер.${NC}"
    fi
fi

# 3. Fake TLS Маскировка
print_step "Шаг 3: Настройка Fake TLS маскировки"
TLS_DOMAINS=("google.com" "facebook.com" "cloudflare.com" "microsoft.com" "apple.com" "amazon.com" "wikipedia.org" "bing.com" "reddit.com" "stackoverflow.com")
echo "Выполняю поиск лучшего домена для маскировки..."

BEST_DOMAIN="google.com"
MIN_PING=999

for domain in "${TLS_DOMAINS[@]}"; do
    echo -n "Тест $domain... "
    PING_TIME=$(ping -c 2 -W 1 $domain 2>/dev/null | grep 'avg' | awk -F'/' '{print $5}')
    if [ ! -z "$PING_TIME" ]; then
        echo -e "${GREEN}${PING_TIME} ms${NC}"
        if (( $(echo "$PING_TIME < $MIN_PING" | bc -l) )); then
            MIN_PING=$PING_TIME
            BEST_DOMAIN=$domain
        fi
    else
        echo -e "${RED}FAIL${NC}"
    fi
done

read -p "Выберите домен для маскировки [по умолчанию $BEST_DOMAIN]: " TLS_DOMAIN < /dev/tty
TLS_DOMAIN=${TLS_DOMAIN:-$BEST_DOMAIN}
echo -e "Для маскировки выбран: ${GREEN}$TLS_DOMAIN${NC}"

echo -e "\n📢 Продвижение канала (AD TAG):"
echo "1) Установить тег сейчас (32 символа)"
echo "2) Настроить позже (через @MTProxybot)"
read -p "Ваш выбор [1/2, по умолчанию 2]: " TAG_CHOICE < /dev/tty
TAG_CHOICE=${TAG_CHOICE:-2}

AD_TAG=""
if [ "$TAG_CHOICE" == "1" ]; then
    read -p "Введите тег (hex): " AD_TAG < /dev/tty
fi

# 4. Установка зависимостей
print_step "Шаг 4: Установка инструментов сборки"
apt-get update
# Устанавливаем всё необходимое для сборки
for pkg in git curl build-essential make gcc g++ xxd libssl-dev zlib1g-dev bc ufw; do
    apt-get install -y $pkg || echo -e "${RED}Ошибка установки $pkg${NC}"
done

# 5. Компиляция
print_step "Шаг 5: Клонирование и компиляция (может занять 2-5 минут)"
mkdir -p $BASE_DIR
cd $BASE_DIR
[[ -d "source" ]] && rm -rf source
git clone https://github.com/TelegramMessenger/MTProxy source
cd source
make -j$(nproc)
if [ ! -f "objs/bin/mtproto-proxy" ]; then
    echo -e "${RED}ОШИБКА: Компиляция не удалась!${NC}"
    exit 1
fi
cp objs/bin/mtproto-proxy $BIN_PATH

# 6. Генерация секрета
print_step "Шаг 6: Генерация ключей"
echo -n "Создание секретного ключа... "
# Основной секрет (16 байт)
RAW_SECRET=$(head -c 16 /dev/urandom | xxd -ps | tr '[:lower:]' '[:upper:]')
# TLS секрет (ee + secret + hex(domain))
DOMAIN_HEX=$(echo -n "$TLS_DOMAIN" | xxd -ps | tr '[:lower:]' '[:upper:]')
PROXY_SECRET="EE${RAW_SECRET}${DOMAIN_HEX}"
echo -e "${GREEN}Готово${NC}"

# 7. Системная настройка
print_step "Шаг 7: Системная настройка"
echo -n "Создание пользователя и прав... "
id -u mtproxy &>/dev/null || useradd -r -M -s /bin/false mtproxy
chown -R mtproxy:mtproxy $BASE_DIR
chmod +x $BIN_PATH
echo -e "${GREEN}OK${NC}"

echo -n "Загрузка конфигурации Telegram... "
curl -s https://core.telegram.org/getProxySecret -o $BASE_DIR/proxy-secret
curl -s https://core.telegram.org/getProxyConfig -o $BASE_DIR/proxy-multi.conf
echo -e "${GREEN}OK${NC}"

# 8. Firewall
print_step "Шаг 8: Настройка доступа"
echo -n "Проверка портов и Firewall... "
if command -v ss > /dev/null; then
    BUSY_SERVICE=$(ss -tlpn | grep ":$PROXY_PORT " | awk -F',' '{print $2}' | sed 's/\"//g')
    if [ ! -z "$BUSY_SERVICE" ]; then
        echo -e "\n${RED}ВНИМАНИЕ: Порт $PROXY_PORT занят: $BUSY_SERVICE${NC}"
    fi
fi

if command -v ufw > /dev/null && systemctl is-active --quiet ufw; then
    ufw allow $PROXY_PORT/tcp &>/dev/null
fi
iptables -I INPUT -p tcp --dport $PROXY_PORT -j ACCEPT 2>/dev/null
if command -v netfilter-persistent > /dev/null; then
    netfilter-persistent save &>/dev/null
fi
echo -e "${GREEN}Готово${NC}"

# 9. Systemd
print_step "Шаг 9: Создание службы"
echo -n "Конфигурация unit-файла... "
TAG_ARG=""
[[ ! -z "$AD_TAG" ]] && TAG_ARG="-P $AD_TAG"

cat <<EOF > /etc/systemd/system/$SERVICE_NAME.service
[Unit]
Description=Telegram MTProxy
After=network.target

[Service]
Type=simple
# Запуск от root для получения порта, затем сброс прав
WorkingDirectory=$BASE_DIR
Environment="PORT=$PROXY_PORT"
Environment="SECRET=$RAW_SECRET"
Environment="ADDR=$PROXY_ADDR"
Environment="TAG=$AD_TAG"
Environment="TLS_DOM=$TLS_DOMAIN"
ExecStart=$BIN_PATH -u mtproxy -p 8888 -H $PROXY_PORT -S $RAW_SECRET --aes-pwd proxy-secret proxy-multi.conf -M 1 $TAG_ARG
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable $SERVICE_NAME &>/dev/null
systemctl restart $SERVICE_NAME
echo -e "${GREEN}Служба запущена${NC}"

# 10. CLI Команда
cat <<'EOF' > $CLI_PATH
#!/bin/bash
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
CYAN='\033[1;36m'
BOLD='\033[1m'
NC='\033[0m'

show_dashboard() {
    local UNIT="/etc/systemd/system/mtproxy.service"
    [[ ! -f "$UNIT" ]] && { echo "MTProxy не установлен."; exit 1; }
    
    local PORT=$(grep -oP '(?<=Environment="PORT=)[^"]+' "$UNIT" | head -1)
    local SECRET=$(grep -oP '(?<=Environment="SECRET=)[^"]+' "$UNIT" | head -1)
    local ADDR=$(grep -oP '(?<=Environment="ADDR=)[^"]+' "$UNIT" | head -1)
    local TAG=$(grep -oP '(?<=Environment="TAG=)[^"]+' "$UNIT" | head -1)
    local TLS_DOM=$(grep -oP '(?<=Environment="TLS_DOM=)[^"]+' "$UNIT" | head -1)
    
    local STATUS_COLOR=$RED
    local STATUS_TEXT="Остановлен (Stopped)"
    systemctl is-active --quiet mtproxy && { STATUS_COLOR=$GREEN; STATUS_TEXT="Активен (Running)"; }

    echo -e "\n${BOLD}${CYAN}┏━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┓${NC}"
    echo -e "${BOLD}${CYAN}┃                💎 ЛИЧНЫЙ ТЕЛЕГРАМ ПРОКСИ                    ┃${NC}"
    echo -e "${BOLD}${CYAN}┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛${NC}"
    
    echo -e "  ${BOLD}Статус:${NC} $STATUS_COLOR$STATUS_TEXT${NC}"
    echo -e "  ${BOLD}Адрес:${NC}  ${YELLOW}$ADDR${NC}:${YELLOW}$PORT${NC}"
    echo -e "  ${BOLD}Секрет:${NC} ${GREEN}$SECRET${NC}"
    echo -e "  ${BOLD}Маскировка:${NC} ${BLUE}$TLS_DOM${NC}"
    echo -e "  ${BOLD}Канал (AD TAG):${NC} ${PURPLE}${TAG:-"(не задан)"}${NC}"
    
    echo -e "\n  ${BOLD}${CYAN}[APP] ПРЯМЫЕ ССЫЛКИ (Для приложения)${NC}"
    echo -e "  ${CYAN}─────────────────────────────────────────────────────────────${NC}"
    echo -e "  🔹 TLS (Рекомендуется): ${BLUE}tg://proxy?server=$ADDR&port=$PORT&secret=ee${SECRET}$(echo -n "$TLS_DOM" | xxd -ps | tr '[:lower:]' '[:upper:]')${NC}"
    echo -e "  🔹 Обычная:             ${BLUE}tg://proxy?server=$ADDR&port=$PORT&secret=$SECRET${NC}"
    echo -e "  🔹 Legacy (DD):         ${BLUE}tg://proxy?server=$ADDR&port=$PORT&secret=dd$SECRET${NC}"
    
    echo -e "\n  ${BOLD}${CYAN}[WEB] ВЕБ-ССЫЛКИ (Для браузера)${NC}"
    echo -e "  ${CYAN}─────────────────────────────────────────────────────────────${NC}"
    echo -e "  🔸 Ссылка: ${BLUE}https://t.me/proxy?server=$ADDR&port=$PORT&secret=ee${SECRET}$(echo -n "$TLS_DOM" | xxd -ps | tr '[:lower:]' '[:upper:]')${NC}"
    
    if [ -z "$TAG" ]; then
        echo -e "\n  ${BOLD}${YELLOW}⚠️  ВНИМАНИЕ: Канал для продвижения не настроен.${NC}"
        echo -e "     Зарегистрируйте прокси в @MTProxybot, чтобы добавить канал."
    fi
     echo -e "\n  ${BOLD}${BLUE}Управление:${NC} mtproxy {status|logs|restart|check|uninstall}\n"
}

case "$1" in
    logs) journalctl -u mtproxy -f ;;
    restart) systemctl restart mtproxy && echo "Сервис перезапущен.";;
    status) systemctl status mtproxy ;;
    check)
        PORT=$(grep -oP '(?<=Environment="PORT=)[^"]+' "/etc/systemd/system/mtproxy.service" | head -1)
        echo "Проверка доступности порта $PORT из интернета..."
        
        # Используем TransmissionBT сервис
        RES=$(curl -s --max-time 10 "http://portcheck.transmissionbt.com/$PORT")

        if [ "$RES" == "1" ]; then
            echo -e "${GREEN}✅ Порт открыт! Ваш прокси виден миру.${NC}"
        else
            echo -e "${RED}❌ Порт закрыт!${NC}"
            echo -e "${YELLOW}Проверьте Firewall в панели хостинга и настройки сервера.${NC}"
        fi
        ;;
    uninstall)
        read -p "Удалить MTProxy полностью? [y/N]: " conf < /dev/tty
        [[ "$conf" =~ ^[Yy]$ ]] && { systemctl stop mtproxy; systemctl disable mtproxy; rm -rf /opt/mtproxy /etc/systemd/system/mtproxy.service /usr/local/bin/mtproxy; echo "Удалено."; }
        ;;
    *) show_dashboard ;;
esac
EOF
chmod +x $CLI_PATH

# Финал
print_step "Установка завершена!"
sleep 2
mtproxy

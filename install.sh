#!/bin/bash

# =================================================================
# Telegram MTProxy Installer (Professional Edition)
# =================================================================

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
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
    # Попытка проверки через несколько сервисов
    local res=$(curl -s --max-time 5 "https://port-check.io/api?port=$port")
    if [[ "$res" == *"open"* ]]; then return 0; fi
    
    local res2=$(curl -s --max-time 5 "https://api.hackertarget.com/nmap/?q=$(curl -s https://api.ipify.org)&p=$port")
    if [[ "$res2" == *"open"* ]]; then return 0; fi
    
    return 1
}

# Очистка экрана и приветствие
clear
print_banner "Установка Telegram MTProxy"

# 1. Диагностика сети
print_step "Шаг 1: Диагностика сети до серверов Telegram"
# Используем IP из предоставленного списка
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
# Используем /dev/tty для чтения при запуске через pipe
read -p "Введите порт для прокси [по умолчанию 443]: " PROXY_PORT < /dev/tty
PROXY_PORT=${PROXY_PORT:-443}

read -p "Укажите домен (например, proxy.example.com) [оставьте пустым для авто-IP]: " PROXY_DOMAIN < /dev/tty
if [ -z "$PROXY_DOMAIN" ]; then
    PROXY_ADDR=$(curl -s https://api.ipify.org)
    echo -e "Автоматически определен IP: ${GREEN}$PROXY_ADDR${NC}"
else
    PROXY_ADDR=$PROXY_DOMAIN
    echo -e "Используется адрес: ${GREEN}$PROXY_ADDR${NC}"
fi

echo -e "\n📢 Продвижение канала (AD TAG):"
echo "1) Установить тег сейчас (32 символа)"
echo "2) Настроить позже (через @MTProxybot)"
read -p "Ваш выбор [1/2, по умолчанию 2]: " TAG_CHOICE < /dev/tty
TAG_CHOICE=${TAG_CHOICE:-2}

AD_TAG=""
if [ "$TAG_CHOICE" == "1" ]; then
    read -p "Введите тег (hex): " AD_TAG < /dev/tty
fi

# 3. Установка зависимостей
print_step "Шаг 3: Установка базовых инструментов (git, curl, make)"
apt-get update
# Сначала ставим самое важное по одному, чтобы видеть где ошибка
for pkg in git curl build-essential make gcc g++ xxd libssl-dev zlib1g-dev; do
    apt-get install -y $pkg || echo -e "${RED}Ошибка установки $pkg${NC}"
done

print_step "Шаг 3.1: Настройка Firewall (безопасная установка)"
# Пытаемся установить ufw, если его нет
apt-get install -y ufw

# Проверяем наличие ufw перед установкой более низкоуровневых штук
if command -v ufw > /dev/null && systemctl is-active --quiet ufw; then
    echo -e "${GREEN}UFW активен. Пропускаем iptables-persistent.${NC}"
else
    # На Ubuntu 24.04 noble часто конфликт, пробуем ставить только если нужно
    apt-get install -y iptables-persistent || echo -e "${YELLOW}Предупреждение: Не удалось поставить iptables-persistent.${NC}"
fi

# 4. Компиляция
print_step "Шаг 4: Клонирование и компиляция (это может занять 2-5 минут)"
mkdir -p $BASE_DIR
cd $BASE_DIR
if [ -d "source" ]; then
    rm -rf source
fi
git clone https://github.com/TelegramMessenger/MTProxy source
cd source
make -j$(nproc)
if [ ! -f "objs/bin/mtproto-proxy" ]; then
    echo -e "${RED}ОШИБКА: Бинарный файл не найден после компиляции!${NC}"
    exit 1
fi
cp objs/bin/mtproto-proxy $BIN_PATH

# 5. Генерация секрета
print_step "Шаг 5: Генерация секретного ключа"
# Генерируем секрет и переводим в ВЕРХНИЙ РЕГИСТР
PROXY_SECRET=$(head -c 16 /dev/urandom | xxd -ps | tr '[:lower:]' '[:upper:]')
echo -e "Ваш секрет: ${GREEN}$PROXY_SECRET${NC}"

# 6. Системная настройка
print_step "Шаг 6: Настройка системы и пользователей"
id -u mtproxy &>/dev/null || useradd -r -M -s /bin/false mtproxy
chown -R mtproxy:mtproxy $BASE_DIR
chmod +x $BIN_PATH

# 7. Загрузка конфигов Telegram
print_step "Шаг 7: Загрузка конфигурации Telegram"
curl -s https://core.telegram.org/getProxySecret -o $BASE_DIR/proxy-secret
curl -s https://core.telegram.org/getProxyConfig -o $BASE_DIR/proxy-multi.conf

# 8. Firewall
print_step "Шаг 8: Настройка Firewall"
if command -v ufw > /dev/null && systemctl is-active --quiet ufw; then
    ufw allow $PROXY_PORT/tcp
    echo -e "${GREEN}[UFW] Порт $PROXY_PORT открыт.${NC}"
fi

if command -v firewall-cmd > /dev/null && systemctl is-active --quiet firewalld; then
    firewall-cmd --permanent --add-port=$PROXY_PORT/tcp
    firewall-cmd --reload
    echo -e "${GREEN}[Firewalld] Порт $PROXY_PORT открыт.${NC}"
fi

iptables -I INPUT -p tcp --dport $PROXY_PORT -j ACCEPT 2>/dev/null
if command -v netfilter-persistent > /dev/null; then
    netfilter-persistent save 2>/dev/null
fi
echo -e "${GREEN}[iptables] Правила обновлены.${NC}"

# 9. Systemd
print_step "Шаг 9: Регистрация службы"
TAG_ARG=""
if [ ! -z "$AD_TAG" ]; then
    TAG_ARG="-P $AD_TAG"
fi

cat <<EOF > /etc/systemd/system/$SERVICE_NAME.service
[Unit]
Description=Telegram MTProxy
After=network.target

[Service]
Type=simple
User=mtproxy
Group=mtproxy
WorkingDirectory=$BASE_DIR
# Сохраняем переменные для Dashboard
Environment="PORT=$PROXY_PORT"
Environment="SECRET=$PROXY_SECRET"
Environment="ADDR=$PROXY_ADDR"
Environment="TAG=$AD_TAG"
ExecStart=$BIN_PATH -u mtproxy -p 8888 -H $PROXY_PORT -S $PROXY_SECRET --aes-pwd proxy-secret proxy-multi.conf -M 1 $TAG_ARG
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable $SERVICE_NAME
systemctl restart $SERVICE_NAME

# 10. Проверка порта
print_step "Шаг 10: Проверка доступности из интернета"
if check_external_port $PROXY_PORT; then
    echo -e "${GREEN}УСПЕХ: Порт $PROXY_PORT доступен извне!${NC}"
else
    echo -e "${RED}ВНИМАНИЕ: Порт $PROXY_PORT закрыт для внешних подключений.${NC}"
    echo -e "${YELLOW}ОБЯЗАТЕЛЬНО: Откройте TCP порт $PROXY_PORT в панели управления вашим хостингом (Security Groups / Firewall).${NC}"
fi

# 11. CLI Команда
print_step "Шаг 11: Установка команды управления 'mtproxy'"

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
    local UNIT_FILE="/etc/systemd/system/mtproxy.service"
    if [ ! -f "$UNIT_FILE" ]; then 
        echo -e "${RED}MTProxy не установлен.${NC}"; exit 1
    fi
    
    local PORT=$(grep -oP '(?<=Environment="PORT=)[^"]+' "$UNIT_FILE" | head -1)
    local SECRET=$(grep -oP '(?<=Environment="SECRET=)[^"]+' "$UNIT_FILE" | head -1)
    local ADDR=$(grep -oP '(?<=Environment="ADDR=)[^"]+' "$UNIT_FILE" | head -1)
    local TAG=$(grep -oP '(?<=Environment="TAG=)[^"]+' "$UNIT_FILE" | head -1)
    
    [[ -z "$TAG" ]] && TAG_DISP="(не установлен)" || TAG_DISP="@$TAG"
    
    echo -e "${CYAN}=== Статус MTProxy ===${NC}"
    echo ""
    echo -ne "✅ Служба: "
    systemctl is-active --quiet mtproxy && echo -e "${GREEN}Запущена (Running)${NC}" || echo -e "${RED}Остановлена (Stopped)${NC}"
    
    echo -e "📊 Конфигурация:"
    echo -e "   Порт: ${BOLD}$PORT${NC}"
    echo -e "   Секрет: ${BOLD}$SECRET${NC}"
    echo -e "   Секрет для регистрации (в @MTProxybot): ${BOLD}${SECRET}${NC}"
    echo -e "   Продвигаемый канал: ${BOLD}${TAG_DISP}${NC}"
    echo -e "   Хост прокси: ${BOLD}$ADDR${NC}"
    echo ""
    echo -e "🔗 Ссылки для подключения:"
    echo -e "Обычная (для @MTProxybot): ${BLUE}tg://proxy?server=$ADDR&port=$PORT&secret=$SECRET${NC}"
    echo -e "DD (старые клиенты):         ${BLUE}tg://proxy?server=$ADDR&port=$PORT&secret=dd$SECRET${NC}"
    
    TLS_SEC="ee${SECRET}6D6963726F736F66742E636F6D"
    echo -e "TLS:                       ${BLUE}tg://proxy?server=$ADDR&port=$PORT&secret=$TLS_SEC${NC}"
    echo ""
    echo -e "🌐 Веб-ссылки:"
    echo -e "Обычная: ${BLUE}https://t.me/proxy?server=$ADDR&port=$PORT&secret=$SECRET${NC}"
    echo -e "DD:      ${BLUE}https://t.me/proxy?server=$ADDR&port=$PORT&secret=dd$SECRET${NC}"
    echo -e "TLS:     ${BLUE}https://t.me/proxy?server=$ADDR&port=$PORT&secret=$TLS_SEC${NC}"
    echo ""
}

case "$1" in
    status)
        systemctl status mtproxy
        ;;
    logs)
        journalctl -u mtproxy -f
        ;;
    restart)
        systemctl restart mtproxy
        echo -e "${GREEN}Сервис перезапущен.${NC}"
        ;;
    check)
        PORT=$(grep -oP '(?<=Environment="PORT=)[^"]+' "/etc/systemd/system/mtproxy.service" | head -1)
        echo -e "Проверка порта $PORT..."
        if curl -s --max-time 10 "https://port-check.io/api?port=$PORT" | grep -q "open"; then
            echo -e "${GREEN}Порт $PORT открыт.${NC}"
        else
            echo -e "${RED}Порт $PORT ЗАКРЫТ.${NC}"
        fi
        ;;
    uninstall)
        echo -e "${RED}${BOLD}!!! ВНИМАНИЕ !!!${NC}"
        read -p "Вы уверены, что хотите ПОЛНОСТЬЮ удалить MTProxy? [y/N]: " confirm
        if [[ "$confirm" =~ ^[Yy]$ ]]; then
            systemctl stop mtproxy
            systemctl disable mtproxy
            rm -f /etc/systemd/system/mtproxy.service
            rm -rf /opt/mtproxy
            rm -f /usr/local/bin/mtproxy
            echo -e "${GREEN}MTProxy полностью удален.${NC}"
        fi
        ;;
    config|help|*)
        show_dashboard
        echo -e "${YELLOW}Доступные команды:${NC} mtproxy {status|logs|restart|check|uninstall}"
        ;;
esac
EOF

chmod +x $CLI_PATH

echo -e "\n${GREEN}================================================================${NC}"
echo -e "${BOLD}${GREEN}Установка успешно завершена!${NC}"
echo -e "Просто введите ${CYAN}mtproxy${NC} для просмотра всех данных."
echo -e "${GREEN}================================================================${NC}"

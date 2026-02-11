#!/bin/bash

# =================================================================
# Telegram MTProxy Installer (Native C++ Version)
# =================================================================

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
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

clear
echo -e "${BLUE}================================================================${NC}"
echo -e "${BLUE}     Установка Telegram MTProxy (Нативная компиляция)           ${NC}"
echo -e "${BLUE}================================================================${NC}"
echo ""

# Функционал проверки порта извне
check_external_port() {
    local port=$1
    echo -e "${YELLOW}Подготовка к проверке порта $port из интернета...${NC}"
    sleep 2 # Даем сервису время подняться
    
    # Используем API portchecktool.com или подобные через curl
    # Для простоты используем tcp-test сервисы
    local res=$(curl -s "https://port-check.io/api?port=$port")
    
    if [[ "$res" == *"open"* ]] || [[ "$(curl -s --max-time 5 "https://api.hackertarget.com/ nmap/?q=$(curl -s https://api.ipify.org)?p=$port")" == *"open"* ]]; then
        return 0
    else
        # Пытаемся еще раз через другой сервис если первый упал
        return 1
    fi
}

# 1. Диагностика сети перед установкой
echo -e "${YELLOW}Шаг 1: Диагностика сети до серверов Telegram...${NC}"

TG_IPS=("91.108.56.100" "149.154.167.50" "91.108.4.100")
SUCCESS_PINGS=0

for ip in "${TG_IPS[@]}"; do
    echo -n "Проверка $ip... "
    PING_RES=$(ping -c 3 -W 2 $ip | grep 'avg' | awk -F'/' '{print $5}')
    if [ ! -z "$PING_RES" ]; then
        echo -e "${GREEN}OK (${PING_RES} ms)${NC}"
        SUCCESS_PINGS=$((SUCCESS_PINGS+1))
    else
        echo -e "${RED}FAIL${NC}"
    fi
done

if [ "$SUCCESS_PINGS" -eq 0 ]; then
    echo -e "${RED}ВНИМАНИЕ: Все тесты пинга провалились. Возможно, сервер имеет плохую связность с Telegram.${NC}"
    read -p "Продолжить установку все равно? [y/N]: " choice
    [[ "$choice" =~ ^[Yy]$ ]] || exit 1
else
    echo -e "${GREEN}Диагностика завершена успешно ($SUCCESS_PINGS/3 серверов ответили).${NC}"
fi
echo ""

# 2. Сбор данных
echo -e "${YELLOW}Шаг 2: Настройка параметров${NC}"

# Порт
read -p "Введите порт для прокси [по умолчанию 443]: " PROXY_PORT
PROXY_PORT=${PROXY_PORT:-443}

# Домен
read -p "Укажите домен (например, proxy.example.com) [оставьте пустым для авто-IP]: " PROXY_DOMAIN
if [ -z "$PROXY_DOMAIN" ]; then
    PROXY_IP=$(curl -s https://api.ipify.org)
    echo -e "Автоматически определен IP: ${GREEN}$PROXY_IP${NC}"
else
    PROXY_IP=$PROXY_DOMAIN
    echo -e "Используется домен: ${GREEN}$PROXY_DOMAIN${NC}"
fi

# AD TAG
echo -e "\n📢 Настройка продвижения канала (AD TAG):"
echo "1) Установить тег сейчас (нужна строка из 32 символов)"
echo "2) Настроить позже (через @MTProxybot для статистики)"
read -p "Ваш выбор [1/2, по умолчанию 2]: " TAG_CHOICE
TAG_CHOICE=${TAG_CHOICE:-2}

AD_TAG=""
if [ "$TAG_CHOICE" == "1" ]; then
    read -p "Введите тег (hex): " AD_TAG
fi

echo ""

# 3. Установка зависимостей
echo -e "${YELLOW}Шаг 3: Установка зависимостей и инструментов сборки...${NC}"
apt-get update
apt-get install -y git curl build-essential libssl-dev zlib1g-dev ufw firewalld iptables-persistent xxd

# 4. Компиляция
echo -e "${YELLOW}Шаг 4: Клонирование и компиляция MTProxy (это может занять время)...${NC}"
mkdir -p $BASE_DIR
cd $BASE_DIR
if [ ! -d "source" ]; then
    git clone https://github.com/TelegramMessenger/MTProxy source
fi
cd source
make -j$(nproc)
cp objs/bin/mtproto-proxy $BIN_PATH

# 5. Генерация секрета
echo -e "${YELLOW}Шаг 5: Генерация секретного ключа...${NC}"
PROXY_SECRET=$(head -c 16 /dev/urandom | xxd -ps)
echo -e "Ваш секрет: ${GREEN}$PROXY_SECRET${NC}"

# 6. Создание пользователя
id -u mtproxy &>/dev/null || useradd -r -M -s /bin/false mtproxy
chown mtproxy:mtproxy $BIN_PATH

# 7. Получение конфигов Telegram
echo -e "${YELLOW}Шаг 6: Загрузка конфигурации прокси...${NC}"
curl -s https://core.telegram.org/getProxySecret -o $BASE_DIR/proxy-secret
curl -s https://core.telegram.org/getProxyConfig -o $BASE_DIR/proxy-multi.conf

# 8. Настройка Firewall (Умная адаптация)
echo -e "${YELLOW}Шаг 7: Автоматическая настройка Firewall (порт $PROXY_PORT)...${NC}"

# UFW
if command -v ufw > /dev/null && systemctl is-active --quiet ufw; then
    ufw allow $PROXY_PORT/tcp
    echo -e "${GREEN}[UFW] Порт $PROXY_PORT открыт.${NC}"
fi

# Firewalld
if command -v firewall-cmd > /dev/null && systemctl is-active --quiet firewalld; then
    firewall-cmd --permanent --add-port=$PROXY_PORT/tcp
    firewall-cmd --reload
    echo -e "${GREEN}[Firewalld] Порт $PROXY_PORT открыт.${NC}"
fi

# iptables (прямой проброс и сохранение)
iptables -C INPUT -p tcp --dport $PROXY_PORT -j ACCEPT 2>/dev/null || iptables -I INPUT -p tcp --dport $PROXY_PORT -j ACCEPT
if command -v netfilter-persistent > /dev/null; then
    netfilter-persistent save
fi
echo -e "${GREEN}[iptables] Правила обновлены и сохранены.${NC}"

# 9. Создание службы systemd
echo -e "${YELLOW}Шаг 8: Создание службы systemd...${NC}"

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
ExecStart=$BIN_PATH -u mtproxy -p 8888 -H $PROXY_PORT -S $PROXY_SECRET --aes-pwd proxy-secret proxy-multi.conf -M 1 $TAG_ARG
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable $SERVICE_NAME
systemctl restart $SERVICE_NAME

# 10. ФИНАЛЬНАЯ ПРОВЕРКА ПОРТА ИЗВНЕ
echo -e "${YELLOW}Шаг 9: Проверка доступности порта из интернета...${NC}"
if check_external_port $PROXY_PORT; then
    echo -e "${GREEN}УСПЕХ: Порт $PROXY_PORT доступен извне! Прокси готов к работе.${NC}"
else
    echo -e "${RED}ВНИМАНИЕ: Порт $PROXY_PORT закрыт для внешних подключений.${NC}"
    echo -e "${YELLOW}Вероятная причина: Порт заблокирован в панели управления вашего облачного хостинга (AWS, Google Cloud, Azure, Oracle и др.).${NC}"
    echo -e "${YELLOW}Пожалуйста, зайдите в настройки 'Security Groups' или 'Firewall' вашего хостинга и разрешите входящий TCP трафик на порт $PROXY_PORT.${NC}"
fi

# 11. Создание команды управления
echo -e "${YELLOW}Шаг 10: Создание команды управления 'mtproxy'...${NC}"

cat <<'EOF' > $CLI_PATH
#!/bin/bash
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

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
        PORT=$(systemctl cat mtproxy | grep -oP '(?<=-H )[0-9]+' | head -1)
        echo -e "Проверка порта $PORT..."
        if curl -s "https://port-check.io/api?port=$PORT" | grep -q "open"; then
            echo -e "${GREEN}Порт $PORT открыт.${NC}"
        else
            echo -e "${RED}Порт $PORT ЗАКРЫТ.${NC}"
            echo -e "${YELLOW}Проверьте настройки Firewall в панели управления вашего провайдера хостинга.${NC}"
        fi
        ;;
    config)
        SECRET=$(systemctl cat mtproxy | grep -oP '(?<=-S )[a-f0-9]+' | head -1)
        PORT=$(systemctl cat mtproxy | grep -oP '(?<=-H )[0-9]+' | head -1)
        IP=$(curl -s https://api.ipify.org)
        echo -e "${BLUE}Данные для подключения:${NC}"
        echo -e "IP/Домен: ${GREEN}$IP${NC}"
        echo -e "Порт: ${GREEN}$PORT${NC}"
        echo -e "Секрет: ${GREEN}$SECRET${NC}"
        echo ""
        echo -e "Ссылка: ${BLUE}tg://proxy?server=$IP&port=$PORT&secret=$SECRET${NC}"
        ;;
    test)
        echo "Запуск пинг-тестов до Telegram..."
        ips=("91.108.56.100" "149.154.167.50" "91.108.4.100")
        for ip in "${ips[@]}"; do
            ping -c 3 $ip
        done
        ;;
    *)
        echo "Использование: mtproxy {status|logs|restart|config|test|check}"
        exit 1
esac
EOF

chmod +x $CLI_PATH

echo -e "\n${GREEN}================================================================${NC}"
echo -e "${GREEN}Установка завершена!${NC}"
echo -e "Используйте команду ${BLUE}mtproxy config${NC} для получения ссылки."
echo -e "Для проверки доступности порта извне: ${BLUE}mtproxy check${NC}"
echo -e "${GREEN}================================================================${NC}"

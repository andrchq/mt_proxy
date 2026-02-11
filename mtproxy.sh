#!/bin/bash

# Скрипт установки MTProxy (Финальная версия)
# Создает сервис systemd с кастомным портом, сохраняет секреты в info.txt
# и создает утилиту управления в /usr/local/bin/mtproxy
#
# Использование:
#   ./mtproxy.sh          - Установить MTProxy
#   ./mtproxy.sh uninstall - Полностью удалить MTProxy

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# Функция для вывода красивого заголовка в рамке
print_header() {
    local title="$1"
    local color="${2:-$BLUE}"
    echo -e "${color}╔════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${color}║$(printf '%*s' $(( (60 - ${#title}) / 2 )) '')${BOLD}${title}${NC}${color}$(printf '%*s' $(( (60 - ${#title} + 1) / 2 )) '')║${NC}"
    echo -e "${color}╚════════════════════════════════════════════════════════════╝${NC}"
}

# Функция для вывода этапа
print_step() {
    echo -e "\n${CYAN}--- [ $1 ] ---${NC}"
}

clear

# Требуется root
if [[ $EUID -ne 0 ]]; then
    print_header "ОШИБКА ДОСТУПА" "${RED}"
    echo -e "${RED}Этот установщик должен быть запущен от имени root (используйте sudo).${NC}"
    exit 1
fi

# Проверка опции удаления
if [[ "$1" == "uninstall" ]]; then
    if [[ -f "/usr/local/bin/mtproxy" ]]; then
        /usr/local/bin/mtproxy uninstall
        exit $?
    fi

    print_header "УДАЛЕНИЕ MTProxy" "${YELLOW}"
    
    echo -e "${RED}ВНИМАНИЕ: Это полностью удалит MTProxy и все связанные файлы!${NC}"
    echo -e "${YELLOW}Будет удалено следующее:${NC}"
    echo -e "  • Сервис: /etc/systemd/system/mtproxy.service"
    echo -e "  • Директория установки: /opt/MTProxy"
    echo -e "  • Утилита управления: /usr/local/bin/mtproxy"
    echo -e "  • Все конфигурационные файлы и секреты"
    echo ""
    
    read -p "Вы уверены, что хотите продолжить? (введите 'YES' для подтверждения): " CONFIRM
    
    if [[ "$CONFIRM" != "YES" ]]; then
        echo -e "${GREEN}Удаление отменено.${NC}"
        exit 0
    fi
    
    print_step "Остановка и удаление компонентов"
    
    if systemctl is-active --quiet mtproxy; then
        echo -e "${YELLOW}Остановка сервиса MTProxy...${NC}"
        systemctl stop mtproxy
    fi
    
    if systemctl is-enabled --quiet mtproxy 2>/dev/null; then
        echo -e "${YELLOW}Отключение автозагрузки сервиса MTProxy...${NC}"
        systemctl disable mtproxy
    fi
    
    if [[ -f "/etc/systemd/system/mtproxy.service" ]]; then
        echo -e "${YELLOW}Удаление файла сервиса...${NC}"
        rm -f "/etc/systemd/system/mtproxy.service"
        systemctl daemon-reload
    fi
    
    if [[ -d "/opt/MTProxy" ]]; then
        echo -e "${YELLOW}Удаление директории установки...${NC}"
        rm -rf "/opt/MTProxy"
    fi
    
    if [[ -f "/usr/local/bin/mtproxy" ]]; then
        echo -e "${YELLOW}Удаление утилиты управления...${NC}"
        rm -f "/usr/local/bin/mtproxy"
    fi
    
    if command -v ufw &> /dev/null && ufw status | grep -q "Status: active"; then
        echo -e "${YELLOW}Очистка правил брандмауэра...${NC}"
        for port in 8080 8443 9443 1080 3128; do
            if ufw status | grep -q "${port}/tcp"; then
                ufw delete allow ${port}/tcp 2>/dev/null
            fi
        done
    fi
    
    print_header "MTProxy УДАЛЕН" "${GREEN}"
    exit 0
fi

print_header "УСТАНОВКА MTProxy" "${BLUE}"

# Конфигурация
INSTALL_DIR="/opt/MTProxy"
SERVICE_NAME="mtproxy"
DEFAULT_PORT=9443
DEFAULT_CHANNEL="vsemvpn_com"

print_step "Этап 1: Базовая настройка"
read -p "Введите порт прокси (по умолчанию: $DEFAULT_PORT): " USER_PORT
PORT=${USER_PORT:-$DEFAULT_PORT}

# Канал по умолчанию
CHANNEL_TAG="vsemvpn_com"

print_step "Этап 2: Подготовка системы"
if command -v apt >/dev/null 2>&1; then
    echo -e "${YELLOW}Обновление пакетов и установка зависимостей...${NC}"
    apt update -qq
    apt install -y git curl python3 python3-pip xxd || apt install -y vim-common
else
    echo -e "${RED}apt не найден. Установите зависимости вручную: git, curl, python3, xxd.${NC}"
    exit 1
fi

print_step "Этап 3: Установка файлов"
mkdir -p $INSTALL_DIR
cd $INSTALL_DIR
systemctl stop mtproxy 2>/dev/null

echo -e "${YELLOW}Загрузка Python MTProxy...${NC}"
if curl -s -L "https://raw.githubusercontent.com/alexbers/mtprotoproxy/master/mtprotoproxy.py" -o mtprotoproxy.py; then
    chmod +x mtprotoproxy.py
    echo -e "${GREEN}Файлы успешно загружены${NC}"
else
    echo -e "${RED}Ошибка загрузки!${NC}"
    exit 1
fi

print_step "Этап 4: Безопасность и Сеть"
if [[ -f "/opt/MTProxy/info.txt" ]] && grep -q "Base Secret:" /opt/MTProxy/info.txt; then
    USER_SECRET=$(grep "Base Secret:" /opt/MTProxy/info.txt | awk '{print $3}')
    echo -e "${GREEN}Используется прежний секрет: $USER_SECRET${NC}"
else
    USER_SECRET=$(head -c 16 /dev/urandom | xxd -ps)
    echo -e "${GREEN}Сгенерирован новый секрет: $USER_SECRET${NC}"
fi

echo -e "${YELLOW}Определение внешнего IPv4...${NC}"
EXTERNAL_IP=""
for service in "ipv4.icanhazip.com" "ipv4.ident.me" "api.ipify.org"; do
    EXTERNAL_IP=$(curl -4 -s --connect-timeout 5 "$service" 2>/dev/null)
    [[ $EXTERNAL_IP =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]] && break
    EXTERNAL_IP=""
done
[[ -z "$EXTERNAL_IP" ]] && EXTERNAL_IP="YOUR_SERVER_IP"
echo -e "${GREEN}Ваш IP: $EXTERNAL_IP${NC}"

print_step "Этап 5: Конфигурация домена"
echo -e "${CYAN}Вы можете указать доменное имя (например, proxy.example.com)${NC}"
read -p "Введите домен (пусто для IP): " USER_DOMAIN
PROXY_HOST=${USER_DOMAIN:-$EXTERNAL_IP}

print_step "Этап 6: Настройка TLS-маскировки"
TLS_DOMAINS=("github.com" "cloudflare.com" "microsoft.com" "amazon.com" "wikipedia.org" "reddit.com")
RANDOM_DOMAIN=${TLS_DOMAINS[$RANDOM % ${#TLS_DOMAINS[@]}]}
read -p "TLS-домен для маскировки (по умолчанию: $RANDOM_DOMAIN): " USER_TLS_DOMAIN
TLS_DOMAIN=${USER_TLS_DOMAIN:-$RANDOM_DOMAIN}
echo -e "${GREEN}Используется маскировка под: $TLS_DOMAIN${NC}"

print_step "Этап 7: Создание системного сервиса"
cat > "/etc/systemd/system/$SERVICE_NAME.service" << EOL
[Unit]
Description=MTProxy Telegram Proxy
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=$INSTALL_DIR
ExecStart=python3 $INSTALL_DIR/mtprotoproxy.py $PORT $USER_SECRET
Environment=TAG=$CHANNEL_TAG
Environment=TLS_DOMAIN=$TLS_DOMAIN
Environment=MASK_HOST=$TLS_DOMAIN
Environment=FAKE_TLS_DOMAIN=$TLS_DOMAIN
Environment=USERS_FILE=$INSTALL_DIR/users.txt
Restart=always
RestartSec=10
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOL

# Настройка файрвола
if command -v ufw &> /dev/null && ufw status | grep -q "Status: active"; then
    ufw allow $PORT/tcp >/dev/null
fi

print_step "Завершение: Утилита управления"
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
SERVICE_NAME="mtproxy"

print_header() {
    local title="$1"
    local color="${2:-$BLUE}"
    echo -e "${color}╔════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${color}║$(printf '%*s' $(( (60 - ${#title}) / 2 )) '')${BOLD}${title}${NC}${color}$(printf '%*s' $(( (60 - ${#title} + 1) / 2 )) '')║${NC}"
    echo -e "${color}╚════════════════════════════════════════════════════════════╝${NC}"
}

domain_to_hex() { echo -n "$1" | xxd -p | tr -d '\n'; }

get_service_config() {
    if [[ -f "/etc/systemd/system/$SERVICE_NAME.service" ]]; then
        EXEC_START=$(grep "ExecStart=" "/etc/systemd/system/$SERVICE_NAME.service" | cut -d'=' -f2-)
        PORT=$(echo "$EXEC_START" | awk '{print $(NF-1)}')
        SECRET=$(echo "$EXEC_START" | awk '{print $NF}')
        PROMOTED_CHANNEL=$(grep "Environment=TAG=" "/etc/systemd/system/$SERVICE_NAME.service" | cut -d'=' -f3)
    fi
}

get_links() {
    get_service_config
    # Детекция хоста
    if [[ -f "$INSTALL_DIR/info.txt" ]]; then
        PROXY_HOST=$(grep "Хост прокси:" "$INSTALL_DIR/info.txt" | awk '{print $3}')
    fi
    [[ -z "$PROXY_HOST" ]] && PROXY_HOST=$(curl -4 -s ifconfig.me)
    
    TLS_DOMAIN=$(grep "Environment=TLS_DOMAIN=" /etc/systemd/system/mtproxy.service | cut -d'=' -f3)
    TLS_HEX=$(domain_to_hex "${TLS_DOMAIN:-github.com}")
    
    PLAIN_LINK="tg://proxy?server=$PROXY_HOST&port=$PORT&secret=${SECRET}"
    DD_LINK="tg://proxy?server=$PROXY_HOST&port=$PORT&secret=dd${SECRET}"
    EE_LINK="tg://proxy?server=$PROXY_HOST&port=$PORT&secret=ee${SECRET}${TLS_HEX}"
}

case "${1:-status}" in
    "status")
        clear
        print_header "СТАТУС MTProxy" "${BLUE}"
        if systemctl is-active --quiet $SERVICE_NAME; then
            echo -e "${GREEN}✅ Сервис: Активен и работает${NC}"
            get_links
            echo -e "\n${YELLOW}📊 Конфигурация:${NC}"
            echo -e "   Порт:   $PORT"
            echo -e "   Канал:  @${PROMOTED_CHANNEL:-$CHANNEL_TAG}"
            
            echo -e "\n${YELLOW}🤖 Регистрация в @MTProxybot:${NC}"
            echo -e "   Для продвижения канала зарегистрируйте прокси:"
            echo -e "   1. Отправьте /newproxy боту ${CYAN}@MTProxybot${NC}"
            echo -e "   2. Хост:    ${BOLD}$PROXY_HOST${NC}"
            echo -e "   3. Порт:    ${BOLD}$PORT${NC}"
            echo -e "   4. Секрет:  ${BOLD}$SECRET${NC}"

            echo -e "\n${YELLOW}🔗 Ссылки для подключения:${NC}"
            echo -e "${CYAN}TLS (Рекомендуется):${NC} $EE_LINK"
            echo -e "${CYAN}DD (Legacy):${NC}        $DD_LINK"
            echo -e "${CYAN}Обычная:${NC}            $PLAIN_LINK"
        else
            echo -e "${RED}❌ Сервис: Остановлен${NC}"
        fi
        ;;
    "start"|"stop"|"restart")
        clear
        print_header "КОМАНДА: $1" "${YELLOW}"
        systemctl $1 $SERVICE_NAME
        echo -e "${GREEN}Команда выполнена успешно.${NC}"
        ;;
    "links")
        clear
        print_header "ССЫЛКИ MTProxy" "${CYAN}"
        get_links
        echo -e "$EE_LINK\n$DD_LINK\n$PLAIN_LINK"
        ;;
    "logs")
        clear
        print_header "ЛОГИ MTProxy" "${YELLOW}"
        journalctl -u $SERVICE_NAME -f
        ;;
    "uninstall")
        clear
        print_header "УДАЛЕНИЕ MTProxy" "${RED}"
        read -p "Вы уверены? (YES): " CONFIRM
        [[ "$CONFIRM" != "YES" ]] && exit 0
        systemctl stop $SERVICE_NAME; systemctl disable $SERVICE_NAME
        rm -f "/etc/systemd/system/$SERVICE_NAME.service"
        rm -rf "$INSTALL_DIR"
        rm -f "/usr/local/bin/mtproxy"
        systemctl daemon-reload
        echo -e "${GREEN}Удалено.${NC}"
        ;;
    *)
        clear
        print_header "СПРАВКА mtproxy" "${BLUE}"
        echo -e "Команды: status, start, stop, restart, links, logs, uninstall"
        ;;
esac
UTILITY_EOF

mv "/tmp/mtproxy_utility" "/usr/local/bin/mtproxy"
chmod +x "/usr/local/bin/mtproxy"

print_step "Запуск сервиса"
systemctl daemon-reload
systemctl enable $SERVICE_NAME
systemctl start $SERVICE_NAME

sleep 2
clear
/usr/local/bin/mtproxy status

print_header "УСТАНОВКА ЗАВЕРШЕНА" "${GREEN}"
echo -e "\n${BLUE}Управляйте прокси командой: ${BOLD}mtproxy${NC}"
echo -e "${BLUE}Информация сохранена в: ${BOLD}$INSTALL_DIR/info.txt${NC}"

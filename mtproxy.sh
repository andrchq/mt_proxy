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

# Функция для вывода этапа в читаемом виде
print_step() {
    local number="$1"
    local title="$2"
    echo -e "\n${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}${BOLD}ЭТАП ${number}.${NC} ${BOLD}${title}${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

# Вопрос с дефолтным значением: Enter принимает значение по умолчанию
ask_with_default() {
    local prompt="$1"
    local default_value="$2"
    local result
    read -p "${prompt} [Enter = ${default_value}]: " result </dev/tty
    echo "${result:-$default_value}"
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
    
    read -p "Вы уверены, что хотите продолжить? [введите YES для подтверждения, Enter = отмена]: " CONFIRM </dev/tty
    
    if [[ "$CONFIRM" != "YES" ]]; then
        echo -e "${GREEN}Удаление отменено.${NC}"
        exit 0
    fi
    
    print_step "U1" "Остановка и удаление компонентов"
    
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

print_step "1" "Базовая настройка"
PORT=$(ask_with_default "Введите порт прокси" "$DEFAULT_PORT")
if ! [[ "$PORT" =~ ^[0-9]+$ ]] || ((PORT < 1 || PORT > 65535)); then
    echo -e "${RED}Некорректный порт: $PORT. Допустимы значения 1-65535.${NC}"
    exit 1
fi

# Канал по умолчанию
CHANNEL_TAG="$DEFAULT_CHANNEL"

print_step "2" "Подготовка системы"
if command -v apt >/dev/null 2>&1; then
    echo -e "${YELLOW}Обновление пакетов и установка зависимостей...${NC}"
    apt update -qq
    apt install -y git curl python3 python3-pip vim-common
else
    echo -e "${RED}apt не найден. Установите зависимости вручную: git, curl, python3, xxd.${NC}"
    exit 1
fi

print_step "3" "Установка файлов"
mkdir -p "$INSTALL_DIR"
cd "$INSTALL_DIR" || {
    echo -e "${RED}Не удалось перейти в директорию $INSTALL_DIR${NC}"
    exit 1
}
systemctl stop mtproxy 2>/dev/null

echo -e "${YELLOW}Загрузка Python MTProxy...${NC}"
if curl -s -L "https://raw.githubusercontent.com/alexbers/mtprotoproxy/master/mtprotoproxy.py" -o mtprotoproxy.py; then
    chmod +x mtprotoproxy.py
    echo -e "${GREEN}Файлы успешно загружены${NC}"
else
    echo -e "${RED}Ошибка загрузки!${NC}"
    exit 1
fi

print_step "4" "Безопасность и сеть"
if [[ -f "$INSTALL_DIR/info.txt" ]] && grep -q "Base Secret:" "$INSTALL_DIR/info.txt"; then
    USER_SECRET=$(grep -m1 "Base Secret:" "$INSTALL_DIR/info.txt" | awk '{print $3}')
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

print_step "5" "Конфигурация домена"
echo -e "${CYAN}Вы можете указать доменное имя (например, proxy.example.com).${NC}"
PROXY_HOST=$(ask_with_default "Введите домен или IP хоста прокси" "$EXTERNAL_IP")

print_step "6" "Настройка TLS-маскировки"
TLS_DOMAINS=("github.com" "cloudflare.com" "microsoft.com" "amazon.com" "wikipedia.org" "reddit.com")
RANDOM_DOMAIN=${TLS_DOMAINS[$RANDOM % ${#TLS_DOMAINS[@]}]}
TLS_DOMAIN=$(ask_with_default "TLS-домен для маскировки" "$RANDOM_DOMAIN")
echo -e "${GREEN}Используется маскировка под: $TLS_DOMAIN${NC}"

print_step "7" "Создание systemd-сервиса"
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

DOMAIN_HEX=$(echo -n "$TLS_DOMAIN" | xxd -p | tr -d '\n')
cat > "$INSTALL_DIR/info.txt" << EOL
MTProxy Installation Information
===============================
Дата установки: $(date '+%Y-%m-%d %H:%M:%S')
Хост прокси: $PROXY_HOST
Порт: $PORT
Base Secret: $USER_SECRET
TLS Domain: $TLS_DOMAIN

Ссылки подключения:
TLS (ee): tg://proxy?server=$PROXY_HOST&port=$PORT&secret=ee${USER_SECRET}${DOMAIN_HEX}
DD (dd):  tg://proxy?server=$PROXY_HOST&port=$PORT&secret=dd${USER_SECRET}
Plain:    tg://proxy?server=$PROXY_HOST&port=$PORT&secret=${USER_SECRET}
EOL

# Настройка файрвола
if command -v ufw &> /dev/null && ufw status | grep -q "Status: active"; then
    ufw allow "$PORT"/tcp >/dev/null
fi

print_step "8" "Создание утилиты управления"
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
CHANNEL_TAG="vsemvpn_com"

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

get_service_config() {
    if [[ -f "/etc/systemd/system/$SERVICE_NAME.service" ]]; then
        EXEC_START=$(grep -m1 "^ExecStart=" "/etc/systemd/system/$SERVICE_NAME.service" | cut -d'=' -f2-)
        PORT=$(echo "$EXEC_START" | awk '{print $(NF-1)}')
        SECRET=$(echo "$EXEC_START" | awk '{print $NF}')
        PROMOTED_CHANNEL=$(grep -m1 "^Environment=TAG=" "/etc/systemd/system/$SERVICE_NAME.service" | cut -d'=' -f3)
        TLS_DOMAIN=$(grep -m1 "^Environment=TLS_DOMAIN=" "/etc/systemd/system/$SERVICE_NAME.service" | cut -d'=' -f3)
    fi
}

get_links() {
    get_service_config

    if [[ -f "$INSTALL_DIR/info.txt" ]]; then
        PROXY_HOST=$(grep -m1 "Хост прокси:" "$INSTALL_DIR/info.txt" | awk '{print $3}')
        INSTALL_DATE=$(grep -m1 "Дата установки:" "$INSTALL_DIR/info.txt" | cut -d':' -f2- | sed 's/^ //')
    fi
    [[ -z "$PROXY_HOST" ]] && PROXY_HOST=$(curl -4 -s --connect-timeout 5 ifconfig.me)
    [[ -z "$PROXY_HOST" ]] && PROXY_HOST="N/A"

    TLS_HEX=$(domain_to_hex "${TLS_DOMAIN:-github.com}")

    PLAIN_LINK="tg://proxy?server=$PROXY_HOST&port=$PORT&secret=${SECRET}"
    DD_LINK="tg://proxy?server=$PROXY_HOST&port=$PORT&secret=dd${SECRET}"
    EE_LINK="tg://proxy?server=$PROXY_HOST&port=$PORT&secret=ee${SECRET}${TLS_HEX}"
}

show_help() {
    print_block "📚 Подсказка по командам"
    echo -e " ${BOLD}mtproxy${NC}            — открыть дашборд"
    echo -e " ${BOLD}mtproxy dashboard${NC}  — открыть дашборд"
    echo -e " ${BOLD}mtproxy start${NC}      — запустить сервис"
    echo -e " ${BOLD}mtproxy stop${NC}       — остановить сервис"
    echo -e " ${BOLD}mtproxy restart${NC}    — перезапустить сервис"
    echo -e " ${BOLD}mtproxy tls-domain${NC} — заменить TLS-домен, перезапустить и показать лог"
    echo -e " ${BOLD}mtproxy links${NC}      — вывести только ссылки подключения"
    echo -e " ${BOLD}mtproxy logs${NC}       — смотреть логи в реальном времени"
    echo -e " ${BOLD}mtproxy uninstall${NC}  — удалить MTProxy"
}

change_tls_domain() {
    local service_file="/etc/systemd/system/$SERVICE_NAME.service"
    local current_tls new_tls

    if [[ ! -f "$service_file" ]]; then
        echo -e "${RED}Не найден файл сервиса: $service_file${NC}"
        exit 1
    fi

    current_tls=$(grep -m1 "^Environment=TLS_DOMAIN=" "$service_file" | cut -d'=' -f3)
    [[ -z "$current_tls" ]] && current_tls="github.com"

    echo -e "${CYAN}Текущий TLS-домен:${NC} ${BOLD}$current_tls${NC}"
    read -p "Введите новый TLS-домен [Enter = $current_tls]: " new_tls </dev/tty
    new_tls=${new_tls:-$current_tls}

    if [[ ! "$new_tls" =~ ^[A-Za-z0-9.-]+$ ]]; then
        echo -e "${RED}Некорректный домен: $new_tls${NC}"
        exit 1
    fi

    sed -i "s|^Environment=TLS_DOMAIN=.*|Environment=TLS_DOMAIN=$new_tls|" "$service_file"
    sed -i "s|^Environment=MASK_HOST=.*|Environment=MASK_HOST=$new_tls|" "$service_file"
    sed -i "s|^Environment=FAKE_TLS_DOMAIN=.*|Environment=FAKE_TLS_DOMAIN=$new_tls|" "$service_file"

    if [[ -f "$INSTALL_DIR/info.txt" ]]; then
        if grep -q "^TLS Domain:" "$INSTALL_DIR/info.txt"; then
            sed -i "s|^TLS Domain:.*|TLS Domain: $new_tls|" "$INSTALL_DIR/info.txt"
        else
            echo "TLS Domain: $new_tls" >> "$INSTALL_DIR/info.txt"
        fi
    fi

    echo -e "${YELLOW}Перезагружаю systemd и перезапускаю MTProxy...${NC}"
    systemctl daemon-reload
    systemctl restart "$SERVICE_NAME"

    echo -e "${GREEN}TLS-домен обновлён: $new_tls${NC}"
    print_block "📝 Последние логи сервиса (30 строк)"
    journalctl -u "$SERVICE_NAME" -n 30 --no-pager
}

show_dashboard() {
    clear
    print_header "ДАШБОРД MTProxy" "$BLUE"
    get_links

    if systemctl is-active --quiet "$SERVICE_NAME"; then
        SERVICE_STATE="${GREEN}✅ Активен${NC}"
    else
        SERVICE_STATE="${RED}❌ Остановлен${NC}"
    fi

    print_block "📊 Состояние"
    echo -e " Сервис:          $SERVICE_STATE"
    echo -e " Порт:            ${BOLD}${PORT:-N/A}${NC}"
    echo -e " Хост:            ${BOLD}${PROXY_HOST:-N/A}${NC}"
    echo -e " Канал:           ${BOLD}@${PROMOTED_CHANNEL:-$CHANNEL_TAG}${NC}"
    echo -e " TLS-домен:       ${BOLD}${TLS_DOMAIN:-github.com}${NC}"
    echo -e " Дата установки:  ${BOLD}${INSTALL_DATE:-N/A}${NC}"

    print_block "🤖 Регистрация в @MTProxybot"
    echo -e " 1. Отправьте /newproxy боту ${CYAN}@MTProxybot${NC}"
    echo -e " 2. Хост:    ${BOLD}${PROXY_HOST:-N/A}${NC}"
    echo -e " 3. Порт:    ${BOLD}${PORT:-N/A}${NC}"
    echo -e " 4. Секрет:  ${BOLD}${SECRET:-N/A}${NC}"

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
    "start"|"stop"|"restart")
        print_header "КОМАНДА: $1" "$YELLOW"
        systemctl "$1" "$SERVICE_NAME"
        echo -e "${GREEN}Команда выполнена успешно.${NC}"
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
    "links")
        get_links
        echo -e "$EE_LINK\n$DD_LINK\n$PLAIN_LINK"
        ;;
    "logs")
        clear
        print_header "ЛОГИ MTProxy" "$YELLOW"
        journalctl -u "$SERVICE_NAME" -f
        ;;
    "uninstall")
        clear
        print_header "УДАЛЕНИЕ MTProxy" "$RED"
        read -p "Вы уверены? [введите YES для подтверждения, Enter = отмена]: " CONFIRM </dev/tty
        [[ "$CONFIRM" != "YES" ]] && exit 0
        systemctl stop "$SERVICE_NAME"; systemctl disable "$SERVICE_NAME"
        rm -f "/etc/systemd/system/$SERVICE_NAME.service"
        rm -rf "$INSTALL_DIR"
        rm -f "/usr/local/bin/mtproxy"
        systemctl daemon-reload
        echo -e "${GREEN}Удалено.${NC}"
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

print_step "9" "Запуск сервиса"
systemctl daemon-reload
systemctl enable "$SERVICE_NAME"
systemctl start "$SERVICE_NAME"

sleep 2
clear
/usr/local/bin/mtproxy

print_header "УСТАНОВКА ЗАВЕРШЕНА" "${GREEN}"
echo -e "\n${BLUE}Управляйте прокси командой: ${BOLD}mtproxy${NC}"
echo -e "${BLUE}Информация сохранена в: ${BOLD}$INSTALL_DIR/info.txt${NC}"

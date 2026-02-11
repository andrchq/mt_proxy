#!/bin/bash

# MTProxy Установочный Скрипт (Обновленный)
# Создает системную службу с пользовательским портом, сохраняет секреты в info.txt
# и создает утилиту управления в /usr/local/bin/mtp
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

echo -e "${BLUE}===================================================${NC}"
echo -e "${BLUE}       MTProxy Установка (Версия 2.0 RU)          ${NC}"
echo -e "${BLUE}===================================================${NC}\n"

# Проверка прав root
if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}Ошибка: Этот скрипт должен быть запущен от имени root (используйте sudo).${NC}"
    exit 1
fi

# Проверка аргумента удаления
if [[ "$1" == "uninstall" ]]; then
    echo -e "${YELLOW}🗑️  Удаление MTProxy${NC}\n"
    
    echo -e "${RED}ВНИМАНИЕ: Это действие полностью удалит MTProxy и все связанные файлы!${NC}"
    echo -e "${YELLOW}Будут удалены:${NC}"
    echo -e "  • Служба: /etc/systemd/system/mtproxy.service"
    echo -e "  • Папка установки: /opt/MTProxy"
    echo -e "  • Утилита управления: /usr/local/bin/mtp"
    echo -e "  • Все конфигурационные файлы и секреты"
    echo ""
    
    read -p "Вы уверены, что хотите продолжить? (введите 'DA' для подтверждения): " CONFIRM
    
    if [[ "$CONFIRM" != "DA" && "$CONFIRM" != "YES" ]]; then
        echo -e "${GREEN}Удаление отменено.${NC}"
        exit 0
    fi
    
    echo -e "\n${YELLOW}Удаление компонентов...${NC}"
    
    # Остановка и отключение службы
    if systemctl is-active --quiet mtproxy; then
        echo -e "${YELLOW}Остановка службы MTProxy...${NC}"
        systemctl stop mtproxy
    fi
    
    if systemctl is-enabled --quiet mtproxy 2>/dev/null; then
        echo -e "${YELLOW}Отключение автозагрузки...${NC}"
        systemctl disable mtproxy
    fi
    
    # Удаление файла службы
    if [[ -f "/etc/systemd/system/mtproxy.service" ]]; then
        rm -f "/etc/systemd/system/mtproxy.service"
        systemctl daemon-reload
    fi
    
    # Удаление папки установки
    if [[ -d "/opt/MTProxy" ]]; then
        rm -rf "/opt/MTProxy"
    fi
    
    # Удаление утилиты управления (старой и новой)
    if [[ -f "/usr/local/bin/mtp" ]]; then
        rm -f "/usr/local/bin/mtp"
    fi
    if [[ -f "/usr/local/bin/mtproxy" ]]; then
        rm -f "/usr/local/bin/mtproxy"
    fi
    
    # Удаление правил фаервола (если UFW активен)
    if command -v ufw &> /dev/null && ufw status | grep -q "Status: active"; then
        echo -e "${YELLOW}Проверка правил фаервола...${NC}"
        # Пытаемся удалить стандартные порты
        for port in 8080 8443 9443 1080 3128; do
            if ufw status | grep -q "${port}/tcp"; then
                echo -e "${YELLOW}Удаление правила для порта $port...${NC}"
                ufw delete allow ${port}/tcp 2>/dev/null
            fi
        done
    fi
    
    echo -e "\n${GREEN}✅ MTProxy был полностью удален!${NC}"
    exit 0
fi

# Проверка help
if [[ "$1" == "help" || "$1" == "-h" || "$1" == "--help" ]]; then
    echo -e "${BLUE}Скрипт установки MTProxy${NC}\n"
    echo "Использование:"
    echo -e "  ${GREEN}$0${NC}              - Установить MTProxy (интерактивно)"
    echo -e "  ${GREEN}$0 uninstall${NC}    - Полностью удалить MTProxy"
    echo -e "  ${GREEN}$0 help${NC}         - Показать эту справку"
    echo ""
    exit 0
fi

# Конфигурация
INSTALL_DIR="/opt/MTProxy"
SERVICE_NAME="mtproxy"
DEFAULT_PORT=9443
DEFAULT_CHANNEL="vsemvpn_com"

# Получение ввода от пользователя
echo -e "${CYAN}--- Настройка Порта ---${NC}"
read -p "Введите порт для прокси (по умолчанию: $DEFAULT_PORT): " USER_PORT
PORT=${USER_PORT:-$DEFAULT_PORT}

echo -e "\n${CYAN}--- Настройка Продвижения Канала ---${NC}"
echo -e "${YELLOW}💡 Подсказка:${NC} Вы можете рекламировать свой Telegram канал пользователям прокси."
read -p "Введите юзернейм канала/бота для промо (по умолчанию: $DEFAULT_CHANNEL, пусто для отмены): " USER_CHANNEL
CHANNEL_TAG=${USER_CHANNEL:-$DEFAULT_CHANNEL}

if [[ "$CHANNEL_TAG" == "$DEFAULT_CHANNEL" ]]; then
    echo -e "${GREEN}Используется канал по умолчанию: @$CHANNEL_TAG${NC}"
elif [[ -z "$CHANNEL_TAG" ]]; then
    CHANNEL_TAG=""
    echo -e "${YELLOW}Канал для промо не задан.${NC}"
else
    echo -e "${GREEN}Выбран канал: @$CHANNEL_TAG${NC}"
fi

echo -e "\n${YELLOW}🚀 Начало установки...${NC}"

# Установка зависимостей
echo -e "${YELLOW}Установка необходимых пакетов...${NC}"
if command -v apt >/dev/null 2>&1; then
    apt update -qq
    apt install -y git curl python3 python3-pip xxd || apt install -y vim-common
else
    echo -e "${RED}Ошибка: apt не найден. Скрипт поддерживает Debian/Ubuntu.${NC}"
    exit 1
fi

# Создание директорий
mkdir -p $INSTALL_DIR
cd $INSTALL_DIR

# Остановка текущей службы если есть
systemctl stop mtproxy 2>/dev/null

# Скачивание Python MTProxy
echo -e "${YELLOW}Скачивание компонентов прокси...${NC}"
if curl -s -L "https://raw.githubusercontent.com/alexbers/mtprotoproxy/master/mtprotoproxy.py" -o mtprotoproxy.py; then
    chmod +x mtprotoproxy.py
    echo -e "${GREEN}Компоненты успешно загружены.${NC}"
else
    echo -e "${RED}Ошибка при загрузке MTProxy${NC}"
    exit 1
fi

# Генерация или чтение секрета
if [[ -f "/opt/MTProxy/info.txt" ]] && grep -q "Base Secret:" /opt/MTProxy/info.txt; then
    USER_SECRET=$(grep "Base Secret:" /opt/MTProxy/info.txt | awk '{print $3}')
    echo -e "${GREEN}Используется существующий секрет.${NC}"
else
    USER_SECRET=$(head -c 16 /dev/urandom | xxd -ps)
    echo -e "${GREEN}Сгенерирован новый секрет.${NC}"
fi

# Получение внешнего IP
echo -e "${YELLOW}Определение внешнего IP...${NC}"
EXTERNAL_IP=""
for service in "ipv4.icanhazip.com" "ipv4.ident.me" "ifconfig.me/ip" "api.ipify.org"; do
    if EXTERNAL_IP=$(curl -4 -s --connect-timeout 10 "$service" 2>/dev/null) && [[ -n "$EXTERNAL_IP" ]]; then
         if [[ $EXTERNAL_IP =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            break
         fi
    fi
    EXTERNAL_IP=""
done

if [[ -z "$EXTERNAL_IP" ]]; then
    EXTERNAL_IP="ВАШ_IP_АДРЕС"
    echo -e "${RED}Не удалось определить IP автоматически.${NC}"
else
    echo -e "${GREEN}Ваш IP: $EXTERNAL_IP${NC}"
fi

# Настройка домена
echo -e "\n${CYAN}--- Настройка Домена (Опционально) ---${NC}"
echo -e "${YELLOW}💡 Подсказка:${NC} Использование домена вместо IP повышает доверие и удобство."
echo -e "Если у вас есть домен, направленный на этот сервер ($EXTERNAL_IP), введите его ниже."
read -p "Введите доменное имя (или Enter, чтобы использовать IP): " USER_DOMAIN

if [[ -n "$USER_DOMAIN" ]]; then
    if [[ $USER_DOMAIN =~ ^[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?)*$ ]]; then
        PROXY_HOST="$USER_DOMAIN"
        echo -e "${GREEN}Выбран домен: $PROXY_HOST${NC}"
        
        # Проверка DNS
        echo -e "${YELLOW}Проверка DNS записей...${NC}"
        DOMAIN_IP=$(getent ahostsv4 "$PROXY_HOST" 2>/dev/null | awk '/STREAM/ {print $1; exit}')
        
        if [[ -n "$DOMAIN_IP" && -n "$EXTERNAL_IP" && "$DOMAIN_IP" != "$EXTERNAL_IP" ]]; then
            echo -e "${RED}⚠️  ВНИМАНИЕ: Домен $PROXY_HOST ($DOMAIN_IP) не указывает на этот сервер ($EXTERNAL_IP)!${NC}"
            echo -e "${YELLOW}Вам нужно настроить A-запись у вашего регистратора домена.${NC}"
        elif [[ -z "$DOMAIN_IP" ]]; then
             echo -e "${RED}⚠️  ВНИМАНИЕ: Не удалось разрешить IP для домена $PROXY_HOST.${NC}"
        else
            echo -e "${GREEN}✅ DNS настроен корректно.${NC}"
        fi
    else
        echo -e "${RED}Некорректный формат домена. Будет использован IP.${NC}"
        PROXY_HOST="$EXTERNAL_IP"
    fi
else
    PROXY_HOST="$EXTERNAL_IP"
    echo -e "${GREEN}Используется IP адрес.${NC}"
fi

# Настройка Fake TLS
echo -e "\n${CYAN}--- Настройка Маскировки (Fake TLS) ---${NC}"
echo -e "${YELLOW}💡 Подсказка:${NC} Прокси маскируется под популярный сайт, чтобы избежать блокировок."
TLS_DOMAINS=("github.com" "cloudflare.com" "microsoft.com" "amazon.com" "google.com")
RANDOM_DOMAIN=${TLS_DOMAINS[$RANDOM % ${#TLS_DOMAINS[@]}]}
read -p "Введите домен для маскировки (по умолчанию: $RANDOM_DOMAIN): " USER_TLS_DOMAIN
TLS_DOMAIN=${USER_TLS_DOMAIN:-$RANDOM_DOMAIN}

# Создание info.txt
cat > "$INSTALL_DIR/info.txt" << EOL
MTProxy Информация
==================
Дата установки: $(date)
Порт: $PORT
Канал: @$CHANNEL_TAG
Внешний IP: $EXTERNAL_IP
Proxy Host: $PROXY_HOST
TLS Domain (Fake): $TLS_DOMAIN
Секрет (Hex): $USER_SECRET
Статус: Установка...
EOL

# Создание systemd службы
echo -e "${YELLOW}Настройка системной службы...${NC}"
cat > "/etc/systemd/system/$SERVICE_NAME.service" << EOL
[Unit]
Description=MTProxy Telegram Proxy (Python)
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=$INSTALL_DIR
ExecStart=python3 $INSTALL_DIR/mtprotoproxy.py $PORT $USER_SECRET
Environment=TAG=$CHANNEL_TAG
Environment=TLS_DOMAIN=$TLS_DOMAIN
Environment=MASK_HOST=$TLS_DOMAIN
Restart=always
RestartSec=10
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOL

# Права доступа
chown -R root:root $INSTALL_DIR
chmod +x $INSTALL_DIR/mtprotoproxy.py

# Настройка фаервола
if command -v ufw &> /dev/null; then
    if ufw status | grep -q "Status: active"; then
        ufw allow $PORT/tcp
        echo -e "${GREEN}UFW: Порт $PORT открыт${NC}"
    fi
fi

# Создание утилиты управления 'mtp'
echo -e "${YELLOW}Создание утилиты управления 'mtp'...${NC}"

cat > "/tmp/mtp_utility" << 'UTILITY_EOF'
#!/bin/bash

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

INSTALL_DIR="/opt/MTProxy"
SERVICE_NAME="mtproxy"

# Функция конвертации домена в hex
domain_to_hex() {
    echo -n "$1" | xxd -p | tr -d '\n'
}

show_help() {
    echo -e "${BLUE}========================${NC}"
    echo -e "${BLUE}   Управление MTProxy   ${NC}"
    echo -e "${BLUE}========================${NC}"
    echo -e "${GREEN}mtp status${NC}    - Статус и ссылки для подключения"
    echo -e "${GREEN}mtp start${NC}     - Запустить прокси"
    echo -e "${GREEN}mtp stop${NC}      - Остановить прокси"
    echo -e "${GREEN}mtp restart${NC}   - Перезапустить прокси"
    echo -e "${GREEN}mtp logs${NC}      - Посмотреть логи"
    echo -e "${GREEN}mtp check${NC}     - Проверка доступности портов и DNS"
    echo -e "${GREEN}mtp info${NC}      - Детальная конфигурация"
}

get_config() {
    if [[ -f "/etc/systemd/system/mtproxy.service" ]]; then
        EXEC_START=$(grep "ExecStart=" "/etc/systemd/system/mtproxy.service" | cut -d'=' -f2-)
        PORT=$(echo "$EXEC_START" | awk '{print $(NF-1)}')
        SECRET=$(echo "$EXEC_START" | awk '{print $NF}')
        TLS_DOMAIN=$(grep "Environment=TLS_DOMAIN=" "/etc/systemd/system/mtproxy.service" | cut -d'=' -f3)
        [[ -z "$TLS_DOMAIN" ]] && TLS_DOMAIN="google.com"
    fi
}

get_host() {
    # 1. Сначала пробуем взять хост из info.txt (это приоритет, т.к. там может быть домен пользователя)
    if [[ -f "$INSTALL_DIR/info.txt" ]]; then
        SAVED_HOST=$(grep "Proxy Host:" "$INSTALL_DIR/info.txt" | awk '{print $3}')
        if [[ -n "$SAVED_HOST" && "$SAVED_HOST" != "unknown" ]]; then
            PROXY_HOST="$SAVED_HOST"
            return
        fi
    fi
    
    # 2. Если нет, пробуем определить внешний IP
    for service in "ipv4.icanhazip.com" "ipv4.ident.me"; do
        if IP=$(curl -4 -s --connect-timeout 3 "$service"); then
            if [[ $IP =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
                PROXY_HOST="$IP"
                return
            fi
        fi
    done
    
    PROXY_HOST="ВАШ_IP"
}

show_status() {
    echo -e "\n${CYAN}--- Статус Службы ---${NC}"
    if systemctl is-active --quiet mtproxy; then
        echo -e "${GREEN}✅ Служба запущена${NC}"
    else
        echo -e "${RED}❌ Служба остановлена${NC}"
        return 1
    fi
    
    get_config
    get_host
    
    TLS_HEX=$(domain_to_hex "$TLS_DOMAIN")
    
    # Ссылки
    LINK_PLAIN="tg://proxy?server=$PROXY_HOST&port=$PORT&secret=$SECRET"
    LINK_DD="tg://proxy?server=$PROXY_HOST&port=$PORT&secret=dd$SECRET"
    LINK_TLS="tg://proxy?server=$PROXY_HOST&port=$PORT&secret=ee${SECRET}${TLS_HEX}"
    
    echo -e "\n${CYAN}--- Ссылки для Подключения ---${NC}"
    echo -e "${YELLOW}1. Обычная (для регистрации бота):${NC}"
    echo -e "   $LINK_PLAIN"
    
    echo -e "\n${YELLOW}2. DD (защищенная от обнаружения):${NC}"
    echo -e "   $LINK_DD"
    
    echo -e "\n${YELLOW}3. Fake-TLS (рекомендуемая, маскировка под $TLS_DOMAIN):${NC}"
    echo -e "   $LINK_TLS"
    
    echo -e "\n${CYAN}--- Веб-ссылки (нажмите для подключения) ---${NC}"
    echo -e "   ${GREEN}$(echo $LINK_TLS | sed 's/tg:/https:\/\/t.me/')${NC}"
}

check_health() {
    echo -e "${CYAN}--- Диагностика ---${NC}"
    get_config
    get_host
    
    echo -e "Порт службы: $PORT"
    echo -e "Хост/IP:    $PROXY_HOST"
    
    # 1. Проверка порта локально
    echo -n "Проверка порта локально: "
    if timeout 2 bash -c "</dev/tcp/localhost/$PORT" 2>/dev/null; then
        echo -e "${GREEN}ОК (доступен)${NC}"
    else
        echo -e "${RED}ОШИБКА (недоступен)${NC}"
        echo -e "${YELLOW}Возможно, служба не запущена.${NC}"
    fi
    
    # 2. Проверка DNS (если это домен)
    if [[ "$PROXY_HOST" =~ [a-zA-Z] ]]; then
        echo -e "\nПроверка DNS резолвинга для $PROXY_HOST:"
        RESOLVED_IP=$(getent ahostsv4 "$PROXY_HOST" | awk '/STREAM/ {print $1; exit}')
        
        # Получаем текущий внешний IP для сравнения
        CURRENT_IP=$(curl -4 -s ipv4.icanhazip.com)
        
        if [[ -n "$RESOLVED_IP" ]]; then
            echo -e "  -> DNS указывает на IP: ${GREEN}$RESOLVED_IP${NC}"
            
            if [[ "$RESOLVED_IP" == "$CURRENT_IP" ]]; then
                 echo -e "  -> ${GREEN}Совпадает с IP этого сервера ($CURRENT_IP). Все отлично!${NC}"
            else
                 echo -e "  -> ${RED}НЕ СОВПАДАЕТ с IP сервера ($CURRENT_IP)!${NC}"
                 echo -e "     ${YELLOW}Пользователи могут не подключиться. Проверьте настройки DNS.${NC}"
            fi
        else
            echo -e "  -> ${RED}Не удалось разрешить доменное имя!${NC}"
        fi
    else
        echo -e "\nПроверка DNS пропущена (используется IP адрес)."
    fi
}

case "${1:-status}" in
    "start")
        echo -e "${YELLOW}Запуск MTProxy...${NC}"
        systemctl start mtproxy
        show_status
        ;;
    "stop")
        echo -e "${YELLOW}Остановка MTProxy...${NC}"
        systemctl stop mtproxy
        echo -e "${GREEN}Служба остановлена.${NC}"
        ;;
    "restart")
        echo -e "${YELLOW}Перезапуск MTProxy...${NC}"
        systemctl restart mtproxy
        show_status
        ;;
    "status")
        show_status
        ;;
    "links")
        show_status
        ;;
    "logs")
        echo -e "${YELLOW}Логи MTProxy (Ctrl+C для выхода):${NC}"
        journalctl -u mtproxy -f
        ;;
    "check"|"test")
        check_health
        ;;
    "info")
        cat "$INSTALL_DIR/info.txt" 2>/dev/null
        ;;
    *)
        show_help
        ;;
esac
UTILITY_EOF

# Установка утилиты
mv "/tmp/mtp_utility" "/usr/local/bin/mtp"
chmod +x "/usr/local/bin/mtp"

# Удаление старой утилиты если есть
rm -f "/usr/local/bin/mtproxy" 2>/dev/null

# Запуск службы
systemctl daemon-reload
systemctl enable $SERVICE_NAME
systemctl start $SERVICE_NAME

sleep 2

if systemctl is-active --quiet $SERVICE_NAME; then
    echo -e "\n${GREEN}✅ Установка успешно завершена!${NC}"
    
    # Обновляем info.txt с финальными данными используя новую утилиту
    # (просто чтобы убедиться что логика работает, но файл уже создан выше)
    
    echo -e "\n${CYAN}--- Как управлять прокси ---${NC}"
    echo -e "Используйте команду ${BOLD}mtp${NC} для управления:"
    echo -e "  ${GREEN}mtp${NC}        - показать ссылки подключения"
    echo -e "  ${GREEN}mtp check${NC}  - проверить работу и DNS"
    echo -e "  ${GREEN}mtp logs${NC}   - смотреть логи"
    
    # Показываем статус сразу
    /usr/local/bin/mtp status
else
    echo -e "\n${RED}❌ Ошибка: Служба не запустилась.${NC}"
    echo -e "Попробуйте посмотреть логи: journalctl -u mtproxy -e"
fi

echo -e "\n${BLUE}===================================================${NC}"
echo -e "${BLUE}       Спасибо за использование MTProxy!          ${NC}"
echo -e "${BLUE}===================================================${NC}\n"


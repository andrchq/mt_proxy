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

echo -e "${BLUE}Установка MTProxy (Финальная версия)${NC}\n"

# Требуется root
if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}Этот установщик должен быть запущен от имени root (используйте sudo).${NC}"
    exit 1
fi

# Проверка опции удаления
if [[ "$1" == "uninstall" ]]; then
    echo -e "${YELLOW}🗑️  Удаление MTProxy${NC}\n"
    
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
    
    echo -e "\n${YELLOW}Удаление MTProxy...${NC}"
    
    # Остановка и отключение сервиса
    if systemctl is-active --quiet mtproxy; then
        echo -e "${YELLOW}Остановка сервиса MTProxy...${NC}"
        systemctl stop mtproxy
    fi
    
    if systemctl is-enabled --quiet mtproxy 2>/dev/null; then
        echo -e "${YELLOW}Отключение автозагрузки сервиса MTProxy...${NC}"
        systemctl disable mtproxy
    fi
    
    # Удаление файла сервиса
    if [[ -f "/etc/systemd/system/mtproxy.service" ]]; then
        echo -e "${YELLOW}Удаление файла сервиса...${NC}"
        rm -f "/etc/systemd/system/mtproxy.service"
        systemctl daemon-reload
    fi
    
    # Удаление директории установки
    if [[ -d "/opt/MTProxy" ]]; then
        echo -e "${YELLOW}Удаление директории установки...${NC}"
        rm -rf "/opt/MTProxy"
    fi
    
    # Удаление утилиты управления
    if [[ -f "/usr/local/bin/mtproxy" ]]; then
        echo -e "${YELLOW}Удаление утилиты управления...${NC}"
        rm -f "/usr/local/bin/mtproxy"
    fi
    
    # Удаление правил брандмауэра (если UFW активен)
    if command -v ufw &> /dev/null && ufw status | grep -q "Status: active"; then
        echo -e "${YELLOW}Проверка правил брандмауэра...${NC}"
        # Попытка удалить стандартные порты MTProxy
        for port in 8080 8443 9443 1080 3128; do
            if ufw status | grep -q "${port}/tcp"; then
                echo -e "${YELLOW}Удаление правила брандмауэра для порта $port...${NC}"
                ufw delete allow ${port}/tcp 2>/dev/null
            fi
        done
    fi
    
    echo -e "\n${GREEN}✅ MTProxy был полностью удален!${NC}"
    echo -e "${CYAN}Все файлы, сервисы и конфигурации были стерты.${NC}"
    echo -e "${YELLOW}Примечание: Вам может потребоваться вручную удалить любые кастомные правила брандмауэра.${NC}"
    
    exit 0
fi

# Проверка на вызов справки или неверные аргументы
if [[ "$1" == "help" || "$1" == "-h" || "$1" == "--help" ]]; then
    echo -e "${BLUE}Скрипт установки MTProxy${NC}\n"
    echo "Использование:"
    echo -e "  ${GREEN}$0${NC}              - Установить MTProxy с интерактивной настройкой"
    echo -e "  ${GREEN}$0 uninstall${NC}    - Полностью удалить MTProxy и все файлы"
    echo -e "  ${GREEN}$0 help${NC}         - Показать это справочное сообщение"
    echo ""
    echo "После установки используйте команду 'mtproxy' для управления сервисом."
    exit 0
fi

if [[ -n "$1" && "$1" != "install" ]]; then
    echo -e "${RED}Ошибка: Неизвестный аргумент '$1'${NC}"
    echo -e "Используйте '${GREEN}$0 help${NC}' для получения справки."
    exit 1
fi

# Конфигурация
INSTALL_DIR="/opt/MTProxy"
SERVICE_NAME="mtproxy"
DEFAULT_PORT=9443
DEFAULT_CHANNEL="vsemvpn_com"

# Ввод пользователя
read -p "Введите порт прокси (по умолчанию: $DEFAULT_PORT): " USER_PORT
PORT=${USER_PORT:-$DEFAULT_PORT}

echo -e "\n${YELLOW}📢 Настройка продвижения канала:${NC}"
echo -e "${CYAN}Вы можете рекламировать свой Telegram-канал пользователям, подключающимся через ваш прокси.${NC}"
echo -e "${CYAN}Варианты:${NC}"
echo -e "${CYAN}  1. Установить канал сейчас (начнет работать сразу)${NC}"
echo -e "${CYAN}  2. Настроить позже через @MTProxybot (после регистрации, более высокий приоритет)${NC}"
echo ""
read -p "Введите USERNAME канала/бота для продвижения (по умолчанию: $DEFAULT_CHANNEL, оставьте пустым для отмены): " USER_CHANNEL
CHANNEL_TAG=${USER_CHANNEL:-$DEFAULT_CHANNEL}

if [[ "$CHANNEL_TAG" == "$DEFAULT_CHANNEL" ]]; then
    echo -e "${CYAN}Используется канал по умолчанию @$CHANNEL_TAG. Вы сможете переопределить это через @MTProxybot позже.${NC}"
elif [[ -z "$CHANNEL_TAG" ]]; then
    CHANNEL_TAG=""
    echo -e "${CYAN}Канал не установлен. Настройте продвижение через @MTProxybot после регистрации.${NC}"
else
    echo -e "${CYAN}Используется канал @$CHANNEL_TAG. Вы сможете изменить это через @MTProxybot позже.${NC}"
fi

echo -e "\n${YELLOW}Установка нативного сервиса MTProxy...${NC}"

# Установка зависимостей
echo -e "${YELLOW}Установка зависимостей...${NC}"
if command -v apt >/dev/null 2>&1; then
    apt update -qq
    # Убедимся, что xxd доступен (в некоторых системах он поставляется с vim-common)
    apt install -y git curl python3 python3-pip xxd || apt install -y vim-common
else
    echo -e "${RED}apt не найден. Этот скрипт в данный момент поддерживает Debian/Ubuntu (apt).${NC}"
    echo -e "${YELLOW}Установите зависимости вручную: git curl python3 python3-pip xxd (или vim-common).${NC}"
    exit 1
fi

# Создание директории установки
mkdir -p $INSTALL_DIR
cd $INSTALL_DIR

# Остановка существующего сервиса, если он запущен
systemctl stop mtproxy 2>/dev/null

# Загрузка Python MTProxy
echo -e "${YELLOW}Установка Python MTProxy...${NC}"
if curl -s -L "https://raw.githubusercontent.com/alexbers/mtprotoproxy/master/mtprotoproxy.py" -o mtprotoproxy.py; then
    chmod +x mtprotoproxy.py
    echo -e "${GREEN}Python MTProxy успешно загружен${NC}"
else
    echo -e "${RED}Не удалось загрузить MTProxy${NC}"
    exit 1
fi

# Генерация секрета пользователя (или использование существующего)
if [[ -f "/opt/MTProxy/info.txt" ]] && grep -q "Base Secret:" /opt/MTProxy/info.txt; then
    USER_SECRET=$(grep "Base Secret:" /opt/MTProxy/info.txt | awk '{print $3}')
    echo -e "${GREEN}Используется существующий секрет: $USER_SECRET${NC}"
else
    USER_SECRET=$(head -c 16 /dev/urandom | xxd -ps)
    echo -e "${GREEN}Сгенерирован новый секрет: $USER_SECRET${NC}"
fi

# Получение внешнего IP (только IPv4)
echo -e "${YELLOW}Получение внешнего IPv4-адреса...${NC}"
EXTERNAL_IP=""
for service in "ipv4.icanhazip.com" "ipv4.ident.me" "ifconfig.me/ip" "api.ipify.org"; do
    if EXTERNAL_IP=$(curl -4 -s --connect-timeout 10 "$service" 2>/dev/null) && [[ -n "$EXTERNAL_IP" ]]; then
        # Проверка на валидность IPv4
        if [[ $EXTERNAL_IP =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
            # Дополнительная валидация диапазонов IPv4
            IFS='.' read -ra ADDR <<< "$EXTERNAL_IP"
            valid=true
            for i in "${ADDR[@]}"; do
                if [[ $i -gt 255 || $i -lt 0 ]]; then
                    valid=false
                    break
                fi
            done
            if [[ $valid == true ]]; then
                break
            fi
        fi
    fi
    EXTERNAL_IP=""
done

if [[ -z "$EXTERNAL_IP" ]]; then
    EXTERNAL_IP="YOUR_SERVER_IP"
    echo -e "${RED}Не удалось определить внешний IPv4-адрес${NC}"
    echo -e "${YELLOW}Пожалуйста, проверьте ваш IPv4 вручную командой: curl -4 ifconfig.me${NC}"
else
    echo -e "${GREEN}Определен внешний IPv4: $EXTERNAL_IP${NC}"
fi

# Запрос домена (опционально)
echo -e "\n${YELLOW}🌐 Настройка домена (необязательно):${NC}"
echo -e "${CYAN}Вы можете использовать доменное имя вместо IP-адреса для удобства пользователей.${NC}"
echo -e "${CYAN}Примеры: proxy.example.com, vpn.mydomain.org${NC}"
echo -e "${CYAN}Оставьте пустым для использования IP-адреса: $EXTERNAL_IP${NC}"
echo ""
read -p "Введите доменное имя (опционально): " USER_DOMAIN

if [[ -n "$USER_DOMAIN" ]]; then
    # Базовая проверка формата домена
    if [[ $USER_DOMAIN =~ ^[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?)*$ ]]; then
        PROXY_HOST="$USER_DOMAIN"
        echo -e "${GREEN}Используется домен: $PROXY_HOST${NC}"
        echo -e "${YELLOW}Проверка DNS для домена...${NC}"
        DOMAIN_IP=$(getent ahostsv4 "$PROXY_HOST" 2>/dev/null | awk '/STREAM/ {print $1; exit}')
        if [[ -n "$DOMAIN_IP" && -n "$EXTERNAL_IP" && "$DOMAIN_IP" != "$EXTERNAL_IP" ]]; then
            echo -e "${YELLOW}Предупреждение:${NC} DNS ($PROXY_HOST -> ${DOMAIN_IP}) не совпадает с обнаруженным внешним IP (${EXTERNAL_IP})."
            echo -e "${YELLOW}Убедитесь, что A-запись вашего домена указывает на ${EXTERNAL_IP}.${NC}"
        else
            echo -e "${GREEN}DNS в порядке.${NC}"
        fi
    else
        echo -e "${RED}Неверный формат домена. Используется IP-адрес.${NC}"
        PROXY_HOST="$EXTERNAL_IP"
    fi
else
    PROXY_HOST="$EXTERNAL_IP"
    echo -e "${GREEN}Используется IP-адрес: $PROXY_HOST${NC}"
fi

# Настройка TLS домена для лучшей безопасности
echo -e "\n${YELLOW}🔒 Настройка TLS-домена:${NC}"
echo -e "${CYAN}MTProxy использует домен для маскировки под TLS-трафик, чтобы избежать обнаружения.${NC}"
echo -e "${CYAN}Использование реальных доменов более безопасно, чем стандартный google.com${NC}"
echo -e "${CYAN}Примеры: github.com, cloudflare.com, microsoft.com, amazon.com${NC}"
echo ""

# Список хороших TLS-доменов
TLS_DOMAINS=("github.com" "cloudflare.com" "microsoft.com" "amazon.com" "yahoo.com" "wikipedia.org" "stackoverflow.com" "reddit.com")
RANDOM_DOMAIN=${TLS_DOMAINS[$RANDOM % ${#TLS_DOMAINS[@]}]}

read -p "Введите TLS-домен для маскировки (по умолчанию: $RANDOM_DOMAIN): " USER_TLS_DOMAIN
TLS_DOMAIN=${USER_TLS_DOMAIN:-$RANDOM_DOMAIN}

echo -e "${GREEN}Используется TLS-домен: $TLS_DOMAIN${NC}"

# Создание начального info.txt (сохранение выбранного хоста)
mkdir -p $INSTALL_DIR
cat > "$INSTALL_DIR/info.txt" << EOL
Информация о настройке MTProxy
========================
Дата настройки: $(date)
Выбранный порт: $PORT
Выбранный канал: @$CHANNEL_TAG
Внешний IPv4: $EXTERNAL_IP
Хост прокси: $PROXY_HOST
TLS-домен: $TLS_DOMAIN
Секрет регистрации (32 hex, для @MTProxybot): $USER_SECRET
Статус: Установка...
EOL

# Создание сервиса systemd
echo -e "${YELLOW}Создание сервиса systemd...${NC}"
cat > "/etc/systemd/system/$SERVICE_NAME.service" << EOL
[Unit]
Description=MTProxy Telegram Proxy (Python)
After=network.target
Wants=network-online.target
After=network-online.target

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
StartLimitBurst=3
StartLimitIntervalSec=60
KillMode=mixed
KillSignal=SIGTERM
TimeoutStopSec=30

# Лимиты ресурсов для стабильности
LimitNOFILE=65536
LimitNPROC=4096

# Настройки безопасности
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=$INSTALL_DIR
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOL

# Установка прав
chown -R root:root $INSTALL_DIR
chmod +x $INSTALL_DIR/mtprotoproxy.py

# Настройка брандмауэра
if command -v ufw &> /dev/null; then
    if ufw status | grep -q "Status: active"; then
        ufw allow $PORT/tcp
        echo -e "${GREEN}UFW: Открыт порт $PORT/tcp${NC}"
    fi
fi

# Создание утилиты управления
echo -e "${YELLOW}Создание утилиты управления...${NC}"

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

# Функция для конвертации домена в hex для TLS ссылки
domain_to_hex() {
    local domain="$1"
    echo -n "$domain" | xxd -p | tr -d '\n'
}

show_help() {
    echo -e "${BLUE}Утилита управления MTProxy${NC}\n"
    echo "Использование: mtproxy [команда]"
    echo ""
    echo "Команды:"
    echo -e "  ${GREEN}status${NC}    - Показать статус сервиса и ссылки для подключения"
    echo -e "  ${GREEN}start${NC}     - Запустить сервис MTProxy"
    echo -e "  ${GREEN}stop${NC}      - Остановить сервис MTProxy"
    echo -e "  ${GREEN}restart${NC}   - Перезапустить сервис MTProxy"
    echo -e "  ${GREEN}logs${NC}      - Показать логи сервиса"
    echo -e "  ${GREEN}links${NC}     - Показать только ссылки для подключения"
    echo -e "  ${GREEN}info${NC}      - Показать подробную конфигурацию"
    echo -e "  ${GREEN}test${NC}      - Проверить доступность прокси"
    echo -e "  ${GREEN}help${NC}      - Показать эту справку"
}

get_service_config() {
    if [[ -f "/etc/systemd/system/$SERVICE_NAME.service" ]]; then
        EXEC_START=$(grep "ExecStart=" "/etc/systemd/system/$SERVICE_NAME.service" | cut -d'=' -f2-)
        PORT=$(echo "$EXEC_START" | awk '{print $(NF-1)}')
        SECRET=$(echo "$EXEC_START" | awk '{print $NF}')
        # Получение канала из окружения
        PROMOTED_CHANNEL=$(grep "Environment=TAG=" "/etc/systemd/system/$SERVICE_NAME.service" | cut -d'=' -f3)
    fi
}

get_links() {
    if systemctl is-active --quiet $SERVICE_NAME; then
        # Получение недавних логов для извлечения URL
        LOGS=$(journalctl -u $SERVICE_NAME --no-pager -n 20 --since "5 minutes ago")
        
    # Извлечение полных tg://proxy ссылок
    ANY_LINK=$(echo "$LOGS" | grep -o "tg://proxy[^[:space:]]*secret=[^[:space:]]*" | grep -E "server=[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}" | tail -1)
    DD_LINK=$(echo "$LOGS" | grep -o "tg://proxy[^[:space:]]*secret=dd[^[:space:]]*" | grep -E "server=[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}" | tail -1)
    EE_LINK=$(echo "$LOGS" | grep -o "tg://proxy[^[:space:]]*secret=ee[^[:space:]]*" | grep -E "server=[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}" | tail -1)
        
        # Если ссылки не найдены, проверить все логи
        if [[ -z "$DD_LINK" || -z "$EE_LINK" ]]; then
            LOGS=$(journalctl -u $SERVICE_NAME --no-pager -n 50)
            ANY_LINK=$(echo "$LOGS" | grep -o "tg://proxy[^[:space:]]*secret=[^[:space:]]*" | grep -E "server=[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}" | tail -1)
            DD_LINK=$(echo "$LOGS" | grep -o "tg://proxy[^[:space:]]*secret=dd[^[:space:]]*" | grep -E "server=[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}" | tail -1)
            EE_LINK=$(echo "$LOGS" | grep -o "tg://proxy[^[:space:]]*secret=ee[^[:space:]]*" | grep -E "server=[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}" | tail -1)
        fi
        
        # Если все еще нет ссылок, генерируем вручную
        if [[ -z "$ANY_LINK" || -z "$EE_LINK" ]]; then
            get_service_config
            if [[ -n "$PORT" && -n "$SECRET" ]]; then
                PROXY_HOST=""
                
                # Пробуем из info.txt
                if [[ -f "$INSTALL_DIR/info.txt" ]]; then
                    PROXY_HOST=$(grep "Хост прокси:" "$INSTALL_DIR/info.txt" 2>/dev/null | awk '{print $3}')
                fi
                
                # Если всё еще нет, детектим IP
                if [[ -z "$PROXY_HOST" ]]; then
                    for service in "ipv4.icanhazip.com" "ipv4.ident.me" "ifconfig.me/ip" "api.ipify.org"; do
                        if DETECTED_IP=$(curl -4 -s --connect-timeout 5 "$service" 2>/dev/null) && [[ -n "$DETECTED_IP" ]]; then
                            if [[ $DETECTED_IP =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
                                IFS='.' read -ra ADDR <<< "$DETECTED_IP"
                                valid=true
                                for i in "${ADDR[@]}"; do
                                    if [[ $i -gt 255 || $i -lt 0 ]]; then
                                        valid=false
                                        break
                                    fi
                                done
                                if [[ $valid == true ]]; then
                                    PROXY_HOST="$DETECTED_IP"
                                    break
                                fi
                            fi
                        fi
                    done
                fi
                
                if [[ -z "$PROXY_HOST" ]]; then
                    PROXY_HOST="YOUR_SERVER_IP"
                fi
                
                # Получаем TLS домен
                if [[ -z "$TLS_DOMAIN" ]]; then
                    TLS_DOMAIN=$(grep "Environment=TLS_DOMAIN=" /etc/systemd/system/mtproxy.service 2>/dev/null | cut -d'=' -f3)
                    [[ -z "$TLS_DOMAIN" ]] && TLS_DOMAIN="github.com"
                fi
                
                TLS_DOMAIN_HEX=$(domain_to_hex "$TLS_DOMAIN")
                
                PLAIN_LINK="tg://proxy?server=$PROXY_HOST&port=$PORT&secret=${SECRET}"
                DD_LINK="tg://proxy?server=$PROXY_HOST&port=$PORT&secret=dd${SECRET}"
                EE_LINK="tg://proxy?server=$PROXY_HOST&port=$PORT&secret=ee${SECRET}${TLS_DOMAIN_HEX}"
            fi
        fi

        # Всегда пересоздаем ссылки на основе текущего секрета для консистентности
        get_service_config
        if [[ -n "$PORT" && -n "$SECRET" ]]; then
            PROXY_HOST=""
            LINK_SRC="${ANY_LINK:-${DD_LINK:-$EE_LINK}}"
            if [[ -n "$LINK_SRC" ]]; then
                PROXY_HOST=$(echo "$LINK_SRC" | sed -E 's/.*server=([^&]+).*/\1/')
            fi
            
            if [[ -z "$PROXY_HOST" ]]; then
                if [[ -f "$INSTALL_DIR/info.txt" ]]; then
                    PROXY_HOST=$(grep "Хост прокси:" "$INSTALL_DIR/info.txt" 2>/dev/null | awk '{print $3}')
                fi
                if [[ -z "$PROXY_HOST" ]]; then
                    for service in "ipv4.icanhazip.com" "ipv4.ident.me"; do
                        if DETECTED_IP=$(curl -4 -s --connect-timeout 3 "$service" 2>/dev/null) && [[ $DETECTED_IP =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
                            PROXY_HOST="$DETECTED_IP"
                            break
                        fi
                    done
                fi
            fi
            
            if [[ -n "$PROXY_HOST" ]]; then
                TLS_DOMAIN=$(grep "Environment=TLS_DOMAIN=" /etc/systemd/system/mtproxy.service 2>/dev/null | cut -d'=' -f3)
                [[ -z "$TLS_DOMAIN" ]] && TLS_DOMAIN="github.com"
                TLS_DOMAIN_HEX=$(domain_to_hex "$TLS_DOMAIN")
                
                PLAIN_LINK="tg://proxy?server=$PROXY_HOST&port=$PORT&secret=${SECRET}"
                DD_LINK="tg://proxy?server=$PROXY_HOST&port=$PORT&secret=dd${SECRET}"
                EE_LINK="tg://proxy?server=$PROXY_HOST&port=$PORT&secret=ee${SECRET}${TLS_DOMAIN_HEX}"
            fi
        fi
    fi
}

show_status() {
    echo -e "${BLUE}=== Статус MTProxy ===${NC}\n"
    
    if systemctl is-active --quiet $SERVICE_NAME; then
        echo -e "${GREEN}✅ Сервис: Запущен${NC}"
    else
        echo -e "${RED}❌ Сервис: Остановлен${NC}"
        return 1
    fi
    
    get_service_config
    echo -e "${YELLOW}📊 Конфигурация:${NC}"
    echo -e "   Порт: ${GREEN}${PORT:-неизвестно}${NC}"
    echo -e "   Секрет: ${GREEN}${SECRET:-неизвестно}${NC}"
    echo -e "   Секрет регистрации (для @MTProxybot): ${GREEN}${SECRET:-неизвестно}${NC}"
    echo -e "   Продвигаемый канал: ${GREEN}@${PROMOTED_CHANNEL:-неизвестно}${NC}"
    
    if [[ -f "$INSTALL_DIR/info.txt" ]]; then
        PROXY_HOST=$(grep "Хост прокси:" "$INSTALL_DIR/info.txt" 2>/dev/null | awk '{print $3}')
        [[ -n "$PROXY_HOST" && "$PROXY_HOST" != "unknown" ]] && echo -e "   Хост прокси: ${GREEN}$PROXY_HOST${NC}"
    fi
    
    get_links
    if [[ -n "$ANY_LINK" || -n "$PLAIN_LINK" || -n "$DD_LINK" || -n "$EE_LINK" ]]; then
        echo -e "\n${YELLOW}🔗 Ссылки для подключения:${NC}"
        [[ -n "$PLAIN_LINK" ]] && echo -e "${GREEN}Обычная (для @MTProxybot):${NC} $PLAIN_LINK"
        [[ -n "$DD_LINK" ]] && echo -e "${GREEN}DD (старые клиенты):${NC} $DD_LINK"
        [[ -n "$EE_LINK" ]] && echo -e "${GREEN}TLS:${NC}      $EE_LINK"
        
        echo -e "\n${YELLOW}🌐 Веб-ссылки:${NC}"
        [[ -n "$PLAIN_LINK" ]] && echo -e "${GREEN}Обычная:${NC} $(echo "$PLAIN_LINK" | sed 's/tg:/https:\/\/t.me/')"
        [[ -n "$DD_LINK" ]] && echo -e "${GREEN}DD:${NC} $(echo "$DD_LINK" | sed 's/tg:/https:\/\/t.me/')"
        [[ -n "$EE_LINK" ]] && echo -e "${GREEN}TLS:${NC}      $(echo "$EE_LINK" | sed 's/tg:/https:\/\/t.me/')"
    else
        echo -e "\n${RED}❌ Нет доступных ссылок${NC}"
    fi
}

show_links() {
    get_links
    if [[ -n "$PLAIN_LINK" || -n "$DD_LINK" || -n "$EE_LINK" ]]; then
        echo -e "${YELLOW}🔗 Ссылки для подключения MTProxy:${NC}"
        [[ -n "$PLAIN_LINK" ]] && echo "$PLAIN_LINK"
        [[ -n "$DD_LINK" ]] && echo "$DD_LINK"
        [[ -n "$EE_LINK" ]] && echo "$EE_LINK"
    else
        echo -e "${RED}❌ Активные ссылки не найдены. Сервис запущен?${NC}"
        return 1
    fi
}

show_info() {
    echo -e "${BLUE}=== Подробная информация MTProxy ===${NC}\n"
    
    show_status
    
    if [[ -f "$INSTALL_DIR/info.txt" ]]; then
        echo -e "\n${YELLOW}📄 Файл конфигурации:${NC}"
        cat "$INSTALL_DIR/info.txt"
    fi
    
    echo -e "\n${YELLOW}🛠️  Команды управления:${NC}"
    echo -e "${GREEN}mtproxy status${NC}    - Показать статус и ссылки"
    echo -e "${GREEN}mtproxy restart${NC}   - Перезапустить сервис"
    echo -e "${GREEN}mtproxy logs${NC}      - Посмотреть логи"
}

update_info_file() {
    get_service_config
    get_links
    
    PROXY_HOST=""
    if [[ -n "$PLAIN_LINK" ]]; then
        PROXY_HOST=$(echo "$PLAIN_LINK" | sed -E 's/.*server=([^&]+).*/\1/')
    elif [[ -n "$DD_LINK" ]]; then
        PROXY_HOST=$(echo "$DD_LINK" | sed -E 's/.*server=([^&]+).*/\1/')
    elif [[ -n "$ANY_LINK" ]]; then
        PROXY_HOST=$(echo "$ANY_LINK" | sed -E 's/.*server=([^&]+).*/\1/')
    else
        for service in "ipv4.icanhazip.com" "ipv4.ident.me" "ifconfig.me/ip" "api.ipify.org"; do
            if DETECTED_IP=$(curl -4 -s --connect-timeout 5 "$service" 2>/dev/null) && [[ -n "$DETECTED_IP" ]]; then
                if [[ $DETECTED_IP =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
                    IFS='.' read -ra ADDR <<< "$DETECTED_IP"
                    valid=true
                    for i in "${ADDR[@]}"; do
                        if [[ $i -gt 255 || $i -lt 0 ]]; then
                            valid=false
                            break
                        fi
                    done
                    if [[ $valid == true ]]; then
                        PROXY_HOST="$DETECTED_IP"
                        break
                    fi
                fi
            fi
        done
    fi
    
    mkdir -p "$INSTALL_DIR"
    cat > "$INSTALL_DIR/info.txt" << EOL
Итоговая конфигурация MTProxy
==========================
Дата установки: $(date)
Путь установки: $INSTALL_DIR
Имя сервиса: $SERVICE_NAME
Тип прокси: Python MTProxy

Детали подключения:
------------------
Хост прокси: ${PROXY_HOST:-неизвестно}
Внешний IP: ${EXTERNAL_IP:-неизвестно}
Порт: ${PORT:-неизвестно}
Базовый секрет: ${SECRET:-неизвестно}
Секрет регистрации (для @MTProxybot): ${SECRET:-неизвестно}
Продвигаемый канал: @${PROMOTED_CHANNEL:-${CHANNEL_TAG:-неизвестно}}

Рабочие ссылки для подключения:
------------------------
Обычная ссылка (для регистрации): ${PLAIN_LINK:-Нет данных}
DD ссылка: ${DD_LINK:-Нет данных}
TLS ссылка: ${EE_LINK:-Нет данных}

Ссылки для веб-браузера:
-----------------
Обычная: $(echo "${PLAIN_LINK:-Нет данных}" | sed 's/tg:/https:\/\/t.me/')
DD: $(echo "${DD_LINK:-Нет данных}" | sed 's/tg:/https:\/\/t.me/')
TLS: $(echo "${EE_LINK:-Нет данных}" | sed 's/tg:/https:\/\/t.me/')

Управление сервисом:
------------------
Статус:  mtproxy status
Запуск:  mtproxy start
Стоп:    mtproxy stop
Рестарт: mtproxy restart
Логи:    mtproxy logs
Инфо:    mtproxy info

ВАЖНО: Секреты сохраняются при перезапуске!
Обновлено: $(date)
EOL
}

# Обработчик команд
case "${1:-status}" in
    "start")
        echo -e "${YELLOW}Запуск сервиса MTProxy...${NC}"
        systemctl start $SERVICE_NAME
        sleep 2
        if systemctl is-active --quiet $SERVICE_NAME; then
            echo -e "${GREEN}✅ Сервис успешно запущен${NC}"
            update_info_file
            show_links
        else
            echo -e "${RED}❌ Не удалось запустить сервис${NC}"
            exit 1
        fi
        ;;
    "stop")
        echo -e "${YELLOW}Остановка сервиса MTProxy...${NC}"
        systemctl stop $SERVICE_NAME
        echo -e "${GREEN}✅ Сервис остановлен${NC}"
        ;;
    "restart")
        echo -e "${YELLOW}Перезапуск сервиса MTProxy...${NC}"
        systemctl restart $SERVICE_NAME
        sleep 2
        if systemctl is-active --quiet $SERVICE_NAME; then
            echo -e "${GREEN}✅ Сервис успешно перезапущен${NC}"
            update_info_file
            show_links
        else
            echo -e "${RED}❌ Не удалось перезапустить сервис${NC}"
            exit 1
        fi
        ;;
    "status")
        show_status
        update_info_file
        ;;
    "links")
        show_links
        ;;
    "logs")
        echo -e "${YELLOW}Отображение логов MTProxy (Ctrl+C для выхода):${NC}"
        journalctl -u $SERVICE_NAME -f
        ;;
    "info")
        show_info
        ;;
    "test")
        echo -e "${YELLOW}Тестирование доступности MTProxy...${NC}"
        get_service_config
        if [[ -n "$PORT" ]]; then
            echo -e "Тестирование доступности порта $PORT..."
            if command -v nc >/dev/null 2>&1; then
                if timeout 5 nc -z localhost "$PORT" 2>/dev/null; then
                    echo -e "${GREEN}✅ Порт $PORT открыт локально${NC}"
                else
                    echo -e "${RED}❌ Порт $PORT недоступен локально${NC}"
                fi
            elif command -v telnet >/dev/null 2>&1; then
                if timeout 5 bash -c "echo | telnet localhost $PORT" 2>/dev/null | grep -q "Connected"; then
                    echo -e "${GREEN}✅ Порт $PORT открыт локально${NC}"
                else
                    echo -e "${RED}❌ Порт $PORT недоступен локально${NC}"
                fi
            else
                echo -e "${YELLOW}⚠️  nc/telnet недоступны для тестирования порта${NC}"
            fi
            
            # Проверка, слушает ли сервис
            if ss -tlnp 2>/dev/null | grep -q ":$PORT "; then
                echo -e "${GREEN}✅ Сервис прослушивает порт $PORT${NC}"
            else
                echo -e "${RED}❌ Ни один сервис не прослушивает порт $PORT${NC}"
            fi
            
            # Проверка логов на ошибки
            RECENT_ERRORS=$(journalctl -u mtproxy --no-pager -n 10 --since "10 minutes ago" | grep -i "error\|fail\|exception" | tail -3)
            if [[ -n "$RECENT_ERRORS" ]]; then
                echo -e "${RED}Недавние ошибки в логах:${NC}"
                echo "$RECENT_ERRORS"
            else
                echo -e "${GREEN}✅ Недавних ошибок в логах не обнаружено${NC}"
            fi
        else
            echo -e "${RED}❌ Не удалось определить порт из конфигурации сервиса${NC}"
        fi
        ;;
    "help"|"-h"|"--help")
        show_help
        ;;
    *)
        echo -e "${RED}Неизвестная команда: $1${NC}"
        show_help
        exit 1
        ;;
esac
UTILITY_EOF

# Перемещение утилиты и установка прав
mv "/tmp/mtproxy_utility" "/usr/local/bin/mtproxy"
chmod +x "/usr/local/bin/mtproxy"

# Перезагрузка демонов и запуск сервиса
systemctl daemon-reload
systemctl enable $SERVICE_NAME
systemctl start $SERVICE_NAME

sleep 3

# Проверка статуса сервиса и создание файла info
if systemctl is-active --quiet $SERVICE_NAME; then
    echo -e "${GREEN}✅ Сервис MTProxy запущен!${NC}"
    
    # Обновление файла info через утилиту управления
    /usr/local/bin/mtproxy status
    
    echo -e "\n${YELLOW}🎉 Установка завершена!${NC}"
    echo -e "\n${CYAN}📋 Быстрые команды:${NC}"
    echo -e "${GREEN}mtproxy${NC}         - Показать статус и ссылки"
    echo -e "${GREEN}mtproxy restart${NC} - Перезапустить сервис"
    echo -e "${GREEN}mtproxy links${NC}   - Показать ссылки для подключения"
    echo -e "${GREEN}mtproxy help${NC}    - Показать все команды"
    
    echo -e "\n${YELLOW}📢 Продвигаемый канал: ${GREEN}@$CHANNEL_TAG${NC}"
    echo -e "${CYAN}Пользователи, подключающиеся через ваш прокси, будут видеть этот канал в списке продвигаемых.${NC}"
    
else
    echo -e "${RED}❌ Не удалось запустить сервис${NC}"
    systemctl status $SERVICE_NAME --no-pager
    exit 1
fi

echo -e "\n${BLUE}📄 Конфигурация сохранена в: ${GREEN}$INSTALL_DIR/info.txt${NC}"
echo -e "${BLUE}🔧 Утилита управления: ${GREEN}/usr/local/bin/mtproxy${NC}"
echo -e "${BLUE}🔄 Сервис будет автоматически запускаться при загрузке системы${NC}"
echo -e "\n${YELLOW}💡 Чтобы полностью удалить MTProxy позже:${NC}"
echo -e "${GREEN}$0 uninstall${NC}"

#!/usr/bin/env bash

set -o pipefail
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH"

DEFAULT_INSTALL_PATH="/opt/dujiao-next"
ENV_RECORD_FILE="/etc/dujiaonext_env"
COMPOSE_FILE="docker-compose.yml"

CRON_TAG_BEGIN="# DUJIAO_NEXT_BACKUP_BEGIN"
CRON_TAG_END="# DUJIAO_NEXT_BACKUP_END"
BACKUP_LOG="/var/log/dujiaonext_backup.log"
SQLITE_MARK_FILE="/etc/dujiaonext_sqlite3_auto_installed"

DEFAULT_API_PORT="39180"
DEFAULT_USER_PORT="34567"
DEFAULT_ADMIN_PORT="39282"

ADMIN_USER="admin"
ADMIN_PASS=""
REDIS_PASS=""

API_CONTAINER="dujiaonext-api"
USER_CONTAINER="dujiaonext-user"
ADMIN_CONTAINER="dujiaonext-admin"
REDIS_CONTAINER="dujiaonext-redis"
USER_GATEWAY_CONTAINER="dujiaonext-user-gateway"
ADMIN_GATEWAY_CONTAINER="dujiaonext-admin-gateway"

info() { echo -e "\033[32m[INFO]\033[0m $1"; }
warn() { echo -e "\033[33m[WARN]\033[0m $1" >&2; }
err()  { echo -e "\033[31m[ERROR]\033[0m $1" >&2; }
die()  { echo -e "\033[31m[FATAL]\033[0m $1" >&2; exit 1; }

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "系统缺少依赖: $1"
}

ensure_sqlite3() {
    if command -v sqlite3 >/dev/null 2>&1; then
        return 0
    fi

    warn "未检测到 sqlite3，开始自动安装..."

    if command -v apt >/dev/null 2>&1; then
        apt update && apt install -y sqlite3 || die "sqlite3 安装失败。"
    elif command -v apt-get >/dev/null 2>&1; then
        apt-get update && apt-get install -y sqlite3 || die "sqlite3 安装失败。"
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y sqlite || die "sqlite3 安装失败。"
    elif command -v yum >/dev/null 2>&1; then
        yum install -y sqlite || die "sqlite3 安装失败。"
    elif command -v apk >/dev/null 2>&1; then
        apk add --no-cache sqlite || die "sqlite3 安装失败。"
    else
        die "无法自动安装 sqlite3，请手动安装。"
    fi

    touch "$SQLITE_MARK_FILE"
    info "sqlite3 已安装。"
}

uninstall_sqlite3_if_auto_installed() {
    if [[ ! -f "$SQLITE_MARK_FILE" ]]; then
        return 0
    fi

    warn "检测到 sqlite3 是本脚本自动安装的，准备卸载 sqlite3..."

    if command -v apt >/dev/null 2>&1; then
        apt remove -y sqlite3 >/dev/null 2>&1 || true
        apt autoremove -y >/dev/null 2>&1 || true
    elif command -v apt-get >/dev/null 2>&1; then
        apt-get remove -y sqlite3 >/dev/null 2>&1 || true
        apt-get autoremove -y >/dev/null 2>&1 || true
    elif command -v dnf >/dev/null 2>&1; then
        dnf remove -y sqlite >/dev/null 2>&1 || true
    elif command -v yum >/dev/null 2>&1; then
        yum remove -y sqlite >/dev/null 2>&1 || true
    elif command -v apk >/dev/null 2>&1; then
        apk del sqlite >/dev/null 2>&1 || true
    fi

    rm -f "$SQLITE_MARK_FILE"
    info "sqlite3 自动安装记录已清理。"
}

get_local_ip() {
    hostname -I 2>/dev/null | awk '{print $1}'
}

valid_port() {
    local p="$1"
    [[ "$p" =~ ^[0-9]+$ ]] && [[ "$p" -ge 1 ]] && [[ "$p" -le 65535 ]]
}

docker_compose_cmd() {
    if docker compose version >/dev/null 2>&1; then
        echo "docker compose"
    elif command -v docker-compose >/dev/null 2>&1; then
        echo "docker-compose"
    else
        die "未检测到 Docker Compose。"
    fi
}

compose_run() {
    local dc_cmd
    dc_cmd="$(docker_compose_cmd)"
    $dc_cmd --env-file .env -f "$COMPOSE_FILE" "$@"
}

get_workdir() {
    [[ -f "$ENV_RECORD_FILE" ]] && cat "$ENV_RECORD_FILE" || echo ""
}

generate_passwords() {
    ADMIN_PASS="$(openssl rand -hex 16)"
    REDIS_PASS="$(openssl rand -hex 24)"
}

write_pwd_file() {
    local workdir="$1"
    mkdir -p "${workdir}/config"
    {
        echo "后台账号: ${ADMIN_USER}"
        echo "后台密码: ${ADMIN_PASS}"
        echo "Redis密码: ${REDIS_PASS}"
    } > "${workdir}/config/passwords.txt"
    chmod 600 "${workdir}/config/passwords.txt"
}

read_pwd_file() {
    local workdir="$1"
    [[ -f "${workdir}/config/passwords.txt" ]] && cat "${workdir}/config/passwords.txt" || echo "未能读取密码文件"
}

create_compose_file() {
    local workdir="$1"

    cat > "${workdir}/${COMPOSE_FILE}" <<'EOF'
services:
  redis:
    image: redis:7-alpine
    container_name: dujiaonext-redis
    restart: unless-stopped
    command: ["redis-server", "--appendonly", "yes", "--requirepass", "${REDIS_PASSWORD}"]
    volumes:
      - ./data/redis:/data
    healthcheck:
      test: ["CMD", "redis-cli", "-a", "${REDIS_PASSWORD}", "ping"]
      interval: 10s
      timeout: 3s
      retries: 10
    networks:
      - dujiao-net

  api:
    image: dujiaonext/api:${TAG}
    container_name: dujiaonext-api
    restart: unless-stopped
    environment:
      TZ: ${TZ}
      DJ_DEFAULT_ADMIN_USERNAME: ${DJ_DEFAULT_ADMIN_USERNAME}
      DJ_DEFAULT_ADMIN_PASSWORD: ${DJ_DEFAULT_ADMIN_PASSWORD}
    ports:
      - "127.0.0.1:${API_PORT}:8080"
    volumes:
      - ./config/config.yml:/app/config.yml:ro
      - ./data/db:/app/db
      - ./data/uploads:/app/uploads
      - ./data/logs:/app/logs
    depends_on:
      redis:
        condition: service_healthy
    networks:
      - dujiao-net

  user:
    image: dujiaonext/user:${TAG}
    container_name: dujiaonext-user
    restart: unless-stopped
    expose:
      - "80"
    depends_on:
      - api
    networks:
      - dujiao-net

  admin:
    image: dujiaonext/admin:${TAG}
    container_name: dujiaonext-admin
    restart: unless-stopped
    expose:
      - "80"
    depends_on:
      - api
    networks:
      - dujiao-net

  user-gateway:
    image: nginx:alpine
    container_name: dujiaonext-user-gateway
    restart: unless-stopped
    ports:
      - "${USER_BIND_IP}:${USER_PORT}:80"
    volumes:
      - ./nginx/user.conf:/etc/nginx/conf.d/default.conf:ro
    depends_on:
      - user
      - api
    networks:
      - dujiao-net

  admin-gateway:
    image: nginx:alpine
    container_name: dujiaonext-admin-gateway
    restart: unless-stopped
    ports:
      - "${ADMIN_BIND_IP}:${ADMIN_PORT}:80"
    volumes:
      - ./nginx/admin.conf:/etc/nginx/conf.d/default.conf:ro
    depends_on:
      - admin
      - api
    networks:
      - dujiao-net

networks:
  dujiao-net:
    driver: bridge
EOF
}

create_nginx_files() {
    local workdir="$1"
    mkdir -p "${workdir}/nginx"

    cat > "${workdir}/nginx/user.conf" <<'EOF'
server {
    listen 80;
    server_name _;
    client_max_body_size 100m;
    gzip off;

    location / {
        proxy_pass http://user:80;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header Accept-Encoding "";

        sub_filter_once off;
        sub_filter_types text/html text/css application/javascript;
        sub_filter '</head>' '<style>a[href="https://github.com/dujiao-next"],a[href="https://github.com/dujiao-next/dujiao-next"]{display:none!important;visibility:hidden!important;width:0!important;height:0!important;overflow:hidden!important;}</style></head>';
    }

    location /api/ {
        proxy_pass http://api:8080/api/;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }

    location /uploads/ {
        proxy_pass http://api:8080/uploads/;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
    }

    location = /sitemap.xml {
        proxy_pass http://api:8080/sitemap.xml;
    }

    location = /robots.txt {
        proxy_pass http://api:8080/robots.txt;
    }
}
EOF

    cat > "${workdir}/nginx/admin.conf" <<'EOF'
server {
    listen 80;
    server_name _;
    client_max_body_size 100m;

    location / {
        proxy_pass http://admin:80;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }

    location /api/ {
        proxy_pass http://api:8080/api/;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }

    location /uploads/ {
        proxy_pass http://api:8080/uploads/;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
    }
}
EOF
}

download_config() {
    local workdir="$1"
    local cfg="${workdir}/config/config.yml"

    if [[ -f "$cfg" ]]; then
        return
    fi

    curl -fsSL https://raw.githubusercontent.com/dujiao-next/dujiao-next/main/config.yml.example -o "$cfg" \
        || die "下载 config.yml.example 失败。"
}

patch_config_yml() {
    local workdir="$1"
    local cfg="${workdir}/config/config.yml"
    [[ -f "$cfg" ]] || die "config.yml 不存在。"

    python3 - "$cfg" "$REDIS_PASS" <<'PYEOF'
import sys, re, secrets, string

path = sys.argv[1]
redis_pass = sys.argv[2]

text = open(path, "r", encoding="utf-8").read()
text = text.replace("\r\n", "\n").replace("\r", "\n")

redis_block = f"""redis:
  host: redis
  port: 6379
  password: {redis_pass}
  db: 0
"""

if re.search(r'(?m)^redis:\s*$', text):
    text = re.sub(r'(?ms)^redis:\s*\n(?:^[ \t]+.*\n?)*', redis_block, text, count=1)
else:
    text += "\n\n" + redis_block

text = re.sub(r'(?m)^(\s*host:\s*)(127\.0\.0\.1|localhost)\s*$', r'\1redis', text)
text = re.sub(r'(?m)^(\s*driver:\s*)(mysql|postgres|postgresql)\s*$', r'\1sqlite', text)
text = re.sub(r'(?m)^(\s*dsn:\s*).+$', r'\1/app/db/dujiao.db', text)

alphabet = string.ascii_letters + string.digits
secret = ''.join(secrets.choice(alphabet) for _ in range(48))
text = re.sub(r'(?m)^(\s*secret:\s*)(your.*|change.*|please.*)$', r'\1' + secret, text)

open(path, "w", encoding="utf-8", newline="\n").write(text)
PYEOF
}

write_env_file() {
    local workdir="$1"
    local api_port="$2"
    local user_port="$3"
    local admin_port="$4"
    local user_bind_ip="$5"
    local admin_bind_ip="$6"

    cat > "${workdir}/.env" <<EOF
TAG=latest
TZ=Asia/Shanghai

API_PORT=${api_port}
USER_PORT=${user_port}
ADMIN_PORT=${admin_port}

USER_BIND_IP=${user_bind_ip}
ADMIN_BIND_IP=${admin_bind_ip}

DJ_DEFAULT_ADMIN_USERNAME=${ADMIN_USER}
DJ_DEFAULT_ADMIN_PASSWORD=${ADMIN_PASS}

REDIS_PASSWORD=${REDIS_PASS}
EOF
}

show_access() {
    local workdir="$1"
    local ip
    ip="$(get_local_ip)"

    local api_port user_port admin_port user_bind_ip admin_bind_ip
    api_port="$(grep -oP '^API_PORT=\K.*' "${workdir}/.env" 2>/dev/null || echo "$DEFAULT_API_PORT")"
    user_port="$(grep -oP '^USER_PORT=\K.*' "${workdir}/.env" 2>/dev/null || echo "$DEFAULT_USER_PORT")"
    admin_port="$(grep -oP '^ADMIN_PORT=\K.*' "${workdir}/.env" 2>/dev/null || echo "$DEFAULT_ADMIN_PORT")"
    user_bind_ip="$(grep -oP '^USER_BIND_IP=\K.*' "${workdir}/.env" 2>/dev/null || echo "127.0.0.1")"
    admin_bind_ip="$(grep -oP '^ADMIN_BIND_IP=\K.*' "${workdir}/.env" 2>/dev/null || echo "127.0.0.1")"

    echo ""
    echo "=================================================="
    echo -e "\033[32m✅ Dujiao-Next 已就绪\033[0m"
    echo "--------------------------------------------------"
    echo -e "API 检测: \033[36mhttp://127.0.0.1:${api_port}/health\033[0m"

    [[ "$user_bind_ip" == "0.0.0.0" ]] \
        && echo -e "前台地址: \033[36mhttp://${ip}:${user_port}\033[0m" \
        || echo -e "前台地址: \033[36mhttp://127.0.0.1:${user_port}\033[0m"

    [[ "$admin_bind_ip" == "0.0.0.0" ]] \
        && echo -e "后台地址: \033[36mhttp://${ip}:${admin_port}\033[0m" \
        || echo -e "后台地址: \033[36mhttp://127.0.0.1:${admin_port}\033[0m"

    echo "--------------------------------------------------"
    echo "$(read_pwd_file "$workdir")"
    echo "密码文件: ${workdir}/config/passwords.txt"
    echo "安装目录: ${workdir}"
    echo "=================================================="
    echo ""
}

wait_app_ready() {
    local port
    port="$(grep -oP '^API_PORT=\K.*' .env 2>/dev/null || echo "$DEFAULT_API_PORT")"

    info "等待 API 启动..."

    for i in {1..60}; do
        if curl -fsSL "http://127.0.0.1:${port}/health" >/dev/null 2>&1; then
            info "API 已就绪。"
            return 0
        fi
        sleep 2
    done

    warn "服务可能没有正常启动，最近日志如下："
    docker logs --tail=120 "$API_CONTAINER" 2>/dev/null || true
    return 1
}

deploy_dujiao_next() {
    info "开始部署 Dujiao-Next..."

    require_cmd docker
    require_cmd curl
    require_cmd awk
    require_cmd tar
    require_cmd openssl
    require_cmd python3
    ensure_sqlite3

    local dc_cmd
    dc_cmd="$(docker_compose_cmd)"

    read -r -p "安装路径 [回车默认: $DEFAULT_INSTALL_PATH]: " input_path
    local install_path="${input_path:-$DEFAULT_INSTALL_PATH}"

    if [[ -d "$install_path" && "$(ls -A "$install_path" 2>/dev/null)" ]]; then
        err "目标目录已存在且非空：$install_path"
        err "请先执行 [8] 完全卸载，或换一个目录。"
        return
    fi

    read -r -p "API 本机端口 [回车默认: $DEFAULT_API_PORT]: " input_api_port
    local api_port="${input_api_port:-$DEFAULT_API_PORT}"
    valid_port "$api_port" || die "API 端口非法。"

    read -r -p "前台端口 [回车默认: $DEFAULT_USER_PORT]: " input_user_port
    local user_port="${input_user_port:-$DEFAULT_USER_PORT}"
    valid_port "$user_port" || die "前台端口非法。"

    read -r -p "后台端口 [回车默认: $DEFAULT_ADMIN_PORT]: " input_admin_port
    local admin_port="${input_admin_port:-$DEFAULT_ADMIN_PORT}"
    valid_port "$admin_port" || die "后台端口非法。"

    local user_bind_ip="127.0.0.1"
    local admin_bind_ip="127.0.0.1"

    read -r -p "前台是否允许公网直接访问？(y/N): " public_user
    [[ "$public_user" =~ ^[Yy]$ ]] && user_bind_ip="0.0.0.0"

    read -r -p "后台是否允许公网直接访问？不建议开启 (y/N): " public_admin
    [[ "$public_admin" =~ ^[Yy]$ ]] && admin_bind_ip="0.0.0.0"

    mkdir -p "$install_path"/{config,nginx,data/db,data/uploads,data/logs,data/redis,backups}
    chmod -R 0777 "$install_path"/data 2>/dev/null || true

    echo "$install_path" > "$ENV_RECORD_FILE"
    cd "$install_path" || return

    generate_passwords
    write_pwd_file "$install_path"
    write_env_file "$install_path" "$api_port" "$user_port" "$admin_port" "$user_bind_ip" "$admin_bind_ip"
    create_compose_file "$install_path"
    create_nginx_files "$install_path"
    download_config "$install_path"
    patch_config_yml "$install_path"

    info "拉取官方镜像并启动..."
    $dc_cmd --env-file .env -f "$COMPOSE_FILE" pull || die "镜像拉取失败。"
    $dc_cmd --env-file .env -f "$COMPOSE_FILE" up -d --force-recreate || die "服务启动失败。"

    wait_app_ready || true
    show_access "$install_path"
}

upgrade_service() {
    local workdir
    workdir="$(get_workdir)"
    [[ -z "$workdir" ]] && { err "未找到部署记录。"; return; }

    ensure_sqlite3

    cd "$workdir" || return

    REDIS_PASS="$(grep -oP '^REDIS_PASSWORD=\K.*' .env 2>/dev/null || true)"
    [[ -n "$REDIS_PASS" ]] && patch_config_yml "$workdir"

    create_nginx_files "$workdir"
    create_compose_file "$workdir"

    info "开始升级..."
    compose_run pull || die "镜像拉取失败。"
    compose_run up -d --force-recreate || die "服务重建失败。"

    wait_app_ready || true
    show_access "$workdir"
}

pause_service() {
    local workdir
    workdir="$(get_workdir)"
    [[ -z "$workdir" ]] && { err "未发现部署环境。"; return; }
    cd "$workdir" || return
    compose_run stop
    info "服务已停止。"
}

restart_service() {
    local workdir
    workdir="$(get_workdir)"
    [[ -z "$workdir" ]] && { err "未发现部署环境。"; return; }

    cd "$workdir" || return

    REDIS_PASS="$(grep -oP '^REDIS_PASSWORD=\K.*' .env 2>/dev/null || true)"
    [[ -n "$REDIS_PASS" ]] && patch_config_yml "$workdir"

    create_nginx_files "$workdir"
    create_compose_file "$workdir"

    compose_run up -d --force-recreate
    wait_app_ready || true
    show_access "$workdir"
}

do_backup() {
    local workdir
    workdir="$(get_workdir)"
    [[ -z "$workdir" ]] && { err "未找到部署环境。"; return; }

    local backup_dir="${workdir}/backups"
    mkdir -p "$backup_dir"

    local timestamp
    timestamp="$(date +"%Y%m%d_%H%M%S")"

    local temp_dir="/tmp/dujiaonext_backup_tmp_${timestamp}"
    rm -rf "$temp_dir"
    mkdir -p "$temp_dir"

    cp "${workdir}/${COMPOSE_FILE}" "${temp_dir}/" 2>/dev/null || true
    cp "${workdir}/.env" "${temp_dir}/" 2>/dev/null || true
    [[ -d "${workdir}/config" ]] && cp -r "${workdir}/config" "${temp_dir}/config"
    [[ -d "${workdir}/nginx" ]] && cp -r "${workdir}/nginx" "${temp_dir}/nginx"
    [[ -d "${workdir}/data" ]] && cp -r "${workdir}/data" "${temp_dir}/data"

    local backup_file="${backup_dir}/dujiaonext_backup_${timestamp}.tar.gz"

    tar -czf "$backup_file" -C "$temp_dir" .
    rm -rf "$temp_dir"

    cd "$backup_dir" || return
    ls -t dujiaonext_backup_*.tar.gz 2>/dev/null | awk 'NR>20' | xargs -r rm -f

    info "备份完成: ${backup_file}"
}

restore_backup() {
    local workdir
    workdir="$(get_workdir)"

    ensure_sqlite3

    local search_dir="${workdir:-$DEFAULT_INSTALL_PATH}/backups"
    local default_backup
    default_backup="$(ls -t "${search_dir}"/dujiaonext_backup_*.tar.gz 2>/dev/null | head -n 1 || true)"

    read -r -p "输入备份文件路径 [回车使用最新备份: ${default_backup}]: " backup_path
    local path="${backup_path:-$default_backup}"

    [[ ! -f "$path" ]] && {
        err "备份文件不存在。"
        return
    }

    mkdir -p /root/dujiaonext-backups-safe
    local safe_backup="/root/dujiaonext-backups-safe/$(basename "$path")"
    cp -f "$path" "$safe_backup" || die "复制备份到安全目录失败。"

    read -r -p "恢复目标目录 [回车默认: $DEFAULT_INSTALL_PATH]: " target_dir
    local wd="${target_dir:-$DEFAULT_INSTALL_PATH}"

    local timestamp
    timestamp="$(date +"%Y%m%d_%H%M%S")"
    local old_dir="${wd}.before_restore_${timestamp}"

    if [[ -d "$wd" ]]; then
        warn "目标目录已存在，不会删除。"
        read -r -p "是否停止服务并把当前目录改名为 ${old_dir} 后恢复？(y/N): " confirm

        [[ ! "$confirm" =~ ^[Yy]$ ]] && {
            warn "已取消恢复。"
            return
        }

        if [[ -f "$wd/$COMPOSE_FILE" ]]; then
            cd "$wd" 2>/dev/null && {
                docker compose --env-file .env -f "$COMPOSE_FILE" down --remove-orphans 2>/dev/null || true
                docker-compose --env-file .env -f "$COMPOSE_FILE" down --remove-orphans 2>/dev/null || true
            }
        fi

        mv "$wd" "$old_dir" || die "旧目录改名失败，未执行恢复。"
        info "旧目录已保留: ${old_dir}"
    fi

    mkdir -p "$wd"

    tar -xzf "$safe_backup" -C "$wd" || die "解压备份失败。"

    mkdir -p "$wd/backups"
    cp -f "$safe_backup" "$wd/backups/$(basename "$safe_backup")" 2>/dev/null || true

    echo "$wd" > "$ENV_RECORD_FILE"

    cd "$wd" || return
    chmod -R 0777 data 2>/dev/null || true

    REDIS_PASS="$(grep -oP '^REDIS_PASSWORD=\K.*' .env 2>/dev/null || true)"
    [[ -n "$REDIS_PASS" ]] && patch_config_yml "$wd"

    create_nginx_files "$wd"
    create_compose_file "$wd"

    compose_run up -d --force-recreate || die "恢复后启动失败。"

    wait_app_ready || true
    show_access "$wd"
}

setup_auto_backup() {
    require_cmd crontab

    local workdir
    workdir="$(get_workdir)"

    [[ -z "$workdir" ]] && {
        err "环境未部署。"
        return
    }

    local cron_script="${workdir}/cron_backup.sh"
    local script_path
    script_path="$(readlink -f "${BASH_SOURCE[0]}")"

    echo " 1) 每 3 分钟备份，推荐"
    echo " 2) 自定义每隔 N 分钟备份"
    echo " 3) 每天固定时间备份"
    echo " 4) 删除定时备份"

    read -r -p "请选择 [1/2/3/4，回车默认 1]: " cron_type
    cron_type="${cron_type:-1}"

    local cron_spec=""

    case "$cron_type" in
        1)
            cron_spec="*/3 * * * *"
        ;;
        2)
            read -r -p "输入间隔分钟数，例如 3/5/10/15/30/60: " min_interval
            [[ "$min_interval" =~ ^[0-9]+$ ]] || { err "分钟数非法。"; return; }
            cron_spec="*/${min_interval} * * * *"
        ;;
        3)
            read -r -p "输入时间，例如 04:30: " cron_time
            local hour="${cron_time%:*}"
            local minute="${cron_time#*:}"
            [[ "$hour" =~ ^[0-9]+$ && "$minute" =~ ^[0-9]+$ ]] || { err "时间格式错误。"; return; }
            cron_spec="${minute} ${hour} * * *"
        ;;
        4)
            crontab -l 2>/dev/null | sed "/${CRON_TAG_BEGIN}/,/${CRON_TAG_END}/d" | crontab - 2>/dev/null || true
            rm -f "$cron_script"
            info "定时备份已删除。"
            return
        ;;
        *)
            err "选择无效。"
            return
        ;;
    esac

    cat > "$cron_script" <<EOF
#!/usr/bin/env bash
bash "$script_path" run-backup >> "$BACKUP_LOG" 2>&1
EOF

    chmod +x "$cron_script"

    (
        crontab -l 2>/dev/null | sed "/${CRON_TAG_BEGIN}/,/${CRON_TAG_END}/d"
        echo "$CRON_TAG_BEGIN"
        echo "${cron_spec} bash ${cron_script}"
        echo "$CRON_TAG_END"
    ) | crontab -

    info "定时备份已设置: ${cron_spec}"
}

manage_goods_sold_count() {
    local workdir
    workdir="$(get_workdir)"

    [[ -z "$workdir" ]] && {
        err "未发现部署环境。"
        return
    }

    ensure_sqlite3

    local db_file
    db_file="$(find "$workdir/data/db" -type f \( -name "*.db" -o -name "*.sqlite" -o -name "*.sqlite3" \) 2>/dev/null | head -n 1)"

    [[ -z "$db_file" || ! -f "$db_file" ]] && {
        err "未找到 SQLite 数据库文件。"
        echo "搜索目录: $workdir/data/db"
        return
    }

    info "数据库文件: $db_file"

    local goods_table
    goods_table="$(sqlite3 "$db_file" "SELECT name FROM sqlite_master WHERE type='table' AND name IN ('goods','products','product','items') LIMIT 1;")"

    [[ -z "$goods_table" ]] && {
        err "未找到商品表。"
        echo "当前数据库表："
        sqlite3 "$db_file" ".tables"
        return
    }

    local sold_col=""
    for col in manual_stock_sold sold_count sold sales sales_count sold_num volume sales_volume; do
        if sqlite3 "$db_file" "PRAGMA table_info($goods_table);" | awk -F'|' '{print $2}' | grep -qx "$col"; then
            sold_col="$col"
            break
        fi
    done

    [[ -z "$sold_col" ]] && {
        err "未找到已售数量字段。"
        echo "商品表字段："
        sqlite3 "$db_file" "PRAGMA table_info($goods_table);"
        return
    }

    local name_col=""
    for col in title_json name title goods_name product_name; do
        if sqlite3 "$db_file" "PRAGMA table_info($goods_table);" | awk -F'|' '{print $2}' | grep -qx "$col"; then
            name_col="$col"
            break
        fi
    done

    [[ -z "$name_col" ]] && {
        err "未找到商品名称字段。"
        echo "商品表字段："
        sqlite3 "$db_file" "PRAGMA table_info($goods_table);"
        return
    }

    local category_col=""
    for col in category_id cate_id group_id class_id; do
        if sqlite3 "$db_file" "PRAGMA table_info($goods_table);" | awk -F'|' '{print $2}' | grep -qx "$col"; then
            category_col="$col"
            break
        fi
    done

    local category_table=""
    for tbl in categories category goods_categories goods_category product_categories product_category; do
        if sqlite3 "$db_file" "SELECT name FROM sqlite_master WHERE type='table' AND name='$tbl';" | grep -qx "$tbl"; then
            category_table="$tbl"
            break
        fi
    done

    local category_name_col=""
    if [[ -n "$category_table" ]]; then
        for col in name title category_name cate_name; do
            if sqlite3 "$db_file" "PRAGMA table_info($category_table);" | awk -F'|' '{print $2}' | grep -qx "$col"; then
                category_name_col="$col"
                break
            fi
        done
    fi

    echo ""
    echo "==================================================="
    echo "              修改商品已售数量"
    echo "==================================================="

    local selected_category=""

    if [[ -n "$category_table" && -n "$category_col" && -n "$category_name_col" ]]; then
        echo "分类列表："
        echo "---------------------------------------------------"
        sqlite3 -header -column "$db_file" "SELECT id AS 分类ID, $category_name_col AS 分类名称 FROM $category_table ORDER BY id ASC;"
        echo "---------------------------------------------------"
        read -r -p "请输入分类ID: " selected_category

        [[ ! "$selected_category" =~ ^[0-9]+$ ]] && {
            err "分类ID非法。"
            return
        }

        echo ""
        echo "商品列表："
        echo "---------------------------------------------------"
        sqlite3 -header -column "$db_file" "SELECT id AS 商品ID, $name_col AS 商品名称, $sold_col AS 已售数量 FROM $goods_table WHERE $category_col=$selected_category ORDER BY id ASC;"
    else
        warn "未识别到分类表或分类字段，将列出全部商品。"
        echo ""
        echo "商品列表："
        echo "---------------------------------------------------"
        sqlite3 -header -column "$db_file" "SELECT id AS 商品ID, $name_col AS 商品名称, $sold_col AS 已售数量 FROM $goods_table ORDER BY id ASC;"
    fi

    echo "---------------------------------------------------"

    read -r -p "请输入要修改的商品ID: " goods_id
    [[ ! "$goods_id" =~ ^[0-9]+$ ]] && {
        err "商品ID非法。"
        return
    }

    local exists
    if [[ -n "$selected_category" && -n "$category_col" ]]; then
        exists="$(sqlite3 "$db_file" "SELECT COUNT(*) FROM $goods_table WHERE id=$goods_id AND $category_col=$selected_category;")"
    else
        exists="$(sqlite3 "$db_file" "SELECT COUNT(*) FROM $goods_table WHERE id=$goods_id;")"
    fi

    [[ "$exists" != "1" ]] && {
        err "商品不存在。"
        return
    }

    local current_info
    current_info="$(sqlite3 "$db_file" "SELECT $name_col || ' 当前已售: ' || $sold_col FROM $goods_table WHERE id=$goods_id;")"
    echo "$current_info"

    read -r -p "请输入新的已售数量: " new_sold
    [[ ! "$new_sold" =~ ^[0-9]+$ ]] && {
        err "已售数量必须是非负整数。"
        return
    }

    sqlite3 "$db_file" "UPDATE $goods_table SET $sold_col=$new_sold WHERE id=$goods_id;" || {
        err "修改失败。"
        return
    }

    info "修改完成。"

    echo ""
    sqlite3 -header -column "$db_file" "SELECT id AS 商品ID, $name_col AS 商品名称, $sold_col AS 已售数量 FROM $goods_table WHERE id=$goods_id;"

    docker restart "$API_CONTAINER" >/dev/null 2>&1 || true
    docker restart "$USER_GATEWAY_CONTAINER" >/dev/null 2>&1 || true
}

uninstall_service() {
    local workdir
    workdir="$(get_workdir)"
    [[ -z "$workdir" ]] && workdir="$DEFAULT_INSTALL_PATH"

    echo -e "\033[31m⚠️ 警告：这会停止服务，并删除 Dujiao-Next 当前安装目录！\033[0m"
    read -r -p "确认完全卸载？请输入 y: " confirm
    [[ ! "$confirm" =~ ^[Yy]$ ]] && { warn "已取消卸载。"; return; }

    if [[ -d "$workdir" && -f "$workdir/$COMPOSE_FILE" ]]; then
        cd "$workdir" 2>/dev/null && {
            docker compose --env-file .env -f "$COMPOSE_FILE" down -v --remove-orphans 2>/dev/null || true
            docker-compose --env-file .env -f "$COMPOSE_FILE" down -v --remove-orphans 2>/dev/null || true
        }
    fi

    docker rm -f \
        "$API_CONTAINER" "$USER_CONTAINER" "$ADMIN_CONTAINER" "$REDIS_CONTAINER" \
        "$USER_GATEWAY_CONTAINER" "$ADMIN_GATEWAY_CONTAINER" \
        dujiao_next dujiao-next 2>/dev/null || true

    docker network ls --format '{{.Name}}' | grep -Ei 'dujiao|dujiaonext' | xargs -r docker network rm 2>/dev/null || true
    docker volume ls -q | grep -Ei 'dujiao|dujiaonext' | xargs -r docker volume rm -f 2>/dev/null || true

    cd /
    rm -rf "$workdir"
    rm -f "$ENV_RECORD_FILE"
    rm -f "$BACKUP_LOG"
    rm -f /etc/cron.d/dujiaonext /etc/cron.d/dujiao-next 2>/dev/null || true

    crontab -l 2>/dev/null | sed "/${CRON_TAG_BEGIN}/,/${CRON_TAG_END}/d" | crontab - 2>/dev/null || true

    docker system prune -f >/dev/null 2>&1 || true

    uninstall_sqlite3_if_auto_installed

    info "卸载完成。"
}

install_ftp() {
    clear
    echo -e "\033[32m📂 FTP/SFTP 备份工具加载中...\033[0m"
    bash <(curl -fsSL https://raw.githubusercontent.com/hiapb/ftp/main/back.sh | sed 's/\r$//')
    sleep 2
    exit 0
}

reset_admin_password() {
    local workdir
    workdir="$(get_workdir)"

    [[ -z "$workdir" ]] && {
        err "未发现部署环境。"
        return
    }

    cd "$workdir" || return

    local new_pass
    new_pass="$(openssl rand -hex 16)"

    sed -i "s/^DJ_DEFAULT_ADMIN_PASSWORD=.*/DJ_DEFAULT_ADMIN_PASSWORD=${new_pass}/" .env

    ADMIN_PASS="$new_pass"
    REDIS_PASS="$(grep -oP '^REDIS_PASSWORD=\K.*' .env 2>/dev/null || true)"
    write_pwd_file "$workdir"

    warn "注意：默认后台密码通常只在首次初始化管理员时生效。"
    compose_run up -d --force-recreate
    show_access "$workdir"
}

show_logs() {
    local workdir
    workdir="$(get_workdir)"

    [[ -z "$workdir" ]] && {
        err "未发现部署环境。"
        return
    }

    cd "$workdir" || return
    compose_run ps
    echo ""
    compose_run logs --tail=160 api
    echo ""
    compose_run logs --tail=80 user-gateway
    echo ""
    compose_run logs --tail=80 admin-gateway
}

main_menu() {
    clear
    echo "==================================================="
    echo "              Dujiao-Next 一键管理"
    echo "==================================================="

    local wd
    wd="$(get_workdir)"

    echo -e " 当前安装目录: \033[36m${wd:-未部署}\033[0m"
    echo "---------------------------------------------------"
    echo "  1) 一键部署"
    echo "  2) 升级服务"
    echo "  3) 停止服务"
    echo "  4) 重启服务"
    echo "  5) 手动备份"
    echo "  6) 恢复备份"
    echo "  7) 定时备份"
    echo "  8) 完全卸载"
    echo "  9) FTP/SFTP 备份工具"
    echo " 10) 重置后台密码"
    echo " 11) 查看状态和日志"
    echo " 12) 修改商品已售数量"
    echo "  0) 退出"
    echo "==================================================="

    read -r -p "请输入选项 [0-12]: " choice

    case "$choice" in
        1) deploy_dujiao_next ;;
        2) upgrade_service ;;
        3) pause_service ;;
        4) restart_service ;;
        5) do_backup ;;
        6) restore_backup ;;
        7) setup_auto_backup ;;
        8) uninstall_service ;;
        9) install_ftp ;;
        10) reset_admin_password ;;
        11) show_logs ;;
        12) manage_goods_sold_count ;;
        0) info "已退出。"; exit 0 ;;
        *) warn "无效选项。" ;;
    esac
}

if [[ "${1:-}" == "run-backup" ]]; then
    do_backup
else
    if [[ $EUID -ne 0 ]]; then
        die "请使用 root 用户运行。"
    fi

    while true; do
        main_menu
        echo ""
        read -r -p "按回车返回主菜单..."
    done
fi

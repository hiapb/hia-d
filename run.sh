#!/usr/bin/env bash

set -o pipefail

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH"

DEFAULT_INSTALL_PATH="/opt/dujiao-next"
ENV_RECORD_FILE="/etc/dujiaonext_env"
COMPOSE_FILE="docker-compose.yml"

CRON_TAG_BEGIN="# DUJIAO_NEXT_BACKUP_BEGIN"
CRON_TAG_END="# DUJIAO_NEXT_BACKUP_END"
BACKUP_LOG="/var/log/dujiaonext_backup.log"

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
    healthcheck:
      test: ["CMD", "wget", "-qO-", "http://127.0.0.1:8080/health"]
      interval: 10s
      timeout: 3s
      retries: 10
    networks:
      - dujiao-net

  user:
    image: dujiaonext/user:${TAG}
    container_name: dujiaonext-user
    restart: unless-stopped
    expose:
      - "80"
    depends_on:
      api:
        condition: service_healthy
    networks:
      - dujiao-net

  admin:
    image: dujiaonext/admin:${TAG}
    container_name: dujiaonext-admin
    restart: unless-stopped
    expose:
      - "80"
    depends_on:
      api:
        condition: service_healthy
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

    location / {
        proxy_pass http://user:80;
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
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }

    location = /sitemap.xml {
        proxy_pass http://api:8080/sitemap.xml;
        proxy_set_header Host $host;
    }

    location = /robots.txt {
        proxy_pass http://api:8080/robots.txt;
        proxy_set_header Host $host;
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
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
EOF
}

download_config() {
    local workdir="$1"
    local cfg="${workdir}/config/config.yml"

    if [[ -f "$cfg" ]]; then
        warn "已存在 config/config.yml，跳过下载。"
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
    echo -e "\033[32m✅ Dujiao-Next 已部署\033[0m"
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

    [[ -z "$workdir" ]] && {
        err "未找到部署记录。"
        return
    }

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

    local temp_dir="${backup_dir}/tmp_${timestamp}"
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
    ls -t dujiaonext_backup_*.tar.gz 2>/dev/null | awk 'NR>5' | xargs -r rm -f

    info "备份完成: ${backup_file}"
}

restore_backup() {
    local workdir
    workdir="$(get_workdir)"

    local search_dir="${workdir:-$DEFAULT_INSTALL_PATH}/backups"
    local default_backup
    default_backup="$(ls -t "${search_dir}"/dujiaonext_backup_*.tar.gz 2>/dev/null | head -n 1 || true)"

    read -r -p "输入备份文件路径 [回车使用最新备份: ${default_backup}]: " backup_path
    local path="${backup_path:-$default_backup}"

    [[ ! -f "$path" ]] && {
        err "备份文件不存在。"
        return
    }

    read -r -p "恢复目标目录 [回车默认: $DEFAULT_INSTALL_PATH]: " target_dir
    local wd="${target_dir:-$DEFAULT_INSTALL_PATH}"

    if [[ -d "$wd" ]]; then
        read -r -p "目标目录已存在，是否删除并恢复？(y/N): " confirm
        [[ ! "$confirm" =~ ^[Yy]$ ]] && return

        cd "$wd" 2>/dev/null && {
            docker compose --env-file .env -f "$COMPOSE_FILE" down -v --remove-orphans 2>/dev/null || true
            docker-compose --env-file .env -f "$COMPOSE_FILE" down -v --remove-orphans 2>/dev/null || true
        }
        cd /
        rm -rf "$wd"
    fi

    mkdir -p "$wd"
    tar -xzf "$path" -C "$wd" || die "解压备份失败。"

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

    echo " 1) 每隔 N 分钟备份"
    echo " 2) 每天固定时间备份"
    echo " 3) 删除定时备份"

    read -r -p "请选择 [1/2/3]: " cron_type
    local cron_spec=""

    case "$cron_type" in
        1)
            read -r -p "输入间隔分钟数，例如 10/15/20/30/60: " min_interval
            [[ "$min_interval" =~ ^[0-9]+$ ]] || { err "分钟数非法。"; return; }
            cron_spec="*/${min_interval} * * * *"
        ;;
        2)
            read -r -p "输入时间，例如 04:30: " cron_time
            local hour="${cron_time%:*}"
            local minute="${cron_time#*:}"
            [[ "$hour" =~ ^[0-9]+$ && "$minute" =~ ^[0-9]+$ ]] || { err "时间格式错误。"; return; }
            cron_spec="${minute} ${hour} * * *"
        ;;
        3)
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

    info "定时备份已设置。"
}

uninstall_service() {
    local workdir
    workdir="$(get_workdir)"
    [[ -z "$workdir" ]] && workdir="$DEFAULT_INSTALL_PATH"

    echo -e "\033[31m⚠️ 警告：这会停止服务，并删除 Dujiao-Next 本地数据！\033[0m"
    read -r -p "确认完全卸载？请输入 y: " confirm
    [[ ! "$confirm" =~ ^[Yy]$ ]] && { warn "已取消卸载。"; return; }

    info "停止 compose 服务..."

    if [[ -d "$workdir" && -f "$workdir/$COMPOSE_FILE" ]]; then
        cd "$workdir" 2>/dev/null && {
            docker compose --env-file .env -f "$COMPOSE_FILE" down -v --remove-orphans 2>/dev/null || true
            docker-compose --env-file .env -f "$COMPOSE_FILE" down -v --remove-orphans 2>/dev/null || true
        }
    fi

    info "删除相关容器..."
    docker rm -f \
        "$API_CONTAINER" \
        "$USER_CONTAINER" \
        "$ADMIN_CONTAINER" \
        "$REDIS_CONTAINER" \
        "$USER_GATEWAY_CONTAINER" \
        "$ADMIN_GATEWAY_CONTAINER" \
        dujiao_next \
        dujiao-next \
        2>/dev/null || true

    info "删除相关网络..."
    docker network ls --format '{{.Name}}' \
        | grep -Ei 'dujiao|dujiaonext' \
        | xargs -r docker network rm 2>/dev/null || true

    info "删除相关卷..."
    docker volume ls -q \
        | grep -Ei 'dujiao|dujiaonext' \
        | xargs -r docker volume rm -f 2>/dev/null || true

    info "删除安装目录和记录文件..."
    cd /
    rm -rf "$workdir"
    rm -rf "$DEFAULT_INSTALL_PATH"
    rm -f "$ENV_RECORD_FILE"
    rm -f "$BACKUP_LOG"
    rm -f /etc/cron.d/dujiaonext /etc/cron.d/dujiao-next 2>/dev/null || true

    info "清理定时任务..."
    crontab -l 2>/dev/null \
        | sed "/${CRON_TAG_BEGIN}/,/${CRON_TAG_END}/d" \
        | crontab - 2>/dev/null || true

    docker system prune -f >/dev/null 2>&1 || true

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
    echo "  0) 退出"
    echo "==================================================="

    read -r -p "请输入选项 [0-11]: " choice

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

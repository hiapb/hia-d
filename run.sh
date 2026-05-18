#!/usr/bin/env bash

set -o pipefail

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH"

DEFAULT_INSTALL_PATH="/opt/dujiao-next"
ENV_RECORD_FILE="/etc/dujiaonext_env"
COMPOSE_FILE="docker-compose.sqlite.yml"

CRON_TAG_BEGIN="# DUJIAO_NEXT_BACKUP_BEGIN"
CRON_TAG_END="# DUJIAO_NEXT_BACKUP_END"
BACKUP_LOG="/var/log/dujiaonext_backup.log"

API_CONTAINER="dujiaonext-api"
USER_CONTAINER="dujiaonext-user"
ADMIN_CONTAINER="dujiaonext-admin"
REDIS_CONTAINER="dujiaonext-redis"

DEFAULT_API_PORT="39180"
DEFAULT_USER_PORT="34567"
DEFAULT_ADMIN_PORT="39282"

ADMIN_USER="admin"
ADMIN_PASS=""
REDIS_PASS=""

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
        die "未检测到 Docker Compose，请先安装 Docker / Docker Compose。"
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

    cat > "${workdir}/${COMPOSE_FILE}" <<'DOCKEREOF'
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
    environment:
      TZ: ${TZ}
    ports:
      - "${USER_BIND_IP}:${USER_PORT}:80"
    depends_on:
      - api
    networks:
      - dujiao-net

  admin:
    image: dujiaonext/admin:${TAG}
    container_name: dujiaonext-admin
    restart: unless-stopped
    environment:
      TZ: ${TZ}
    ports:
      - "${ADMIN_BIND_IP}:${ADMIN_PORT}:80"
    depends_on:
      - api
    networks:
      - dujiao-net

networks:
  dujiao-net:
    driver: bridge
DOCKEREOF
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
import sys
import re
import secrets
import string

path = sys.argv[1]
redis_pass = sys.argv[2]

text = open(path, "r", encoding="utf-8").read()

text = text.replace("\r\n", "\n").replace("\r", "\n")

text = re.sub(r'(?m)^(\s*host:\s*)(127\.0\.0\.1|localhost)\s*$', r'\1redis', text)

if re.search(r'(?m)^redis:\s*$', text):
    text = re.sub(
        r'(?ms)^redis:\s*\n(?:^[ \t]+.*\n?)*',
        f'''redis:
  host: redis
  port: 6379
  password: {redis_pass}
  db: 0
''',
        text,
        count=1
    )
else:
    text += f'''

redis:
  host: redis
  port: 6379
  password: {redis_pass}
  db: 0
'''

text = re.sub(r'(?m)^(\s*driver:\s*)mysql\s*$', r'\1sqlite', text)
text = re.sub(r'(?m)^(\s*driver:\s*)postgres\s*$', r'\1sqlite', text)
text = re.sub(r'(?m)^(\s*dsn:\s*).+$', r'\1/app/db/dujiao.db', text)

alphabet = string.ascii_letters + string.digits
jwt1 = ''.join(secrets.choice(alphabet) for _ in range(48))
jwt2 = ''.join(secrets.choice(alphabet) for _ in range(48))

text = re.sub(r'(?m)^(\s*secret:\s*)your.*$', r'\1' + jwt1, text, count=1)
text = re.sub(r'(?m)^(\s*secret:\s*)change.*$', r'\1' + jwt2, text, count=1)

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

    cat > "${workdir}/.env" <<ENVEFF
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
ENVEFF
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

    if [[ "$user_bind_ip" == "0.0.0.0" ]]; then
        echo -e "前台地址: \033[36mhttp://${ip}:${user_port}\033[0m"
    else
        echo -e "前台地址: \033[36mhttp://127.0.0.1:${user_port}\033[0m"
    fi

    if [[ "$admin_bind_ip" == "0.0.0.0" ]]; then
        echo -e "后台地址: \033[36mhttp://${ip}:${admin_port}\033[0m"
    else
        echo -e "后台地址: \033[36mhttp://127.0.0.1:${admin_port}\033[0m"
    fi

    echo "--------------------------------------------------"
    echo "$(read_pwd_file "$workdir")"
    echo "密码文件: ${workdir}/config/passwords.txt"
    echo "安装目录: ${workdir}"
    echo "=================================================="
    echo ""
}

wait_app_ready() {
    info "等待容器启动..."

    for i in {1..60}; do
        if docker ps --format '{{.Names}} {{.Status}}' | grep -q "^${API_CONTAINER} .*Up"; then
            if curl -fsSL "http://127.0.0.1:$(grep -oP '^API_PORT=\K.*' .env)/health" >/dev/null 2>&1; then
                info "API 已就绪。"
                return 0
            fi
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
        err "请先执行菜单 [8] 完全卸载，或换一个目录。"
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
    if [[ "$public_user" =~ ^[Yy]$ ]]; then
        user_bind_ip="0.0.0.0"
    fi

    read -r -p "后台是否允许公网直接访问？不建议开启 (y/N): " public_admin
    if [[ "$public_admin" =~ ^[Yy]$ ]]; then
        admin_bind_ip="0.0.0.0"
    fi

    mkdir -p "$install_path"/{config,data/db,data/uploads,data/logs,data/redis,backups}
    chmod -R 0777 "$install_path"/data 2>/dev/null || true

    echo "$install_path" > "$ENV_RECORD_FILE"
    cd "$install_path" || return

    generate_passwords
    write_pwd_file "$install_path"
    write_env_file "$install_path" "$api_port" "$user_port" "$admin_port" "$user_bind_ip" "$admin_bind_ip"
    create_compose_file "$install_path"
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

    info "开始升级..."
    compose_run pull || die "镜像拉取失败。"
    compose_run up -d --force-recreate || die "服务重建失败。"

    wait_app_ready || true
    show_access "$workdir"
}

pause_service() {
    local workdir
    workdir="$(get_workdir)"

    [[ -z "$workdir" ]] && {
        err "未发现部署环境。"
        return
    }

    cd "$workdir" || return
    compose_run stop
    info "服务已停止。"
}

restart_service() {
    local workdir
    workdir="$(get_workdir)"

    [[ -z "$workdir" ]] && {
        err "未发现部署环境。"
        return
    }

    cd "$workdir" || return

    local redis_env
    redis_env="$(grep -oP '^REDIS_PASSWORD=\K.*' .env 2>/dev/null || true)"

    if [[ -n "$redis_env" ]]; then
        REDIS_PASS="$redis_env"
        patch_config_yml "$workdir"
    fi

    compose_run up -d --force-recreate
    wait_app_ready || true
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
}

change_ports() {
    local workdir
    workdir="$(get_workdir)"

    [[ -z "$workdir" ]] && {
        err "未发现部署环境。"
        return
    }

    cd "$workdir" || return

    local old_api old_user old_admin old_user_bind old_admin_bind
    old_api="$(grep -oP '^API_PORT=\K.*' .env || echo "$DEFAULT_API_PORT")"
    old_user="$(grep -oP '^USER_PORT=\K.*' .env || echo "$DEFAULT_USER_PORT")"
    old_admin="$(grep -oP '^ADMIN_PORT=\K.*' .env || echo "$DEFAULT_ADMIN_PORT")"
    old_user_bind="$(grep -oP '^USER_BIND_IP=\K.*' .env || echo "127.0.0.1")"
    old_admin_bind="$(grep -oP '^ADMIN_BIND_IP=\K.*' .env || echo "127.0.0.1")"

    read -r -p "API 本机端口 [当前: ${old_api}]: " new_api
    new_api="${new_api:-$old_api}"
    valid_port "$new_api" || die "API 端口非法。"

    read -r -p "前台端口 [当前: ${old_user}]: " new_user
    new_user="${new_user:-$old_user}"
    valid_port "$new_user" || die "前台端口非法。"

    read -r -p "后台端口 [当前: ${old_admin}]: " new_admin
    new_admin="${new_admin:-$old_admin}"
    valid_port "$new_admin" || die "后台端口非法。"

    local new_user_bind="$old_user_bind"
    local new_admin_bind="$old_admin_bind"

    read -r -p "前台公网监听？输入 y 公网 / n 本机 / 回车不变: " pub_user
    if [[ "$pub_user" =~ ^[Yy]$ ]]; then
        new_user_bind="0.0.0.0"
    elif [[ "$pub_user" =~ ^[Nn]$ ]]; then
        new_user_bind="127.0.0.1"
    fi

    read -r -p "后台公网监听？输入 y 公网 / n 本机 / 回车不变: " pub_admin
    if [[ "$pub_admin" =~ ^[Yy]$ ]]; then
        new_admin_bind="0.0.0.0"
    elif [[ "$pub_admin" =~ ^[Nn]$ ]]; then
        new_admin_bind="127.0.0.1"
    fi

    sed -i "s/^API_PORT=.*/API_PORT=${new_api}/" .env
    sed -i "s/^USER_PORT=.*/USER_PORT=${new_user}/" .env
    sed -i "s/^ADMIN_PORT=.*/ADMIN_PORT=${new_admin}/" .env
    sed -i "s/^USER_BIND_IP=.*/USER_BIND_IP=${new_user_bind}/" .env
    sed -i "s/^ADMIN_BIND_IP=.*/ADMIN_BIND_IP=${new_admin_bind}/" .env

    compose_run up -d --force-recreate
    show_access "$workdir"
}

fix_redis_config() {
    local workdir
    workdir="$(get_workdir)"

    [[ -z "$workdir" ]] && {
        err "未发现部署环境。"
        return
    }

    cd "$workdir" || return

    local redis_env
    redis_env="$(grep -oP '^REDIS_PASSWORD=\K.*' .env 2>/dev/null || true)"

    [[ -z "$redis_env" ]] && die ".env 中找不到 REDIS_PASSWORD。"

    REDIS_PASS="$redis_env"
    patch_config_yml "$workdir"

    compose_run down --remove-orphans
    compose_run up -d --force-recreate

    wait_app_ready || true
    show_access "$workdir"
}

do_backup() {
    local workdir
    workdir="$(get_workdir)"

    [[ -z "$workdir" ]] && {
        err "未找到部署环境。"
        return
    }

    local backup_dir="${workdir}/backups"
    mkdir -p "$backup_dir"

    local timestamp
    timestamp="$(date +"%Y%m%d_%H%M%S")"

    local temp_dir="${backup_dir}/tmp_${timestamp}"
    mkdir -p "$temp_dir"

    cp "${workdir}/${COMPOSE_FILE}" "${temp_dir}/" 2>/dev/null || true
    cp "${workdir}/.env" "${temp_dir}/" 2>/dev/null || true
    [[ -d "${workdir}/config" ]] && cp -r "${workdir}/config" "${temp_dir}/config"
    [[ -d "${workdir}/data" ]] && cp -r "${workdir}/data" "${temp_dir}/data"

    local backup_file="${backup_dir}/dujiaonext_backup_${timestamp}.tar.gz"

    tar -czf "$backup_file" -C "$temp_dir" .
    rm -rf "$temp_dir"

    cd "$backup_dir" || return
    ls -t dujiaonext_backup_*.tar.gz 2>/dev/null | awk 'NR>5' | xargs -r rm -f

    info "备份完成: ${backup_file}"
}

uninstall_service() {
    local workdir
    workdir="$(get_workdir)"

    [[ -z "$workdir" ]] && workdir="$DEFAULT_INSTALL_PATH"

    echo -e "\033[31m⚠️ 警告：这会停止服务，并删除 Dujiao-Next 本地数据！\033[0m"
    read -r -p "确认完全卸载？请输入 y: " confirm
    [[ ! "$confirm" =~ ^[Yy]$ ]] && {
        warn "已取消卸载。"
        return
    }

    info "停止 compose 服务..."

    if [[ -d "$workdir" ]]; then
        if [[ -f "$workdir/$COMPOSE_FILE" ]]; then
            cd "$workdir" 2>/dev/null && {
                docker compose --env-file .env -f "$COMPOSE_FILE" down -v --remove-orphans 2>/dev/null || true
                docker-compose --env-file .env -f "$COMPOSE_FILE" down -v --remove-orphans 2>/dev/null || true
            }
        fi
    fi

    info "删除相关容器..."
    docker rm -f \
        "$API_CONTAINER" \
        "$USER_CONTAINER" \
        "$ADMIN_CONTAINER" \
        "$REDIS_CONTAINER" \
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

    info "清理悬空资源..."
    docker system prune -f >/dev/null 2>&1 || true

    info "卸载完成。"
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
    echo "  6) 修复 Redis 配置/NOAUTH"
    echo "  7) 查看状态和 API 日志"
    echo "  8) 完全卸载"
    echo "  9) 修改端口/公网监听"
    echo "  0) 退出"
    echo "==================================================="

    read -r -p "请输入选项 [0-9]: " choice

    case "$choice" in
        1) deploy_dujiao_next ;;
        2) upgrade_service ;;
        3) pause_service ;;
        4) restart_service ;;
        5) do_backup ;;
        6) fix_redis_config ;;
        7) show_logs ;;
        8) uninstall_service ;;
        9) change_ports ;;
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

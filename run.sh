#!/usr/bin/env bash

# ==========================================
# Dujiao-Next
# ==========================================

set -o pipefail

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH"

DEFAULT_INSTALL_PATH="/opt/dujiao-next"
ENV_RECORD_FILE="/etc/dujiaonext_env"

CRON_TAG_BEGIN="# DUJIAO_BACKUP_BEGIN"
CRON_TAG_END="# DUJIAO_BACKUP_END"
BACKUP_LOG="/var/log/dujiaonext_backup.log"

CONTAINER_NAME="dujiao_next"
IMAGE_NAME="ghcr.io/apernet/dujiao-next:latest"

DEFAULT_HOST_PORT="34567"

ADMIN_PASS=""

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
    if command -v docker-compose >/dev/null 2>&1; then
        echo "docker-compose"
    elif docker compose version >/dev/null 2>&1; then
        echo "docker compose"
    else
        die "未检测到 Docker Compose，请先安装 Docker / Docker Compose。"
    fi
}

get_workdir() {
    [[ -f "$ENV_RECORD_FILE" ]] && cat "$ENV_RECORD_FILE" || echo ""
}

generate_admin_password() {
    ADMIN_PASS="$(openssl rand -hex 16)"
}

write_pwd_file() {
    local workdir="$1"
    mkdir -p "${workdir}/configs"
    echo -n "$ADMIN_PASS" > "${workdir}/configs/pwd"
    chmod 600 "${workdir}/configs/pwd"
}

read_pwd_file() {
    local workdir="$1"
    if [[ -f "${workdir}/configs/pwd" ]]; then
        cat "${workdir}/configs/pwd"
    else
        echo "未能读取"
    fi
}

show_access() {
    local workdir="$1"
    local env_file="${workdir}/.env"

    local host_port
    host_port="$(grep -oP '^PORT=\K.*' "$env_file" 2>/dev/null || echo "$DEFAULT_HOST_PORT")"

    local current_pass
    current_pass="$(read_pwd_file "$workdir")"

    echo ""
    echo "=================================================="
    echo -e "\033[32m✅ Dujiao-Next 实例已就绪\033[0m"
    echo "--------------------------------------------------"
    echo -e "Web 控制台: \033[36mhttp://$(get_local_ip):${host_port}\033[0m"
    echo "--------------------------------------------------"
    echo -e "初始管理密码: \033[31m${current_pass}\033[0m"
    echo -e "密码存储路径: \033[33m${workdir}/configs/pwd\033[0m"
    echo -e "核心数据目录: \033[33m${workdir}/configs\033[0m"
    echo "--------------------------------------------------"
    echo "网络映射:"
    echo "  主机端口 ${host_port} -> 容器端口 3000"
    echo "=================================================="
    echo ""
}

wait_app_ready() {
    info "等待 Dujiao-Next 容器启动..."

    for i in {1..60}; do
        if docker ps --format '{{.Names}} {{.Status}}' | grep -q "^${CONTAINER_NAME} .*Up"; then
            info "容器已启动。"
            return 0
        fi
        sleep 2
    done

    warn "服务可能未正常启动，请检查日志："
    docker logs --tail=100 "$CONTAINER_NAME" 2>/dev/null || true
    return 1
}

create_compose_file() {
    local workdir="$1"

    cat > "${workdir}/docker-compose.yml" <<DOCKEREOF
services:
  dujiao-next:
    image: ${IMAGE_NAME}
    container_name: ${CONTAINER_NAME}
    restart: always
    ports:
      - "\${PORT}:3000"
    volumes:
      - ./configs:/app/configs
      - ./data:/app/data
    environment:
      - TZ=\${TZ}
      - APP_ENV=production
DOCKEREOF
}

deploy_dujiao_next() {
    info "开始部署 Dujiao-Next..."

    require_cmd docker
    require_cmd curl
    require_cmd tar
    require_cmd awk
    require_cmd openssl

    local dc_cmd
    dc_cmd="$(docker_compose_cmd)"

    read -r -p "安装路径 [回车默认: $DEFAULT_INSTALL_PATH]: " input_path
    local install_path="${input_path:-$DEFAULT_INSTALL_PATH}"

    if [[ -d "$install_path" && "$(ls -A "$install_path" 2>/dev/null)" ]]; then
        err "目标目录已存在且非空，请先执行 [8] 完全卸载，或换一个目录。"
        return
    fi

    mkdir -p "$install_path"
    echo "$install_path" > "$ENV_RECORD_FILE"

    cd "$install_path" || return

    read -r -p "访问端口 [回车默认: $DEFAULT_HOST_PORT]: " input_port
    local host_port="${input_port:-$DEFAULT_HOST_PORT}"

    valid_port "$host_port" || die "端口非法，只允许 1-65535。"

    mkdir -p configs data backups
    chmod -R 755 backups data

    generate_admin_password
    write_pwd_file "$install_path"

    cat > .env <<ENVEFF
PORT=${host_port}
TZ=Asia/Shanghai
ENVEFF

    create_compose_file "$install_path"

    info "拉取镜像并启动服务..."

    $dc_cmd pull || warn "镜像拉取失败，将尝试直接启动。"
    $dc_cmd up -d || die "服务启动失败，请检查 Docker。"

    wait_app_ready || true
    show_access "$install_path"
}

upgrade_service() {
    local workdir
    workdir="$(get_workdir)"

    [[ -z "$workdir" ]] && {
        err "未找到部署记录，环境尚未部署。"
        return
    }

    cd "$workdir" || return

    local dc_cmd
    dc_cmd="$(docker_compose_cmd)"

    info "开始升级服务..."

    $dc_cmd pull || die "镜像拉取失败。"
    $dc_cmd up -d || die "服务重建失败。"

    wait_app_ready || true
    show_access "$workdir"
}

pause_service() {
    local workdir
    workdir="$(get_workdir)"

    [[ -z "$workdir" ]] && {
        err "未发现活动实例。"
        return
    }

    cd "$workdir" || return
    $(docker_compose_cmd) stop
    info "服务已停止。"
}

restart_service() {
    local workdir
    workdir="$(get_workdir)"

    [[ -z "$workdir" ]] && {
        err "未找到部署环境。"
        return
    }

    cd "$workdir" || return
    $(docker_compose_cmd) restart
    wait_app_ready || true
    show_access "$workdir"
}

reset_admin_password() {
    local workdir
    workdir="$(get_workdir)"

    [[ -z "$workdir" ]] && {
        err "无法定位配置目录。"
        return
    }

    generate_admin_password
    write_pwd_file "$workdir"

    cd "$workdir" || return
    $(docker_compose_cmd) restart "$CONTAINER_NAME" >/dev/null 2>&1 || true

    info "后台密码已重置。"
    show_access "$workdir"
}

do_backup() {
    local workdir
    workdir="$(get_workdir)"

    [[ -z "$workdir" ]] && {
        err "未找到备份目标。"
        return
    }

    local backup_dir="${workdir}/backups"
    mkdir -p "$backup_dir"

    local timestamp
    timestamp="$(date +"%Y%m%d_%H%M%S")"

    local temp_dir="${backup_dir}/tmp_${timestamp}"
    mkdir -p "$temp_dir"

    cp "${workdir}/docker-compose.yml" "${temp_dir}/" 2>/dev/null || true
    cp "${workdir}/.env" "${temp_dir}/" 2>/dev/null || true
    [[ -d "${workdir}/configs" ]] && cp -r "${workdir}/configs" "${temp_dir}/configs"
    [[ -d "${workdir}/data" ]] && cp -r "${workdir}/data" "${temp_dir}/data"

    local backup_file="${backup_dir}/dujiaonext_backup_${timestamp}.tar.gz"

    tar -czf "$backup_file" -C "$temp_dir" .
    rm -rf "$temp_dir"

    cd "$backup_dir" || return
    ls -t dujiaonext_backup_*.tar.gz 2>/dev/null | awk 'NR>5' | xargs -r rm -f

    info "备份已完成: ${backup_file}"
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

    local safe_backup="/tmp/$(basename "$path")"
    cp "$path" "$safe_backup" || die "复制备份文件失败。"

    read -r -p "恢复目标目录 [回车默认: $DEFAULT_INSTALL_PATH]: " target_dir
    local wd="${target_dir:-$DEFAULT_INSTALL_PATH}"

    if [[ -d "$wd" ]]; then
        read -r -p "目标目录已存在，是否删除并恢复？(y/N): " confirm

        [[ ! "$confirm" =~ ^[Yy]$ ]] && {
            rm -f "$safe_backup"
            return
        }

        cd "$wd" 2>/dev/null && $(docker_compose_cmd) down 2>/dev/null || true
        docker rm -f "$CONTAINER_NAME" 2>/dev/null || true
        cd /
        rm -rf "$wd"
    fi

    mkdir -p "$wd"
    tar -xzf "$safe_backup" -C "$wd" || die "解压备份失败。"

    mkdir -p "${wd}/backups"
    cp "$safe_backup" "${wd}/backups/$(basename "$safe_backup")" 2>/dev/null || true
    rm -f "$safe_backup"

    echo "$wd" > "$ENV_RECORD_FILE"

    cd "$wd" || return
    mkdir -p configs data backups
    chmod -R 755 backups data 2>/dev/null || true

    [[ ! -f "${wd}/docker-compose.yml" ]] && create_compose_file "$wd"

    if [[ ! -f "${wd}/.env" ]]; then
        cat > "${wd}/.env" <<ENVEFF
PORT=$DEFAULT_HOST_PORT
TZ=Asia/Shanghai
ENVEFF
    fi

    if [[ ! -f "${wd}/configs/pwd" ]]; then
        generate_admin_password
        write_pwd_file "$wd"
    fi

    $(docker_compose_cmd) up -d || die "恢复后启动失败。"

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
            [[ "$min_interval" =~ ^[0-9]+$ ]] || {
                err "分钟数非法。"
                return
            }
            cron_spec="*/${min_interval} * * * *"
        ;;
        2)
            read -r -p "输入时间，例如 04:30: " cron_time
            local hour="${cron_time%:*}"
            local minute="${cron_time#*:}"
            [[ "$hour" =~ ^[0-9]+$ && "$minute" =~ ^[0-9]+$ ]] || {
                err "时间格式错误。"
                return
            }
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

    cat > "$cron_script" <<CRONEOF
#!/usr/bin/env bash
bash "$script_path" run-backup >> "$BACKUP_LOG" 2>&1
CRONEOF

    chmod +x "$cron_script"

    (
        crontab -l 2>/dev/null | sed "/${CRON_TAG_BEGIN}/,/${CRON_TAG_END}/d"
        echo "$CRON_TAG_BEGIN"
        echo "${cron_spec} bash ${cron_script}"
        echo "$CRON_TAG_END"
    ) | crontab -

    info "定时备份已设置。"
}

clean_all_dujiaonext() {
    docker rm -f "$CONTAINER_NAME" 2>/dev/null || true
    docker network prune -f 2>/dev/null || true
}

uninstall_service() {
    local workdir
    workdir="$(get_workdir)"

    [[ -z "$workdir" ]] && workdir="$DEFAULT_INSTALL_PATH"

    echo -e "\033[31m⚠️ 警告：这会停止服务并删除本地数据！\033[0m"
    read -r -p "确认卸载？(y/N): " confirm
    [[ ! "$confirm" =~ ^[Yy]$ ]] && return

    if [[ -d "$workdir" ]]; then
        cd "$workdir" 2>/dev/null && $(docker_compose_cmd) down 2>/dev/null || true
    fi

    clean_all_dujiaonext

    cd /
    rm -rf "$workdir"
    rm -f "$ENV_RECORD_FILE"

    crontab -l 2>/dev/null | sed "/${CRON_TAG_BEGIN}/,/${CRON_TAG_END}/d" | crontab - 2>/dev/null || true

    info "已完全卸载。"
}

install_ftp() {
    clear
    echo -e "\033[32m📂 FTP/SFTP 备份工具加载中...\033[0m"
    bash <(curl -fsSL https://raw.githubusercontent.com/hiapb/ftp/main/back.sh | sed 's/\r$//')
    sleep 2
    exit 0
}

main_menu() {
    clear
    echo "==================================================="
    echo "               Dujiao-Next 一键管理"
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
    echo "  0) 退出"
    echo "==================================================="

    read -r -p "请输入选项 [0-10]: " choice

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

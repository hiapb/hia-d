#!/usr/bin/env bash

# ==========================================
# Dujiao-Next 自动化运维矩阵
# ==========================================

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH"

DEFAULT_INSTALL_PATH="/opt/dujiao-next"
ENV_RECORD_FILE="/etc/dujiaonext_env"

CRON_TAG_BEGIN="# DUJIAO_BACKUP_BEGIN"
CRON_TAG_END="# DUJIAO_BACKUP_END"
BACKUP_LOG="/var/log/dujiaonext_backup.log"

CONTAINER_NAME="dujiao_next"
# 替换为实际的 Dujiao-Next 官方或您编译的镜像地址
IMAGE_NAME="ghcr.io/apernet/dujiao-next:latest" 

# [核心变更] 重置默认端口，规避常见扫描器
DEFAULT_HOST_PORT="34567"

ADMIN_PASS=""

info() { echo -e "\033[32m[INFO]\033[0m $1"; }
warn() { echo -e "\033[33m[WARN]\033[0m $1" >&2; }
err()  { echo -e "\033[31m[ERROR]\033[0m $1" >&2; }
die()  { echo -e "\033[31m[FATAL]\033[0m $1" >&2; exit 1; }

require_cmd() { command -v "$1" >/dev/null 2>&1 || die "系统缺少核心依赖: $1"; }

get_local_ip() {
    hostname -I | awk '{print $1}' || echo "127.0.0.1"
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
        die "未探测到 Docker Compose 引擎，请先安装 Docker。"
    fi
}

get_workdir() {
    [[ -f "$ENV_RECORD_FILE" ]] && cat "$ENV_RECORD_FILE" || echo ""
}

generate_admin_password() {
    # 采用高熵随机数生成 16 字节十六进制密码，抵御字典爆破
    ADMIN_PASS=$(openssl rand -hex 16)
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
    host_port=$(grep -oP '^PORT=\K.*' "$env_file" 2>/dev/null || echo "$DEFAULT_HOST_PORT")

    local current_pass
    current_pass=$(read_pwd_file "$workdir")

    echo ""
    echo "=================================================="
    echo -e "\033[32m✅ Dujiao-Next 商业实例已就绪\033[0m"
    echo "--------------------------------------------------"
    echo -e "Web 控制台: \033[36mhttp://$(get_local_ip):${host_port}\033[0m"
    echo "--------------------------------------------------"
    echo -e "初始管理密码: \033[31m${current_pass}\033[0m"
    echo -e "密码存储路径: \033[33m${workdir}/configs/pwd\033[0m"
    echo -e "核心数据目录: \033[33m${workdir}/configs\033[0m"
    echo "--------------------------------------------------"
    echo "网络映射逻辑:"
    echo "  公网/网关: ${host_port} 穿透至容器层 3000 (或根据镜像底层自行映射)"
    echo "=================================================="
    echo ""
}

wait_app_ready() {
    info "监听 Dujiao-Next 进程初始化心跳..."

    for i in {1..60}; do
        if docker ps --format '{{.Names}} {{.Status}}' | grep -q "^${CONTAINER_NAME} .*Up"; then
            info "容器存活确认。服务已接管。"
            return 0
        fi
        sleep 2
    done

    warn "服务可能遭遇 CrashLoopBackOff 状态，请检查日志。"
    docker logs --tail=100 "$CONTAINER_NAME" 2>/dev/null || true
    return 1
}

create_compose_file() {
    local workdir="$1"

    cat > "${workdir}/docker-compose.yml" <<EOF
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
EOF
}

deploy_aiclient2api() {
    info "== 启动 Dujiao-Next 工业级编排 =="

    require_cmd docker
    require_cmd curl
    require_cmd tar
    require_cmd awk
    require_cmd openssl

    local dc_cmd
    dc_cmd=$(docker_compose_cmd)

    read -r -p "规划物理落盘路径 [回车默认: $DEFAULT_INSTALL_PATH]: " input_path
    local install_path=${input_path:-$DEFAULT_INSTALL_PATH}

    if [[ -d "$install_path" && "$(ls -A "$install_path" 2>/dev/null)" ]]; then
        err "目标向量域已存在污染数据，为保证数据一致性，请先执行 [8] 进行物理擦除。"
        return
    fi

    mkdir -p "$install_path"
    echo "$install_path" > "$ENV_RECORD_FILE"

    cd "$install_path" || return

    read -r -p "设定前端入口端口 [回车默认: $DEFAULT_HOST_PORT]: " input_port
    local host_port=${input_port:-$DEFAULT_HOST_PORT}

    valid_port "$host_port" || die "端口阈值溢出或非法，仅限 1-65535"

    mkdir -p configs data backups
    chmod -R 777 backups data

    generate_admin_password
    write_pwd_file "$install_path"

    cat > .env <<EOF
PORT=${host_port}
TZ=Asia/Shanghai
EOF

    create_compose_file "$install_path"

    info "下发镜像拉取指令并构建运行态..."

    $dc_cmd pull || warn "镜像中心响应超时，尝试利用本地缓存冷启动..."
    $dc_cmd up -d || die "守护进程唤醒失败，请检查 Docker Daemon 状态。"

    wait_app_ready || true
    show_access "$install_path"
}

upgrade_service() {
    local workdir
    workdir=$(get_workdir)

    [[ -z "$workdir" ]] && {
        err "内存映射未命中，环境尚未部署。"
        return
    }

    cd "$workdir" || return

    local dc_cmd
    dc_cmd=$(docker_compose_cmd)

    info "执行无缝轮转更新逻辑..."

    $dc_cmd pull || die "镜像层同步断裂"
    $dc_cmd up -d || die "服务重建失败"

    wait_app_ready || true
    show_access "$workdir"
}

pause_service() {
    local workdir
    workdir=$(get_workdir)

    [[ -z "$workdir" ]] && {
        err "未发现活动态实例。"
        return
    }

    cd "$workdir" && $(docker_compose_cmd) stop
    info "资源已冻结，服务暂停挂起。"
}

restart_service() {
    local workdir
    workdir=$(get_workdir)

    [[ -z "$workdir" ]] && {
        err "环境游离缺失。"
        return
    }

    cd "$workdir" || return
    $(docker_compose_cmd) restart
    wait_app_ready || true
    show_access "$workdir"
}

reset_admin_password() {
    local workdir
    workdir=$(get_workdir)

    [[ -z "$workdir" ]] && {
        err "无法定位配置文件域。"
        return
    }

    generate_admin_password
    write_pwd_file "$workdir"

    cd "$workdir" || return
    $(docker_compose_cmd) restart "$CONTAINER_NAME" >/dev/null 2>&1 || true

    info "密码字典已被覆写更新。"
    show_access "$workdir"
}

do_backup() {
    local workdir
    workdir=$(get_workdir)

    [[ -z "$workdir" ]] && {
        err "目标备份域为空。"
        return
    }

    local backup_dir="${workdir}/backups"
    mkdir -p "$backup_dir"

    local timestamp
    timestamp=$(date +"%Y%m%d_%H%M%S")

    local temp_dir="${backup_dir}/tmp_${timestamp}"
    mkdir -p "$temp_dir"

    # 执行原子级拷贝，防止读写锁死
    cp "${workdir}/docker-compose.yml" "${temp_dir}/" 2>/dev/null || true
    cp "${workdir}/.env" "${temp_dir}/" 2>/dev/null || true
    [[ -d "${workdir}/configs" ]] && cp -r "${workdir}/configs" "${temp_dir}/configs"
    [[ -d "${workdir}/data" ]] && cp -r "${workdir}/data" "${temp_dir}/data"

    local backup_file="${backup_dir}/dujiaonext_backup_${timestamp}.tar.gz"

    tar -czf "$backup_file" -C "$temp_dir" .
    rm -rf "$temp_dir"

    # 动态修剪陈旧备份，收敛磁盘 IO
    cd "$backup_dir" || return
    ls -t dujiaonext_backup_*.tar.gz 2>/dev/null | awk 'NR>5' | xargs -r rm -f

    info "快照已固化至: ${backup_file}"
}

restore_backup() {
    local workdir
    workdir=$(get_workdir)

    local search_dir="${workdir:-$DEFAULT_INSTALL_PATH}/backups"
    local default_backup
    default_backup=$(ls -t "${search_dir}"/dujiaonext_backup_*.tar.gz 2>/dev/null | head -n 1 || true)

    read -r -p "输入重载源路径 [回车使用最新切片: ${default_backup}]: " backup_path
    local path=${backup_path:-$default_backup}

    [[ ! -f "$path" ]] && {
        err "块文件损坏或不存在。"
        return
    }

    local safe_backup="/tmp/$(basename "$path")"
    cp "$path" "$safe_backup" || die "沙盒隔离失败"

    read -r -p "指定恢复靶区 [回车默认: $DEFAULT_INSTALL_PATH]: " target_dir
    local wd=${target_dir:-$DEFAULT_INSTALL_PATH}

    if [[ -d "$wd" ]]; then
        read -r -p "侦测到靶区存在残存活动，是否强制降维抹除？(y/N): " confirm

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
    tar -xzf "$safe_backup" -C "$wd" || die "算法层解压崩解"

    mkdir -p "${wd}/backups"
    cp "$safe_backup" "${wd}/backups/$(basename "$safe_backup")" 2>/dev/null || true
    rm -f "$safe_backup"

    echo "$wd" > "$ENV_RECORD_FILE"

    cd "$wd" || return

    mkdir -p configs data backups
    chmod -R 777 backups data 2>/dev/null || true

    [[ ! -f "${wd}/docker-compose.yml" ]] && create_compose_file "$wd"

    if [[ ! -f "${wd}/.env" ]]; then
        cat > "${wd}/.env" <<EOF
PORT=$DEFAULT_HOST_PORT
TZ=Asia/Shanghai
EOF
    fi

    if [[ ! -f "${wd}/configs/pwd" ]]; then
        generate_admin_password
        write_pwd_file "$wd"
    fi

    $(docker_compose_cmd) up -d || die "编排唤醒失败"

    wait_app_ready || true
    show_access "$wd"
}

setup_auto_backup() {
    require_cmd crontab

    local workdir
    workdir=$(get_workdir)

    [[ -z "$workdir" ]] && {
        err "环境未注册，终止任务注入。"
        return
    }

    local cron_script="${workdir}/cron_backup.sh"
    local script_path
    script_path="$(readlink -f "${BASH_SOURCE[0]}")"

    echo " 1) 基于固定分钟步长（推荐策略：10/15/20/30/60）"
    echo " 2) 基于绝对时间锚点（例如：每日 04:30 宕机低谷期）"
    echo " 3) 剥离当前定时轮询机制"

    read -r -p "下达策略编号 [1/2/3]: " cron_type

    local cron_spec=""

    case "$cron_type" in
        1)
            read -r -p "输入步长(分钟): " min_interval
            [[ "$min_interval" =~ ^[0-9]+$ ]] || {
                err "参数非整型数字"
                return
            }
            cron_spec="*/${min_interval} * * * *"
        ;;
        2)
            read -r -p "输入时间锚点 (HH:MM): " cron_time
            local hour="${cron_time%:*}"
            local minute="${cron_time#*:}"
            [[ "$hour" =~ ^[0-9]+$ && "$minute" =~ ^[0-9]+$ ]] || {
                err "时间戳解析失败"
                return
            }
            cron_spec="${minute} ${hour} * * *"
        ;;
        3)
            crontab -l 2>/dev/null | sed "/${CRON_TAG_BEGIN}/,/${CRON_TAG_END}/d" | crontab - 2>/dev/null || true
            rm -f "$cron_script"
            info "轮询钩子已安全卸载。"
            return
        ;;
        *)
            err "指令越界"
            return
        ;;
    esac

    cat > "$cron_script" <<EOF
#!/usr/bin/env bash
bash "$script_path" run-backup >> "$BACKUP_LOG" 2>&1
EOF

    chmod +x "$cron_script"

    # 清洗旧规则并注入新规则
    (
        crontab -l 2>/dev/null | sed "/${CRON_TAG_BEGIN}/,/${CRON_TAG_END}/d"
        echo "$CRON_TAG_BEGIN"
        echo "${cron_spec} bash ${cron_script}"
        echo "$CRON_TAG_END"
    ) | crontab -

    info "Crond 守护进程已成功挂载新规则。"
}

clean_all_dujiaonext() {
    docker rm -f "$CONTAINER_NAME" 2>/dev/null || true
    # 彻底清理孤儿网络
    docker network prune -f 2>/dev/null || true 
}

uninstall_service() {
    local workdir
    workdir=$(get_workdir)

    [[ -z "$workdir" ]] && workdir=$DEFAULT_INSTALL_PATH

    echo -e "\033[31m⚠️ 核心警告：这将导致业务全盘宕机并粉碎全部本地卷数据！\033[0m"
    read -r -p "二次确认指令以授权物理销毁 (y/N): " confirm
    [[ ! "$confirm" =~ ^[Yy]$ ]] && return

    if [[ -d "$workdir" ]]; then
        cd "$workdir" 2>/dev/null && $(docker_compose_cmd) down 2>/dev/null || true
    fi

    clean_all_dujiaonext

    cd /
    rm -rf "$workdir"
    rm -f "$ENV_RECORD_FILE"

    crontab -l 2>/dev/null | sed "/${CRON_TAG_BEGIN}/,/${CRON_TAG_END}/d" | crontab - 2>/dev/null || true

    info "系统已被彻底洗牌，数据已化为比特尘埃。"
}

install_ftp() {
    clear
    echo -e "\033[32m📂 异地容灾 FTP/SFTP 并行备份管道加载中...\033[0m"
    bash <(curl -L https://raw.githubusercontent.com/hiapb/ftp/main/back.sh)
    sleep 2
    exit 0
}

main_menu() {
    clear
    echo "==================================================="
    echo "               Dujiao-Next 深度控制终端            "
    echo "==================================================="
    local wd
    wd=$(get_workdir)
    echo -e " 核心挂载域: \033[36m${wd:-游离态 (未部署)}\033[0m"
    echo "---------------------------------------------------"
    echo "  1) 一键部署"
    echo "  2) 升级服务"
    echo "  3) 停止服务"
    echo "  4) 重启服务"
    echo "  5) 手动备份"
    echo "  6) 恢复备份"
    echo "  7) 定时备份"
    echo "  8) 完全卸载"
    echo "  9) 📂 FTP/SFTP 备份工具"
    echo " 10) 重置后台密码"
    echo "  0) 退出终端"
    echo "==================================================="
    read -r -p "输入指令信道 [0-10]: " choice

    case "$choice" in
        1) deploy_aiclient2api ;;
        2) upgrade_service ;;
        3) pause_service ;;
        4) restart_service ;;
        5) do_backup ;;
        6) restore_backup ;;
        7) setup_auto_backup ;;
        8) uninstall_service ;;
        9) install_ftp ;;
        10) reset_admin_password ;;
        0) info "通信链路切断。老板，祝您生意兴隆。"; exit 0 ;;
        *) warn "信道干扰，未能解析指令。" ;;
    esac
}

if [[ "${1:-}" == "run-backup" ]]; then
    do_backup
else
    if [[ $EUID -ne 0 ]]; then
        die "权限边界不足：必须提权至 Root 账户方可调动底层资源。"
    fi

    while true; do
        main_menu
        echo ""
        read -r -p "➤ 按下回车键重置至主控层..."
    done
fi
#!/usr/bin/env bash

set -o pipefail
umask 077
BACKUP_KEEP=3
PYTHON=python3
CONFIG_TEMPLATE_TAG="v1.5.2"
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
    if docker compose version >/dev/null 2>&1; then
        docker compose --env-file .env -f "$COMPOSE_FILE" "$@"
    elif command -v docker-compose >/dev/null 2>&1; then
        docker-compose --env-file .env -f "$COMPOSE_FILE" "$@"
    else
        err "未检测到 Docker Compose。"
        return 1
    fi
}

get_workdir() {
    [[ -f "$ENV_RECORD_FILE" ]] && cat "$ENV_RECORD_FILE" || echo ""
}


ensure_yaml() {
    require_cmd python3
    if python3 -c 'import yaml' >/dev/null 2>&1; then
        PYTHON=python3
        return 0
    fi
    info "安装 Python YAML 依赖..."
    if command -v apt-get >/dev/null 2>&1; then
        apt-get update && apt-get install -y python3-yaml || return 1
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y python3-pyyaml || return 1
    elif command -v yum >/dev/null 2>&1; then
        yum install -y python3-pyyaml || return 1
    elif command -v apk >/dev/null 2>&1; then
        apk add --no-cache py3-yaml || return 1
    else
        err "请先安装 PyYAML：当前系统 Python 需要能执行 import yaml。"
        return 1
    fi
    python3 -c 'import yaml' || return 1
    PYTHON=python3
}

read_env_value() {
    python3 - "$1" "$2" <<'PYENV'
import sys
from pathlib import Path
for line in Path(sys.argv[1]).read_text().splitlines():
    key, sep, value = line.partition('=')
    if sep and key.strip() == sys.argv[2]:
        value = value.strip()
        if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
            value = value[1:-1]
        print(value)
        break
PYENV
}


refresh_backup_runner() {
    local workdir="$1" manager="${1}/manager.sh" source_path
    source_path="${BASH_SOURCE[0]}"
    [[ -f "$source_path" ]] || { err "请把管理脚本保存为文件后运行。"; return 1; }
    if [[ "$source_path" != "$manager" ]] && ! [[ "$source_path" -ef "$manager" ]]; then
        cp "$source_path" "$manager" || return 1
    fi
    chmod 700 "$manager" || return 1
    printf '#!/usr/bin/env bash\nexec bash %q run-backup >> %q 2>&1\n' \
        "$manager" "$BACKUP_LOG" > "${workdir}/cron_backup.sh" || return 1
    chmod 700 "${workdir}/cron_backup.sh"
}

with_deploy_lock() {
    local workdir
    workdir="$(get_workdir)"
    [[ -n "$workdir" && -d "$workdir" && "$workdir" != / ]] || {
        err "未找到有效的部署目录。"
        return 1
    }
    require_cmd flock
    (
        flock -w 30 9 || { err "另一个管理或备份任务正在运行，请稍后重试。"; exit 1; }
        "$@" "$workdir"
    ) 9>"${workdir}/.manager.lock"
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
    local workdir="$1" cfg="${1}/config/config.yml" tmp
    [[ -f "$cfg" ]] && return 0
    tmp="$(mktemp "${workdir}/config/.download-XXXXXX")" || return 1
    if ! curl -fsSL --connect-timeout 10 --max-time 60 \
        "https://raw.githubusercontent.com/dujiao-next/dujiao-next/${CONFIG_TEMPLATE_TAG}/config.yml.example" -o "$tmp"; then
        rm -f "$tmp"
        err "下载配置模板失败。"
        return 1
    fi
    mv -f "$tmp" "$cfg"
}

patch_config_yml() {
    local workdir="$1" phase="${2:-upgrade}"
    "$PYTHON" - "$workdir" "$phase" <<'PYCONFIG'
import os, secrets, sqlite3, sys, tempfile
from pathlib import Path
from urllib.parse import quote
import yaml

class StrictLoader(yaml.SafeLoader):
    pass

def mapping(loader, node, deep=False):
    result = {}
    for key_node, value_node in node.value:
        key = loader.construct_object(key_node, deep=deep)
        if key in result:
            raise ValueError('YAML 配置含重复字段：' + str(key))
        result[key] = loader.construct_object(value_node, deep=deep)
    return result
StrictLoader.add_constructor(yaml.resolver.BaseResolver.DEFAULT_MAPPING_TAG, mapping)

def main():
    wd = Path(sys.argv[1]).resolve()
    phase = sys.argv[2]
    path = wd / 'config/config.yml'
    cfg = yaml.load(path.read_text(encoding='utf-8-sig'), Loader=StrictLoader)
    if not isinstance(cfg, dict):
        raise ValueError('config.yml 顶层必须是 YAML 对象')
    def section(key):
        value = cfg.setdefault(key, {})
        if not isinstance(value, dict):
            raise ValueError(key + ' 配置必须是 YAML 对象')
        return value
    # 不重新下载覆盖已有配置，不对 host、dsn 等字段做全局正则替换。
    for key in ('server', 'database'):
        if key not in cfg or not isinstance(cfg[key], dict):
            raise ValueError('缺少关键配置 '+key+'；请从完整备份恢复 config.yml 后重试')
    server, database = section('server'), section('database')
    if str(server.get('port', 8080)) != '8080':
        raise ValueError('此 Docker 部署要求 server.port=8080，请核对容器和网关端口配置')
    server['host'] = '0.0.0.0'
    if str(database.get('driver', 'sqlite')).lower() != 'sqlite':
        raise ValueError('检测到非 SQLite 数据库；脚本不会把现有数据库改成 SQLite')
    database['driver'] = 'sqlite'
    dsn = str(database.get('dsn', './db/dujiao.db'))
    db_base = (wd / 'data/db').resolve()
    if dsn.startswith('/app/db/'):
        db_path = db_base / dsn[len('/app/db/'):]
    elif dsn.startswith(('./db/', 'db/')):
        db_path = db_base / (dsn[2:] if dsn.startswith('./') else dsn)[3:]
    else:
        raise ValueError('无法确认 SQLite 数据库挂载路径：'+dsn)
    db_path = db_path.resolve()
    if db_base not in db_path.parents:
        raise ValueError('SQLite 数据库路径超出 data/db，已停止')
    if phase != 'install' and not db_path.is_file():
        raise ValueError('没有找到现有数据库 '+str(db_path)+'，已停止，避免启动一个空库')

    env = {}
    for line in (wd/'.env').read_text().splitlines():
        k, sep, v = line.partition('=')
        if sep:
            v = v.strip()
            if len(v) >= 2 and v[0] == v[-1] and v[0] in "\"'":
                v = v[1:-1]
            env[k.strip()] = v
    password = env.get('REDIS_PASSWORD', '')
    if not password:
        raise ValueError('.env 中 REDIS_PASSWORD 为空，已停止')
    if '$' in password:
        raise ValueError('REDIS_PASSWORD 含 $，请先核对 Compose 插值后的真实密码')
    for key, db in (('redis',0),('queue',1)):
        block = section(key)
        block.update(host='redis', port=6379, password=password)
        block.setdefault('enabled', True)
        block.setdefault('db', db)
    section('queue').setdefault('concurrency', 10)
    section('queue').setdefault('queues', {'default':10, 'critical':5})

    def weak(value):
        return (not isinstance(value,str) or len(value)<32 or
                any(x in value.lower() for x in
                    ('change-me','change-in-production','your-secret-key')))
    app = section('app')
    app_secret = app.get('secret_key', 'change-me-32-byte-secret-key!!')
    if weak(app_secret):
        # 旧 app 密钥还用于 2FA、上游/渠道凭证和游客订单摘要。
        # 仅在没有依赖旧密钥的数据时自动更换；不修改任何数据库记录。
        if db_path.exists():
            uri = 'file:' + quote(str(db_path), safe='/') + '?mode=ro'
            conn = sqlite3.connect(uri, uri=True, timeout=10)
            try:
                if conn.execute('PRAGMA quick_check').fetchall() != [('ok',)]:
                    raise ValueError('现有 SQLite 数据库检查失败')
                tables = {r[0] for r in conn.execute("SELECT name FROM sqlite_master WHERE type='table'")}
                protected = {
                    'admins': ('totp_secret',), 'users': ('totp_secret',),
                    'site_connections': ('api_secret',),
                    'channel_clients': ('channel_secret','bot_token'),
                }
                for table, fields in protected.items():
                    if table not in tables:
                        continue
                    cols = {r[1] for r in conn.execute('PRAGMA table_info("'+table+'")')}
                    for field in fields:
                        if field in cols and conn.execute(
                            'SELECT 1 FROM "'+table+'" WHERE "'+field+'" IS NOT NULL '
                            'AND "'+field+'" <> ? LIMIT 1', ('',)).fetchone():
                            raise ValueError('弱 app.secret_key 已用于历史数据 '+table+'.'+field+
                                             '。已保留旧密钥；需要迁移这些数据后才能升级')
                if 'orders' in tables:
                    cols = {r[1] for r in conn.execute('PRAGMA table_info("orders")')}
                    if 'guest_password' in cols and conn.execute(
                        "SELECT 1 FROM orders WHERE guest_password LIKE 'hmac-sha256:%' LIMIT 1").fetchone():
                        raise ValueError('旧 app.secret_key 已用于游客订单密码摘要，不能直接更换；需要应用支持密钥迁移')
            finally:
                conn.close()
        app_secret = secrets.token_hex(32)
        app['secret_key'] = app_secret
        print('[INFO] 已生成独立的 app.secret_key；未发现依赖旧密钥的历史数据。')
    used = {app_secret.strip()}
    for key in ('jwt','user_jwt'):
        block = section(key)
        value = block.get('secret','')
        if weak(value) or value.strip() in used:
            value = secrets.token_hex(32)
            while value.strip() in used:
                value = secrets.token_hex(32)
            block['secret'] = value
            print('[INFO] 已修复 '+key+'.secret，对应账号需要重新登录。')
        used.add(value.strip())
    rendered = yaml.safe_dump(cfg, allow_unicode=True, sort_keys=False)
    # PyYAML 重新序列化会去掉注释，但保留未修改的配置字段和值。
    if yaml.load(rendered, Loader=StrictLoader) != cfg:
        raise ValueError('YAML 写入校验失败')
    fd, temp_path = tempfile.mkstemp(prefix='.config-', suffix='.yml', dir=path.parent)
    try:
        with os.fdopen(fd,'w',encoding='utf-8') as stream:
            stream.write(rendered)
            stream.flush()
            os.fsync(stream.fileno())
        os.chmod(temp_path, path.stat().st_mode & 0o777)
        os.replace(temp_path, path)
    finally:
        if os.path.exists(temp_path):
            os.unlink(temp_path)
    print('[INFO] 配置校验通过，合格的现有密钥保持不变。')
try:
    main()
except Exception as exc:
    print('[ERROR] 配置检查失败：'+str(exc), file=sys.stderr)
    sys.exit(1)
PYCONFIG
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
    local port state i
    port="$(read_env_value .env API_PORT)"
    port="${port:-$DEFAULT_API_PORT}"
    info "等待 API 启动，最多检测 40 次..."
    for i in {1..40}; do
        state="$(docker inspect -f '{{.State.Running}} {{.State.Restarting}}' "$API_CONTAINER" 2>/dev/null)"
        if [[ "$state" == 'true false' ]]; then
            if docker exec "$API_CONTAINER" wget -q -T 2 -O /dev/null \
                http://127.0.0.1:8080/health 2>/dev/null; then
                info "API 已就绪。"
                return 0
            fi
            if curl -fsS --connect-timeout 1 --max-time 2 \
                "http://127.0.0.1:${port}/health" >/dev/null 2>&1; then
                info "API 已就绪。"
                return 0
            fi
        fi
        sleep 2
    done
    err "API 未通过健康检查，最近日志如下："
    docker logs --tail=100 "$API_CONTAINER" 2>&1 || true
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
    ensure_yaml || return 1
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
    download_config "$install_path" || return 1
    patch_config_yml "$install_path" install || return 1

    info "拉取官方镜像并启动..."
    $dc_cmd --env-file .env -f "$COMPOSE_FILE" pull || die "镜像拉取失败。"
    $dc_cmd --env-file .env -f "$COMPOSE_FILE" up -d --force-recreate || die "服务启动失败。"

    wait_app_ready || return 1
    show_access "$install_path"
}

upgrade_service() {
    require_cmd docker
    require_cmd curl
    require_cmd python3
    require_cmd tar
    ensure_yaml || return 1
    with_deploy_lock upgrade_locked
}

upgrade_locked() {
    local workdir="$1" was_running
    cd "$workdir" || return 1
    [[ -f .env && -f "$COMPOSE_FILE" && -f config/config.yml ]] || {
        err "现有部署文件不完整，已停止升级。"
        return 1
    }
    # 在下载镜像、改配置和重建服务前，先生成一份完整备份。
    backup_locked "$workdir" || { err "备份失败，未执行升级。"; return 1; }
    if command -v crontab >/dev/null 2>&1 && \
        crontab -l 2>/dev/null | grep -qFx "$CRON_TAG_BEGIN"; then
        refresh_backup_runner "$workdir" || warn "定时备份脚本更新失败，请通过选项 7 重新设置。"
    fi
    compose_run config -q || { err "Compose 配置校验失败，未执行升级。"; return 1; }
    info "拉取镜像..."
    compose_run pull || { err "镜像拉取失败，现有服务未重建。"; return 1; }
    was_running="$(docker inspect -f '{{.State.Running}}' "$API_CONTAINER" 2>/dev/null)"
    compose_run stop api || { err "无法停止 API，未修改配置。"; return 1; }
    if ! patch_config_yml "$workdir" upgrade; then
        [[ "$was_running" == true ]] && compose_run start api
        err "配置修复未完成，已停止升级；原配置未被覆盖。"
        return 1
    fi
    # 沿用已有 Compose 和 Nginx 配置，避免覆盖手动修改；重建网关刷新服务 IP。
    compose_run up -d --force-recreate || {
        err "容器重建失败。升级前备份：${LAST_BACKUP_FILE}"
        return 1
    }
    if ! wait_app_ready; then
        err "升级未成功。升级前备份：${LAST_BACKUP_FILE}"
        return 1
    fi
    info "升级成功。升级前备份：${LAST_BACKUP_FILE}"
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
    with_deploy_lock restart_locked
}

restart_locked() {
    local workdir="$1"
    cd "$workdir" || return 1
    # 重启不修改密钥、配置文件或数据库。
    compose_run restart api redis user admin || return 1
    wait_app_ready || return 1
    compose_run restart user-gateway admin-gateway || return 1
    show_access "$workdir"
}

do_backup() {
    require_cmd python3
    require_cmd tar
    with_deploy_lock backup_locked
}

backup_locked() {
    local workdir="$1" result
    result="$(python3 - "$workdir" "$BACKUP_KEEP" <<'PYBACKUP'
import datetime, gzip, json, os, shutil, sqlite3, sys, tarfile, tempfile, time
from pathlib import Path
from urllib.parse import quote

def main():
    wd = Path(sys.argv[1]).resolve()
    keep = int(sys.argv[2])
    if keep < 1:
        raise ValueError('备份保留份数必须大于零')
    for required in ('.env','docker-compose.yml','config/config.yml'):
        if not (wd/required).is_file():
            raise ValueError('缺少部署文件：'+required)
    dest = wd/'backups'
    dest.mkdir(mode=0o700, parents=True, exist_ok=True)
    stamp = datetime.datetime.now().strftime('%Y%m%d_%H%M%S_%f')
    final = dest/('dujiaonext_backup_'+stamp+'.tar.gz')
    partial = dest/('.'+final.name+'.partial')
    stage = Path(tempfile.mkdtemp(prefix='.backup-stage-', dir=dest))
    try:
        for name in ('docker-compose.yml','.env','cron_backup.sh','manager.sh'):
            if (wd/name).is_file():
                shutil.copy2(wd/name, stage/name)
        for name in ('config','nginx'):
            if (wd/name).is_dir():
                shutil.copytree(wd/name, stage/name, symlinks=True)
        if (wd/'data').is_dir():
            # SQLite WAL/SHM 不直接复制；数据库使用官方在线备份接口生成一致快照。
            def ignore(folder, names):
                return [n for n in names if n.endswith(('-wal','-shm','-journal'))]
            shutil.copytree(wd/'data', stage/'data', symlinks=True, ignore=ignore)
            for original in (wd/'data').rglob('*'):
                if not original.is_file() or original.is_symlink():
                    continue
                if original.name.endswith(('-wal','-shm','-journal')):
                    continue
                with original.open('rb') as stream:
                    is_sqlite = stream.read(16) == b'SQLite format 3\x00'
                if not is_sqlite:
                    continue
                copy = stage / original.relative_to(wd)
                copy.unlink(missing_ok=True)
                uri = 'file:' + quote(str(original),safe='/') + '?mode=ro'
                src = sqlite3.connect(uri, uri=True, timeout=30)
                dst = sqlite3.connect(str(copy))
                deadline = time.monotonic()+180
                def progress(*args):
                    if time.monotonic()>deadline:
                        raise TimeoutError('SQLite 备份超时：'+original.name)
                try:
                    src.backup(dst, pages=256, progress=progress, sleep=0.1)
                    dst.commit()
                    mode = dst.execute('PRAGMA journal_mode=DELETE').fetchone()[0]
                    if mode.lower() != 'delete':
                        raise ValueError('无法将备份转换为独立 SQLite 文件')
                    if dst.execute('PRAGMA quick_check').fetchall() != [('ok',)]:
                        raise ValueError('SQLite 备份完整性检查失败：'+original.name)
                finally:
                    dst.close()
                    src.close()
                for suffix in ('-wal','-shm','-journal'):
                    Path(str(copy)+suffix).unlink(missing_ok=True)
        (stage/'backup_meta.json').write_text(json.dumps({
            'created_at':datetime.datetime.now().astimezone().isoformat(),
            'source':str(wd), 'keep':keep, 'sqlite_snapshot':True,
        },ensure_ascii=False,indent=2), encoding='utf-8')
        with tarfile.open(partial,'w:gz') as archive:
            for item in sorted(stage.iterdir()):
                archive.add(item, arcname=item.name, recursive=True)
        # 完整读取 gzip 校验 CRC，再核对归档中关键文件。
        with gzip.open(partial,'rb') as stream, open(os.devnull,'wb') as sink:
            shutil.copyfileobj(stream,sink)
        with tarfile.open(partial,'r:gz') as archive:
            names = {m.name[2:] if m.name.startswith('./') else m.name for m in archive.getmembers()}
            if not {'.env','docker-compose.yml','config/config.yml'} <= names:
                raise ValueError('备份归档缺少关键文件')
        os.chmod(partial,0o600)
        os.replace(partial,final)
        # 仅在新备份成功发布后轮换；三种备份共用同一目录和同一上限。
        backups = sorted(dest.glob('dujiaonext_backup_*.tar.gz'),
                         key=lambda p:(p.stat().st_mtime_ns,p.name), reverse=True)
        for old in backups[keep:]:
            old.unlink()
        print(str(final))
    finally:
        if partial.exists():
            partial.unlink()
        shutil.rmtree(stage, ignore_errors=True)
try:
    main()
except Exception as exc:
    print('[ERROR] 备份失败：'+str(exc),file=sys.stderr)
    sys.exit(1)
PYBACKUP
)" || return 1
    LAST_BACKUP_FILE="$result"
    info "备份完成：${LAST_BACKUP_FILE}（只保留最近 ${BACKUP_KEEP} 份）"
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

    REDIS_PASS="$(read_env_value .env REDIS_PASSWORD)"
    # 恢复保持备份原密钥和业务配置；有兼容问题时通过日志处理。

    [[ -f "$wd/$COMPOSE_FILE" ]] || { err "备份缺少 Compose 文件。"; return 1; }

    compose_run up -d --force-recreate || die "恢复后启动失败。"

    wait_app_ready || return 1
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
    local manager_script="${workdir}/manager.sh"
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
            min_interval=$((10#$min_interval))
            (( min_interval >= 1 && min_interval <= 60 )) || { err "分钟数需为 1 到 60。"; return 1; }
            if [[ "$min_interval" == 60 ]]; then
                cron_spec="0 * * * *"
            else
                cron_spec="*/${min_interval} * * * *"
            fi
        ;;
        3)
            read -r -p "输入时间，例如 04:30: " cron_time
            local hour="${cron_time%:*}"
            local minute="${cron_time#*:}"
            [[ "$hour" =~ ^[0-9]+$ && "$minute" =~ ^[0-9]+$ ]] || { err "时间格式错误。"; return; }
            hour=$((10#$hour))
            minute=$((10#$minute))
            (( hour <= 23 && minute <= 59 )) || { err "时间超出有效范围。"; return 1; }
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

    refresh_backup_runner "$workdir" || return 1

    (
        crontab -l 2>/dev/null | sed "/${CRON_TAG_BEGIN}/,/${CRON_TAG_END}/d"
        echo "$CRON_TAG_BEGIN"
        printf '%s bash "%s"\n' "$cron_spec" "$cron_script"
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

    local db_file="${workdir}/data/db/dujiao.db"

    [[ ! -f "$db_file" ]] && {
        err "未找到数据库文件: $db_file"
        return
    }

    info "数据库文件: $db_file"

    print_line() {
        echo "------------------------------------------------------------------------------------------"
    }

    print_categories() {
        printf "%-8s %-30s %-10s\n" "分类ID" "分类名称" "状态"
        print_line

        sqlite3 -separator '|' "$db_file" "
            SELECT
                id,
                COALESCE(
                    NULLIF(json_extract(name_json, '$.zh-CN'), ''),
                    NULLIF(json_extract(name_json, '$.zh-TW'), ''),
                    NULLIF(json_extract(name_json, '$.en-US'), ''),
                    name_json
                ),
                CASE
                    WHEN is_active=1 OR is_active='true' THEN '启用'
                    ELSE '禁用'
                END
            FROM categories
            ORDER BY sort_order ASC, id ASC;
        " | while IFS='|' read -r id name status; do
            printf "%-8s %-30s %-10s\n" "$id" "$name" "$status"
        done
    }

    print_products_by_category() {
        local cid="$1"

        printf "%-8s %-24s %-10s %-10s %-10s %-10s %-10s %-10s\n" \
            "商品ID" "商品名称" "商品库存" "商品锁定" "商品已售" "SKU库存" "SKU锁定" "SKU已售"
        print_line

        sqlite3 -separator '|' "$db_file" "
            SELECT
                p.id,
                COALESCE(
                    NULLIF(json_extract(p.title_json, '$.zh-CN'), ''),
                    NULLIF(json_extract(p.title_json, '$.zh-TW'), ''),
                    NULLIF(json_extract(p.title_json, '$.en-US'), ''),
                    p.title_json
                ),
                p.manual_stock_total,
                p.manual_stock_locked,
                p.manual_stock_sold,
                COALESCE(SUM(s.manual_stock_total), 0),
                COALESCE(SUM(s.manual_stock_locked), 0),
                COALESCE(SUM(s.manual_stock_sold), 0)
            FROM products p
            LEFT JOIN product_skus s ON s.product_id = p.id
            WHERE p.category_id=$cid
              AND p.deleted_at IS NULL
            GROUP BY p.id
            ORDER BY p.sort_order ASC, p.id ASC;
        " | while IFS='|' read -r id name total locked sold sku_total sku_locked sku_sold; do
            printf "%-8s %-24s %-10s %-10s %-10s %-10s %-10s %-10s\n" \
                "$id" "$name" "$total" "$locked" "$sold" "$sku_total" "$sku_locked" "$sku_sold"
        done
    }

    print_product_detail() {
        local pid="$1"

        printf "%-8s %-24s %-10s %-10s %-10s %-10s %-10s %-10s\n" \
            "商品ID" "商品名称" "商品库存" "商品锁定" "商品已售" "SKU库存" "SKU锁定" "SKU已售"
        print_line

        sqlite3 -separator '|' "$db_file" "
            SELECT
                p.id,
                COALESCE(
                    NULLIF(json_extract(p.title_json, '$.zh-CN'), ''),
                    NULLIF(json_extract(p.title_json, '$.zh-TW'), ''),
                    NULLIF(json_extract(p.title_json, '$.en-US'), ''),
                    p.title_json
                ),
                p.manual_stock_total,
                p.manual_stock_locked,
                p.manual_stock_sold,
                COALESCE(SUM(s.manual_stock_total), 0),
                COALESCE(SUM(s.manual_stock_locked), 0),
                COALESCE(SUM(s.manual_stock_sold), 0)
            FROM products p
            LEFT JOIN product_skus s ON s.product_id = p.id
            WHERE p.id=$pid
            GROUP BY p.id;
        " | while IFS='|' read -r id name total locked sold sku_total sku_locked sku_sold; do
            printf "%-8s %-24s %-10s %-10s %-10s %-10s %-10s %-10s\n" \
                "$id" "$name" "$total" "$locked" "$sold" "$sku_total" "$sku_locked" "$sku_sold"
        done
    }

    print_skus() {
        local pid="$1"

        printf "%-8s %-16s %-10s %-10s %-10s\n" "SKU_ID" "SKU编码" "库存" "锁定" "已售"
        print_line

        sqlite3 -separator '|' "$db_file" "
            SELECT
                id,
                COALESCE(NULLIF(sku_code, ''), '-'),
                manual_stock_total,
                manual_stock_locked,
                manual_stock_sold
            FROM product_skus
            WHERE product_id=$pid
            ORDER BY sort_order ASC, id ASC;
        " | while IFS='|' read -r id code total locked sold; do
            printf "%-8s %-16s %-10s %-10s %-10s\n" "$id" "$code" "$total" "$locked" "$sold"
        done
    }

    echo ""
    echo "==================================================="
    echo "              修改商品已售数量"
    echo "==================================================="
    echo ""

    echo "分类列表："
    print_line
    print_categories
    print_line

    read -r -p "请输入分类ID: " category_id

    [[ ! "$category_id" =~ ^[0-9]+$ ]] && {
        err "分类ID非法。"
        return
    }

    local category_exists
    category_exists="$(sqlite3 "$db_file" "SELECT COUNT(*) FROM categories WHERE id=$category_id;")"

    [[ "$category_exists" != "1" ]] && {
        err "分类不存在。"
        return
    }

    echo ""
    echo "商品列表："
    print_line
    print_products_by_category "$category_id"
    print_line

    read -r -p "请输入要修改的商品ID: " product_id

    [[ ! "$product_id" =~ ^[0-9]+$ ]] && {
        err "商品ID非法。"
        return
    }

    local product_exists
    product_exists="$(sqlite3 "$db_file" "
        SELECT COUNT(*)
        FROM products
        WHERE id=$product_id
          AND category_id=$category_id
          AND deleted_at IS NULL;
    ")"

    [[ "$product_exists" != "1" ]] && {
        err "商品不存在或不属于该分类。"
        return
    }

    echo ""
    echo "当前商品信息："
    print_line
    print_product_detail "$product_id"
    print_line

    echo ""
    echo "当前 SKU 信息："
    print_line
    print_skus "$product_id"
    print_line

    read -r -p "请输入新的已售数量: " new_sold

    [[ ! "$new_sold" =~ ^[0-9]+$ ]] && {
        err "已售数量必须是非负整数。"
        return
    }

    echo ""
    echo "将执行："
    echo "  products.manual_stock_sold = ${new_sold}"
    echo "  product_skus.manual_stock_sold = ${new_sold}"
    echo ""
    read -r -p "确认修改？(y/N): " confirm

    [[ ! "$confirm" =~ ^[Yy]$ ]] && {
        warn "已取消修改。"
        return
    }

    sqlite3 "$db_file" "
        BEGIN;

        UPDATE products
        SET
            manual_stock_sold=$new_sold,
            updated_at=datetime('now')
        WHERE id=$product_id;

        UPDATE product_skus
        SET
            manual_stock_sold=$new_sold,
            updated_at=datetime('now')
        WHERE product_id=$product_id;

        COMMIT;
    " || {
        err "修改失败。"
        return
    }

    info "数据库已修改。"

    echo ""
    echo "修改后商品信息："
    print_line
    print_product_detail "$product_id"
    print_line

    echo ""
    echo "修改后 SKU 信息："
    print_line
    print_skus "$product_id"
    print_line

    info "正在清理缓存..."

    local redis_pass
    redis_pass="$(read_env_value "$workdir/.env" REDIS_PASSWORD)"

    if [[ -n "$redis_pass" ]]; then
        docker exec "$REDIS_CONTAINER" redis-cli -a "$redis_pass" FLUSHALL >/dev/null 2>&1 || true
    fi

    docker restart "$API_CONTAINER" >/dev/null 2>&1 || true
    docker restart "$ADMIN_GATEWAY_CONTAINER" >/dev/null 2>&1 || true
    docker restart "$USER_GATEWAY_CONTAINER" >/dev/null 2>&1 || true

    info "修改完成。"

    echo ""
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
    REDIS_PASS="$(read_env_value .env REDIS_PASSWORD)"
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
    echo "  2) 升级服务（自动备份，保留 3 份）"
    echo "  3) 停止服务"
    echo "  4) 重启服务"
    echo "  5) 手动备份（保留 3 份）"
    echo "  6) 恢复备份"
    echo "  7) 定时备份"
    echo "  8) 完全卸载"
    echo "  9) FTP/SFTP 备份工具"
    echo " 10) 重置后台密码"
    echo " 11) 查看状态和日志"
    echo " 12) 修改商品已售数量"
    echo "  0) 退出"
    echo "==================================================="

    read -r -p "请输入选项 [0-12]: " choice || exit 0

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

if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then
    return 0
fi

if [[ $EUID -ne 0 ]]; then
    die "请使用 root 用户运行。"
fi

if [[ "${1:-}" == "run-backup" ]]; then
    do_backup
else
    if [[ $EUID -ne 0 ]]; then
        die "请使用 root 用户运行。"
    fi

    while true; do
        main_menu
        echo ""
        read -r -p "按回车返回主菜单..." || exit 0
    done
fi

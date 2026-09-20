#!/usr/bin/env bash
# ==============================================================================
# 项目名称: aiproxy-box (AI 代理全能工具箱)
# 脚本功能: 交互式 TUI 字符菜单与自动化容器运维管理
# 项目地址: https://github.com/aiproxy-box/aiproxy-box
# 快捷命令: aiproxy
# ==============================================================================

# 基础目录定位
SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || realpath "${BASH_SOURCE[0]}" 2>/dev/null || echo "$0")"
APP_DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"
cd "$APP_DIR" || exit 1

DATA_DIR="$APP_DIR/data"
TEMPLATES_DIR="$APP_DIR/templates"
COMPOSE_FILE="$APP_DIR/docker-compose.yml"
ENV_FILE="$APP_DIR/.env"

# 版本标识
VERSION="1.0.0"

# ANSI 颜色定义
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
BLUE="\033[34m"
MAGENTA="\033[35m"
CYAN="\033[36m"
WHITE="\033[37m"
BOLD="\033[1m"
DIM="\033[2m"
RESET="\033[0m"

# ------------------------------------------------------------------------------
# 基础打印与日志工具函数
# ------------------------------------------------------------------------------
info() {
    echo -e "${CYAN}[INFO]${RESET} $*"
}

success() {
    echo -e "${GREEN}[SUCCESS]${RESET} $*"
}

warn() {
    echo -e "${YELLOW}[WARN]${RESET} $*"
}

error() {
    echo -e "${RED}[ERROR]${RESET} $*"
}

pause() {
    echo ""
    read -r -p "按回车键继续..." dummy
}

# ------------------------------------------------------------------------------
# 权限与依赖检查
# ------------------------------------------------------------------------------
check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        warn "当前非 root 用户，执行系统级操作（Swap、包安装、系统网络配置）可能需要 sudo 权限。"
    fi
}

get_compose_cmd() {
    if docker compose version >/dev/null 2>&1; then
        echo "docker compose"
    elif command -v docker-compose >/dev/null 2>&1; then
        echo "docker-compose"
    else
        echo ""
    fi
}

compose() {
    local cmd
    cmd=$(get_compose_cmd)
    if [ -z "$cmd" ]; then
        error "未检测到 Docker Compose！请先通过菜单项或安装脚本安装 Docker 环境。"
        return 1
    fi
    $cmd -f "$COMPOSE_FILE" "$@"
}

check_docker() {
    if ! command -v docker >/dev/null 2>&1; then
        return 1
    fi
    if [ -z "$(get_compose_cmd)" ]; then
        return 1
    fi
    return 0
}

install_docker() {
    info "正在安装 Docker 与 Docker Compose..."
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL https://get.docker.com | sh
    elif command -v wget >/dev/null 2>&1; then
        wget -qO- https://get.docker.com | sh
    else
        error "请先安装 curl 或 wget！"
        return 1
    fi

    # 启动并配置自启
    if command -v systemctl >/dev/null 2>&1; then
        systemctl enable --now docker
    elif command -v service >/dev/null 2>&1; then
        service docker start
    fi

    if check_docker; then
        success "Docker 及 Compose 安装成功！"
    else
        error "Docker 安装失败，请检查网络或手动安装。"
        return 1
    fi
}

# ------------------------------------------------------------------------------
# 硬件与系统信息检测
# ------------------------------------------------------------------------------
get_ram_info() {
    local total_mb=0 free_mb=0
    if [ -f /proc/meminfo ]; then
        total_mb=$(awk '/MemTotal/ {print int($2 / 1024)}' /proc/meminfo)
        free_mb=$(awk '/MemAvailable/ {print int($2 / 1024)}' /proc/meminfo 2>/dev/null || awk '/MemFree/ {print int($2 / 1024)}' /proc/meminfo)
    elif command -v free >/dev/null 2>&1; then
        total_mb=$(free -m | awk '/Mem:/ {print $2}')
        free_mb=$(free -m | awk '/Mem:/ {print $4}')
    fi
    echo "${total_mb:-2048} ${free_mb:-1024}"
}

get_swap_info() {
    local total_mb=0 free_mb=0
    if [ -f /proc/meminfo ]; then
        total_mb=$(awk '/SwapTotal/ {print int($2 / 1024)}' /proc/meminfo)
        free_mb=$(awk '/SwapFree/ {print int($2 / 1024)}' /proc/meminfo)
    elif command -v free >/dev/null 2>&1; then
        total_mb=$(free -m | awk '/Swap:/ {print $2}')
        free_mb=$(free -m | awk '/Swap:/ {print $4}')
    fi
    echo "${total_mb:-0} ${free_mb:-0}"
}

CACHED_HOST_IP=""

get_host_ip() {
    if [ -n "$CACHED_HOST_IP" ]; then
        echo "$CACHED_HOST_IP"
        return
    fi
    local ip
    ip=$(curl -s -m 1 https://ip.sb 2>/dev/null || \
         curl -s -m 1 https://icanhazip.com 2>/dev/null || \
         curl -s -m 1 https://api.ipify.org 2>/dev/null || \
         hostname -I 2>/dev/null | awk '{print $1}')
    CACHED_HOST_IP="${ip:-127.0.0.1}"
    echo "$CACHED_HOST_IP"
}

# ------------------------------------------------------------------------------
# 环境配置 (.env) 管理
# ------------------------------------------------------------------------------
load_env() {
    if [ -f "$ENV_FILE" ]; then
        # 读取配置并过滤注释
        while IFS='=' read -r key value || [ -n "$key" ]; do
            # 去除两端空白和注释
            key=$(echo "$key" | tr -d ' ' | tr -d '\r')
            if [[ -z "$key" || "$key" =~ ^# ]]; then
                continue
            fi
            value=$(echo "$value" | tr -d '\r')
            # 去除外层单双引号
            value="${value%\"}"
            value="${value#\"}"
            value="${value%\'}"
            value="${value#\'}"
            export "$key"="$value"
        done < "$ENV_FILE"
    fi

    # 默认值回落
    BIND_IP="${BIND_IP:-127.0.0.1}"
    ENABLED_SERVICES="${ENABLED_SERVICES:-newapi,grok2api,cliproxy,workbuddy}"
    NEWAPI_PORT="${NEWAPI_PORT:-3000}"
    GROK2API_PORT="${GROK2API_PORT:-8000}"
    CLIPROXY_PORT="${CLIPROXY_PORT:-8317}"
    WORKBUDDY_PORT="${WORKBUDDY_PORT:-7863}"
    TZ="${TZ:-Asia/Shanghai}"
}

save_env() {
    cat <<EOF > "$ENV_FILE"
# ==============================================================================
# aiproxy-box 环境与网络配置文件
# 自动生成时间: $(date '+%Y-%m-%d %H:%M:%S')
# ==============================================================================

# 监听 IP 地址: 127.0.0.1 (本地回环安全模式) 或 0.0.0.0 (公网直开模式)
BIND_IP=${BIND_IP:-127.0.0.1}

# 启用的核心组件清单 (逗号分隔: newapi,grok2api,cliproxy,workbuddy)
ENABLED_SERVICES=${ENABLED_SERVICES:-newapi,grok2api,cliproxy,workbuddy}

# 服务映射端口
NEWAPI_PORT=${NEWAPI_PORT:-3000}
GROK2API_PORT=${GROK2API_PORT:-8000}
CLIPROXY_PORT=${CLIPROXY_PORT:-8317}
WORKBUDDY_PORT=${WORKBUDDY_PORT:-7863}

# 系统时区
TZ=${TZ:-Asia/Shanghai}
EOF
}

is_service_enabled() {
    local svc="$1"
    local list="${2:-$ENABLED_SERVICES}"
    [[ ",${list}," =~ ,${svc}, ]]
}

# ------------------------------------------------------------------------------
# 凭据随机生成与模版同步
# ------------------------------------------------------------------------------
generate_random_hex() {
    local num_bytes="${1:-32}"
    if command -v openssl >/dev/null 2>&1; then
        openssl rand -hex "$num_bytes" 2>/dev/null | tr -d '\r\n'
    elif [ -c /dev/urandom ]; then
        head -c "$num_bytes" /dev/urandom 2>/dev/null | od -An -tx1 2>/dev/null | tr -d ' \r\n' || head -c "$((num_bytes * 2))" /dev/urandom | tr -dc 'a-f0-9'
    else
        date +%s%N | sha256sum | awk '{print $1}' | head -c "$((num_bytes * 2))"
    fi
}

generate_random_base64() {
    local num_bytes="${1:-32}"
    if command -v openssl >/dev/null 2>&1; then
        openssl rand -base64 "$num_bytes" 2>/dev/null | tr -d '\r\n'
    elif [ -c /dev/urandom ]; then
        head -c "$num_bytes" /dev/urandom 2>/dev/null | base64 | tr -d '\r\n'
    else
        date +%s%N | base64 | tr -d '\r\n' | head -c 44
    fi
}

init_service_configs() {
    mkdir -p "$DATA_DIR/newapi"
    mkdir -p "$DATA_DIR/grok2api/data"
    mkdir -p "$DATA_DIR/cliproxy/auths"
    mkdir -p "$DATA_DIR/workbuddy/auths"
    mkdir -p "$DATA_DIR/workbuddy/data"

    # 1. Grok2API 初始配置
    if [ ! -f "$DATA_DIR/grok2api/config.yaml" ] && [ -f "$TEMPLATES_DIR/grok2api.yaml" ]; then
        info "初始化 Grok2API 默认配置文件并注入随机加密密钥 (AES-256 / 32字节)..."
        local jwt_secret enc_key
        jwt_secret=$(generate_random_hex 32)
        enc_key=$(generate_random_base64 32)
        sed -e "s#CHANGE_ME_JWT_SECRET_32_HEX_CHARACTERS#$jwt_secret#g" \
            -e "s#CHANGE_ME_BASE64_ENCRYPTION_KEY_32_BYTES#$enc_key#g" \
            "$TEMPLATES_DIR/grok2api.yaml" > "$DATA_DIR/grok2api/config.yaml"
    fi

    # 2. CLIProxyAPI 初始配置
    if [ ! -f "$DATA_DIR/cliproxy/config.yaml" ] && [ -f "$TEMPLATES_DIR/cliproxy.yaml" ]; then
        info "初始化 CLIProxyAPI 默认配置文件..."
        cp "$TEMPLATES_DIR/cliproxy.yaml" "$DATA_DIR/cliproxy/config.yaml"
    fi

    # 3. WorkBuddy2API 初始配置与 UID 权限修复
    if [ ! -f "$DATA_DIR/workbuddy/config.json" ] && [ -f "$TEMPLATES_DIR/workbuddy.json" ]; then
        info "初始化 WorkBuddy2API 默认配置文件..."
        cp "$TEMPLATES_DIR/workbuddy.json" "$DATA_DIR/workbuddy/config.json"
    fi

    # 设置目录权限，防止 umask 导致容器内部权限拒绝
    chmod 755 "$DATA_DIR/newapi" 2>/dev/null || true
    chmod 755 "$DATA_DIR/grok2api" "$DATA_DIR/grok2api/data" 2>/dev/null || true
    [ -f "$DATA_DIR/grok2api/config.yaml" ] && chmod 644 "$DATA_DIR/grok2api/config.yaml" 2>/dev/null || true
    [ -f "$DATA_DIR/cliproxy/config.yaml" ] && chmod 644 "$DATA_DIR/cliproxy/config.yaml" 2>/dev/null || true

    # 修复 WorkBuddy2API 的 uid 10001 读写权限问题 (跨 uid 部署经典踩坑点)
    if [ -d "$DATA_DIR/workbuddy" ]; then
        chmod 755 "$DATA_DIR/workbuddy" 2>/dev/null || true
        [ -f "$DATA_DIR/workbuddy/config.json" ] && chmod 644 "$DATA_DIR/workbuddy/config.json" 2>/dev/null || true
        if [ "$(id -u)" -eq 0 ]; then
            chown -R 10001:10001 "$DATA_DIR/workbuddy" 2>/dev/null || true
        fi
        chmod -R 777 "$DATA_DIR/workbuddy/auths" "$DATA_DIR/workbuddy/data" 2>/dev/null || true
    fi
}

# ------------------------------------------------------------------------------
# 动态 Compose 组装引擎
# ------------------------------------------------------------------------------
generate_compose() {
    if [ -z "$ENABLED_SERVICES" ]; then
        load_env
    fi
    init_service_configs

    if [ -z "$ENABLED_SERVICES" ]; then
        warn "未启用任何核心服务，无法生成有效 Compose 文件！"
        return 1
    fi

    # 读取内存信息，决定是否注入 OOM 防护限额
    read -r ram_total ram_free <<< "$(get_ram_info)"
    local is_low_spec=false
    if [ "$ram_total" -le 1536 ]; then
        is_low_spec=true
    fi

    info "正在动态组装 docker-compose.yml (内存探测: ${ram_total}MB, 低配限额注入: $is_low_spec)..."

    cat <<'EOF' > "$COMPOSE_FILE"
# ==============================================================================
# 由 aiproxy-box 自动化引擎动态组装生成 - 请勿直接手动修改
# 生成时间: 
EOF
    echo "# 生成时间: $(date '+%Y-%m-%d %H:%M:%S')" >> "$COMPOSE_FILE"
    cat <<'EOF' >> "$COMPOSE_FILE"
# ==============================================================================

networks:
  aiproxy-net:
    name: aiproxy-net
    driver: bridge

services:
EOF

    # 1. NewAPI 组件
    if is_service_enabled "newapi"; then
        cat <<EOF >> "$COMPOSE_FILE"
  new-api:
    image: calciumion/new-api:latest
    container_name: new-api
    restart: unless-stopped
    ports:
      - "\${BIND_IP:-127.0.0.1}:\${NEWAPI_PORT:-3000}:3000"
    volumes:
      - ./data/newapi:/data
    environment:
      - TZ=\${TZ:-Asia/Shanghai}
    networks:
      - aiproxy-net
    logging:
      driver: "json-file"
      options:
        max-size: "20m"
        max-file: "3"
EOF
        if [ "$is_low_spec" = true ]; then
            cat <<EOF >> "$COMPOSE_FILE"
    deploy:
      resources:
        limits:
          memory: 350M
EOF
        fi
    fi

    # 2. Grok2API 组件
    if is_service_enabled "grok2api"; then
        cat <<EOF >> "$COMPOSE_FILE"
  grok2api:
    image: ghcr.io/chenyme/grok2api:latest
    container_name: grok2api
    restart: unless-stopped
    ports:
      - "\${BIND_IP:-127.0.0.1}:\${GROK2API_PORT:-8000}:8000"
    volumes:
      - ./data/grok2api/config.yaml:/run/grok2api/config.yaml:ro
      - ./data/grok2api/data:/app/data
    environment:
      - TZ=\${TZ:-Asia/Shanghai}
    networks:
      - aiproxy-net
    logging:
      driver: "json-file"
      options:
        max-size: "20m"
        max-file: "3"
EOF
        if [ "$is_low_spec" = true ]; then
            cat <<EOF >> "$COMPOSE_FILE"
    deploy:
      resources:
        limits:
          memory: 250M
EOF
        fi
    fi

    # 3. CLIProxyAPI 组件
    if is_service_enabled "cliproxy"; then
        cat <<EOF >> "$COMPOSE_FILE"
  cli-proxy-api:
    image: eceasy/cli-proxy-api:latest
    container_name: cli-proxy-api
    restart: unless-stopped
    ports:
      - "\${BIND_IP:-127.0.0.1}:\${CLIPROXY_PORT:-8317}:8317"
    volumes:
      - ./data/cliproxy/config.yaml:/CLIProxyAPI/config.yaml
      - ./data/cliproxy/auths:/root/.cli-proxy-api
    environment:
      - TZ=\${TZ:-Asia/Shanghai}
    networks:
      - aiproxy-net
    logging:
      driver: "json-file"
      options:
        max-size: "20m"
        max-file: "3"
EOF
        if [ "$is_low_spec" = true ]; then
            cat <<EOF >> "$COMPOSE_FILE"
    deploy:
      resources:
        limits:
          memory: 250M
EOF
        fi
    fi

    # 4. WorkBuddy2API 组件
    if is_service_enabled "workbuddy"; then
        cat <<EOF >> "$COMPOSE_FILE"
  workbuddy2api:
    image: ghcr.io/sliverkiss/workbuddy2api:latest
    container_name: workbuddy2api
    restart: unless-stopped
    ports:
      - "\${BIND_IP:-127.0.0.1}:\${WORKBUDDY_PORT:-7863}:7863"
    volumes:
      - ./data/workbuddy/auths:/app/auths
      - ./data/workbuddy/data:/app/data
      - ./data/workbuddy/config.json:/app/config.json:ro
    environment:
      - TZ=\${TZ:-Asia/Shanghai}
    networks:
      - aiproxy-net
    logging:
      driver: "json-file"
      options:
        max-size: "20m"
        max-file: "3"
EOF
        if [ "$is_low_spec" = true ]; then
            cat <<EOF >> "$COMPOSE_FILE"
    deploy:
      resources:
        limits:
          memory: 200M
EOF
        fi
    fi

    success "Compose 文件已成功构建！"
}

ensure_initialized() {
    load_env
    if [ ! -f "$ENV_FILE" ]; then
        save_env
    fi
    init_service_configs
    if [ ! -f "$COMPOSE_FILE" ]; then
        generate_compose
    fi
}

# ------------------------------------------------------------------------------
# 状态探测与彩色看板渲染
# ------------------------------------------------------------------------------
get_container_status() {
    local cname="$1"
    if ! docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qw "$cname"; then
        echo "未创建"
        return
    fi
    local state
    state=$(docker inspect -f '{{.State.Status}}' "$cname" 2>/dev/null)
    if [ "$state" = "running" ]; then
        echo "运行中"
    else
        echo "已停止"
    fi
}

get_container_stats() {
    local cname="$1"
    local output
    output=$(docker stats --no-stream --format "{{.CPUPerc}} | {{.MemUsage}}" "$cname" 2>/dev/null)
    if [ -n "$output" ]; then
        echo "$output"
    else
        echo "0.00% | 0MB"
    fi
}

print_header() {
    clear 2>/dev/null || echo ""
    read -r ram_total ram_free <<< "$(get_ram_info)"
    read -r swap_total swap_free <<< "$(get_swap_info)"
    local host_ip
    host_ip=$(get_host_ip)

    echo -e "${CYAN}======================================================================${RESET}"
    echo -e "${BOLD}${CYAN}        __ _ _ __  _ __ _____  ___   _      _                      ${RESET}"
    echo -e "${BOLD}${CYAN}       / _\` | '_ \| '__/ _ \ \/ / | | |    | |                     ${RESET}"
    echo -e "${BOLD}${CYAN}      | (_| | |_) | | | (_) >  <| |_| |____| |__   _____  __       ${RESET}"
    echo -e "${BOLD}${CYAN}       \__,_| .__/|_|  \___/_/\_\\__, |______| '_ \ / _ \ \/ /      ${RESET}"
    echo -e "${BOLD}${CYAN}            | |                   __/ |      | |_) | (_) >  <       ${RESET}"
    echo -e "${BOLD}${CYAN}            |_|                  |___/       |_.__/ \___/_/\_\      ${RESET}"
    echo -e "${CYAN}======================================================================${RESET}"
    echo -e " 版本: ${GREEN}v${VERSION}${RESET}  |  项目目录: ${DIM}${APP_DIR}${RESET}"
    echo -e " 宿主 IP: ${YELLOW}${host_ip}${RESET}  |  网络模式: $( [ "${BIND_IP}" = "0.0.0.0" ] && echo -e "${RED}公网直开 (0.0.0.0)${RESET}" || echo -e "${GREEN}安全双模 (127.0.0.1)${RESET}" )"
    echo -e " 物理内存: ${WHITE}${ram_total}MB${RESET} (剩余: ${WHITE}${ram_free}MB${RESET}) | 虚拟内存 (Swap): ${WHITE}${swap_total}MB${RESET} (剩余: ${WHITE}${swap_free}MB${RESET})"

    if [ "$ram_total" -le 1536 ] && [ "$swap_total" -lt 1024 ]; then
        echo -e " ${RED}⚠ 警告: 当前物理内存 <= 1.5GB 且 Swap 未达标，极易发生 OOM 崩溃！建议使用菜单 6 创建 Swap。${RESET}"
    fi
    echo -e "${CYAN}----------------------------------------------------------------------${RESET}"
    echo -e "${BOLD} 组件运行状态概览:${RESET}"

    printf " %-16s %-10s %-12s %-20s %-20s\n" "组件服务" "安装状态" "运行状态" "监听绑定" "实时资源占用"
    printf " %-16s %-10s %-12s %-20s %-20s\n" "----------------" "--------" "--------" "-------------------" "-------------------"

    local svcs=("newapi:NewAPI:new-api:$NEWAPI_PORT" "grok2api:Grok2API:grok2api:$GROK2API_PORT" "cliproxy:CLIProxyAPI:cli-proxy-api:$CLIPROXY_PORT" "workbuddy:WorkBuddy2API:workbuddy2api:$WORKBUDDY_PORT")

    for item in "${svcs[@]}"; do
        IFS=':' read -r code label cname port <<< "$item"
        local inst_str="${DIM}未安装${RESET}"
        local run_str="${DIM}---${RESET}"
        local bind_str="${DIM}---${RESET}"
        local res_str="${DIM}---${RESET}"

        if is_service_enabled "$code"; then
            inst_str="${GREEN}已启用${RESET}"
            bind_str="${BIND_IP}:${port}"
            local st
            st=$(get_container_status "$cname")
            if [ "$st" = "运行中" ]; then
                run_str="${GREEN}● 运行中${RESET}"
                res_str=$(get_container_stats "$cname")
            elif [ "$st" = "已停止" ]; then
                run_str="${RED}■ 已停止${RESET}"
            else
                run_str="${YELLOW}○ 未运行${RESET}"
            fi
        fi

        printf " %-16s %-18b %-20b %-20s %-20s\n" "$label" "$inst_str" "$run_str" "$bind_str" "$res_str"
    done
    echo -e "${CYAN}======================================================================${RESET}"
}

# ------------------------------------------------------------------------------
# 菜单功能 1: 服务启停管理
# ------------------------------------------------------------------------------
menu_service_control() {
    while true; do
        clear 2>/dev/null || echo ""
        echo -e "${CYAN}================== [1] 服务启停与重启管理 ==================${RESET}"
        echo -e " ${GREEN}1.${RESET} 启动全部已启用服务"
        echo -e " ${YELLOW}2.${RESET} 重启全部已启用服务"
        echo -e " ${RED}3.${RESET} 停止全部服务"
        echo -e " ---------------------------------------------------------"
        echo -e " ${CYAN}4.${RESET} 启动单个容器"
        echo -e " ${CYAN}5.${RESET} 重启单个容器"
        echo -e " ${CYAN}6.${RESET} 停止单个容器"
        echo -e " ---------------------------------------------------------"
        echo -e " ${WHITE}0.${RESET} 返回主菜单"
        echo -e "${CYAN}===========================================================${RESET}"
        read -r -p "请输入选项编号 [0-6]: " opt
        case "$opt" in
            1)
                info "正在启动全部服务..."
                generate_compose
                compose up -d
                success "启动指令已执行！"
                pause
                ;;
            2)
                info "正在重启全部服务..."
                generate_compose
                compose restart
                success "重启完毕！"
                pause
                ;;
            3)
                info "正在停止全部服务..."
                compose down
                success "所有容器已停止！"
                pause
                ;;
            4)
                echo -e "可选容器: new-api, grok2api, cli-proxy-api, workbuddy2api"
                read -r -p "请输入要启动的容器名称: " cname
                if [ -n "$cname" ]; then
                    (docker start "$cname" 2>/dev/null || compose up -d "$cname") && success "$cname 已启动" || error "启动失败"
                fi
                pause
                ;;
            5)
                echo -e "可选容器: new-api, grok2api, cli-proxy-api, workbuddy2api"
                read -r -p "请输入要重启的容器名称: " cname
                if [ -n "$cname" ]; then
                    (docker restart "$cname" 2>/dev/null || (compose stop "$cname" 2>/dev/null && compose up -d "$cname")) && success "$cname 已重启" || error "重启失败"
                fi
                pause
                ;;
            6)
                echo -e "可选容器: new-api, grok2api, cli-proxy-api, workbuddy2api"
                read -r -p "请输入要停止的容器名称: " cname
                if [ -n "$cname" ]; then
                    docker stop "$cname" && success "$cname 已停止" || error "停止失败"
                fi
                pause
                ;;
            0)
                break
                ;;
            *)
                warn "无效选项，请重新输入"
                sleep 1
                ;;
        esac
    done
}

# ------------------------------------------------------------------------------
# 菜单功能 2: 组件配置与加装
# ------------------------------------------------------------------------------
toggle_service_list() {
    local target="$1"
    local cur_list="$2"
    local list=()
    IFS=',' read -r -a current <<< "$cur_list"
    local found=false
    for s in "${current[@]}"; do
        if [ "$s" = "$target" ]; then
            found=true
        else
            [ -n "$s" ] && list+=("$s")
        fi
    done

    if [ "$found" = false ]; then
        list+=("$target")
    fi

    IFS=','; echo "${list[*]}"
}

toggle_service() {
    local target="$1"
    ENABLED_SERVICES=$(toggle_service_list "$target" "$ENABLED_SERVICES")
    save_env
}

menu_component_selection() {
    load_env
    local temp_services="$ENABLED_SERVICES"
    while true; do
        clear 2>/dev/null || echo ""
        echo -e "${CYAN}================== [2] 组件定制与加装 ==================${RESET}"
        echo -e " 当前待应用组件: ${GREEN}${temp_services:-（无）}${RESET}"
        echo -e " 说明: 您可以按需开启或关闭各个组件，确认后选择 [5] 保存并生效。"
        echo -e " ---------------------------------------------------------"
        echo -e " 1. [$(is_service_enabled 'newapi' "$temp_services" && echo -e "${GREEN}✓ 启用${RESET}" || echo -e "${RED}✗ 禁用${RESET}")] NewAPI (AI 聚合渠道分发网关)"
        echo -e " 2. [$(is_service_enabled 'grok2api' "$temp_services" && echo -e "${GREEN}✓ 启用${RESET}" || echo -e "${RED}✗ 禁用${RESET}")] Grok2API (Grok 逆向与多账号池网关)"
        echo -e " 3. [$(is_service_enabled 'cliproxy' "$temp_services" && echo -e "${GREEN}✓ 启用${RESET}" || echo -e "${RED}✗ 禁用${RESET}")] CLIProxyAPI (Claude/Codex/GrokBuild OAuth 代理)"
        echo -e " 4. [$(is_service_enabled 'workbuddy' "$temp_services" && echo -e "${GREEN}✓ 启用${RESET}" || echo -e "${RED}✗ 禁用${RESET}")] WorkBuddy2API (Gemini/Claude 多功能网关)"
        echo -e " ---------------------------------------------------------"
        echo -e " 5. ${BOLD}${MAGENTA}应用变更并立即重新部署容器${RESET}"
        echo -e " 6. 全选并开启所有 4 大核心服务"
        echo -e " 0. 返回主菜单 (放弃未应用修改)"
        echo -e "${CYAN}===========================================================${RESET}"
        read -r -p "请输入切换组件编号 [0-6]: " opt
        case "$opt" in
            1)
                temp_services=$(toggle_service_list "newapi" "$temp_services")
                ;;
            2)
                temp_services=$(toggle_service_list "grok2api" "$temp_services")
                ;;
            3)
                temp_services=$(toggle_service_list "cliproxy" "$temp_services")
                ;;
            4)
                temp_services=$(toggle_service_list "workbuddy" "$temp_services")
                ;;
            5)
                if [ -z "$temp_services" ]; then
                    warn "错误: 必须至少启用一个核心组件！已自动恢复全部启用。"
                    temp_services="newapi,grok2api,cliproxy,workbuddy"
                    sleep 1
                    continue
                fi
                ENABLED_SERVICES="$temp_services"
                save_env
                info "正在应用组件配置并重新启动 Docker Compose..."
                generate_compose
                compose up -d --remove-orphans
                success "组件重构与应用完成！"
                pause
                break
                ;;
            6)
                temp_services="newapi,grok2api,cliproxy,workbuddy"
                success "已全选 4 大核心服务！请选择 5 应用变更。"
                sleep 1
                ;;
            0)
                # 放弃未应用的修改，重新载入原有配置
                load_env
                break
                ;;
            *)
                warn "无效输入！"
                sleep 1
                ;;
        esac
    done
}

# ------------------------------------------------------------------------------
# 菜单功能 3: 实时日志查看
# ------------------------------------------------------------------------------
menu_view_logs() {
    clear 2>/dev/null || echo ""
    echo -e "${CYAN}================== [3] 服务日志实时查看 ==================${RESET}"
    echo -e " ${GREEN}1.${RESET} 查看 NewAPI 日志"
    echo -e " ${GREEN}2.${RESET} 查看 Grok2API 日志"
    echo -e " ${GREEN}3.${RESET} 查看 CLIProxyAPI 日志"
    echo -e " ${GREEN}4.${RESET} 查看 WorkBuddy2API 日志"
    echo -e " ${YELLOW}5.${RESET} 查看所有已启用服务聚合日志"
    echo -e " ---------------------------------------------------------"
    echo -e " ${WHITE}0.${RESET} 返回主菜单"
    echo -e "${CYAN}===========================================================${RESET}"
    echo -e "${DIM}提示: 进入日志查看后，按下 Ctrl+C 即可安全退出日志回到菜单。${RESET}"
    read -r -p "请选择服务 [0-5]: " opt

    local log_interrupted=false
    trap 'log_interrupted=true; echo ""' INT

    case "$opt" in
        1) compose logs -f --tail=100 new-api ;;
        2) compose logs -f --tail=100 grok2api ;;
        3) compose logs -f --tail=100 cli-proxy-api ;;
        4) compose logs -f --tail=100 workbuddy2api ;;
        5) compose logs -f --tail=50 ;;
        0) trap - INT; return ;;
        *) warn "无效选项" ; sleep 1 ;;
    esac

    trap - INT
    if [ "$log_interrupted" = true ]; then
        info "已退出实时日志跟踪。"
    fi
    pause
}

# ------------------------------------------------------------------------------
# 菜单功能 4: 服务状态与资源监控
# ------------------------------------------------------------------------------
menu_status_monitor() {
    clear 2>/dev/null || echo ""
    echo -e "${CYAN}================== [4] 服务状态与资源监控 ==================${RESET}"
    echo -e "${BOLD}Docker 容器详情列表:${RESET}"
    docker ps --filter "network=aiproxy-net" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" 2>/dev/null || docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
    echo ""
    echo -e "${BOLD}实时资源开销 (CPU / 内存 / 网络 I/O / 磁盘 I/O):${RESET}"
    docker stats --no-stream --format "table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.MemPerc}}\t{{.NetIO}}\t{{.BlockIO}}" $(docker ps -q --filter "network=aiproxy-net" 2>/dev/null) 2>/dev/null || docker stats --no-stream
    pause
}

# ------------------------------------------------------------------------------
# 端口校验与冲突检测
# ------------------------------------------------------------------------------
is_valid_port() {
    local port="$1"
    [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ]
}

check_host_port_conflict() {
    local port="$1"
    local svc_cname="$2"
    if ! is_valid_port "$port"; then
        return 1
    fi
    local in_use=false
    if command -v ss >/dev/null 2>&1; then
        if ss -tulpn 2>/dev/null | grep -E ":${port}\b" >/dev/null; then
            in_use=true
        fi
    elif command -v netstat >/dev/null 2>&1; then
        if netstat -tulpn 2>/dev/null | grep -E ":${port}\b" >/dev/null; then
            in_use=true
        fi
    elif command -v lsof >/dev/null 2>&1; then
        if lsof -i ":${port}" >/dev/null 2>&1; then
            in_use=true
        fi
    fi

    if [ "$in_use" = true ]; then
        if [ -n "$svc_cname" ] && docker ps --format '{{.Names}}' 2>/dev/null | grep -qw "$svc_cname"; then
            return 0
        fi
        return 2
    fi
    return 0
}

# ------------------------------------------------------------------------------
# 菜单功能 5: 网络监听模式切换 (127.0.0.1 安全双模 vs 0.0.0.0 公网直开)
# ------------------------------------------------------------------------------
menu_network_mode() {
    clear 2>/dev/null || echo ""
    load_env
    echo -e "${CYAN}================== [5] 网络监听与端口策略切换 ==================${RESET}"
    echo -e " 当前绑定地址 (BIND_IP): ${YELLOW}${BIND_IP}${RESET}"
    echo ""
    echo -e " 模式说明:"
    echo -e " 【模式 A】${GREEN}127.0.0.1 (本地回环双模 / 强烈推荐)${RESET}"
    echo -e "   - 容器间加入 aiproxy-net 桥接网络，通过内网别名高速互通（例如 http://grok2api:8000）；"
    echo -e "   - 宿主机端口仅向本机 127.0.0.1 暴露，外部公网无法扫描探测，免去被爆破风险；"
    echo -e "   - 适合配合 Caddy / Nginx 等反向代理工具配置 SSL 证书和域名访问。"
    echo ""
    echo -e " 【模式 B】${RED}0.0.0.0 (公网直开模式)${RESET}"
    echo -e "   - 服务端口直接向全网暴露，任意用户访问 http://服务器公网IP:端口 即可调用；"
    echo -e "   - 适合临时测试或没有域名的海外云服务器。"
    echo -e "   - ${RED}安全注意: 请务必在各组件配置文件中设置高强度 API Key 与管理员密码！${RESET}"
    echo -e "${CYAN}---------------------------------------------------------------${RESET}"
    echo -e " 1. 切换为 【127.0.0.1 本地回环双模】"
    echo -e " 2. 切换为 【0.0.0.0 公网直开模式】"
    echo -e " 3. 自定义映射端口 (NewAPI, Grok2API, CLIProxy, WorkBuddy)"
    echo -e " 0. 返回主菜单"
    echo -e "${CYAN}===============================================================${RESET}"
    read -r -p "请选择 [0-3]: " opt
    case "$opt" in
        1)
            BIND_IP="127.0.0.1"
            save_env
            info "已设置为 127.0.0.1，正在重新生成 Compose 并重启生效..."
            generate_compose
            compose up -d
            success "网络模式已切换为 127.0.0.1 (安全双模)！"
            pause
            ;;
        2)
            BIND_IP="0.0.0.0"
            save_env
            info "已设置为 0.0.0.0，正在重新生成 Compose 并重启生效..."
            generate_compose
            compose up -d
            success "网络模式已切换为 0.0.0.0 (公网暴露)！"
            pause
            ;;
        3)
            echo -e "当前端口: NewAPI=$NEWAPI_PORT, Grok2API=$GROK2API_PORT, CLIProxy=$CLIPROXY_PORT, WorkBuddy=$WORKBUDDY_PORT"
            read -r -p "NewAPI 端口 [默认 $NEWAPI_PORT]: " p1
            read -r -p "Grok2API 端口 [默认 $GROK2API_PORT]: " p2
            read -r -p "CLIProxy 端口 [默认 $CLIPROXY_PORT]: " p3
            read -r -p "WorkBuddy 端口 [默认 $WORKBUDDY_PORT]: " p4
            local np1="${p1:-$NEWAPI_PORT}"
            local np2="${p2:-$GROK2API_PORT}"
            local np3="${p3:-$CLIPROXY_PORT}"
            local np4="${p4:-$WORKBUDDY_PORT}"

            # 校验端口格式
            for p in "$np1" "$np2" "$np3" "$np4"; do
                if ! is_valid_port "$p"; then
                    error "端口 $p 格式无效！端口必须为 1-65535 之间的整数。"
                    pause
                    return
                fi
            done

            # 校验项目各服务端口是否内部冲突
            if [ "$np1" = "$np2" ] || [ "$np1" = "$np3" ] || [ "$np1" = "$np4" ] || \
               [ "$np2" = "$np3" ] || [ "$np2" = "$np4" ] || [ "$np3" = "$np4" ]; then
                error "配置错误：各组件监听端口不能互相重复冲突！"
                pause
                return
            fi

            # 校验宿主机端口占用
            local warn_msg=""
            if ! check_host_port_conflict "$np1" "new-api"; then
                [ $? -eq 2 ] && warn_msg="NewAPI 端口 $np1"
            fi
            if ! check_host_port_conflict "$np2" "grok2api"; then
                [ $? -eq 2 ] && warn_msg="${warn_msg:+$warn_msg, }Grok2API 端口 $np2"
            fi
            if ! check_host_port_conflict "$np3" "cli-proxy-api"; then
                [ $? -eq 2 ] && warn_msg="${warn_msg:+$warn_msg, }CLIProxy 端口 $np3"
            fi
            if ! check_host_port_conflict "$np4" "workbuddy2api"; then
                [ $? -eq 2 ] && warn_msg="${warn_msg:+$warn_msg, }WorkBuddy 端口 $np4"
            fi

            if [ -n "$warn_msg" ]; then
                warn "检测到宿主机外部进程可能已占用: ${warn_msg}！"
                read -r -p "是否仍然强制应用？(y/N): " force_apply
                if [[ ! "$force_apply" =~ ^[Yy]$ ]]; then
                    info "已取消端口修改。"
                    pause
                    return
                fi
            fi

            NEWAPI_PORT="$np1"
            GROK2API_PORT="$np2"
            CLIPROXY_PORT="$np3"
            WORKBUDDY_PORT="$np4"
            save_env
            generate_compose
            compose up -d
            success "端口配置已更新并生效！"
            pause
            ;;
        0)
            return
            ;;
        *)
            warn "无效输入！"
            sleep 1
            ;;
    esac
}

# ------------------------------------------------------------------------------
# 菜单功能 6: 虚拟内存 (Swap) 管理与调优
# ------------------------------------------------------------------------------
menu_swap_manager() {
    while true; do
        clear 2>/dev/null || echo ""
        read -r ram_total ram_free <<< "$(get_ram_info)"
        read -r swap_total swap_free <<< "$(get_swap_info)"

        echo -e "${CYAN}================== [6] 虚拟内存 (Swap) 管理 ==================${RESET}"
        echo -e " 物理内存总量: ${WHITE}${ram_total} MB${RESET} (剩余: ${ram_free} MB)"
        echo -e " 当前 Swap 总量: ${WHITE}${swap_total} MB${RESET} (剩余: ${swap_free} MB)"
        local swappiness
        swappiness=$(cat /proc/sys/vm/swappiness 2>/dev/null || echo "未知")
        echo -e " 当前 Swap 积极度 (vm.swappiness): ${YELLOW}${swappiness}${RESET} (推荐: 10)"
        echo -e "${CYAN}---------------------------------------------------------------${RESET}"
        echo -e " 1. 一键创建 1GB Swap (适合 512MB~1GB 内存 VPS)"
        echo -e " 2. 一键创建 2GB Swap (适合 1GB~2GB 内存 VPS，黄金标准)"
        echo -e " 3. 一键创建 4GB Swap (适合极小内存同时运行多个后端服务)"
        echo -e " 4. 自定义容量创建 Swap"
        echo -e " 5. 调优 Swap 换页倾向 (设置 vm.swappiness=10 并持久化)"
        echo -e " 6. 删除并卸载已有 Swapfile"
        echo -e " 0. 返回主菜单"
        echo -e "${CYAN}===============================================================${RESET}"
        read -r -p "请选择 [0-6]: " opt
        case "$opt" in
            1) create_swap 1024 ; pause ;;
            2) create_swap 2048 ; pause ;;
            3) create_swap 4096 ; pause ;;
            4)
                read -r -p "请输入欲创建的 Swap 大小 (MB): " custom_mb
                if [[ "$custom_mb" =~ ^[0-9]+$ ]] && [ "$custom_mb" -gt 100 ]; then
                    create_swap "$custom_mb"
                else
                    error "输入格式错误！"
                fi
                pause
                ;;
            5)
                tune_swappiness
                pause
                ;;
            6)
                delete_swap
                pause
                ;;
            0)
                break
                ;;
            *)
                warn "无效输入！"
                sleep 1
                ;;
        esac
    done
}

create_swap() {
    local size_mb="$1"
    check_root

    info "准备创建 ${size_mb}MB Swap 虚拟内存..."
    local swap_file="/swapfile"

    if [ -f "$swap_file" ]; then
        warn "检测到系统中已存在 $swap_file，正在先卸载并清理..."
        swapoff "$swap_file" 2>/dev/null || true
        rm -f "$swap_file"
    fi

    # 针对 Btrfs 文件系统关闭 CoW 写时复制属性，避免 swapon 报 Invalid argument
    touch "$swap_file" 2>/dev/null || true
    chattr +C "$swap_file" 2>/dev/null || true

    # 尝试使用 fallocate，失败则降级为 dd
    info "分配磁盘空间 (${size_mb}MB)..."
    if ! fallocate -l "${size_mb}M" "$swap_file" 2>/dev/null; then
        dd if=/dev/zero of="$swap_file" bs=1M count="$size_mb" status=progress
    fi

    chmod 600 "$swap_file"
    mkswap "$swap_file"
    swapon "$swap_file"

    # 持久化到 /etc/fstab
    if ! grep -q "$swap_file" /etc/fstab 2>/dev/null; then
        echo "$swap_file swap swap defaults 0 0" >> /etc/fstab
        info "已将 Swap 配置持久化写入 /etc/fstab"
    fi

    tune_swappiness
    success "恭喜！${size_mb}MB Swap 创建并挂载成功！"
}

tune_swappiness() {
    check_root
    info "正在将系统 vm.swappiness 调优为 10 (优先使用物理内存，避免过度磁盘 I/O)..."
    sysctl -w vm.swappiness=10 >/dev/null 2>&1 || true

    if [ -f /etc/sysctl.conf ]; then
        if grep -qE '^[[:space:]]*vm\.swappiness' /etc/sysctl.conf; then
            sed -i -E 's/^[[:space:]]*vm\.swappiness[[:space:]]*=.*/vm.swappiness=10/' /etc/sysctl.conf
        else
            echo "vm.swappiness=10" >> /etc/sysctl.conf
        fi
        success "已永久写入 /etc/sysctl.conf (vm.swappiness=10)！"
    fi

    if [ -d /etc/sysctl.d ]; then
        echo "vm.swappiness=10" > /etc/sysctl.d/99-aiproxy.conf 2>/dev/null || true
    fi
}

delete_swap() {
    check_root
    local swap_file="/swapfile"
    if [ ! -f "$swap_file" ]; then
        warn "未检测到 $swap_file，无需清理！"
        return
    fi
    info "正在卸载并删除 $swap_file..."
    swapoff "$swap_file" 2>/dev/null || true
    rm -f "$swap_file"
    if [ -f /etc/fstab ]; then
        sed -i '\|/swapfile[[:space:]]|d' /etc/fstab
    fi
    success "Swap 虚拟内存已完全移除！"
}

# ------------------------------------------------------------------------------
# 菜单功能 7: NewAPI 渠道配置指引 & 内网连通性一键测试
# ------------------------------------------------------------------------------
menu_channel_guide() {
    clear 2>/dev/null || echo ""
    load_env
    local host_ip
    host_ip=$(get_host_ip)

    echo -e "${CYAN}================== [7] NewAPI 渠道配置卡片与内网连通指引 ==================${RESET}"
    echo -e " 当同时部署 NewAPI 与各后端服务时，优先推荐使用 ${GREEN}Docker 内网别名直连${RESET}："
    echo -e " - ${BOLD}零公网暴露${RESET}：外部无法窃听或嗅探 API 密钥；"
    echo -e " - ${BOLD}零回环延迟${RESET}：同一 bridge 内网寻址，响应速度最快；"
    echo -e " - ${BOLD}免配置域名${RESET}：无需反代或配置 SSL 证书直接互通。"
    echo -e "${CYAN}----------------------------------------------------------------------${RESET}"

    # 读取各服务配置中的密钥
    local grok_key="请在管理后台查看"
    local cliproxy_key="sk-cliproxy-default-key"
    local workbuddy_key="sk-workbuddy-default-key"

    if [ -f "$DATA_DIR/cliproxy/config.yaml" ]; then
        local found_key
        found_key=$(awk '/api-keys:/ {getline; print $2}' "$DATA_DIR/cliproxy/config.yaml" 2>/dev/null | tr -d '"' | tr -d "'")
        [ -n "$found_key" ] && cliproxy_key="$found_key"
    fi

    if [ -f "$DATA_DIR/workbuddy/config.json" ]; then
        local found_wb_key
        found_wb_key=$(grep '"api_key"' "$DATA_DIR/workbuddy/config.json" 2>/dev/null | cut -d '"' -f 4)
        [ -n "$found_wb_key" ] && workbuddy_key="$found_wb_key"
    fi

    # 1. Grok2API 卡片
    if is_service_enabled "grok2api"; then
        echo -e "${BOLD}${MAGENTA}【渠道 1: Grok2API (Grok 逆向多账号池)】${RESET}"
        echo -e "  - 渠道类型: ${GREEN}OpenAI${RESET}"
        echo -e "  - 渠道名称: Grok2API-内网集群"
        echo -e "  - 代理地址 (Base URL): ${YELLOW}http://grok2api:8000${RESET} (宿主机直连: http://${BIND_IP}:${GROK2API_PORT})"
        echo -e "  - 密钥 (Key): ${WHITE}${grok_key}${RESET} (可在后台配置或直接在渠道填入自定义 Token)"
        echo -e "  - 支持模型填入: ${CYAN}grok-3, grok-3-deepsearch, grok-3-reasoning, grok-2, grok-2-imageGen${RESET}"
        echo ""
    fi

    # 2. CLIProxyAPI 卡片
    if is_service_enabled "cliproxy"; then
        echo -e "${BOLD}${MAGENTA}【渠道 2: CLIProxyAPI (Claude/Codex/GrokBuild OAuth 代理)】${RESET}"
        echo -e "  - 渠道类型: ${GREEN}OpenAI${RESET} 或 ${GREEN}Anthropic (按凭据类型选)${RESET}"
        echo -e "  - 渠道名称: CLIProxyAPI-网关"
        echo -e "  - 代理地址 (Base URL): ${YELLOW}http://cli-proxy-api:8317${RESET} (宿主机直连: http://${BIND_IP}:${CLIPROXY_PORT})"
        echo -e "  - 密钥 (Key): ${WHITE}${cliproxy_key}${RESET}"
        echo -e "  - 推荐模型填入: ${CYAN}claude-3-7-sonnet, claude-3-5-sonnet, gpt-4o, o1, gemini-2.5-pro${RESET}"
        echo -e "  - 管理后台地址: ${DIM}http://${host_ip}:${CLIPROXY_PORT}/management.html${RESET}"
        echo ""
    fi

    # 3. WorkBuddy2API 卡片
    if is_service_enabled "workbuddy"; then
        echo -e "${BOLD}${MAGENTA}【渠道 3: WorkBuddy2API (Gemini/Claude 智能代理)】${RESET}"
        echo -e "  - 渠道类型: ${GREEN}OpenAI${RESET}"
        echo -e "  - 渠道名称: WorkBuddy2API-节点"
        echo -e "  - 代理地址 (Base URL): ${YELLOW}http://workbuddy2api:7863${RESET} (宿主机直连: http://${BIND_IP}:${WORKBUDDY_PORT})"
        echo -e "  - 密钥 (Key): ${WHITE}${workbuddy_key}${RESET}"
        echo -e "  - 推荐模型填入: ${CYAN}gemini-2.5-pro, gemini-2.5-flash, claude-3-7-sonnet, claude-3-5-sonnet${RESET}"
        echo ""
    fi

    echo -e "${CYAN}======================================================================${RESET}"
    echo -e " 1. 执行内网与宿主连通性实时测试 (Internal Curl Test)"
    echo -e " 0. 返回主菜单"
    read -r -p "请选择 [0-1]: " opt
    if [ "$opt" = "1" ]; then
        run_connectivity_test
        pause
    fi
}

run_connectivity_test() {
    echo ""
    info "正在开始执行服务健康与连通性测试..."

    # 测试宿主机直连端口 (0.0.0.0 测试时回环到 127.0.0.1)
    local test_ip="$BIND_IP"
    [ "$test_ip" = "0.0.0.0" ] && test_ip="127.0.0.1"

    local test_services=()
    is_service_enabled "newapi" && test_services+=("NewAPI:$test_ip:$NEWAPI_PORT:new-api")
    is_service_enabled "grok2api" && test_services+=("Grok2API:$test_ip:$GROK2API_PORT:grok2api")
    is_service_enabled "cliproxy" && test_services+=("CLIProxyAPI:$test_ip:$CLIPROXY_PORT:cli-proxy-api")
    is_service_enabled "workbuddy" && test_services+=("WorkBuddy2API:$test_ip:$WORKBUDDY_PORT:workbuddy2api")

    for item in "${test_services[@]}"; do
        IFS=':' read -r name ip port cname <<< "$item"
        if docker ps --format '{{.Names}}' 2>/dev/null | grep -qw "$cname"; then
            local code
            code=$(curl -s -o /dev/null -w "%{http_code}" -m 3 "http://${ip}:${port}" 2>/dev/null || echo "FAIL")
            if [ "$code" != "FAIL" ] && [ "$code" != "000" ]; then
                echo -e " [宿主机直连] ${name} (http://${ip}:${port}): ${GREEN}✓ 连通正常 (HTTP Code: $code)${RESET}"
            else
                echo -e " [宿主机直连] ${name} (http://${ip}:${port}): ${RED}✗ 无法连接 (拒绝访问/未监听)${RESET}"
            fi
        else
            echo -e " [宿主机直连] ${name}: ${DIM}跳过 (容器未运行)${RESET}"
        fi
    done

    # 测试容器桥接网络连通性 (如果有 NewAPI 运行)
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -qw "new-api"; then
        echo ""
        info "正在测试 NewAPI 容器内网桥接访问 (${CYAN}aiproxy-net${RESET})..."
        local internal_targets=()
        is_service_enabled "grok2api" && internal_targets+=("Grok2API:grok2api:8000")
        is_service_enabled "cliproxy" && internal_targets+=("CLIProxyAPI:cli-proxy-api:8317")
        is_service_enabled "workbuddy" && internal_targets+=("WorkBuddy2API:workbuddy2api:7863")

        for item in "${internal_targets[@]}"; do
            IFS=':' read -r sname target port <<< "$item"
            # 兼容检测: calciumion/new-api 容器基于 Alpine，默认自带 wget，部分版本含 curl
            local incode="FAIL"
            incode=$(docker exec new-api sh -c "
                if command -v curl >/dev/null 2>&1; then
                    curl -s -o /dev/null -w '%{http_code}' -m 3 'http://${target}:${port}' 2>/dev/null || echo FAIL
                elif command -v wget >/dev/null 2>&1; then
                    status=\$(wget -S -O /dev/null -T 3 'http://${target}:${port}' 2>&1 | awk '/HTTP\// {print \$2}' | tail -n 1)
                    if [ -n \"\$status\" ]; then
                        echo \"\$status\"
                    elif wget -q -O /dev/null -T 3 'http://${target}:${port}' 2>/dev/null; then
                        echo \"200\"
                    else
                        echo \"FAIL\"
                    fi
                elif command -v nc >/dev/null 2>&1; then
                    nc -z -w 3 '${target}' '${port}' >/dev/null 2>&1 && echo \"OPEN\" || echo \"FAIL\"
                else
                    echo \"FAIL\"
                fi
            " 2>/dev/null || echo "FAIL")

            if [ "$incode" != "FAIL" ] && [ "$incode" != "000" ] && [ -n "$incode" ]; then
                echo -e " [内网直连] NewAPI ➔ http://${target}:${port} (${sname}): ${GREEN}✓ 连通正常 (HTTP Code: $incode)${RESET}"
            else
                echo -e " [内网直连] NewAPI ➔ http://${target}:${port} (${sname}): ${YELLOW}○ 无响应或目标未就绪${RESET}"
            fi
        done
    fi
}

# ------------------------------------------------------------------------------
# 菜单功能 8: 反向代理助手 (Caddy / Caddy-pro 联动)
# ------------------------------------------------------------------------------
menu_caddy_helper() {
    clear 2>/dev/null || echo ""
    load_env
    echo -e "${CYAN}================== [8] 反向代理助手 (Caddy / Caddyfile) ==================${RESET}"
    echo -e " 说明: 本工具自动探测 Caddy 环境，并输出标准 HTTPS 反向代理配置代码块。"

    local has_caddy=false
    if command -v caddy >/dev/null 2>&1 || [ -f /etc/caddy/Caddyfile ]; then
        has_caddy=true
        echo -e " 宿主机 Caddy 状态: ${GREEN}已安装${RESET}"
    else
        echo -e " 宿主机 Caddy 状态: ${YELLOW}未检测到全局 Caddy (仍可生成配置文本供手动使用)${RESET}"
    fi

    echo -e "${CYAN}----------------------------------------------------------------------${RESET}"
    read -r -p "请输入欲绑定的顶级主域名 (例如 example.com): " domain
    if [ -z "$domain" ]; then
        warn "域名为空，返回上一层"
        sleep 1
        return
    fi

    # 动态组装已启用服务的 Caddy 反代配置
    local caddy_blocks=""
    if is_service_enabled "newapi"; then
        caddy_blocks="${caddy_blocks}
# NewAPI 统一中转面板 (支持自动签发 Let's Encrypt SSL)
api.${domain} {
    reverse_proxy 127.0.0.1:${NEWAPI_PORT}
}
"
    fi
    if is_service_enabled "grok2api"; then
        caddy_blocks="${caddy_blocks}
# Grok2API 独立接口端点
grok.${domain} {
    reverse_proxy 127.0.0.1:${GROK2API_PORT}
}
"
    fi
    if is_service_enabled "cliproxy"; then
        caddy_blocks="${caddy_blocks}
# CLIProxyAPI 独立管理与接口
cliproxy.${domain} {
    reverse_proxy 127.0.0.1:${CLIPROXY_PORT}
}
"
    fi
    if is_service_enabled "workbuddy"; then
        caddy_blocks="${caddy_blocks}
# WorkBuddy2API 独立接口
workbuddy.${domain} {
    reverse_proxy 127.0.0.1:${WORKBUDDY_PORT}
}
"
    fi

    if [ -z "$caddy_blocks" ]; then
        warn "当前未启用任何服务，无须生成反代配置！"
        pause
        return
    fi

    echo ""
    echo -e "${BOLD}已为您生成已启用服务的 Caddyfile 反代配置代码:${RESET}"
    echo -e "${MAGENTA}----------------------------------------------------------------------${RESET}"
    echo "# ==================== aiproxy-box 反向代理块开始 ===================="
    echo "$caddy_blocks"
    echo "# ==================== aiproxy-box 反向代理块结束 ===================="
    echo -e "${MAGENTA}----------------------------------------------------------------------${RESET}"

    if [ "$has_caddy" = true ] && [ -f /etc/caddy/Caddyfile ]; then
        read -r -p "是否直接将上述配置追加到 /etc/caddy/Caddyfile 并重载 Caddy? (y/N): " append_choice
        if [[ "$append_choice" =~ ^[Yy]$ ]]; then
            cat <<EOF >> /etc/caddy/Caddyfile

# === aiproxy-box auto reverse proxy block ===
$caddy_blocks
EOF
            caddy reload --config /etc/caddy/Caddyfile 2>/dev/null && success "已追加配置并重载 Caddy！" || warn "配置已追加，但重载可能需要手动执行: caddy reload"
        fi
    fi
    pause
}

# ------------------------------------------------------------------------------
# 菜单功能 9: 服务镜像更新
# ------------------------------------------------------------------------------
menu_update_images() {
    clear 2>/dev/null || echo ""
    echo -e "${CYAN}================== [9] 服务镜像更新与平滑重建 ==================${RESET}"
    info "正在拉取各个启用的最新 Docker 镜像..."
    generate_compose
    compose pull
    info "正在平滑重建容器..."
    compose up -d
    success "全部服务镜像更新并重启完毕！"
    pause
}

# ------------------------------------------------------------------------------
# 菜单功能 10: 数据备份与迁移
# ------------------------------------------------------------------------------
menu_backup() {
    clear 2>/dev/null || echo ""
    echo -e "${CYAN}================== [10] 数据备份与打包 ==================${RESET}"
    local backup_name="aiproxy-box-backup-$(date '+%Y%m%d_%H%M%S').tar.gz"
    info "正在打包凭证、数据库与配置文件到: $backup_name ..."

    # 检查待备份的关键项是否存在，防止 tar 报错
    local items=()
    for f in data .env templates docker-compose.yml; do
        [ -e "$APP_DIR/$f" ] && items+=("$f")
    done

    if [ ${#items[@]} -eq 0 ]; then
        warn "未检测到可备份的文件（请先运行或初始化服务）！"
        pause
        return
    fi

    # 排除大体积临时日志，仅备份配置和关键数据
    tar -czf "$APP_DIR/$backup_name" \
        -C "$APP_DIR" \
        --exclude="*.log" \
        --exclude="*.tar.gz" \
        "${items[@]}" 2>/dev/null

    if [ -f "$APP_DIR/$backup_name" ]; then
        local bsize
        bsize=$(du -h "$APP_DIR/$backup_name" | awk '{print $1}')
        success "备份成功！文件保存于: ${BOLD}${APP_DIR}/${backup_name}${RESET} (大小: ${bsize})"
        echo -e "提示: 迁移服务器时，只需将该备份包解压至新服务器 /opt/aiproxy-box 即可无缝恢复。"
    else
        error "打包失败，请检查磁盘空间！"
    fi
    pause
}

# ------------------------------------------------------------------------------
# 菜单功能 11: 全局快捷命令注册
# ------------------------------------------------------------------------------
register_shortcut() {
    check_root
    local target_bin="/usr/local/bin/aiproxy"
    info "正在注册全局命令: aiproxy ➔ $APP_DIR/aiproxy.sh ..."
    chmod +x "$APP_DIR/aiproxy.sh"
    ln -sf "$APP_DIR/aiproxy.sh" "$target_bin"
    if [ -L "$target_bin" ]; then
        success "注册成功！您现在可以在任意终端路径直接输入 ${BOLD}${GREEN}aiproxy${RESET} 唤醒控制台。"
    else
        warn "软链接创建失败，请检查 /usr/local/bin 写入权限。"
    fi
}

# ------------------------------------------------------------------------------
# 菜单功能 12: 完全卸载
# ------------------------------------------------------------------------------
menu_uninstall() {
    clear 2>/dev/null || echo ""
    echo -e "${RED}================== [12] 完全卸载 aiproxy-box ==================${RESET}"
    warn "警告: 卸载操作将停止所有容器并删除网络配置！"
    read -r -p "是否确认卸载？(y/N): " confirm_un
    if [[ ! "$confirm_un" =~ ^[Yy]$ ]]; then
        info "已取消卸载。"
        sleep 1
        return
    fi

    info "正在停止并清理容器..."
    compose down -v --remove-orphans 2>/dev/null || true

    read -r -p "是否同时彻底删除所有凭证与持久化数据 (data/ 目录)？(y/N): " rm_data
    if [[ "$rm_data" =~ ^[Yy]$ ]]; then
        rm -rf "$DATA_DIR" "$ENV_FILE" "$COMPOSE_FILE"
        info "运行时数据已清空。"
    fi

    rm -f "/usr/local/bin/aiproxy"
    success "aiproxy-box 容器与快捷方式卸载完成！"

    if [ "$APP_DIR" = "/opt/aiproxy-box" ]; then
        read -r -p "是否同时删除项目安装目录 ($APP_DIR)？(y/N): " rm_dir
        if [[ "$rm_dir" =~ ^[Yy]$ ]]; then
            info "正在清理 $APP_DIR ..."
            rm -rf "$APP_DIR"
        fi
    fi
    pause
    exit 0
}

# ------------------------------------------------------------------------------
# 主菜单交互循环
# ------------------------------------------------------------------------------
main_menu() {
    ensure_initialized
    # 捕获 Ctrl+C 防止意外退出主循环
    trap 'echo ""; echo -e "\n${GREEN}[INFO] 如需退出 aiproxy 控制台，请输入 0 回车。${RESET}"' INT
    while true; do
        print_header
        echo -e " ${BOLD}核心功能操作:${RESET}"
        echo -e "  ${GREEN}1.${RESET} 服务启停与重启管理       ${GREEN}7.${RESET} NewAPI 渠道配置指引与连通性测试"
        echo -e "  ${GREEN}2.${RESET} 组件配置与加装定制       ${GREEN}8.${RESET} 反向代理助手 (Caddyfile 生成)"
        echo -e "  ${GREEN}3.${RESET} 服务日志实时跟踪查看     ${GREEN}9.${RESET} 服务镜像更新与平滑重建"
        echo -e "  ${GREEN}4.${RESET} 服务状态与硬件资源监控   ${GREEN}10.${RESET} 数据备份与迁移打包"
        echo -e "  ${GREEN}5.${RESET} 网络监听模式快速切换     ${GREEN}11.${RESET} 全局快捷命令注册 (aiproxy)"
        echo -e "  ${GREEN}6.${RESET} 虚拟内存 (Swap) 管理     ${RED}12.${RESET} 完全卸载 aiproxy-box"
        echo -e " ----------------------------------------------------------------------"
        echo -e "  ${WHITE}0.${RESET} 退出管理菜单"
        echo -e "${CYAN}======================================================================${RESET}"
        read -r -p " 请输入操作选项 [0-12]: " choice
        case "$choice" in
            1) menu_service_control ;;
            2) menu_component_selection ;;
            3) menu_view_logs ;;
            4) menu_status_monitor ;;
            5) menu_network_mode ;;
            6) menu_swap_manager ;;
            7) menu_channel_guide ;;
            8) menu_caddy_helper ;;
            9) menu_update_images ;;
            10) menu_backup ;;
            11) register_shortcut ; pause ;;
            12) menu_uninstall ;;
            0)
                echo -e "${GREEN}感谢使用 aiproxy-box，再见！${RESET}"
                exit 0
                ;;
            *)
                warn "无效输入，请在 0-12 之间选择！"
                sleep 1
                ;;
        esac
    done
}

# ------------------------------------------------------------------------------
# CLI 命令行直接调用适配 (非交互模式)
# ------------------------------------------------------------------------------
cli_dispatch() {
    load_env
    case "$1" in
        menu|"")
            main_menu
            ;;
        init)
            info "正在初始化 aiproxy-box 基础配置与 Compose 编排..."
            ensure_initialized
            success "项目环境与 Compose 编排文件初始化完成！"
            ;;
        status)
            print_header
            ;;
        start)
            if [ -n "$2" ]; then
                docker start "$2" 2>/dev/null || compose up -d "$2"
            else
                generate_compose
                compose up -d
            fi
            ;;
        stop)
            if [ -n "$2" ]; then
                docker stop "$2"
            else
                compose down
            fi
            ;;
        restart)
            if [ -n "$2" ]; then
                docker restart "$2" 2>/dev/null || (compose stop "$2" && compose up -d "$2")
            else
                generate_compose
                compose restart
            fi
            ;;
        logs)
            if [ -n "$2" ]; then
                compose logs -f --tail=100 "$2"
            else
                compose logs -f --tail=50
            fi
            ;;
        update)
            generate_compose
            compose pull && compose up -d
            ;;
        backup)
            menu_backup
            ;;
        test)
            run_connectivity_test
            ;;
        help|--help|-h)
            echo "aiproxy-box CLI 命令行调用说明:"
            echo "  aiproxy               - 开启交互式 TUI 字符菜单"
            echo "  aiproxy init          - 初始化项目配置并生成 Compose 文件"
            echo "  aiproxy status        - 打印当前服务与资源状态"
            echo "  aiproxy start [svc]   - 启动所有或指定容器"
            echo "  aiproxy stop [svc]    - 停止所有或指定容器"
            echo "  aiproxy restart [svc] - 重启所有或指定容器"
            echo "  aiproxy logs [svc]    - 查看所有或指定容器实时日志"
            echo "  aiproxy update        - 拉取最新镜像并平滑重建"
            echo "  aiproxy backup        - 立即创建配置与数据备份包"
            echo "  aiproxy test          - 执行内网与宿主连通性测试"
            ;;
        *)
            warn "未知指令: $1，请使用 'aiproxy help' 查看帮助。"
            exit 1
            ;;
    esac
}

# 入口分发: 仅在直接执行时调用，被 source 引用时不触发交互
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    cli_dispatch "$@"
fi

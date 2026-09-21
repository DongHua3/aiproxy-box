#!/usr/bin/env bash
# ==============================================================================
# aiproxy-box 一键在线安装脚本
# 支持 Debian / Ubuntu / CentOS / Rocky / AlmaLinux / Alpine 等主流 Linux 系统
# 用法: curl -fsSL https://raw.githubusercontent.com/DongHua3/aiproxy-box/main/install.sh | bash
# ==============================================================================

set -e

# 颜色输出定义
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
CYAN="\033[36m"
WHITE="\033[37m"
BOLD="\033[1m"
RESET="\033[0m"

INSTALL_DIR="/opt/aiproxy-box"
REPO_URL="https://github.com/DongHua3/aiproxy-box.git"
REPO_ARCHIVE="https://github.com/DongHua3/aiproxy-box/archive/refs/heads/main.tar.gz"

echo -e "${CYAN}======================================================================${RESET}"
echo -e "${BOLD}${CYAN}            aiproxy-box (AI 代理全能工具箱) 一键安装程序             ${RESET}"
echo -e "${CYAN}======================================================================${RESET}"

# 1. 检查 root 权限
if [ "$(id -u)" -ne 0 ]; then
    echo -e "${RED}[ERROR] 必须使用 root 用户执行安装！请运行: sudo bash install.sh${RESET}"
    exit 1
fi

# 2. 检查并安装系统基础包
echo -e "${CYAN}[1/5] 正在检查并更新基础软件包依赖...${RESET}"
install_pkg() {
    if command -v apt-get >/dev/null 2>&1; then
        apt-get update -y
        apt-get install -y curl git tar sed gawk openssl
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y curl git tar sed gawk openssl
    elif command -v yum >/dev/null 2>&1; then
        yum install -y curl git tar sed gawk openssl
    elif command -v apk >/dev/null 2>&1; then
        apk add --no-cache curl git tar sed gawk bash openssl
    elif command -v pacman >/dev/null 2>&1; then
        pacman -Sy --noconfirm curl git tar sed gawk openssl
    fi
}
install_pkg >/dev/null 2>&1 || true

# 3. 检查 Docker 与 Docker Compose
echo -e "${CYAN}[2/5] 正在检查 Docker 与 Docker Compose 运行时...${RESET}"
has_docker=false
has_compose=false

if command -v docker >/dev/null 2>&1; then
    has_docker=true
fi

if docker compose version >/dev/null 2>&1 || command -v docker-compose >/dev/null 2>&1; then
    has_compose=true
fi

if [ "$has_docker" = false ] || [ "$has_compose" = false ]; then
    echo -e "${YELLOW}[INFO] 未检测到完整的 Docker 环境，正在通过官方源自动安装...${RESET}"
    curl -fsSL https://get.docker.com | sh || {
        echo -e "${RED}[ERROR] Docker 自动安装失败，请手动安装 Docker 后再运行本安装脚本！${RESET}"
        exit 1
    }
    if command -v systemctl >/dev/null 2>&1; then
        systemctl enable --now docker >/dev/null 2>&1 || true
    elif command -v rc-service >/dev/null 2>&1; then
        rc-update add docker boot >/dev/null 2>&1 || true
        rc-service docker start >/dev/null 2>&1 || true
    fi
fi
echo -e "${GREEN}✓ Docker 及 Docker Compose 准备就绪！${RESET}"

# 4. 下载与部署项目文件至 /opt/aiproxy-box
echo -e "${CYAN}[3/5] 正在安装 aiproxy-box 到 ${INSTALL_DIR} ...${RESET}"
mkdir -p "$INSTALL_DIR"

if command -v git >/dev/null 2>&1; then
    if [ -d "$INSTALL_DIR/.git" ]; then
        echo -e "${YELLOW}[INFO] 检测到已存在 Git 仓库，正在拉取最新代码...${RESET}"
        cd "$INSTALL_DIR" && git pull || true
    else
        git clone "$REPO_URL" "$INSTALL_DIR" 2>/dev/null || {
            echo -e "${YELLOW}[WARN] Git 克隆失败，尝试下载 Release 归档包...${RESET}"
            curl -fsSL "$REPO_ARCHIVE" | tar -xz -C "$INSTALL_DIR" --strip-components=1 2>/dev/null || true
        }
    fi
else
    curl -fsSL "$REPO_ARCHIVE" 2>/dev/null | tar -xz -C "$INSTALL_DIR" --strip-components=1 2>/dev/null || true
fi

# 如果安装脚本在本地代码仓库中被直接调用执行，同步当前脚本与模版文件
CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ "$CURRENT_DIR" != "$INSTALL_DIR" ] && [ -f "$CURRENT_DIR/aiproxy.sh" ] && [ -d "$CURRENT_DIR/templates" ]; then
    echo -e "${CYAN}[INFO] 同步本地代码文件至 ${INSTALL_DIR}...${RESET}"
    for item in aiproxy.sh install.sh README.md templates LICENSE .gitignore; do
        [ -e "$CURRENT_DIR/$item" ] && cp -rf "$CURRENT_DIR/$item" "$INSTALL_DIR"/ 2>/dev/null || true
    done
fi

# 5. 配置快捷命令与初始化权限
echo -e "${CYAN}[4/5] 正在配置执行权限与全局软链接 /usr/local/bin/aiproxy ...${RESET}"
if [ ! -f "$INSTALL_DIR/aiproxy.sh" ]; then
    echo -e "${RED}[ERROR] 未能在 ${INSTALL_DIR} 找到 aiproxy.sh，下载或代码克隆失败，请检查网络连接或权限！${RESET}"
    exit 1
fi
chmod +x "$INSTALL_DIR/aiproxy.sh"
ln -sf "$INSTALL_DIR/aiproxy.sh" /usr/local/bin/aiproxy

# 执行一次初始化生成配置与 Compose 编排
cd "$INSTALL_DIR"
bash "$INSTALL_DIR/aiproxy.sh" init >/dev/null 2>&1 || true

echo -e "${CYAN}[5/5] 安装校验完成！${RESET}"
echo -e "${GREEN}======================================================================${RESET}"
echo -e "${BOLD}${GREEN}恭喜！aiproxy-box 已成功安装在您的系统中！${RESET}"
echo -e "全局快捷命令: ${BOLD}${YELLOW}aiproxy${RESET} (随时随地直接输入回车即可唤出菜单)"
echo -e "项目部署目录: ${BOLD}${WHITE}${INSTALL_DIR}${RESET}"
echo -e "${GREEN}======================================================================${RESET}"
echo ""
launch_now="n"
if [ -t 0 ]; then
    read -r -p "是否立即启动 aiproxy 交互控制台？(Y/n): " launch_now || launch_now="n"
elif [ -e /dev/tty ] && [ -r /dev/tty ]; then
    read -r -p "是否立即启动 aiproxy 交互控制台？(Y/n): " launch_now < /dev/tty 2>/dev/null || launch_now="n"
else
    echo -e "${YELLOW}[INFO] 检测到非交互式终端环境 (如管道或自动化脚本)，已跳过自动启动控制台。${RESET}"
    echo -e "您可以随时在终端运行 ${BOLD}${YELLOW}aiproxy${RESET} 开启控制台。"
    exit 0
fi

if [[ ! "$launch_now" =~ ^[Nn]$ ]]; then
    if [ -t 0 ]; then
        exec /usr/local/bin/aiproxy
    elif [ -e /dev/tty ] && [ -r /dev/tty ]; then
        exec /usr/local/bin/aiproxy < /dev/tty
    fi
fi

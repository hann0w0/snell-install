#!/usr/bin/env bash
#
# Snell Server 一键管理脚本
# 支持 V5 稳定版 / V6
# 支持 Debian/Ubuntu/CentOS/Fedora/Arch
#

set -uo pipefail

# ============================================================
# 版本与路径 (解耦多实例路径)
# ============================================================
V5_VERSION="v5.0.1"   # 默认兜底版本
V6_VERSION="v6.0.0b2"  # 默认兜底版本
INSTALL_DIR="/usr/local/bin"
CONFIG_DIR="/etc/snell"
DOWNLOAD_BASE="https://dl.nssurge.com/snell"

# 多实例共存的动态路径获取函数 (由全局变量 SUFFIX "v5" 或 "v6" 驱动)
SUFFIX="v5"
ARCH=""

# 初始化全局变量以防止 nounset 错误
CUR_LISTEN=""
CUR_PSK=""
CUR_IPV6=""
CUR_TFO=""
CUR_DNS=""
CUR_PORT=""
CUR_VER=""

get_bin_path() {
    echo "${INSTALL_DIR}/snell-server-${SUFFIX}"
}

get_config_file() {
    echo "${CONFIG_DIR}/snell-server-${SUFFIX}.conf"
}

get_version_file() {
    echo "${CONFIG_DIR}/.version-${SUFFIX}"
}

get_service_name() {
    echo "snell-${SUFFIX}"
}

get_service_file() {
    echo "/etc/systemd/system/$(get_service_name).service"
}

# 验证下载包在 Surge 服务器上是否存在 (通过 HEAD 快速检测)
check_url_exists() {
    local ver="$1"
    local test_url="${DOWNLOAD_BASE}/snell-server-${ver}-linux-amd64.zip"
    if command -v curl &>/dev/null; then
        local code
        code=$(curl -fsSL -o /dev/null -w "%{http_code}" --connect-timeout 2 "$test_url" 2>/dev/null || echo "404")
        [[ "$code" == "200" ]] && return 0 || return 1
    elif command -v wget &>/dev/null; then
        if wget -q --spider --timeout=2 "$test_url" &>/dev/null; then
            return 0
        else
            return 1
        fi
    fi
    return 1
}

# 动态获取并双重验证官网最新可下载版本
fetch_latest_versions() {
    # 确保有 curl/wget，检查网络
    if ! command -v curl &>/dev/null && ! command -v wget &>/dev/null; then
        return
    fi
    
    local html=""
    if command -v curl &>/dev/null; then
        html=$(curl -fsSL --connect-timeout 3 "https://kb.nssurge.com/surge-knowledge-base/release-notes/snell" 2>/dev/null || true)
    else
        html=$(wget -qO- --timeout=3 "https://kb.nssurge.com/surge-knowledge-base/release-notes/snell" 2>/dev/null || true)
    fi

    if [[ -n "$html" ]]; then
        # 1. 动态探测并校验 V6 可下载最新版 (测试前 5 个候选版本)
        local v6_candidates
        v6_candidates=$(echo "$html" | grep -oE 'v6\.[0-9]+\.[0-9]+(b[0-9]+)?' | sort -u -r | head -n 5 || true)
        for candidate in $v6_candidates; do
            if check_url_exists "$candidate"; then
                V6_VERSION="$candidate"
                break
            fi
        done

        # 2. 动态探测并校验 V5 可下载最新版 (测试前 5 个候选版本)
        local v5_candidates
        v5_candidates=$(echo "$html" | grep -oE 'v5\.[0-9]+\.[0-9]+' | sort -u -r | head -n 5 || true)
        for candidate in $v5_candidates; do
            if check_url_exists "$candidate"; then
                V5_VERSION="$candidate"
                break
            fi
        done
    fi
}


# ============================================================
# 颜色
# ============================================================
R='\033[0;31m'
G='\033[0;32m'
Y='\033[0;33m'
B='\033[0;34m'
P='\033[0;35m'
C='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

# ============================================================
# 输出工具
# ============================================================
info()    { echo -e "  ${B}▸${NC} $*"; }
ok()      { echo -e "  ${G}✔${NC} $*"; }
warn()    { echo -e "  ${Y}⚠${NC} $*"; }
err()     { echo -e "  ${R}✘${NC} $*"; }
die()     { err "$*"; exit 1; }

hr() { printf "  ${DIM}"; printf '%.s─' {1..48}; printf "${NC}\n"; }
dhr() { printf "  ${DIM}"; printf '%.s┈' {1..48}; printf "${NC}\n"; }

pause() {
    echo ""
    read -rsn1 -p "  按任意键返回主菜单..."
    echo ""
}

# ============================================================
# 自动持久化保存并安装快捷指令 'snell'
# ============================================================
install_shortcut() {
    local script_dest="/usr/local/bin/snell"
    local github_url="https://raw.githubusercontent.com/hann0w0/snell-install/main/snell.sh"
    
    # 清理旧版本遗留的缓存与软链接
    if [[ -L "$script_dest" ]]; then
        rm -f "$script_dest" 2>/dev/null || true
    fi
    if [[ -f "/root/snell.sh" ]]; then
        rm -f "/root/snell.sh" 2>/dev/null || true
    fi
    
    # 检查当前运行的脚本是否已经是目标路径。如果是，说明已经是本地安装的版本在运行，无需重复下载/拷贝
    local cur_real_path
    cur_real_path=$(readlink -f "$0" 2>/dev/null || echo "")
    if [[ "$cur_real_path" == "$script_dest" ]]; then
        return 0
    fi
    
    # 否则，我们需要将脚本部署到目标路径
    info "正在为您配置本地快捷调用指令 'snell'..."
    
    local success=false
    # 场景 1：如果是通过本地普通文件运行 (如 ./snell.sh)，且不是管道或系统 shell 二进制
    local base_name
    base_name=$(basename "$cur_real_path" 2>/dev/null || echo "")
    if [[ -f "$0" ]] && [[ "$base_name" != "bash" && "$base_name" != "sh" && "$base_name" != "zsh" && "$cur_real_path" != *"/dev/fd/"* ]]; then
        if cp -f "$0" "$script_dest" 2>/dev/null; then
            success=true
        fi
    fi
    
    # 场景 2：如果是通过网络管道一键运行 (如 curl | bash)，我们直接从 github 拉取最新版本并写入目标路径
    if [[ "$success" == "false" ]]; then
        if command -v curl &>/dev/null; then
            curl -fsSL --connect-timeout 5 "$github_url" > "$script_dest" 2>/dev/null && success=true
        elif command -v wget &>/dev/null; then
            wget -q --timeout=5 -O "$script_dest" "$github_url" 2>/dev/null && success=true
        fi
    fi
    
    if [[ "$success" == "true" ]]; then
        chmod +x "$script_dest" 2>/dev/null || true
        ok "快捷指令 'snell' 部署成功！以后在终端键入 'snell' 或 'sudo snell' 即可直接启动面板。"
    else
        warn "快捷指令 'snell' 部署失败，但不影响当前面板的使用。"
    fi
}

# ============================================================
# 智能版本选择辅助函数
# ============================================================
auto_select_or_ask_version() {
    local action="$1"
    local v5_exists=false
    local v6_exists=false
    [[ -f "${INSTALL_DIR}/snell-server-v5" ]] && v5_exists=true
    [[ -f "${INSTALL_DIR}/snell-server-v6" ]] && v6_exists=true
    
    if [[ "$v5_exists" == "true" && "$v6_exists" == "false" ]]; then
        SUFFIX="v5"
        return 0
    elif [[ "$v5_exists" == "false" && "$v6_exists" == "true" ]]; then
        SUFFIX="v6"
        return 0
    fi
    
    # 两个都存在，或者两个都不存在，让用户选择
    echo -e "  ${BOLD}请选择要${action}的 Snell 版本:${NC}"
    echo -e "  ${G}1${NC}. V5"
    echo -e "  ${G}2${NC}. V6"
    echo -e "  ${G}0${NC}. 返回主菜单"
    echo ""
    local choice
    read -rp "  请选择 [1/2/0, 默认 1]: " choice
    case "$choice" in
        2) SUFFIX="v6" ;;
        0) echo ""; return 1 ;;
        *) SUFFIX="v5" ;;
    esac
    ok "已选择: Snell ${SUFFIX}"
    echo ""
    return 0
}

# ============================================================
# 主菜单
# ============================================================
show_menu() {
    clear
    echo ""
    hr
    echo -e "  ${BOLD}${C} Snell Server 管理脚本${NC}"
    echo -e "  ${DIM} 支持 V5 / V6 同步共存${NC}"
    hr
    echo ""

    # 获取 V5 状态
    local st5 sc5 vt5 ae5
    local v5_bin="${INSTALL_DIR}/snell-server-v5"
    local v5_service="snell-v5"
    local v5_ver_file="${CONFIG_DIR}/.version-v5"
    if systemctl is-active --quiet "$v5_service" 2>/dev/null; then
        st5="● 运行中" sc5="${G}"
    elif [[ -f "$v5_bin" ]]; then
        st5="○ 已停止" sc5="${R}"
    else
        st5="○ 未安装" sc5="${DIM}"
    fi
    vt5="N/A"
    [[ -f "$v5_ver_file" ]] && vt5=$(cat "$v5_ver_file")
    if systemctl is-enabled --quiet "$v5_service" 2>/dev/null; then
        ae5="${G}是${NC}"
    else
        ae5="${DIM}否${NC}"
    fi

    # 获取 V6 状态
    local st6 sc6 vt6 ae6
    local v6_bin="${INSTALL_DIR}/snell-server-v6"
    local v6_service="snell-v6"
    local v6_ver_file="${CONFIG_DIR}/.version-v6"
    if systemctl is-active --quiet "$v6_service" 2>/dev/null; then
        st6="● 运行中" sc6="${G}"
    elif [[ -f "$v6_bin" ]]; then
        st6="○ 已停止" sc6="${R}"
    else
        st6="○ 未安装" sc6="${DIM}"
    fi
    vt6="N/A"
    [[ -f "$v6_ver_file" ]] && vt6=$(cat "$v6_ver_file")
    if systemctl is-enabled --quiet "$v6_service" 2>/dev/null; then
        ae6="${G}是${NC}"
    else
        ae6="${DIM}否${NC}"
    fi

    # 填充版本号以使后方的自启列完美对齐
    local vt5_padded vt6_padded
    vt5_padded=$(printf "%-10s" "$vt5")
    vt6_padded=$(printf "%-10s" "$vt6")

    echo -e "  ${BOLD}V5 状态${NC}: ${sc5}${BOLD}${st5}${NC}   版本: ${BOLD}${vt5_padded}${NC}   自启: ${ae5}"
    echo -e "  ${BOLD}V6 状态${NC}: ${sc6}${BOLD}${st6}${NC}   版本: ${BOLD}${vt6_padded}${NC}   自启: ${ae6}"
    echo ""
    echo -e "  ${DIM}▎安装管理${NC}"
    echo ""
    echo -e "  ${G}1${NC}.  安装 Snell"
    echo -e "  ${G}2${NC}.  更新 Snell"
    echo -e "  ${G}3${NC}.  卸载 Snell"
    echo ""
    echo -e "  ${DIM}▎配置与服务${NC}"
    echo ""
    echo -e "  ${G}4${NC}.  修改配置"
    echo -e "  ${G}5${NC}.  查看配置"
    echo -e "  ${G}6${NC}.  重启服务"
    echo -e "  ${G}7${NC}.  运行日志"
    echo ""
    echo -e "  ${DIM}▎系统优化${NC}"
    echo ""
    echo -e "  ${G}8${NC}.  BBR 优化"
    echo -e "  ${G}9${NC}.  时间同步"
    echo -e "  ${G}10${NC}. 定时更新"
    echo -e "  ${G}11${NC}. 更新脚本"
    echo ""
    echo -e "  ${DIM}0${NC}.  退出"
    echo ""
}

# ============================================================
# 工具函数
# ============================================================
check_root() {
    [[ $EUID -eq 0 ]] || die "请使用 root 用户运行此脚本"
}

get_public_ip4() {
    local ip=""
    if command -v curl &>/dev/null; then
        ip=$(curl -s4m 3 https://api.ipify.org || curl -s4m 3 https://ifconfig.me || curl -s4m 3 https://ip.sb || echo "")
    elif command -v wget &>/dev/null; then
        ip=$(wget -qT 3 -O- https://api.ipify.org || wget -qT 3 -O- https://ifconfig.me || wget -qT 3 -O- https://ip.sb || echo "")
    fi
    if [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo "$ip"
    else
        ip -4 addr show scope global 2>/dev/null | grep inet | grep -v '127.0.0.1' | awk '{print $2}' | cut -d/ -f1 | head -1 || echo ""
    fi
}

get_public_ip6() {
    local ip=""
    if command -v curl &>/dev/null; then
        ip=$(curl -s6m 3 https://api6.ipify.org || curl -s6m 3 https://ifconfig.co || curl -s6m 3 https://ip.sb || echo "")
    elif command -v wget &>/dev/null; then
        ip=$(wget -qT 3 -O- https://api6.ipify.org || wget -qT 3 -O- https://ifconfig.co || wget -qT 3 -O- https://ip.sb || echo "")
    fi
    if [[ "$ip" == *":"* ]]; then
        echo "$ip"
    else
        ip -6 addr show scope global 2>/dev/null | grep inet6 | grep -v '::1' | awk '{print $2}' | cut -d/ -f1 | head -1 || echo ""
    fi
}

port_in_use() {
    local port="$1"
    if command -v ss &>/dev/null; then
        ss -tln | grep -q ":${port}\b" && return 0
    elif command -v netstat &>/dev/null; then
        netstat -tln | grep -q ":${port}\b" && return 0
    elif command -v lsof &>/dev/null; then
        lsof -i :"$port" &>/dev/null && return 0
    fi
    return 1
}

detect_arch() {
    local arch
    arch=$(uname -m)
    case "$arch" in
        x86_64|amd64)   ARCH="amd64" ;;
        i386|i686)      ARCH="i386" ;;
        aarch64|arm64)  ARCH="aarch64" ;;
        armv7*)         ARCH="armv7l" ;;
        *)              die "不支持的架构: $arch" ;;
    esac
}

ensure_deps() {
    local missing=()
    for cmd in wget unzip; do
        command -v "$cmd" &>/dev/null || missing+=("$cmd")
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        info "安装依赖: ${missing[*]}"
        if command -v apt-get &>/dev/null; then
            apt-get update -qq && apt-get install -y -qq "${missing[@]}"
        elif command -v dnf &>/dev/null; then
            dnf install -y -q "${missing[@]}"
        elif command -v yum &>/dev/null; then
            yum install -y -q "${missing[@]}"
        elif command -v pacman &>/dev/null; then
            pacman -Sy --noconfirm "${missing[@]}"
        else
            die "无法安装 ${missing[*]}，请手动安装"
        fi
    fi
}

random_port() { shuf -i 10000-65535 -n 1; }

random_psk() {
    if command -v openssl &>/dev/null; then
        openssl rand -base64 32
    else
        head -c 32 /dev/urandom | base64
    fi
}

# 验证端口号是否在有效范围内
validate_port() {
    local port="$1"
    if [[ ! "$port" =~ ^[0-9]+$ ]] || [[ "$port" -lt 1 || "$port" -gt 65535 ]]; then
        err "无效端口号，请输入 1-65535 范围内的数字"
        return 1
    fi
    return 0
}

# 获取另一个版本实例的端口号（用于冲突检测）
get_other_port() {
    local other_suffix="v5"
    [[ "$SUFFIX" == "v5" ]] && other_suffix="v6"
    local other_cfg="${CONFIG_DIR}/snell-server-${other_suffix}.conf"
    if [[ -f "$other_cfg" ]]; then
        grep -E "^listen\s*=" "$other_cfg" 2>/dev/null | head -1 | sed 's/^[^=]*=[[:space:]]*//' | grep -oE '[0-9]+$'
    fi
}

get_download_url() {
    local ver="$1"
    if [[ "$ARCH" == "armv7l" && "$ver" == "$V6_VERSION" ]]; then
        die "Snell V6 不支持 armv7l 架构，请选择 V5"
    fi
    echo "${DOWNLOAD_BASE}/snell-server-${ver}-linux-${ARCH}.zip"
}

download_and_install() {
    local ver="$1"
    local url
    url=$(get_download_url "$ver")
    local tmp
    tmp=$(mktemp -d)

    info "下载 Snell Server ${ver} (${ARCH})"
    echo -e "  ${DIM}${url}${NC}"

    if ! wget -q --show-progress -O "${tmp}/snell.zip" "$url"; then
        rm -rf "$tmp"; die "下载失败"
    fi

    # 校验下载文件大小，防止不完整的下载
    local zip_size
    zip_size=$(wc -c < "${tmp}/snell.zip" 2>/dev/null || echo "0")
    if [[ "$zip_size" -lt 1000 ]]; then
        rm -rf "$tmp"; die "下载的文件异常过小 (${zip_size} bytes)，可能不完整"
    fi

    unzip -o -q "${tmp}/snell.zip" -d "$tmp"
    local bin
    bin=$(find "$tmp" -name "snell-server" -type f | head -1)
    [[ -n "$bin" ]] || { rm -rf "$tmp"; die "解压后未找到二进制文件"; }

    local service_name
    service_name=$(get_service_name)
    systemctl stop "$service_name" 2>/dev/null || true
    
    local bin_path
    bin_path=$(get_bin_path)
    install -m 755 "$bin" "$bin_path"
    rm -rf "$tmp"
    mkdir -p "$CONFIG_DIR"
    
    local version_file
    version_file=$(get_version_file)
    echo "$ver" > "$version_file"
    ok "已安装 $bin_path"
}

write_config() {
    local port="$1" psk="$2" ipv6="$3" tfo="$4" dns="$5"
    mkdir -p "$CONFIG_DIR"

    local addr
    [[ "$ipv6" == "true" ]] && addr="[::]:${port}" || addr="0.0.0.0:${port}"

    local config_file
    config_file=$(get_config_file)
    cat > "$config_file" << EOF
[snell-server]
listen = ${addr}
psk = ${psk}
ipv6 = ${ipv6}
tfo = ${tfo}
dns = ${dns}
EOF

    chmod 600 "$config_file"
    ok "配置已写入 ${config_file}"
}

write_service() {
    local service_file service_name bin_path config_file
    service_file=$(get_service_file)
    service_name=$(get_service_name)
    bin_path=$(get_bin_path)
    config_file=$(get_config_file)

    cat > "$service_file" << EOF
[Unit]
Description=Snell Proxy Server (${service_name})
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
LimitNOFILE=65535
ExecStart=${bin_path} -c ${config_file}
Restart=on-failure
RestartSec=3s
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
ReadOnlyPaths=${CONFIG_DIR}

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
}

apply_ecn() {
    local v="$1"
    if [[ "$v" == "true" ]]; then
        sysctl -w net.ipv4.tcp_ecn=1 &>/dev/null || true
        if grep -q "net.ipv4.tcp_ecn" /etc/sysctl.conf 2>/dev/null; then
            sed -i 's/net.ipv4.tcp_ecn=.*/net.ipv4.tcp_ecn=1/' /etc/sysctl.conf
        else
            echo "net.ipv4.tcp_ecn=1" >> /etc/sysctl.conf
        fi
        ok "ECN 已启用"
    else
        sysctl -w net.ipv4.tcp_ecn=0 &>/dev/null || true
        if grep -q "net.ipv4.tcp_ecn" /etc/sysctl.conf 2>/dev/null; then
            sed -i 's/net.ipv4.tcp_ecn=.*/net.ipv4.tcp_ecn=0/' /etc/sysctl.conf
        fi
    fi
}

apply_tfo() {
    if [[ "$1" == "true" ]]; then
        sysctl -w net.ipv4.tcp_fastopen=3 &>/dev/null || true
        if grep -q "net.ipv4.tcp_fastopen" /etc/sysctl.conf 2>/dev/null; then
            sed -i 's/net.ipv4.tcp_fastopen=.*/net.ipv4.tcp_fastopen=3/' /etc/sysctl.conf
        else
            echo "net.ipv4.tcp_fastopen=3" >> /etc/sysctl.conf
        fi
        ok "TFO 已启用"
    fi
}

open_firewall() {
    local p="$1"
    info "配置防火墙 (${p})"
    if command -v ip6tables &>/dev/null; then
        ip6tables -C INPUT -p tcp --dport "$p" -j ACCEPT 2>/dev/null || ip6tables -A INPUT -p tcp --dport "$p" -j ACCEPT
        ip6tables -C INPUT -p udp --dport "$p" -j ACCEPT 2>/dev/null || ip6tables -A INPUT -p udp --dport "$p" -j ACCEPT
    fi
    if command -v iptables &>/dev/null; then
        iptables -C INPUT -p tcp --dport "$p" -j ACCEPT 2>/dev/null || iptables -A INPUT -p tcp --dport "$p" -j ACCEPT
        iptables -C INPUT -p udp --dport "$p" -j ACCEPT 2>/dev/null || iptables -A INPUT -p udp --dport "$p" -j ACCEPT
    fi
    if command -v firewall-cmd &>/dev/null && systemctl is-active --quiet firewalld 2>/dev/null; then
        firewall-cmd --permanent --add-port="${p}/tcp" &>/dev/null || true
        firewall-cmd --permanent --add-port="${p}/udp" &>/dev/null || true
        firewall-cmd --reload &>/dev/null || true
    fi
    if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "active"; then
        ufw allow "$p" &>/dev/null || true
    fi
    ok "防火墙已放行"
}

close_firewall() {
    local p="$1"
    [[ -n "$p" ]] || return
    info "清理防火墙规则 (${p})"
    if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "active"; then
        ufw delete allow "$p" &>/dev/null || true
    fi
    if command -v firewall-cmd &>/dev/null && systemctl is-active --quiet firewalld 2>/dev/null; then
        firewall-cmd --permanent --remove-port="${p}/tcp" &>/dev/null || true
        firewall-cmd --permanent --remove-port="${p}/udp" &>/dev/null || true
        firewall-cmd --reload &>/dev/null || true
    fi
    if command -v iptables &>/dev/null; then
        iptables -D INPUT -p tcp --dport "$p" -j ACCEPT 2>/dev/null || true
        iptables -D INPUT -p udp --dport "$p" -j ACCEPT 2>/dev/null || true
    fi
    if command -v ip6tables &>/dev/null; then
        ip6tables -D INPUT -p tcp --dport "$p" -j ACCEPT 2>/dev/null || true
        ip6tables -D INPUT -p udp --dport "$p" -j ACCEPT 2>/dev/null || true
    fi
    ok "防火墙规则已清理"
}

# 从配置文件读取值，只匹配第一个 = 号，避免 base64 尾部 = 被吞
cfg_val() {
    local cfg
    cfg=$(get_config_file)
    grep -E "^$1\s*=" "$cfg" 2>/dev/null | head -1 | sed 's/^[^=]*=[[:space:]]*//' 
}

parse_config() {
    local cfg vf
    cfg=$(get_config_file)
    vf=$(get_version_file)
    [[ -f "$cfg" ]] || return 1
    CUR_LISTEN=$(cfg_val listen)
    CUR_PSK=$(cfg_val psk)
    CUR_IPV6=$(cfg_val ipv6)
    CUR_TFO=$(cfg_val tfo)
    CUR_DNS=$(cfg_val dns)
    CUR_PORT=$(echo "$CUR_LISTEN" | grep -oE '[0-9]+$')
    CUR_VER="N/A"
    [[ -f "$vf" ]] && CUR_VER=$(cat "$vf")
}

# ============================================================
# 1. 安装
# ============================================================
do_install() {
    clear
    echo ""
    hr
    echo -e "  ${BOLD}${C} 安装 Snell Server${NC}"
    hr
    echo ""

    detect_arch
    ensure_deps
    
    info "正在实时同步 Surge 官网最新版本..."
    fetch_latest_versions
    echo ""

    # 版本
    echo -e "  ${BOLD}选择版本${NC}"
    echo -e "  ${G}1${NC}. V5  (${V5_VERSION})"
    echo -e "  ${G}2${NC}. V6  (${V6_VERSION})"
    echo ""
    read -rp "  选择 [1/2, 默认 1]: " vc
    local sv
    case "$vc" in
        2) SUFFIX="v6"; sv="$V6_VERSION" ;;
        *) SUFFIX="v5"; sv="$V5_VERSION" ;;
    esac
    
    local bin_path
    bin_path=$(get_bin_path)
    if [[ -f "$bin_path" ]]; then
        warn "已检测到已安装的 Snell Server ${SUFFIX}"
        read -rp "  覆盖安装？(y/N) " ow
        [[ "$ow" == "y" || "$ow" == "Y" ]] || { info "已取消"; pause; return; }
        echo ""
    fi

    ok "版本: Snell ${SUFFIX} (${sv})"
    echo ""
    hr
    echo ""

    # 端口检测，防实例间碰撞
    local other_port=""
    other_port=$(get_other_port)

    local rp
    rp=$(random_port)
    while [[ -n "$other_port" && "$rp" == "$other_port" ]] || port_in_use "$rp"; do
        rp=$(random_port)
    done

    if [[ -n "$other_port" ]]; then
        info "提示: 另一个版本 Snell ${other_suffix} 已安装，其占用端口为: ${other_port}，请不要使用冲突的端口。"
    fi

    read -rp "  端口 [回车随机 ${rp}]: " ip
    local port="${ip:-$rp}"
    if ! validate_port "$port"; then
        pause
        return
    fi
    if [[ -n "$other_port" && "$port" == "$other_port" ]]; then
        local other_suffix="v5"
        [[ "$SUFFIX" == "v5" ]] && other_suffix="v6"
        err "错误: 端口与已安装的 Snell ${other_suffix} 端口 (${other_port}) 冲突！"
        pause
        return
    fi
    if port_in_use "$port"; then
        err "错误: 端口 ${port} 已被系统其他服务占用，请更换端口！"
        pause
        return
    fi
    ok "端口: ${port}"
    echo ""

    # PSK
    local rpsk
    rpsk=$(random_psk)
    read -rp "  PSK [回车随机生成]: " ik
    local psk="${ik:-$rpsk}"
    ok "PSK: ${psk}"
    echo ""

    # IPv6
    read -rp "  监听 IPv6? (Y/n) [默认 Y]: " i6
    local ipv6="true"
    [[ "$i6" == "n" || "$i6" == "N" ]] && ipv6="false"
    ok "IPv6: ${ipv6}"
    echo ""

    # TFO
    read -rp "  TCP Fast Open? (y/N) [默认 N]: " it
    local tfo="false"
    [[ "$it" == "y" || "$it" == "Y" ]] && tfo="true"
    ok "TFO: ${tfo}"
    echo ""

    # ECN
    read -rp "  ECN? (y/N) [默认 N]: " ie
    local ecn="false"
    [[ "$ie" == "y" || "$ie" == "Y" ]] && ecn="true"
    ok "ECN: ${ecn}"
    echo ""

    # DNS
    local ddns="1.1.1.1,8.8.8.8,2606:4700:4700::1111,2001:4860:4860::8888"
    echo -e "  ${DIM}默认: ${ddns}${NC}"
    read -rp "  DNS [回车默认]: " id
    local dns="${id:-$ddns}"
    ok "DNS: ${dns}"

    echo ""
    hr
    echo ""
    echo -e "  ${BOLD}确认配置${NC}"
    echo ""
    echo -e "  对象 ......  ${BOLD}Snell ${SUFFIX}${NC}"
    echo -e "  版本 ......  ${BOLD}${sv}${NC}"
    echo -e "  端口 ......  ${BOLD}${port}${NC}"
    echo -e "  PSK  ......  ${BOLD}${psk}${NC}"
    echo -e "  IPv6 ......  ${BOLD}${ipv6}${NC}"
    echo -e "  TFO  ......  ${BOLD}${tfo}${NC}"
    echo -e "  ECN  ......  ${BOLD}${ecn}${NC}"
    echo -e "  DNS  ......  ${BOLD}${dns}${NC}"
    echo -e "  UDP  ......  ${BOLD}启用${NC}"
    echo ""
    read -rp "  确认安装? (Y/n) " cf
    [[ "$cf" == "n" || "$cf" == "N" ]] && { info "已取消"; pause; return; }

    echo ""
    hr
    echo ""

    download_and_install "$sv"
    write_config "$port" "$psk" "$ipv6" "$tfo" "$dns"
    write_service
    open_firewall "$port"
    apply_tfo "$tfo"
    apply_ecn "$ecn"

    local service_name
    service_name=$(get_service_name)
    systemctl enable "$service_name" &>/dev/null
    systemctl start "$service_name"

    echo ""
    hr
    echo -e "  ${G}${BOLD} 安装完成，服务已启动${NC}"
    hr
    echo ""

    show_client_config "$port" "$psk" "$sv"
    pause
}

# ============================================================
# 2. 更新
# ============================================================
do_update() {
    clear
    echo ""
    hr
    echo -e "  ${BOLD}${C} 更新 Snell Server${NC}"
    hr
    echo ""

    auto_select_or_ask_version "更新" || return

    local bin_path version_file service_name
    bin_path=$(get_bin_path)
    version_file=$(get_version_file)
    service_name=$(get_service_name)

    [[ -f "$bin_path" ]] || { err "Snell ${SUFFIX} 尚未安装"; pause; return; }

    detect_arch
    ensure_deps

    info "正在实时同步 Surge 官网最新版本..."
    fetch_latest_versions
    echo ""

    local cv="N/A"
    [[ -f "$version_file" ]] && cv=$(cat "$version_file")
    info "当前 Snell ${SUFFIX} 版本: ${cv}"
    echo ""

    local target_ver=""
    if [[ "$SUFFIX" == "v6" ]]; then
        target_ver="$V6_VERSION"
    else
        target_ver="$V5_VERSION"
    fi

    # 检查当前已安装的版本
    if [[ "$cv" == "$target_ver" ]]; then
        echo ""
        warn "当前系统已安装 Snell ${SUFFIX} 版本为 ${cv}，目标更新版本也是 ${target_ver}，无需更新！"
        pause
        return
    fi

    echo -e "  准备将 Snell ${SUFFIX} 更新至目标版本: ${target_ver}"
    read -rp "  是否继续？(Y/n) " yn
    [[ "$yn" == "n" || "$yn" == "N" ]] && { info "已取消"; pause; return; }

    echo ""
    # 1. 升级前先备份当前二进制
    local backup_bin="${bin_path}.bak"
    cp -f "$bin_path" "$backup_bin" 2>/dev/null || true

    # 2. 执行安装新版
    download_and_install "$target_ver"

    # 3. 重启并验证
    info "正在启动新版本服务并验证其稳定性..."
    systemctl restart "$service_name" &>/dev/null || true
    sleep 3

    if systemctl is-active --quiet "$service_name" 2>/dev/null; then
        ok "服务重启成功，新版本验证通过！"
        rm -f "$backup_bin" 2>/dev/null || true
    else
        err "新版本服务启动失败！正在执行安全回滚..."
        # 回滚二进制与版本号记录
        mv -f "$backup_bin" "$bin_path" 2>/dev/null || true
        echo "$cv" > "$version_file"
        systemctl restart "$service_name" &>/dev/null || true
        err "已成功回滚至原版本: ${cv}"
    fi
    pause
}

# ============================================================
# 3. 卸载
# ============================================================
do_uninstall() {
    clear
    echo ""
    hr
    echo -e "  ${BOLD}${R} 卸载 Snell Server${NC}"
    hr
    echo ""

    local v5_exists=false
    local v6_exists=false
    [[ -f "${INSTALL_DIR}/snell-server-v5" ]] && v5_exists=true
    [[ -f "${INSTALL_DIR}/snell-server-v6" ]] && v6_exists=true

    if [[ "$v5_exists" == "false" && "$v6_exists" == "false" ]]; then
        err "未检测到已安装的 Snell"
        pause
        return
    fi

    local mode=""
    if [[ "$v5_exists" == "true" && "$v6_exists" == "false" ]]; then
        mode="v5"
    elif [[ "$v5_exists" == "false" && "$v6_exists" == "true" ]]; then
        mode="v6"
    else
        # 两个都存在，让用户选择
        echo -e "  ${BOLD}请选择要卸载的 Snell 版本:${NC}"
        echo -e "  ${G}1${NC}. 卸载 V5"
        echo -e "  ${G}2${NC}. 卸载 V6"
        echo -e "  ${G}3${NC}. 同时卸载 V5 和 V6"
        echo -e "  ${G}0${NC}. 返回主菜单"
        echo ""
        local choice
        read -rp "  请选择 [1-3/0, 默认 1]: " choice
        case "$choice" in
            2) mode="v6" ;;
            3) mode="all" ;;
            0) return ;;
            *) mode="v5" ;;
        esac
        echo ""
    fi

    local cf
    if [[ "$mode" == "all" ]]; then
        warn "将停止并删除所有的 Snell 服务"
        read -rp "  确认同时卸载 V5 和 V6？(Y/n) " cf
    else
        warn "将停止并删除 Snell ${mode} 服务"
        read -rp "  确认卸载 Snell ${mode}？(Y/n) " cf
    fi
    cf="${cf:-Y}"
    [[ "$cf" == "y" || "$cf" == "Y" ]] || { info "已取消"; pause; return; }

    # 卸载前获取端口号以便后续清理防火墙规则
    local v5_port=""
    local v6_port=""
    local v5_cfg="${CONFIG_DIR}/snell-server-v5.conf"
    local v6_cfg="${CONFIG_DIR}/snell-server-v6.conf"
    if [[ -f "$v5_cfg" ]]; then
        v5_port=$(grep -E "^listen\s*=" "$v5_cfg" 2>/dev/null | head -1 | sed 's/^[^=]*=[[:space:]]*//' | grep -oE '[0-9]+$')
    fi
    if [[ -f "$v6_cfg" ]]; then
        v6_port=$(grep -E "^listen\s*=" "$v6_cfg" 2>/dev/null | head -1 | sed 's/^[^=]*=[[:space:]]*//' | grep -oE '[0-9]+$')
    fi

    # 执行服务停止与文件删除
    if [[ "$mode" == "v5" || "$mode" == "all" ]]; then
        info "正在卸载 Snell V5..."
        [[ -n "$v5_port" ]] && close_firewall "$v5_port"
        systemctl stop snell-v5 2>/dev/null || true
        systemctl disable snell-v5 2>/dev/null || true
        rm -f "${INSTALL_DIR}/snell-server-v5" "/etc/systemd/system/snell-v5.service" "${CONFIG_DIR}/.version-v5"
        if [[ "$mode" == "v5" ]]; then
            rm -f "$v5_cfg"
            # 检查如果此时 V6 也不存在了，则清理整个配置目录
            if [[ ! -f "${INSTALL_DIR}/snell-server-v6" ]]; then
                rm -rf "$CONFIG_DIR" 2>/dev/null || true
            fi
        fi
        ok "Snell V5 已卸载并清除配置、自启与防火墙端口"
    fi

    if [[ "$mode" == "v6" || "$mode" == "all" ]]; then
        info "正在卸载 Snell V6..."
        [[ -n "$v6_port" ]] && close_firewall "$v6_port"
        systemctl stop snell-v6 2>/dev/null || true
        systemctl disable snell-v6 2>/dev/null || true
        rm -f "${INSTALL_DIR}/snell-server-v6" "/etc/systemd/system/snell-v6.service" "${CONFIG_DIR}/.version-v6"
        if [[ "$mode" == "v6" ]]; then
            rm -f "$v6_cfg"
            # 检查如果此时 V5 也不存在了，则清理整个配置目录
            if [[ ! -f "${INSTALL_DIR}/snell-server-v5" ]]; then
                rm -rf "$CONFIG_DIR" 2>/dev/null || true
            fi
        fi
        ok "Snell V6 已卸载并清除配置、自启与防火墙端口"
    fi

    systemctl daemon-reload

    # 如果是全部卸载，清理定时任务、快捷方式和整个配置目录并直接退出
    if [[ "$mode" == "all" ]]; then
        info "正在清理定时更新任务..."
        if [[ -f /etc/crontab ]]; then
            sed -i '/--cron-check/d' /etc/crontab
            systemctl restart cron &>/dev/null || systemctl restart crond &>/dev/null || true
        fi
        
        info "正在清除所有配置文件..."
        rm -rf "$CONFIG_DIR"
        
        info "正在清除快捷调用指令 'snell'..."
        rm -f "/usr/local/bin/snell"
        
        ok "所有 Snell 服务、配置文件、定时更新及快捷方式已彻底清除！"
        echo ""
        ok "卸载流程已全部完成，面板将自动退出。"
        exit 0
    fi

    echo ""
    ok "卸载流程执行完毕"
    pause
}

# ============================================================
# 4. 修改配置
# ============================================================
do_modify() {
    clear
    echo ""
    hr
    echo -e "  ${BOLD}${C} 修改配置${NC}"
    hr
    echo ""

    auto_select_or_ask_version "修改配置" || return

    if ! parse_config; then
        err "配置文件不存在"
        pause
        return
    fi

    if [[ -z "$CUR_PORT" || ! "$CUR_PORT" =~ ^[0-9]+$ ]]; then
        err "错误: 无法解析当前端口号，配置文件可能损坏！"
        pause
        return
    fi

    local config_file
    config_file=$(get_config_file)

    echo -e "  ${G}1${NC}. 端口    ${DIM}当前: ${CUR_PORT}${NC}"
    echo -e "  ${G}2${NC}. PSK     ${DIM}当前: ${CUR_PSK}${NC}"
    echo -e "  ${G}3${NC}. IPv6    ${DIM}当前: ${CUR_IPV6:-true}${NC}"
    echo -e "  ${G}4${NC}. TFO     ${DIM}当前: ${CUR_TFO:-false}${NC}"
    echo -e "  ${G}5${NC}. DNS     ${DIM}当前: ${CUR_DNS:-未设置}${NC}"
    echo -e "  ${G}6${NC}. 重新生成随机 PSK"
    echo ""
    echo -e "  ${DIM}0. 返回${NC}"
    echo ""
    read -rp "  选择 [0-6]: " mc

    # 输入非数字或者越界保护
    if [[ ! "$mc" =~ ^[0-9]+$ ]] || [[ "$mc" -lt 1 || "$mc" -gt 6 ]]; then
        return
    fi

    local other_port=""
    other_port=$(get_other_port)

    case "$mc" in
        1)
            read -rp "  新端口: " np
            [[ -n "$np" ]] || { warn "未输入"; pause; return; }
            if ! validate_port "$np"; then
                pause
                return
            fi
            if [[ -n "$other_port" && "$np" == "$other_port" ]]; then
                local other_suffix="v5"
                [[ "$SUFFIX" == "v5" ]] && other_suffix="v6"
                err "错误: 新端口与已安装的 Snell ${other_suffix} 端口 (${other_port}) 冲突！"
                pause
                return
            fi
            if port_in_use "$np"; then
                err "错误: 端口 ${np} 已被系统其他服务占用，请更换端口！"
                pause
                return
            fi
            close_firewall "$CUR_PORT"
            if [[ "${CUR_IPV6}" == "true" ]]; then
                sed -i "s|^listen\s*=.*|listen = [::]:${np}|" "$config_file"
            else
                sed -i "s|^listen\s*=.*|listen = 0.0.0.0:${np}|" "$config_file"
            fi
            open_firewall "$np"
            ok "端口 -> ${np}"
            ;;
        2)
            read -rp "  新 PSK: " nk
            [[ -n "$nk" ]] || { warn "未输入"; pause; return; }
            sed -i "s|^psk\s*=.*|psk = ${nk}|" "$config_file"
            ok "PSK 已修改"
            ;;
        3)
            local nv
            if [[ "${CUR_IPV6}" == "true" ]]; then
                nv="false"
                sed -i "s|^listen\s*=.*|listen = 0.0.0.0:${CUR_PORT}|" "$config_file"
            else
                nv="true"
                sed -i "s|^listen\s*=.*|listen = [::]:${CUR_PORT}|" "$config_file"
            fi
            if grep -q "^ipv6\s*=" "$config_file"; then
                sed -i "s|^ipv6\s*=.*|ipv6 = ${nv}|" "$config_file"
            else
                echo "ipv6 = ${nv}" >> "$config_file"
            fi
            ok "IPv6 -> ${nv}"
            ;;
        4)
            local nt
            [[ "${CUR_TFO}" == "true" ]] && nt="false" || nt="true"
            if grep -q "^tfo" "$config_file"; then
                sed -i "s|^tfo\s*=.*|tfo = ${nt}|" "$config_file"
            else
                echo "tfo = ${nt}" >> "$config_file"
            fi
            apply_tfo "$nt"
            ok "TFO -> ${nt}"
            ;;
        5)
            read -rp "  新 DNS (逗号分隔): " nd
            [[ -n "$nd" ]] || { warn "未输入"; pause; return; }
            if grep -q "^dns" "$config_file"; then
                sed -i "s|^dns\s*=.*|dns = ${nd}|" "$config_file"
            else
                echo "dns = ${nd}" >> "$config_file"
            fi
            ok "DNS 已修改"
            ;;
        6)
            local nk
            nk=$(random_psk)
            sed -i "s|^psk\s*=.*|psk = ${nk}|" "$config_file"
            ok "新 PSK: ${nk}"
            ;;
        *)
            return
            ;;
    esac

    echo ""
    read -rp "  立即重启 Snell ${SUFFIX} 使配置生效? (Y/n) " rr
    if [[ "$rr" != "n" && "$rr" != "N" ]]; then
        local service_name
        service_name=$(get_service_name)
        systemctl restart "$service_name" && ok "已重启" || err "重启失败"
    fi
    pause
}

# ============================================================
# 5. 查看配置
# ============================================================
do_show() {
    clear
    echo ""
    hr
    echo -e "  ${BOLD}${C} 配置信息${NC}"
    hr
    echo ""

    local ip4 ip6
    ip4=$(get_public_ip4)
    ip6=$(get_public_ip6)
    [[ -z "$ip4" ]] && ip4="N/A"
    [[ -z "$ip6" ]] && ip6="N/A"

    local addr="${ip4}"
    [[ "$addr" == "N/A" || "$addr" == "YOUR_IP" ]] && addr="${ip6}"

    local v5_cfg_exists=false
    local v6_cfg_exists=false
    
    # 局部载入变量防止 nounset 错误
    local CUR_LISTEN CUR_PSK CUR_IPV6 CUR_TFO CUR_DNS CUR_PORT CUR_VER SUFFIX

    # 1. 基础服务状态信息展示
    for sfx in "v5" "v6"; do
        SUFFIX="$sfx"
        local cfg
        cfg=$(get_config_file)
        if [[ -f "$cfg" ]]; then
            [[ "$sfx" == "v5" ]] && v5_cfg_exists=true
            [[ "$sfx" == "v6" ]] && v6_cfg_exists=true
            
            parse_config
            local st service_name
            service_name=$(get_service_name)
            if systemctl is-active --quiet "$service_name" 2>/dev/null; then
                st="${G}运行中${NC}"
            else
                st="${R}已停止${NC}"
            fi

            echo -e "  ${BOLD}Snell ${sfx^^}${NC} ...... 状态: [${st}]  端口: [${CUR_PORT}]  PSK: [${CUR_PSK}]"
        fi
    done

    if [[ "$v5_cfg_exists" == "false" && "$v6_cfg_exists" == "false" ]]; then
        err "未检测到任何已配置的 Snell 服务"
        echo ""
        pause
        return
    fi

    echo ""
    hr

    # 2. Surge 客户端输出
    echo ""
    echo -e "  ${BOLD}${Y} Surge 客户端${NC}"
    echo ""
    echo -e "  ${G}[Proxy]${NC}"
    
    if [[ "$v5_cfg_exists" == "true" ]]; then
        SUFFIX="v5"
        parse_config
        echo -e "  ${G}Snell-V5 = snell, ${addr}, ${CUR_PORT}, psk=${CUR_PSK}, version=5, udp-relay=true${NC}"
    fi
    if [[ "$v6_cfg_exists" == "true" ]]; then
        SUFFIX="v6"
        parse_config
        echo -e "  ${G}Snell-V6 = snell, ${addr}, ${CUR_PORT}, psk=${CUR_PSK}, version=6, udp-relay=true${NC}"
    fi

    # 3. Clash 客户端输出
    echo ""
    echo -e "  ${BOLD}${Y} Clash 客户端${NC}"
    echo ""
    echo -e "  ${G}proxies:${NC}"

    if [[ "$v5_cfg_exists" == "true" ]]; then
        SUFFIX="v5"
        parse_config
        echo -e "  ${G}  - name: Snell V5${NC}"
        echo -e "  ${G}    type: snell${NC}"
        echo -e "  ${G}    server: ${addr}${NC}"
        echo -e "  ${G}    port: ${CUR_PORT}${NC}"
        echo -e "  ${G}    psk: ${CUR_PSK}${NC}"
        echo -e "  ${G}    version: 5${NC}"
        echo -e "  ${G}    udp: true${NC}"
    fi
    if [[ "$v5_cfg_exists" == "true" && "$v6_cfg_exists" == "true" ]]; then
        echo ""
    fi
    if [[ "$v6_cfg_exists" == "true" ]]; then
        SUFFIX="v6"
        parse_config
        echo -e "  ${G}  - name: Snell V6${NC}"
        echo -e "  ${G}    type: snell${NC}"
        echo -e "  ${G}    server: ${addr}${NC}"
        echo -e "  ${G}    port: ${CUR_PORT}${NC}"
        echo -e "  ${G}    psk: ${CUR_PSK}${NC}"
        echo -e "  ${G}    version: 5${NC}"
        echo -e "  ${G}    udp: true${NC}"
        echo ""
        echo -e "  ${DIM}* 提示：Clash 暂未支持 V6 的原生协议，V6 实例将在 Clash 中自动降级为 V5 协议运行${NC}"
    fi

    echo ""
    pause
}

show_client_config() {
    local port="$1" psk="$2" ver="$3"
    local ip4="${4:-}" ip6="${5:-}"

    if [[ -z "$ip4" ]]; then
        ip4=$(get_public_ip4)
        [[ -z "$ip4" ]] && ip4="YOUR_IP"
    fi
    if [[ -z "$ip6" ]]; then
        ip6=$(get_public_ip6)
        [[ -z "$ip6" ]] && ip6="YOUR_IPv6"
    fi

    local sv="4"
    [[ "$ver" == *"v5"* ]] && sv="5"
    [[ "$ver" == *"v6"* ]] && sv="6"

    # 选择展示的地址：优先 IPv4
    local addr="${ip4}"
    [[ "$addr" == "N/A" || "$addr" == "YOUR_IP" ]] && addr="${ip6}"

    echo ""
    echo -e "  ${BOLD}${Y} Surge 客户端${NC}"
    echo ""
    echo -e "  ${G}[Proxy]${NC}"
    echo -e "  ${G}Snell = snell, ${addr}, ${port}, psk=${psk}, version=${sv}, udp-relay=true${NC}"
    # 如果同时有 IPv4 和 IPv6，提示备用地址
    if [[ "$ip4" != "N/A" && "$ip4" != "YOUR_IP" && "$ip6" != "N/A" && "$ip6" != "YOUR_IPv6" ]]; then
        echo ""
        echo -e "  ${DIM}# IPv6 备用:${NC}"
        echo -e "  ${DIM}# Snell-v6 = snell, ${ip6}, ${port}, psk=${psk}, version=${sv}, udp-relay=true${NC}"
    fi

    echo ""
    echo -e "  ${BOLD}${Y} Clash 客户端${NC}"
    echo ""
    echo -e "  ${G}proxies:${NC}"
    echo -e "  ${G}  - name: Snell${NC}"
    echo -e "  ${G}    type: snell${NC}"
    echo -e "  ${G}    server: ${addr}${NC}"
    echo -e "  ${G}    port: ${port}${NC}"
    echo -e "  ${G}    psk: ${psk}${NC}"
    
    if [[ "$sv" == "6" ]]; then
        echo -e "  ${G}    version: 5${NC}"
        echo -e "  ${G}    udp: true${NC}"
        echo ""
        echo -e "  ${DIM}* 提示：Clash 暂未支持 V6${NC}"
    else
        echo -e "  ${G}    version: ${sv}${NC}"
        echo -e "  ${G}    udp: true${NC}"
        echo ""
    fi
}

# ============================================================
# 6. 重启服务
# ============================================================
do_restart() {
    clear
    echo ""
    hr
    echo -e "  ${BOLD}${C} 重启服务${NC}"
    hr
    echo ""

    auto_select_or_ask_version "重启服务" || return

    local service_name
    service_name=$(get_service_name)

    if ! systemctl is-enabled --quiet "$service_name" 2>/dev/null; then
        err "服务 ${service_name} 未注册"
        pause
        return
    fi

    systemctl restart "$service_name"
    sleep 1

    if systemctl is-active --quiet "$service_name"; then
        ok "已重启"
        echo ""
        systemctl status "$service_name" --no-pager -l 2>/dev/null | head -12
    else
        err "启动失败"
        echo ""
        journalctl -u "$service_name" --no-pager -n 15
    fi
    pause
}

# ============================================================
# 7. 运行日志
# ============================================================
do_logs() {
    clear
    echo ""
    hr
    echo -e "  ${BOLD}${C} 运行日志${NC}  ${DIM}按 Ctrl+C 退出日志并返回菜单${NC}"
    hr
    echo ""

    auto_select_or_ask_version "查看日志" || return

    local service_name
    service_name=$(get_service_name)

    # 首先展示系统服务状态
    if systemctl is-enabled --quiet "$service_name" 2>/dev/null; then
        echo -e "  ${BOLD}● 系统服务状态 (${service_name}):${NC}"
        systemctl status "$service_name" --no-pager -l 2>/dev/null || true
        echo ""
        hr
        echo ""
    else
        warn "服务 ${service_name} 未注册，无法展示状态"
    fi

    echo -e "  ${BOLD}● 实时运行日志 (${service_name}):${NC}"
    # 捕获 SIGINT 信号，防止 Ctrl+C 退出整个脚本
    trap '' INT
    journalctl -u "$service_name" --no-pager -f -n 30 2>/dev/null || true
    trap - INT
    echo ""
    pause
}

# ============================================================
# 8. BBR 优化
# ============================================================
do_bbr() {
    clear
    echo ""
    hr
    echo -e "  ${BOLD}${C} BBR 与网络深度调优${NC}"
    hr
    echo ""

    info "正在清理系统中已存在的旧 BBR 与 TCP 优化参数..."
    if [[ -f /etc/sysctl.conf ]]; then
        # 1. 尝试使用全新起止标记进行整块清理 (防止多次运行时中文注释及变量叠加)
        sed -i '/# === SNELL_SYSCTL_START ===/,/# === SNELL_SYSCTL_END ===/d' /etc/sysctl.conf

        # 2. 清洗可能存在的任何变体旧中文注释（避免以前重复写入留下的注释叠加）
        local chinese_keywords=(
            "文件句柄"
            "并发"
            "网络队列"
            "连接优化"
            "拥塞控制"
            "窗口与缓冲区"
            "大带宽"
            "长距离"
            "IPv6"
            "路由缓存"
            "邻居表"
            "时间戳"
            "连接回收"
            "安全与转发"
            "其他辅助"
            "BBR"
            "SNELL_SYSCTL"
            "大缓冲区"
            "足够跑满"
            "跑满"
            "丢包卡顿"
            "短连接"
            "延迟优化"
            "历史 RTT"
            "历史RTT"
            "突发灵活"
            "平滑暴力"
            "BBR Blast"
        )
        for kw in "${chinese_keywords[@]}"; do
            sed -i "/${kw}/d" /etc/sysctl.conf
        done

        # 3. 清理对应的配置项（不论等号两边是否有空格，都彻底移除，包含可能存在冲突的第三方 TCP/BBR 配置键名）
        local keys=(
            # 基础文件句柄限制
            "fs.file-max" "fs.nr_open"
            
            # 队列与最大连接数限制
            "net.core.somaxconn" "net.ipv4.tcp_max_syn_backlog" "net.ipv4.tcp_abort_on_overflow"
            "net.ipv4.ip_local_port_range" "net.core.netdev_max_backlog" "net.ipv4.tcp_max_tw_buckets"
            
            # 拥塞控制及排队算法 (核心冲突点)
            "net.core.default_qdisc" "net.ipv4.tcp_congestion_control" "net.ipv4.tcp_fastopen"
            
            # 缓冲区与内存控制 (大带宽/长距离核心冲突)
            "net.ipv4.tcp_window_scaling" "net.ipv4.tcp_adv_win_scale" "net.ipv4.tcp_moderate_rcvbuf"
            "net.core.rmem_max" "net.core.wmem_max" "net.core.rmem_default" "net.core.wmem_default"
            "net.ipv4.tcp_rmem" "net.ipv4.tcp_wmem" "net.ipv4.tcp_mem"
            "net.ipv4.udp_rmem_min" "net.ipv4.udp_wmem_min" "net.ipv4.udp_mem"
            
            # IPv6 专项优化与邻居表限制
            "net.ipv6.conf.all.disable_ipv6" "net.ipv6.conf.default.disable_ipv6" "net.ipv6.conf.lo.disable_ipv6"
            "net.ipv6.conf.all.forwarding" "net.ipv6.conf.default.forwarding"
            "net.ipv6.route.max_size" "net.ipv6.neigh.default.gc_thresh"
            "net.ipv6.neigh.default.gc_thresh1" "net.ipv6.neigh.default.gc_thresh2" "net.ipv6.neigh.default.gc_thresh3"
            
            # 时间戳与网络连接回收 (包含已被内核弃用且有NAT严重 Bug 的 tcp_tw_recycle)
            "net.ipv4.tcp_timestamps" "net.ipv4.tcp_tw_reuse" "net.ipv4.tcp_tw_recycle" "net.ipv4.tcp_fin_timeout"
            "net.ipv4.tcp_slow_start_after_idle"
            
            # 安全与路由转发
            "net.ipv4.conf.all.rp_filter" "net.ipv4.conf.default.rp_filter" "net.ipv4.ip_forward"
            "net.ipv4.conf.all.route_localnet" "net.ipv4.tcp_rfc1337" "net.ipv4.tcp_ecn"
            "net.ipv4.tcp_syncookies"
            
            # SACK/FACK 网络重传控制
            "net.ipv4.tcp_no_metrics_save" "net.ipv4.tcp_sack" "net.ipv4.tcp_fack" "net.ipv4.tcp_dsack" "net.ipv4.tcp_mtu_probing"
        )
        for key in "${keys[@]}"; do
            sed -i "/^[[:space:]#]*${key}[[:space:]]*=/d" /etc/sysctl.conf
        done

        # 4. 清除多余的连续空白行
        sed -i '/^$/N;/^\n$/D' /etc/sysctl.conf
        ok "旧优化参数及中文注释清理完成"
    fi

    # 确保文件末尾有换行符
    [[ -f /etc/sysctl.conf ]] && sed -i '$a\' /etc/sysctl.conf

    info "正在写入全新 BBR 与网络协议栈调优参数..."
    cat << 'EOF' >> /etc/sysctl.conf
# === SNELL_SYSCTL_START ===
# 1. 基础文件句柄限制 (适配高并发)
fs.file-max                     = 6815744
fs.nr_open                      = 6815744

# 2. 网络队列与连接优化
net.core.somaxconn              = 65535
net.ipv4.tcp_max_syn_backlog    = 8192
net.ipv4.tcp_abort_on_overflow  = 1
net.ipv4.ip_local_port_range    = 1024 65535
net.core.netdev_max_backlog     = 65536

# 3. BBR 与 拥塞控制
net.core.default_qdisc          = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_fastopen           = 3

# 4. TCP 窗口与缓冲区优化 (针对大带宽/长距离链路)
net.ipv4.tcp_window_scaling     = 1
net.ipv4.tcp_adv_win_scale      = 1
net.ipv4.tcp_moderate_rcvbuf    = 1
net.core.rmem_max               = 67108864
net.core.wmem_max               = 67108864
net.ipv4.tcp_rmem               = 4096 87380 67108864
net.ipv4.tcp_wmem               = 4096 65536 67108864
net.ipv4.udp_rmem_min           = 8192
net.ipv4.udp_wmem_min           = 8192

# 5. IPv6 专项开启与调优
net.ipv6.conf.all.disable_ipv6 = 0
net.ipv6.conf.default.disable_ipv6 = 0
net.ipv6.conf.lo.disable_ipv6 = 0
net.ipv6.conf.all.forwarding = 1
net.ipv6.conf.default.forwarding = 1
# 扩大 IPv6 路由缓存和邻居表，防止高并发时丢包
net.ipv6.route.max_size = 1048576
net.ipv6.neigh.default.gc_thresh1 = 1024
net.ipv6.neigh.default.gc_thresh2 = 4096
net.ipv6.neigh.default.gc_thresh3 = 8192

# 6. 时间戳与连接回收
net.ipv4.tcp_timestamps         = 1
net.ipv4.tcp_tw_reuse           = 1
net.ipv4.tcp_fin_timeout        = 30
net.ipv4.tcp_slow_start_after_idle = 0

# 7. 安全与转发配置
net.ipv4.conf.all.rp_filter     = 0
net.ipv4.conf.default.rp_filter = 0
net.ipv4.ip_forward             = 1
net.ipv4.conf.all.route_localnet= 1
net.ipv4.tcp_rfc1337            = 1
net.ipv4.tcp_ecn                = 0

# 8. 其他辅助优化
net.ipv4.tcp_no_metrics_save    = 1
net.ipv4.tcp_sack               = 1
net.ipv4.tcp_fack               = 1
net.ipv4.tcp_mtu_probing        = 1
# === SNELL_SYSCTL_END ===
EOF

    info "正在应用内核优化参数 (sysctl -p)..."
    echo ""
    modprobe tcp_bbr &>/dev/null || true
    sysctl -p &>/dev/null || true
    sysctl --system &>/dev/null || true
    echo ""
    ok "BBR 与协议栈调优参数已成功应用！"
    pause
}

# ============================================================
# 9. 时间同步
# ============================================================
do_sync_time() {
    clear
    echo ""
    hr
    echo -e "  ${BOLD}${C} 时间同步${NC}"
    hr
    echo ""

    # 1. 检查时区是否已为 Asia/Shanghai
    local cur_tz=""
    if command -v timedatectl &>/dev/null; then
        cur_tz=$(timedatectl show 2>/dev/null | grep "Timezone=" | cut -d= -f2 || true)
    fi
    
    # 2. 检查 chrony 或其他同步服务是否运行，且已配置好
    local service_active=false
    # 动态检测 chrony 配置路径
    local chrony_conf_check="/etc/chrony.conf"
    [[ -d /etc/chrony ]] && chrony_conf_check="/etc/chrony/chrony.conf"
    if systemctl is-active --quiet chrony 2>/dev/null || systemctl is-active --quiet chronyd 2>/dev/null; then
        if [[ -f "$chrony_conf_check" ]] && grep -q "ntp.aliyun.com" "$chrony_conf_check" 2>/dev/null; then
            service_active=true
        fi
    fi

    # 如果时区和同步服务配置完毕，则直接返回
    if [[ "$cur_tz" == "Asia/Shanghai" && "$service_active" == "true" ]]; then
        ok "检测到系统已配置 Asia/Shanghai 时区，且 Chrony 同步正常，无需重复配置！"
        echo -e "  系统当前时间: $(date)"
        echo ""
        pause
        return
    fi

    info "系统时间配置未完善，正在开始同步..."
    echo ""

    info "正在配置系统时区为 Asia/Shanghai..."
    timedatectl set-timezone Asia/Shanghai 2>/dev/null || true
    
    info "正在安装并配置 chrony..."
    if command -v apt-get &>/dev/null; then
        apt-get update -qq && apt-get install -y chrony -qq
    elif command -v dnf &>/dev/null; then
        dnf install -y -q chrony
    elif command -v yum &>/dev/null; then
        yum install -y -q chrony
    elif command -v pacman &>/dev/null; then
        pacman -Sy --noconfirm chrony
    fi

    info "正在写入 chrony.conf 配置..."
    # 动态检测 chrony 配置路径（Debian/Ubuntu 为 /etc/chrony/chrony.conf，CentOS/RHEL 为 /etc/chrony.conf）
    local chrony_conf="/etc/chrony.conf"
    [[ -d /etc/chrony ]] && chrony_conf="/etc/chrony/chrony.conf"
    cat <<EOF > "$chrony_conf"
server ntp.aliyun.com iburst
server ntp.tencent.com iburst
driftfile /var/lib/chrony/chrony.drift
logdir /var/log/chrony
maxupdateskew 100.0
rtcsync
makestep 1.0 3
EOF

    info "正在重启 chrony 服务并强制同步..."
    if systemctl is-enabled --quiet chrony 2>/dev/null || systemctl is-enabled --quiet chronyd 2>/dev/null; then
        systemctl restart chrony &>/dev/null || systemctl restart chronyd &>/dev/null || true
        sleep 1
        chronyc -a makestep &>/dev/null || true
    fi

    ok "时间同步完成，当前系统时间: $(date)"
    echo ""
    pause
}

# ============================================================
# 10. 定时更新设置 (中国时间 03:30)
# ============================================================
get_cron_time() {
    echo "30 3 * * *"
}

do_cron_menu() {
    clear
    echo ""
    hr
    echo -e "  ${BOLD}${C} 定时自动更新设置${NC}"
    hr
    echo ""

    local cron_job
    local cron_time
    cron_time=$(get_cron_time)
    cron_job="${cron_time} root /bin/bash /usr/local/bin/snell --cron-check &>/dev/null"

    # 检查 cron 是否已配置
    local is_enabled=false
    if [[ -f /etc/crontab ]] && grep -q -- "--cron-check" /etc/crontab 2>/dev/null; then
        is_enabled=true
    fi

    if [[ "$is_enabled" == "true" ]]; then
        echo -e "  当前状态: ${G}已开启${NC}"
        echo -e "  执行时间: 中国时间每天 ${Y}03:30${NC} (系统排程: ${cron_time})"
        echo ""
        read -rp "  是否关闭定时自动更新任务？(y/N) " opt
        if [[ "$opt" == "y" || "$opt" == "Y" ]]; then
            sed -i '\/--cron-check/d' /etc/crontab
            # 重启 cron 服务以应用修改
            systemctl restart cron &>/dev/null || systemctl restart crond &>/dev/null || true
            ok "定时自动更新任务已关闭！"
        else
            info "未做修改"
        fi
    else
        echo -e "  当前状态: ${DIM}已关闭${NC}"
        echo -e "  执行时间: 中国时间每天 ${Y}03:30${NC} (系统排程: ${cron_time})"
        echo ""
        read -rp "  是否开启定时自动更新任务？(Y/n) " opt
        if [[ "$opt" != "n" && "$opt" != "N" ]]; then
            # 确保 crontab 文件末尾有换行符
            [[ -f /etc/crontab ]] && sed -i '$a\' /etc/crontab
            echo "$cron_job" >> /etc/crontab
            systemctl enable cron &>/dev/null || systemctl enable crond &>/dev/null || true
            systemctl restart cron &>/dev/null || systemctl restart crond &>/dev/null || true
            ok "定时自动更新任务已成功开启！"
        else
            info "已取消"
        fi
    fi
    echo ""
    pause
}

# ============================================================
# 11. 更新管理脚本自身
# ============================================================
update_self() {
    clear
    echo ""
    hr
    echo -e "  ${BOLD}${C} 更新 Snell Server 管理脚本${NC}"
    hr
    echo ""

    local github_url="https://raw.githubusercontent.com/hann0w0/snell-install/main/snell.sh"
    local script_dest="/usr/local/bin/snell"

    info "正在从 GitHub 仓库获取最新版管理脚本..."
    echo -e "  ${DIM}${github_url}${NC}"
    echo ""

    local tmp
    tmp=$(mktemp)
    
    local success=false
    if command -v curl &>/dev/null; then
        curl -fsSL --connect-timeout 5 "$github_url" > "$tmp" 2>/dev/null && success=true
    elif command -v wget &>/dev/null; then
        wget -q --timeout=5 -O "$tmp" "$github_url" 2>/dev/null && success=true
    fi

    if [[ "$success" == "true" ]]; then
        # 简单校验下载到的文件是否包含 bash 声明，防止下到 404 网页或空白
        if grep -q "#!/usr/bin/env bash" "$tmp" || grep -q "#!/bin/bash" "$tmp"; then
            # 覆写目标文件并赋予权限
            cat "$tmp" > "$script_dest"
            chmod +x "$script_dest"
            rm -f "$tmp"
            
            # 清理可能存在的旧版本残留（以防万一）
            [[ -f "/root/snell.sh" ]] && rm -f "/root/snell.sh" 2>/dev/null || true
            
            ok "管理脚本已成功更新至最新版本！"
            echo ""
            info "正在重新载入并启动新版脚本..."
            sleep 1
            exec "$script_dest"
        else
            rm -f "$tmp"
            err "更新失败：下载的文件内容校验未通过（可能网络连接超时或源文件损坏）"
        fi
    else
        rm -f "$tmp"
        err "更新失败：无法连接到 GitHub 仓库，请检查您的网络连接"
    fi
    pause
}

# 静默检查与升级，由 cron 触发 (依次循环检测每一个可能存在的实例)
check_and_auto_update() {
    # 1. 检测系统架构与依赖
    detect_arch
    
    # 2. 抓取官网最新版本号
    fetch_latest_versions
    
    for sfx in "v5" "v6"; do
        SUFFIX="$sfx"
        local bin_path version_file service_name
        bin_path=$(get_bin_path)
        version_file=$(get_version_file)
        service_name=$(get_service_name)

        if [[ ! -f "$bin_path" ]]; then
            continue
        fi

        # 读取当前版本号
        local cv="N/A"
        [[ -f "$version_file" ]] && cv=$(cat "$version_file")
        [[ "$cv" == "N/A" ]] && continue
        
        local target_ver=""
        if [[ "$SUFFIX" == "v6" ]]; then
            target_ver="$V6_VERSION"
        else
            target_ver="$V5_VERSION"
        fi

        # 版本不一致时，静默升级并重启服务
        if [[ -n "$target_ver" && "$cv" != "$target_ver" ]]; then
            local tmp
            tmp=$(mktemp -d)
            local url
            url=$(get_download_url "$target_ver")
            
            if wget -q -O "${tmp}/snell.zip" "$url"; then
                unzip -o -q "${tmp}/snell.zip" -d "$tmp"
                local bin
                bin=$(find "$tmp" -name "snell-server" -type f | head -1)
                if [[ -n "$bin" ]]; then
                    # 升级前备份原有二进制
                    local backup_bin="${bin_path}.bak"
                    cp -f "$bin_path" "$backup_bin" 2>/dev/null || true
                    
                    systemctl stop "$service_name" 2>/dev/null || true
                    install -m 755 "$bin" "$bin_path"
                    echo "$target_ver" > "$version_file"
                    systemctl restart "$service_name" 2>/dev/null || true
                    
                    # 睡眠 3 秒检测是否能稳定运行
                    sleep 3
                    if systemctl is-active --quiet "$service_name" 2>/dev/null; then
                        # 运行成功，删除备份
                        rm -f "$backup_bin" 2>/dev/null || true
                    else
                        # 运行失败，静默安全回滚
                        mv -f "$backup_bin" "$bin_path" 2>/dev/null || true
                        echo "$cv" > "$version_file"
                        systemctl restart "$service_name" 2>/dev/null || true
                    fi
                fi
            fi
            rm -rf "$tmp"
        fi
    done
    exit 0
}

# 炫酷的进度条与动态加载
smooth_progress() {
    local start_pct="$1"
    local end_pct="$2"
    local desc="$3"
    local run_cmd="${4:-}"
    local width=30

    # 如果没有要跑的后台命令，直接平滑步进绘制
    if [[ -z "$run_cmd" ]]; then
        for ((p=start_pct; p<=end_pct; p+=2)); do
            local filled=$(( p * width / 100 ))
            local empty=$(( width - filled ))
            local bar=""
            for ((i=0; i<filled; i++)); do bar="${bar}█"; done
            for ((i=0; i<empty; i++)); do bar="${bar}░"; done
            printf "\r  ${C}初始化${NC} [${G}%s${NC}] %3d%%  %s" "$bar" "$p" "$desc"
            sleep 0.015
        done
        return
    fi

    # 如果有后台任务，启动任务并在等待时播放转圈动画 + 进度平缓上升
    bash -c "$run_cmd" &
    local pid=$!
    local current_pct=$start_pct
    local spin='-\|/'
    local spin_idx=0

    while kill -0 $pid 2>/dev/null; do
        # 进度值在等待中缓慢增加，但不超过目标结束值的前一位
        if (( current_pct < end_pct - 1 )); then
            (( current_pct++ ))
        fi
        
        local filled=$(( current_pct * width / 100 ))
        local empty=$(( width - filled ))
        local bar=""
        for ((i=0; i<filled; i++)); do bar="${bar}█"; done
        for ((i=0; i<empty; i++)); do bar="${bar}░"; done
        
        local ch="${spin:$spin_idx:1}"
        printf "\r  ${C}初始化${NC} [${G}%s${NC}] %3d%% [%s] %s" "$bar" "$current_pct" "$ch" "$desc"
        
        spin_idx=$(( (spin_idx + 1) % 4 ))
        sleep 0.08
    done

    # 任务结束后，平滑拉满到 end_pct
    for ((p=current_pct; p<=end_pct; p+=2)); do
        local filled=$(( p * width / 100 ))
        local empty=$(( width - filled ))
        local bar=""
        for ((i=0; i<filled; i++)); do bar="${bar}█"; done
        for ((i=0; i<empty; i++)); do bar="${bar}░"; done
        printf "\r  ${C}初始化${NC} [${G}%s${NC}] %3d%% [✓] %s" "$bar" "$p" "$desc"
        sleep 0.01
    done
}

# ============================================================
# 入口
# ============================================================
main() {
    check_root
    
    # 支持 Cron 定时任务静默拉取更新，当带有参数时直接走检测函数并退出
    if [[ "${1:-}" == "--cron-check" ]]; then
        check_and_auto_update
        exit 0
    fi
    
    clear
    echo ""
    hr
    echo -e "  ${BOLD}${C} 正在加载 Snell Server 管理脚本...${NC}"
    hr
    echo ""
    
    # 步骤 1: 检测系统架构（同步执行确保 ARCH 变量正确设置）
    smooth_progress 0 45 "正在检测系统架构..."
    detect_arch
    
    # 步骤 2: 检测系统依赖并静默补全（同步执行确保依赖就绪）
    smooth_progress 45 90 "正在检查并准备系统依赖 (wget, unzip)..."
    ensure_deps &>/dev/null
    
    # 步骤 3: 准备运行环境并安装快捷方式
    smooth_progress 90 100 "加载完成！"
    install_shortcut
    sleep 0.2
    
    while true; do
        show_menu
        read -rp "  选择 [0-11]: " ch
        case "$ch" in
            1) do_install ;;
            2) do_update ;;
            3) do_uninstall ;;
            4) do_modify ;;
            5) do_show ;;
            6) do_restart ;;
            7) do_logs ;;
            8) do_bbr ;;
            9) do_sync_time ;;
            10) do_cron_menu ;;
            11) update_self ;;
            0) echo ""; info "再见"; echo ""; exit 0 ;;
            *) warn "无效选项"; sleep 0.3 ;;
        esac
    done
}

main "$@"

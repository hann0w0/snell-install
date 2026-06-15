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
        v6_candidates=$(echo "$html" | grep -oE 'v6\.[0-9]+\.[0-9]+(b[0-9]+)?' | sort -V -r | head -n 5 || true)
        for candidate in $v6_candidates; do
            if check_url_exists "$candidate"; then
                V6_VERSION="$candidate"
                break
            fi
        done

        # 2. 动态探测并校验 V5 可下载最新版 (测试前 5 个候选版本)
        local v5_candidates
        v5_candidates=$(echo "$html" | grep -oE 'v5\.[0-9]+\.[0-9]+' | sort -V -r | head -n 5 || true)
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

clear_stdin() {
    while read -t 0.01 -n 100000; do :; done 2>/dev/null || true
}

pause() {
    echo ""
    clear_stdin
    read -rsn1 -p "  按任意键返回主菜单..."
    echo ""
}

# ============================================================
# 自动持久化保存并安装快捷指令 'snell'
# ============================================================
install_shortcut() {
    local script_dest="/usr/local/bin/snell"
    local github_url="https://raw.githubusercontent.com/hann0w0/snell-install/main/snell.sh"
    
    # 清理旧版本遗留的软链接
    if [[ -L "$script_dest" ]]; then
        rm -f "$script_dest" 2>/dev/null || true
    fi
    
    # 检查当前运行的脚本是否已经是目标路径
    local cur_real_path
    cur_real_path=$(readlink -f "$0" 2>/dev/null || echo "")
    if [[ "$cur_real_path" == "$script_dest" ]]; then
        return 0
    fi
    
    info "正在为您配置本地快捷调用指令 'snell'..."
    
    local success=false
    # 场景 1：如果本地有运行中的普通文件，直接 cp
    local base_name
    base_name=$(basename "$cur_real_path" 2>/dev/null || echo "")
    if [[ -f "$0" ]] && [[ "$base_name" != "bash" && "$base_name" != "sh" && "$base_name" != "zsh" && "$cur_real_path" != *"/dev/fd/"* ]]; then
        if cp -f "$0" "$script_dest" 2>/dev/null; then
            success=true
        fi
    fi
    
    # 场景 2：如果是网络管道运行，从 GitHub 拉取
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
        
        # 拷贝成功后，若当前运行的不是 /root/snell.sh 且该残留存在，则清理它，防范自杀
        if [[ "$cur_real_path" != "/root/snell.sh" && -f "/root/snell.sh" ]]; then
            rm -f "/root/snell.sh" 2>/dev/null || true
        fi
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
    elif [[ "$v5_exists" == "false" && "$v6_exists" == "false" ]]; then
        err "未检测到任何已安装的 Snell Server 实例，无法执行${action}。"
        pause
        return 1
    fi
    
    # 两个都存在，或者两个都不存在，让用户选择
    local v5_ver="N/A"
    local v6_ver="N/A"
    [[ -f "${CONFIG_DIR}/.version-v5" ]] && v5_ver=$(cat "${CONFIG_DIR}/.version-v5")
    [[ -f "${CONFIG_DIR}/.version-v6" ]] && v6_ver=$(cat "${CONFIG_DIR}/.version-v6")

    echo -e "  ${BOLD}请选择要${action}的 Snell 版本:${NC}"
    echo -e "  ${G}1${NC}. Snell (${v5_ver})"
    echo -e "  ${G}2${NC}. Snell (${v6_ver})"
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
# 智能扫描并导入接管系统中的非标外部 Snell 实例
# ============================================================
scan_external_snell() {
    local ext_svc=""
    local ext_bin=""
    local ext_cfg=""
    local svc_files=""
    local svc=""
    local bname=""
    local exec_line=""
    local ps_line=""
    local cmd_part=""
    local confirm_import=""
    local confirm_import_val=""
    local ver_choice=""
    local import_suffix=""
    local import_ver_name=""
    local target_bin=""
    local target_cfg=""
    local SUFFIX=""
    local service_name=""
    local cur_port=""

    # 1. 查找 systemd 服务中非标命名的 snell 服务
    svc_files=$(find /etc/systemd/system/ -maxdepth 1 -name "*snell*.service" 2>/dev/null || true)
    if [[ -n "$svc_files" ]]; then
        for svc in $svc_files; do
            bname=$(basename "$svc")
            if [[ "$bname" != "snell-v5.service" && "$bname" != "snell-v6.service" ]]; then
                ext_svc="$bname"
                exec_line=$(grep -E "^ExecStart\s*=" "$svc" 2>/dev/null | head -1 | sed 's/^[^=]*=[[:space:]]*//' || true)
                if [[ -n "$exec_line" ]]; then
                    ext_bin=$(echo "$exec_line" | awk '{print $1}')
                    ext_cfg=$(echo "$exec_line" | grep -oE '\-c\s+\S+' | awk '{print $2}')
                fi
                break
            fi
        done
    fi

    # 2. 如果未找到服务，扫描正在运行的非标进程
    if [[ -z "$ext_bin" ]]; then
        ps_line=$(ps -ef 2>/dev/null | grep -E 'snell-server' | grep -v 'grep' | grep -vE 'snell-server-v[56]' | head -1 || true)
        if [[ -n "$ps_line" ]]; then
            cmd_part=$(echo "$ps_line" | awk '{for(i=8;i<=NF;i++) printf "%s ", $i; print ""}')
            ext_bin=$(echo "$cmd_part" | awk '{print $1}')
            ext_cfg=$(echo "$cmd_part" | grep -oE '\-c\s+\S+' | awk '{print $2}')
            ext_svc="running-process"
        fi
    fi

    # 3. 如果仍未找到，检测经典默认非标路径
    if [[ -z "$ext_bin" ]]; then
        if [[ -f "/usr/local/bin/snell-server" && ! -L "/usr/local/bin/snell-server" ]]; then
            if [[ -f "/etc/snell.conf" ]]; then
                ext_bin="/usr/local/bin/snell-server"
                ext_cfg="/etc/snell.conf"
            elif [[ -f "/etc/snell/snell.conf" ]]; then
                ext_bin="/usr/local/bin/snell-server"
                ext_cfg="/etc/snell/snell.conf"
            fi
        fi
    fi

    # 4. 发现目标，启动导入接管流程
    if [[ -n "$ext_bin" && -f "$ext_bin" && -n "$ext_cfg" && -f "$ext_cfg" ]]; then
        clear
        echo ""
        hr
        echo -e "  ${BOLD}${Y} 发现未接管的外部 Snell 实例！${NC}"
        hr
        echo ""
        warn "检测到当前服务器上存在非本脚本创建的旧 Snell 实例："
        echo -e "  - 二进制路径: ${BOLD}${ext_bin}${NC}"
        echo -e "  - 配置文件:   ${BOLD}${ext_cfg}${NC}"
        [[ -n "$ext_svc" && "$ext_svc" != "running-process" ]] && echo -e "  - Systemd 服务: ${BOLD}${ext_svc}${NC}"
        echo ""
        info "将其导入接管后，即可在主面板直接看到其运行状态，"
        info "并能通过面板修改配置、重启、卸载以及支持自动定时更新！"
        echo ""

        clear_stdin
        read -rp "  是否立即导入并接管该实例？(Y/n) [默认 Y]: " confirm_import
        confirm_import_val="${confirm_import:-y}"
        if [[ "$confirm_import_val" == "y" || "$confirm_import_val" == "Y" ]]; then
            echo ""
            echo -e "  ${BOLD}请指定该实例的 Snell 协议版本:${NC}"
            echo -e "  ${G}1${NC}. Snell V5 (默认)"
            echo -e "  ${G}2${NC}. Snell V6"
            echo ""
            read -rp "  请选择 [1/2, 默认 1]: " ver_choice
            import_suffix="v5"
            import_ver_name="${V5_VERSION}"
            if [[ "$ver_choice" == "2" ]]; then
                import_suffix="v6"
                import_ver_name="${V6_VERSION}"
            fi

            target_bin="${INSTALL_DIR}/snell-server-${import_suffix}"
            target_cfg="${CONFIG_DIR}/snell-server-${import_suffix}.conf"

            if [[ -f "$target_bin" ]]; then
                err "接管失败：系统已存在标准的 Snell ${import_suffix} 实例，无法重复导入！"
                pause
                return
            fi

            info "正在停止旧的外部服务与进程..."
            if [[ -n "$ext_svc" && "$ext_svc" != "running-process" ]]; then
                systemctl stop "$ext_svc" 2>/dev/null || true
                systemctl disable "$ext_svc" 2>/dev/null || true
                rm -f "/etc/systemd/system/${ext_svc}" 2>/dev/null || true
            else
                pkill -9 -f "$ext_bin" 2>/dev/null || true
            fi

            mkdir -p "$CONFIG_DIR"

            info "正在将文件规范化迁移至标准管理路径..."
            # 如果是移动出错，降级用复制，并删除源文件
            mv -f "$ext_bin" "$target_bin" 2>/dev/null || { cp -f "$ext_bin" "$target_bin" && rm -f "$ext_bin"; }
            mv -f "$ext_cfg" "$target_cfg" 2>/dev/null || { cp -f "$ext_cfg" "$target_cfg" && rm -f "$ext_cfg"; }
            chmod +x "$target_bin" 2>/dev/null || true
            chmod 600 "$target_cfg" 2>/dev/null || true

            echo "$import_ver_name" > "${CONFIG_DIR}/.version-${import_suffix}"

            SUFFIX="$import_suffix"
            write_service

            service_name=$(get_service_name)
            systemctl daemon-reload
            systemctl enable "$service_name" &>/dev/null || true
            systemctl start "$service_name" 2>/dev/null || true

            # 防火墙端口放行
            cur_port=$(grep -E "^listen\s*=" "$target_cfg" 2>/dev/null | head -1 | sed 's/^[^=]*=[[:space:]]*//' | grep -oE '[0-9]+$')
            if [[ -n "$cur_port" ]]; then
                open_firewall "$cur_port"
            fi

            ok "成功接管外部 Snell ${import_suffix} 实例！"
            ok "该实例已转换为标准管理模式，服务已成功启动并加载。"
            echo ""
            pause
        else
            info "已跳过导入接管。我们将忽略该外部旧实例。"
            echo ""
            pause
        fi
    fi
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
    echo -e "  ${C}▎核心部署${NC}                    ${C}▎系统调优${NC}"
    echo ""
    echo -e "  ${G}1${NC}.  安装 Snell                ${G}4${NC}.  BBR 优化"
    echo -e "  ${G}2${NC}.  更新 Snell                ${G}5${NC}.  时间同步"
    echo -e "  ${G}3${NC}.  卸载 Snell                ${G}6${NC}.  定时更新"
    echo ""
    echo -e "  ${C}▎参数配置${NC}                    ${C}▎观测维护${NC}"
    echo ""
    echo -e "  ${G}7${NC}.  修改配置                  ${G}10${NC}. 运行日志"
    echo -e "  ${G}8${NC}.  查看配置                  ${G}11${NC}. 更新脚本"
    echo -e "  ${G}9${NC}.  重启服务                  ${G}0${NC}.  退出面板"
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
    for cmd in wget unzip curl; do
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

validate_psk() {
    local psk="$1"
    if [[ ${#psk} -eq 44 ]] && [[ "$psk" =~ ^[A-Za-z0-9+/]+={0,2}$ ]]; then
        return 0
    fi
    return 1
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
        grep -E "^listen\s*=" "$other_cfg" 2>/dev/null | head -1 | sed 's/^[^=]*=[[:space:]]*//' | awk -F: '{print $NF}' | tr -d '[:space:]' | grep -oE '^[0-9]+$'
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
    pkill -9 -x "snell-server-${SUFFIX}" 2>/dev/null || true
    
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

save_iptables() {
    if command -v netfilter-persistent &>/dev/null; then
        netfilter-persistent save &>/dev/null || true
    elif command -v service &>/dev/null && service iptables status &>/dev/null; then
        service iptables save &>/dev/null || true
    elif [[ -d /etc/iptables ]]; then
        iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
        ip6tables-save > /etc/iptables/rules.v6 2>/dev/null || true
    fi
}

open_firewall() {
    local p="$1"
    info "配置防火墙 (${p})"
    
    if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "active"; then
        ufw allow "${p}/tcp" &>/dev/null || true
        ufw allow "${p}/udp" &>/dev/null || true
        ok "防火墙 (ufw) 已放行"
    elif command -v firewall-cmd &>/dev/null && systemctl is-active --quiet firewalld 2>/dev/null; then
        firewall-cmd --permanent --add-port="${p}/tcp" &>/dev/null || true
        firewall-cmd --permanent --add-port="${p}/udp" &>/dev/null || true
        firewall-cmd --reload &>/dev/null || true
        ok "防火墙 (firewalld) 已放行"
    else
        local opened=false
        if command -v iptables &>/dev/null; then
            iptables -C INPUT -p tcp --dport "$p" -j ACCEPT 2>/dev/null || iptables -I INPUT -p tcp --dport "$p" -j ACCEPT
            iptables -C INPUT -p udp --dport "$p" -j ACCEPT 2>/dev/null || iptables -I INPUT -p udp --dport "$p" -j ACCEPT
            opened=true
        fi
        if command -v ip6tables &>/dev/null; then
            ip6tables -C INPUT -p tcp --dport "$p" -j ACCEPT 2>/dev/null || ip6tables -I INPUT -p tcp --dport "$p" -j ACCEPT
            ip6tables -C INPUT -p udp --dport "$p" -j ACCEPT 2>/dev/null || ip6tables -I INPUT -p udp --dport "$p" -j ACCEPT
            opened=true
        fi
        if [ "$opened" = true ]; then
            save_iptables
            ok "防火墙 (iptables) 已放行并保存"
        else
            warn "未检测到可用的防火墙工具，请手动放行端口 ${p}"
        fi
    fi
}

close_firewall() {
    local p="$1"
    [[ -n "$p" ]] || return
    info "清理防火墙规则 (${p})"
    
    if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "active"; then
        ufw delete allow "${p}/tcp" &>/dev/null || true
        ufw delete allow "${p}/udp" &>/dev/null || true
        ok "防火墙 (ufw) 规则已清理"
    elif command -v firewall-cmd &>/dev/null && systemctl is-active --quiet firewalld 2>/dev/null; then
        firewall-cmd --permanent --remove-port="${p}/tcp" &>/dev/null || true
        firewall-cmd --permanent --remove-port="${p}/udp" &>/dev/null || true
        firewall-cmd --reload &>/dev/null || true
        ok "防火墙 (firewalld) 规则已清理"
    else
        local cleaned=false
        if command -v iptables &>/dev/null; then
            while iptables -C INPUT -p tcp --dport "$p" -j ACCEPT 2>/dev/null; do
                iptables -D INPUT -p tcp --dport "$p" -j ACCEPT 2>/dev/null || break
            done
            while iptables -C INPUT -p udp --dport "$p" -j ACCEPT 2>/dev/null; do
                iptables -D INPUT -p udp --dport "$p" -j ACCEPT 2>/dev/null || break
            done
            cleaned=true
        fi
        if command -v ip6tables &>/dev/null; then
            while ip6tables -C INPUT -p tcp --dport "$p" -j ACCEPT 2>/dev/null; do
                ip6tables -D INPUT -p tcp --dport "$p" -j ACCEPT 2>/dev/null || break
            done
            while ip6tables -C INPUT -p udp --dport "$p" -j ACCEPT 2>/dev/null; do
                ip6tables -D INPUT -p udp --dport "$p" -j ACCEPT 2>/dev/null || break
            done
            cleaned=true
        fi
        if [ "$cleaned" = true ]; then
            save_iptables
            ok "防火墙 (iptables) 规则已清理并保存"
        fi
    fi
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

    # 声明全部局部变量以避免 set -u 触发 nounset 错误退出
    local vc="" ow="" ip="" ik="" i6="" it="" ie="" id="" cf=""

    detect_arch
    ensure_deps
    
    info "正在实时同步 Surge 官网最新版本..."
    fetch_latest_versions
    echo ""

    # 版本
    echo -e "  ${BOLD}选择版本${NC}"
    echo -e "  ${G}1${NC}. Snell (${V5_VERSION})"
    echo -e "  ${G}2${NC}. Snell (${V6_VERSION})"
    echo -e "  ${G}0${NC}. 返回主菜单"
    echo ""
    read -rp "  选择 [1/2/0, 默认 1]: " vc
    local sv
    case "$vc" in
        2) SUFFIX="v6"; sv="$V6_VERSION" ;;
        0) echo ""; return ;;
        *) SUFFIX="v5"; sv="$V5_VERSION" ;;
    esac
    
    local bin_path
    bin_path=$(get_bin_path)
    local is_installed=false
    if [[ -f "$bin_path" ]]; then
        is_installed=true
        warn "已检测到已安装的 Snell Server ${SUFFIX}"
        clear_stdin
        read -rp "  覆盖安装？(Y/n) [默认 Y]: " ow
        local ow_val="${ow:-y}"
        [[ "$ow_val" == "y" || "$ow_val" == "Y" ]] || { info "已取消"; pause; return; }
        echo ""
        parse_config &>/dev/null || true
    fi

    ok "版本: Snell ${SUFFIX} (${sv})"
    echo ""
    hr
    echo ""

    # 端口检测，防实例间碰撞
    local other_port=""
    other_port=$(get_other_port)
    local other_suffix="v5"
    [[ "$SUFFIX" == "v5" ]] && other_suffix="v6"

    local rp
    if [[ "$is_installed" == "true" && -n "$CUR_PORT" ]]; then
        rp="$CUR_PORT"
        read -rp "  端口 [回车保持当前 ${rp}]: " ip
    else
        rp=$(random_port)
        while [[ -n "$other_port" && "$rp" == "$other_port" ]] || port_in_use "$rp"; do
            rp=$(random_port)
        done
        read -rp "  端口 [回车随机 ${rp}]: " ip
    fi
    local port="${ip:-$rp}"

    if ! validate_port "$port"; then
        pause
        return
    fi
    if [[ -n "$other_port" && "$port" == "$other_port" ]]; then
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
    local psk=""
    while true; do
        local rpsk
        if [[ "$is_installed" == "true" && -n "$CUR_PSK" ]]; then
            rpsk="$CUR_PSK"
            read -rp "  PSK [回车保持当前 PSK]: " ik
        else
            rpsk=$(random_psk)
            read -rp "  PSK [回车随机生成]: " ik
        fi
        psk="${ik:-$rpsk}"

        if ! validate_psk "$psk"; then
            warn "提示: 检测到您配置的 PSK (${psk}) 不是标准的 32 字节 Base64 强密钥。"
            warn "      Snell V5/V6 官方程序对 PSK 格式有硬性校验，非标短密码极易导致服务启动时崩溃闪退！"
            clear_stdin
            local force_psk=""
            read -rp "      是否确认强制使用该非标密码？(y/N) [默认 N]: " force_psk
            local force_psk_val="${force_psk:-n}"
            if [[ "$force_psk_val" == "y" || "$force_psk_val" == "Y" ]]; then
                break
            fi
        else
            break
        fi
    done
    ok "PSK: ${psk}"
    echo ""

    # IPv6
    local def_i6="true"
    [[ "$is_installed" == "true" && -n "$CUR_IPV6" ]] && def_i6="$CUR_IPV6"
    local i6_prompt="Y/n"
    [[ "$def_i6" == "false" ]] && i6_prompt="y/N"
    read -rp "  监听 IPv6? (${i6_prompt}) [当前: ${def_i6}]: " i6
    local ipv6="$def_i6"
    if [[ -n "$i6" ]]; then
        [[ "$i6" == "n" || "$i6" == "N" ]] && ipv6="false" || ipv6="true"
    fi
    ok "IPv6: ${ipv6}"
    echo ""

    # TFO
    local def_tfo="false"
    [[ "$is_installed" == "true" && -n "$CUR_TFO" ]] && def_tfo="$CUR_TFO"
    local tfo_prompt="y/N"
    [[ "$def_tfo" == "true" ]] && tfo_prompt="Y/n"
    read -rp "  TCP Fast Open? (${tfo_prompt}) [当前: ${def_tfo}]: " it
    local tfo="$def_tfo"
    if [[ -n "$it" ]]; then
        [[ "$it" == "y" || "$it" == "Y" ]] && tfo="true" || tfo="false"
    fi
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
    [[ "$is_installed" == "true" && -n "$CUR_DNS" ]] && ddns="$CUR_DNS"
    read -rp "  DNS [回车保持当前]: " id
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
    clear_stdin
    read -rp "  确认安装? (Y/n) [默认 Y]: " cf
    local cf_val="${cf:-y}"
    [[ "$cf_val" == "n" || "$cf_val" == "N" ]] && { info "已取消"; pause; return; }

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
        local v5_ver="N/A"
        local v6_ver="N/A"
        [[ -f "${CONFIG_DIR}/.version-v5" ]] && v5_ver=$(cat "${CONFIG_DIR}/.version-v5")
        [[ -f "${CONFIG_DIR}/.version-v6" ]] && v6_ver=$(cat "${CONFIG_DIR}/.version-v6")

        echo -e "  ${BOLD}请选择要卸载的 Snell 版本:${NC}"
        echo -e "  ${G}1${NC}. Snell (${v5_ver})"
        echo -e "  ${G}2${NC}. Snell (${v6_ver})"
        echo -e "  ${G}3${NC}. 同时卸载所有版本"
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
        if [[ -n "$v5_port" ]]; then
            close_firewall "$v5_port"
        fi
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
        if [[ -n "$v6_port" ]]; then
            close_firewall "$v6_port"
        fi
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
        info "正在清理定时更新与流量统计任务..."
        if [[ -f /etc/crontab ]]; then
            sed -i '/\/snell/d' /etc/crontab 2>/dev/null || true
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
    auto_select_or_ask_version "修改配置" || return

    while true; do
        clear
        echo ""
        hr
        echo -e "  ${BOLD}${C} 修改配置 (Snell ${SUFFIX})${NC}"
        hr
        echo ""

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
        echo -e "  ${DIM}0. 返回主菜单${NC}"
        echo ""
        
        local mc
        read -rp "  选择 [0-6]: " mc
        mc="${mc:-0}"

        if [[ "$mc" == "0" ]]; then
            return
        fi

        if [[ ! "$mc" =~ ^[0-9]+$ ]] || (( mc < 1 || mc > 6 )); then
            warn "无效选项，请重新选择"
            sleep 0.5
            continue
        fi

        local other_port=""
        other_port=$(get_other_port)
        local has_changed=false

        case "$mc" in
            1)
                read -rp "  新端口: " np
                if [[ -n "$np" ]]; then
                    if ! validate_port "$np"; then
                        pause
                        continue
                    fi
                    if [[ -n "$other_port" && "$np" == "$other_port" ]]; then
                        local other_suffix="v5"
                        [[ "$SUFFIX" == "v5" ]] && other_suffix="v6"
                        err "错误: 新端口与已安装的 Snell ${other_suffix} 端口 (${other_port}) 冲突！"
                        pause
                        continue
                    fi
                    if port_in_use "$np"; then
                        err "错误: 端口 ${np} 已被系统其他服务占用，请更换端口！"
                        pause
                        continue
                    fi
                    close_firewall "$CUR_PORT"
                    if [[ "${CUR_IPV6}" == "true" ]]; then
                        sed -i "s|^listen\s*=.*|listen = [::]:${np}|" "$config_file"
                    else
                        sed -i "s|^listen\s*=.*|listen = 0.0.0.0:${np}|" "$config_file"
                    fi
                    open_firewall "$np"
                    ok "端口 -> ${np}"
                    has_changed=true
                else
                    warn "未输入，端口未修改"
                    pause
                fi
                ;;
            2)
                local nk=""
                while true; do
                    read -rp "  新 PSK: " input_nk
                    if [[ -n "$input_nk" ]]; then
                        if ! validate_psk "$input_nk"; then
                            warn "提示: 输入的 PSK (${input_nk}) 不是标准的 32 字节 Base64 密钥。"
                            warn "      Snell V5/V6 官方程序对密码格式有硬性校验，非标短密码极易导致服务崩溃闪退！"
                            clear_stdin
                            local force_nk=""
                            read -rp "      是否确认强制使用该非标密码？(y/N) [默认 N]: " force_nk
                            local force_nk_val="${force_nk:-n}"
                            if [[ "$force_nk_val" == "y" || "$force_nk_val" == "Y" ]]; then
                                nk="$input_nk"
                                break
                            fi
                        else
                            nk="$input_nk"
                            break
                        fi
                    else
                        break
                    fi
                done

                if [[ -n "$nk" ]]; then
                    sed -i "s|^psk\s*=.*|psk = ${nk}|" "$config_file"
                    ok "PSK -> ${nk}"
                    has_changed=true
                else
                    warn "未输入或已取消，PSK 未修改"
                    pause
                fi
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
                has_changed=true
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
                has_changed=true
                ;;
            5)
                read -rp "  新 DNS (逗号分隔): " nd
                if [[ -n "$nd" ]]; then
                    if grep -q "^dns" "$config_file"; then
                        sed -i "s|^dns\s*=.*|dns = ${nd}|" "$config_file"
                    else
                        echo "dns = ${nd}" >> "$config_file"
                    fi
                    ok "DNS 已修改"
                    has_changed=true
                else
                    warn "未输入，DNS 未修改"
                    pause
                fi
                ;;
            6)
                local nk
                nk=$(random_psk)
                sed -i "s|^psk\s*=.*|psk = ${nk}|" "$config_file"
                ok "新 PSK 已自动生成为: ${nk}"
                has_changed=true
                ;;
        esac

        if [[ "$has_changed" == "true" ]]; then
            echo ""
            read -rp "  是否立即重启 Snell ${SUFFIX} 使配置生效? (Y/n) " rr
            rr="${rr:-Y}"
            if [[ "$rr" == "y" || "$rr" == "Y" ]]; then
                local service_name
                service_name=$(get_service_name)
                systemctl restart "$service_name" && ok "服务已成功重启并应用新配置" || err "重启服务失败"
            else
                info "配置已修改，将在下次手动重启服务后生效"
            fi
            pause
        fi
    done
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


# ============================================================
# 8. BBR 优化
# ============================================================
do_bbr() {
    clear
    echo ""
    hr
    echo -e "  ${BOLD}${C} BBR Blast Smooth 深度调优${NC}"
    hr
    echo ""

    info "1/4. 正在清理系统中已存在的旧 BBR 与 TCP 优化参数及注释..."
    if [[ -f /etc/sysctl.conf ]]; then
        # 1. 尝试使用全新起止标记进行整块清理 (防止多次运行时中文注释及变量叠加)
        sed -i '/# === SNELL_SYSCTL_START ===/,/# === SNELL_SYSCTL_END ===/d' /etc/sysctl.conf
        sed -i '/# === SNELL_BBR_START ===/,/# === SNELL_BBR_END ===/d' /etc/sysctl.conf

        # 2. 清洗可能存在的任何变体旧中文注释（避免以前重复写入留下的注释叠加）
        local chinese_keywords=(
            "文件句柄" "并发" "网络队列" "连接优化" "拥塞控制" "窗口与缓冲区"
            "大带宽" "长距离" "IPv6" "路由缓存" "邻居表" "时间戳" "连接回收"
            "安全与转发" "其他辅助" "BBR" "SNELL_SYSCTL" "大缓冲区" "跑满"
            "足够跑满" "丢包卡顿" "短连接" "延迟优化" "历史 RTT" "历史RTT"
            "突发灵活" "平滑暴力" "BBR Blast" "平滑暴力版"
        )
        for kw in "${chinese_keywords[@]}"; do
            sed -i "/${kw}/d" /etc/sysctl.conf
        done

        # 3. 清理对应的配置项，包含可能存在冲突的第三方 TCP/BBR 配置键名
        local keys=(
            "fs.file-max" "fs.nr_open"
            "net.core.somaxconn" "net.ipv4.tcp_max_syn_backlog" "net.ipv4.tcp_abort_on_overflow"
            "net.ipv4.ip_local_port_range" "net.core.netdev_max_backlog" "net.ipv4.tcp_max_tw_buckets"
            "net.core.default_qdisc" "net.ipv4.tcp_congestion_control" "net.ipv4.tcp_fastopen"
            "net.ipv4.tcp_window_scaling" "net.ipv4.tcp_adv_win_scale" "net.ipv4.tcp_moderate_rcvbuf"
            "net.core.rmem_max" "net.core.wmem_max" "net.core.rmem_default" "net.core.wmem_default"
            "net.ipv4.tcp_rmem" "net.ipv4.tcp_wmem" "net.ipv4.tcp_mem"
            "net.ipv4.udp_rmem_min" "net.ipv4.udp_wmem_min" "net.ipv4.udp_mem"
            "net.ipv6.conf.all.disable_ipv6" "net.ipv6.conf.default.disable_ipv6" "net.ipv6.conf.lo.disable_ipv6"
            "net.ipv6.conf.all.forwarding" "net.ipv6.conf.default.forwarding"
            "net.ipv6.route.max_size" "net.ipv6.neigh.default.gc_thresh"
            "net.ipv6.neigh.default.gc_thresh1" "net.ipv6.neigh.default.gc_thresh2" "net.ipv6.neigh.default.gc_thresh3"
            "net.ipv4.tcp_timestamps" "net.ipv4.tcp_tw_reuse" "net.ipv4.tcp_tw_recycle" "net.ipv4.tcp_fin_timeout"
            "net.ipv4.tcp_slow_start_after_idle"
            "net.ipv4.conf.all.rp_filter" "net.ipv4.conf.default.rp_filter" "net.ipv4.ip_forward"
            "net.ipv4.conf.all.route_localnet" "net.ipv4.tcp_rfc1337" "net.ipv4.tcp_ecn"
            "net.ipv4.tcp_syncookies"
            "net.ipv4.tcp_no_metrics_save" "net.ipv4.tcp_sack" "net.ipv4.tcp_fack" "net.ipv4.tcp_dsack" "net.ipv4.tcp_mtu_probing"
        )
        for key in "${keys[@]}"; do
            sed -i "/^[[:space:]#]*${key}[[:space:]]*=/d" /etc/sysctl.conf
        done

        # 4. 清除多余的连续空白行
        sed -i '/^$/N;/^\n$/D' /etc/sysctl.conf
        ok "旧优化参数及注释清理完成。"

        # 5. 扫描并注释 /etc/sysctl.d/ 目录下所有配置文件中可能覆盖新配置的同名冲突参数
        if [[ -d /etc/sysctl.d ]]; then
            local conf_files
            conf_files=$(find /etc/sysctl.d -name "*.conf" 2>/dev/null || true)
            if [[ -n "$conf_files" ]]; then
                for f in $conf_files; do
                    local file_has_conflict=false
                    for key in "${keys[@]}"; do
                        if grep -qE "^[[:space:]]*${key}[[:space:]]*=" "$f" 2>/dev/null; then
                            sed -i "s|^\([[:space:]]*${key}[[:space:]]*=.*\)|# \1 # 与 Snell BBR 冲突，由脚本自动注释|" "$f" 2>/dev/null || true
                            file_has_conflict=true
                        fi
                    done
                    if [[ "$file_has_conflict" == "true" ]]; then
                        info "在目录 /etc/sysctl.d/ 中的配置文件 [$(basename "$f")] 中检测到同名冲突参数，已自动注释屏蔽以防新配置失效。"
                    fi
                done
            fi
        fi
    fi

    # 确保文件末尾有换行符
    [[ -f /etc/sysctl.conf ]] && sed -i '$a\' /etc/sysctl.conf

    info "2/4. 启用并配置 BBR 模块开机自启..."
    modprobe tcp_bbr 2>/dev/null || true
    mkdir -p /etc/modules-load.d
    echo "tcp_bbr" > /etc/modules-load.d/bbr.conf 2>/dev/null || true

    info "3/4. 写入 BBR Blast Smooth (平滑暴力版) 参数..."
    cat << EOF >> /etc/sysctl.conf
# === SNELL_BBR_START ===
# === BBR Blast Smooth (平滑暴力版) ===
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr

# 大缓冲区 (64MB) - 足够跑满 1G，不至于丢包卡顿
net.core.rmem_max=67108864
net.core.wmem_max=67108864
net.ipv4.tcp_rmem=4096 87380 67108864
net.ipv4.tcp_wmem=4096 65536 67108864

# 短连接 & 延迟优化
net.ipv4.tcp_fin_timeout=8
net.ipv4.tcp_tw_reuse=1
net.ipv4.tcp_window_scaling=1
net.ipv4.tcp_timestamps=1
net.ipv4.tcp_sack=1

# 避免保存历史 RTT，保持突发灵活
net.ipv4.tcp_no_metrics_save=1
# === SNELL_BBR_END ===
EOF

    info "4/4. 正在应用内核优化参数 (sysctl -p)..."
    echo ""
    sysctl -p &>/dev/null || true
    sysctl --system &>/dev/null || true
    echo ""

    local current_cc=""
    current_cc=$(sysctl net.ipv4.tcp_congestion_control 2>/dev/null | awk -F= '{print $2}' | tr -d '[:space:]' || echo "")
    if [[ "$current_cc" == "bbr" ]]; then
        ok "BBR 优化参数已成功应用！当前系统拥塞控制算法已切换为: ${G}${current_cc}${NC}"
    else
        warn "BBR 优化已应用，但当前拥塞控制算法为: ${Y}${current_cc:-未知}${NC}，请检查内核是否支持。"
    fi
    echo ""
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
    
    # 2. 检查同步服务运行状态
    local service_active=false
    if systemctl is-active --quiet chrony 2>/dev/null || systemctl is-active --quiet chronyd 2>/dev/null; then
        service_active=true
    fi

    # 3. 检查有无运行中的冲突时间同步服务
    local conflict_detected=false
    if systemctl is-active --quiet systemd-timesyncd 2>/dev/null || systemctl is-active --quiet ntp 2>/dev/null || systemctl is-active --quiet ntpd 2>/dev/null; then
        conflict_detected=true
    fi

    # 4. 如果时区和同步服务已经配置完毕，且没有冲突服务在运行，询问是否需要重新安装
    if [[ "$cur_tz" == "Asia/Shanghai" && "$service_active" == "true" && "$conflict_detected" == "false" ]]; then
        ok "检测到系统已配置 Asia/Shanghai 时区，且时间同步服务正常，无其他冲突服务！"
        echo -e "  系统当前时间: $(date)"
        echo ""
        clear_stdin
        local sync_reinstall=""
        read -rp "  是否要重新安装并净化时间同步服务？(y/N) [默认 N]: " sync_reinstall
        local sync_reinstall_val="${sync_reinstall:-n}"
        if [[ "$sync_reinstall_val" != "y" && "$sync_reinstall_val" != "Y" ]]; then
            return
        fi

        info "正在清除当前系统关于时间同步的所有数据与残留..."
        systemctl disable --now chrony 2>/dev/null || true
        systemctl disable --now chronyd 2>/dev/null || true

        if command -v apt-get &>/dev/null; then
            apt-get purge -y chrony &>/dev/null || true
            apt-get autoremove -y &>/dev/null || true
        elif command -v dnf &>/dev/null; then
            dnf remove -y chrony &>/dev/null || true
        elif command -v yum &>/dev/null; then
            yum remove -y chrony &>/dev/null || true
        elif command -v pacman &>/dev/null; then
            pacman -Rns --noconfirm chrony &>/dev/null || true
        fi

        rm -rf /etc/chrony /etc/chrony.conf /etc/chrony/chrony.conf /etc/chrony.keys /var/lib/chrony /var/log/chrony 2>/dev/null || true
        ok "时间同步服务已彻底清除！"
        echo ""
    fi

    # 5. 检测是否是容器环境 (LXC/OpenVZ/Docker)
    local is_container=false
    local virt_type=""
    if command -v systemd-detect-virt &>/dev/null; then
        virt_type=$(systemd-detect-virt 2>/dev/null || true)
        if [[ "$virt_type" == "lxc" || "$virt_type" == "openvz" || "$virt_type" == "docker" || "$virt_type" == "container" ]]; then
            is_container=true
        fi
    fi

    info "开始系统时间深度优化与冲突排查..."
    echo ""

    info "1/4. 固定系统时区为 Asia/Shanghai..."
    timedatectl set-timezone Asia/Shanghai 2>/dev/null || true

    if [ "$is_container" = true ]; then
        warn "检测到当前处于容器虚拟化环境 (${virt_type})，容器内无权直接修改内核系统时钟。"
        info "时区已为您切换为 Asia/Shanghai，时钟精度将完全依赖您的宿主机环境。"
        echo -e "  系统当前时间: $(date)"
        echo ""
        pause
        return
    fi

    # 6. 自动禁用并清理冲突服务，防止端口和时钟控制权争抢
    info "2/4. 检查并清理冲突的时间同步服务..."
    if systemctl is-active --quiet systemd-timesyncd 2>/dev/null; then
        warn "检测到冲突服务 systemd-timesyncd 正在运行，正在将其停用并禁用..."
        systemctl disable --now systemd-timesyncd &>/dev/null || true
    fi
    if systemctl is-active --quiet ntp 2>/dev/null; then
        warn "检测到冲突服务 ntp 正在运行，正在将其停用并禁用..."
        systemctl disable --now ntp &>/dev/null || true
    fi
    if systemctl is-active --quiet ntpd 2>/dev/null; then
        warn "检测到冲突服务 ntpd 正在运行，正在将其停用并禁用..."
        systemctl disable --now ntpd &>/dev/null || true
    fi
    
    # 7. 安装与配置 Chrony
    info "3/4. 正在安装并配置 chrony..."
    if command -v apt-get &>/dev/null; then
        apt-get update -qq && apt-get install -y chrony -qq
    elif command -v dnf &>/dev/null; then
        dnf install -y -q chrony
    elif command -v yum &>/dev/null; then
        yum install -y -q chrony
    elif command -v pacman &>/dev/null; then
        pacman -Sy --noconfirm chrony
    fi

    # 检测 IP 归属地，决定最优 NTP 服务器配置
    local country=""
    info "正在检测当前主机的公网 IP 归属以配置最优 NTP 服务器..."
    country=$(curl -sL --max-time 3 https://ipinfo.io/country | tr -d '[:space:]' | tr '[:lower:]' '[:upper:]' || true)
    if [[ -z "$country" ]]; then
        country=$(curl -sL --max-time 3 https://ipapi.co/country/ | tr -d '[:space:]' | tr '[:lower:]' '[:upper:]' || true)
    fi

    local chrony_conf="/etc/chrony.conf"
    [[ -d /etc/chrony ]] && chrony_conf="/etc/chrony/chrony.conf"

    if [[ "$country" == "CN" ]]; then
        ok "检测到当前主机为中国大陆 IP (${country})，配置国内高精度源..."
        cat <<EOF > "$chrony_conf"
# 国内机器最优授时源
server ntp.aliyun.com iburst prefer
server ntp.tencent.com iburst
server ntp.ntsc.ac.cn iburst
driftfile /var/lib/chrony/chrony.drift
logdir /var/log/chrony
maxupdateskew 100.0
rtcsync
makestep 1.0 -1
EOF
    else
        ok "检测到当前主机为海外 IP (${country:-未知})，配置全球任播 Anycast 授时源..."
        cat <<EOF > "$chrony_conf"
# 海外/美国机器最优全球任播源
server time.google.com iburst prefer
server time.cloudflare.com iburst
server time.apple.com iburst
# 备用国内高精度大厂源
server ntp.aliyun.com iburst
driftfile /var/lib/chrony/chrony.drift
logdir /var/log/chrony
maxupdateskew 100.0
rtcsync
makestep 1.0 -1
EOF
    fi

    # 8. 启动与配置 Chrony 服务并强制对时
    info "4/4. 启动并配置 chrony 自动对时服务..."
    local svc_name="chrony"
    if ! systemctl list-unit-files | grep -q "^chrony.service" 2>/dev/null; then
        if systemctl list-unit-files | grep -q "^chronyd.service" 2>/dev/null; then
            svc_name="chronyd"
        fi
    fi

    systemctl enable "$svc_name" &>/dev/null || true
    systemctl restart "$svc_name" &>/dev/null || true
    sleep 2
    
    # 显式让 systemd 允许网络对时，并立即执行步进校准
    timedatectl set-ntp true 2>/dev/null || true
    chronyc -a makestep &>/dev/null || true

    ok "时间深度同步与冲突清理完成！"
    
    # 尝试获取并打印当前时间偏差值 (System time offset)
    local offset=""
    if command -v chronyc &>/dev/null; then
        offset=$(chronyc tracking 2>/dev/null | grep -i "System time" | sed -E 's/^[[:space:]]+//' || true)
    fi
    if [[ -n "$offset" ]]; then
        info "对时偏差精度: ${offset}"
    fi

    echo -e "  系统当前时间: $(date)"
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
            trap 'rm -rf "$tmp" 2>/dev/null; trap - EXIT' EXIT
            
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
                    pkill -9 -x "snell-server-${SUFFIX}" 2>/dev/null || true
                    
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
            trap - EXIT
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

    # 临时 Swap 自适应机制，解决小内存 VPS 因内存耗尽导致进程被系统强杀 (Killed) 的痛点
    local mem_total=0
    local swap_total=0
    if [[ -f /proc/meminfo ]]; then
        mem_total=$(grep MemTotal /proc/meminfo | awk '{print $2}')
        mem_total=$(( mem_total / 1024 ))
        swap_total=$(grep SwapTotal /proc/meminfo | awk '{print $2}')
        swap_total=$(( swap_total / 1024 ))
    fi

    if [[ "$mem_total" -gt 0 && "$mem_total" -lt 800 && "$swap_total" -eq 0 ]]; then
        local virt=""
        if command -v systemd-detect-virt &>/dev/null; then
            virt=$(systemd-detect-virt 2>/dev/null || echo "")
        fi
        if [[ "$virt" != "lxc" && "$virt" != "openvz" && "$virt" != "docker" && "$virt" != "container" ]]; then
            info "检测到系统物理内存较小 (${mem_total}MB) 且未配置 Swap，为防止安装进程被系统强杀 (Killed)，正在建立 1GB 临时虚拟内存..."
            if dd if=/dev/zero of=/var/swapfile bs=1M count=1024 &>/dev/null; then
                chmod 600 /var/swapfile
                mkswap /var/swapfile &>/dev/null
                if swapon /var/swapfile &>/dev/null; then
                    ok "临时 Swap 启用成功！脚本退出时会自动释放并物理删除该缓存文件。"
                    trap 'swapoff /var/swapfile 2>/dev/null || true; rm -f /var/swapfile; trap - EXIT' EXIT
                else
                    rm -f /var/swapfile
                fi
            fi
        fi
    fi
    
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

    # 智能扫描并自动接管非标安装的旧 Snell 实例
    scan_external_snell
    
    while true; do
        show_menu
        read -rp "  选择 [0-11]: " ch
        case "$ch" in
            1) do_install ;;
            2) do_update ;;
            3) do_uninstall ;;
            4) do_bbr ;;
            5) do_sync_time ;;
            6) do_cron_menu ;;
            7) do_modify ;;
            8) do_show ;;
            9) do_restart ;;
            10) do_logs ;;
            11) update_self ;;
            0) echo ""; info "再见"; echo ""; exit 0 ;;
            *) warn "无效选项"; sleep 0.3 ;;
        esac
    done
}

main "$@"

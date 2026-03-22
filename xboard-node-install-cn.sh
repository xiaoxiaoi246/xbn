#!/bin/bash
# ============================================================
#   Xboard-Node 中文交互式管理脚本 v2.0
#   项目: https://github.com/cedar2025/Xboard-Node
#   用法: bash 脚本名              → 交互菜单
#         xbn                      → 快捷打开菜单
#         xbn list                 → 查看节点状态
#         xbn log  <id>            → 实时日志
#         xbn start|stop|restart <id>|all  → 控制节点
#         xbn add                  → 添加节点
#         xbn del  <id>            → 删除节点
#         xbn edit <id>            → 修改配置
#         xbn update               → 更新程序
# ============================================================

# set -e 去掉，避免子命令非零退出时整体退出
# 颜色（tput 方式，无转义字符残留）
if command -v tput >/dev/null 2>&1 && tput setaf 1 >/dev/null 2>&1; then
    R=$(tput setaf 1); G=$(tput setaf 2); Y=$(tput setaf 3)
    B=$(tput setaf 4); C=$(tput setaf 6); M=$(tput setaf 5)
    BOLD=$(tput bold); NC=$(tput sgr0)
else
    R=""; G=""; Y=""; B=""; C=""; M=""; BOLD=""; NC=""
fi

# ─── 常量 ──────────────────────────────────────────────────────
INSTALL_DIR="/usr/local/bin"
CONFIG_DIR="/etc/xboard-node"
SERVICE_TEMPLATE="xboard-node@.service"
DOCKER_IMAGE="ghcr.io/cedar2025/xboard-node:latest"
GITHUB_RAW="https://github.com/cedar2025/Xboard-Node/releases/latest/download"
SELF_PATH="/usr/local/bin/xboard-node-install-cn.sh"
SHORTCUT="/usr/local/bin/xbn"

# ─── 日志 ──────────────────────────────────────────────────────
ok()    { echo "${G}[OK]${NC} $*"; }
warn()  { echo "${Y}[!!]${NC} $*"; }
err()   { echo "${R}[ER]${NC} $*"; }
step()  { echo ""; echo "${C}${BOLD}>>> $*${NC}"; }
line()  { echo "${B}--------------------------------------------------${NC}"; }
title() { echo "${C}${BOLD}$*${NC}"; }

# ─── 权限检查 ─────────────────────────────────────────────────
check_root() {
    [ "$(id -u)" = "0" ] && return
    err "请使用 root 用户运行（sudo bash $0）"
    exit 1
}

# ─── 自动注册快捷指令 ─────────────────────────────────────────
auto_shortcut() {
    [ "$(id -u)" != "0" ] && return
    local src
    src=$(realpath "$0" 2>/dev/null || readlink -f "$0" 2>/dev/null || echo "$0")
    # 脚本复制到固定路径
    if [ ! -f "$SELF_PATH" ] || ! cmp -s "$src" "$SELF_PATH" 2>/dev/null; then
        cp "$src" "$SELF_PATH" 2>/dev/null && chmod +x "$SELF_PATH" || true
    fi
    # 写入 xbn 入口
    if [ ! -f "$SHORTCUT" ]; then
        printf '#!/bin/bash\nexec bash %s "$@"\n' "$SELF_PATH" > "$SHORTCUT"
        chmod +x "$SHORTCUT" 2>/dev/null || true
    fi
}

# ─── 架构 / 系统检测 ──────────────────────────────────────────
detect_arch() {
    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64|amd64)  ARCH="amd64" ;;
        aarch64|arm64) ARCH="arm64" ;;
        armv7l)        ARCH="armv7" ;;
        *) err "不支持的架构: $ARCH"; exit 1 ;;
    esac
}

detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release; OS=$ID; OS_VER=${VERSION_ID:-""}
    elif [ -f /etc/alpine-release ]; then
        OS="alpine"; OS_VER=$(cat /etc/alpine-release)
    else
        OS="unknown"; OS_VER=""
    fi
}

install_deps() {
    case "$OS" in
        ubuntu|debian)          apt-get update -qq 2>/dev/null; apt-get install -y -qq wget curl tar >/dev/null 2>&1 ;;
        centos|rhel|rocky|almalinux|fedora) yum install -y -q wget curl tar >/dev/null 2>&1 ;;
        alpine)                 apk add --no-cache wget curl tar >/dev/null 2>&1 ;;
    esac
}

# ─── 面板连通性检测 ───────────────────────────────────────────
check_panel() {
    local url="$1"
    printf "  检测面板连通性..."
    local code
    code=$(curl -sk -o /dev/null -w "%{http_code}" --connect-timeout 6 "${url}" 2>/dev/null || echo "000")
    if [ "$code" = "000" ]; then
        echo " ${R}无法连接${NC} (超时或域名无效)"
        printf "  仍要继续？[y/N]: "
        read -r C2; [ "$C2" = "y" ] || [ "$C2" = "Y" ] || { warn "已取消"; exit 0; }
    elif echo "$code" | grep -qE '^[45]'; then
        echo " ${Y}HTTP ${code}${NC}（面板可达，但返回错误，继续安装）"
    else
        echo " ${G}HTTP ${code} 正常${NC}"
    fi
}

# ─── 下载二进制 ───────────────────────────────────────────────
install_binary() {
    if [ -x "${INSTALL_DIR}/xboard-node" ]; then
        ok "xboard-node 已安装，跳过下载"; return
    fi
    step "下载 xboard-node..."
    local src=""
    [ -f "./xboard-node" ]               && src="./xboard-node"
    [ -f "./xboard-node-linux-${ARCH}" ] && src="./xboard-node-linux-${ARCH}"
    if [ -n "$src" ]; then
        cp "$src" "${INSTALL_DIR}/xboard-node"
        ok "从本地文件安装: $src"
    else
        local url="${GITHUB_RAW}/xboard-node-linux-${ARCH}"
        ok "下载: $url"
        if wget -q "$url" -O "${INSTALL_DIR}/xboard-node" 2>/dev/null || \
           curl -fsSL "$url" -o "${INSTALL_DIR}/xboard-node" 2>/dev/null; then
            ok "下载完成"
        else
            err "下载失败！请检查网络"; exit 1
        fi
    fi
    chmod +x "${INSTALL_DIR}/xboard-node"
}

# ─── systemd 模板 ─────────────────────────────────────────────
install_systemd_template() {
    command -v systemctl >/dev/null 2>&1 || return
    [ -f "/etc/systemd/system/${SERVICE_TEMPLATE}" ] && return
    cat > "/etc/systemd/system/${SERVICE_TEMPLATE}" << 'UNIT'
[Unit]
Description=Xboard Node Backend (node %i)
After=network.target nss-lookup.target

[Service]
Type=simple
ExecStart=/usr/local/bin/xboard-node -c /etc/xboard-node/%i/config.yml
Restart=always
RestartSec=5
LimitNOFILE=1048576
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
UNIT
    systemctl daemon-reload
}

# ─── 写配置文件 ───────────────────────────────────────────────
write_node_config() {
    local nid="$1"
    local dir="${CONFIG_DIR}/${nid}"
    mkdir -p "$dir"
    local type_line=""
    [ -n "$NODE_TYPE" ] && type_line="  node_type: \"${NODE_TYPE}\""
    cat > "${dir}/config.yml" << EOF
panel:
  url: "${PANEL_URL}"
  token: "${PANEL_TOKEN}"
  node_id: ${nid}
${type_line}

node:
  push_interval: 0
  pull_interval: 0

kernel:
  type: "${KERNEL_TYPE}"
  config_dir: "${dir}"
  log_level: "warn"

log:
  level: "info"
  output: "stdout"
EOF
    ok "配置已写入: ${dir}/config.yml"
}

# ─── 旧版迁移 ─────────────────────────────────────────────────
migrate_legacy() {
    [ -f "${CONFIG_DIR}/config.yml" ] || return
    [ -d "${CONFIG_DIR}/config.yml" ] && return
    local lid
    lid=$(grep -E '^\s*node_id:' "${CONFIG_DIR}/config.yml" 2>/dev/null | head -1 | sed 's/[^0-9]*//g')
    [ -z "$lid" ] && lid="1"
    [ -d "${CONFIG_DIR}/${lid}" ] && return
    warn "迁移旧版配置 → 节点 ${lid}..."
    mkdir -p "${CONFIG_DIR}/${lid}"
    mv "${CONFIG_DIR}/config.yml" "${CONFIG_DIR}/${lid}/config.yml"
    if command -v systemctl >/dev/null 2>&1; then
        systemctl stop xboard-node 2>/dev/null || true
        systemctl disable xboard-node 2>/dev/null || true
        rm -f /etc/systemd/system/xboard-node.service
        install_systemd_template
        systemctl enable "xboard-node@${lid}" 2>/dev/null || true
        systemctl start  "xboard-node@${lid}" 2>/dev/null || true
    fi
    ok "迁移完成"
}

# ─── Docker Compose ───────────────────────────────────────────
regen_compose() {
    local nodes=()
    for d in "${CONFIG_DIR}"/*/; do
        [ -f "${d}config.yml" ] && nodes+=("$(basename "$d")")
    done
    [ ${#nodes[@]} -eq 0 ] && { rm -f "${CONFIG_DIR}/docker-compose.yml"; return; }
    printf '# 自动生成，请勿手动修改\nservices:\n' > "${CONFIG_DIR}/docker-compose.yml"
    for nid in "${nodes[@]}"; do
        cat >> "${CONFIG_DIR}/docker-compose.yml" << EOF

  node-${nid}:
    image: ${DOCKER_IMAGE}
    container_name: xboard-node-${nid}
    restart: always
    network_mode: host
    volumes:
      - ./${nid}/config.yml:/etc/xboard-node/config.yml:ro
      - ./${nid}:/etc/xboard-node/data
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"
EOF
    done
}

# ─── 获取节点列表 ─────────────────────────────────────────────
get_node_ids() {
    NODE_IDS=()
    for d in "${CONFIG_DIR}"/*/; do
        [ -f "${d}config.yml" ] && NODE_IDS+=("$(basename "$d")")
    done
}

# ─── 节点状态（含运行时长）────────────────────────────────────
node_status() {
    local nid="$1"
    local status="${R}停止${NC}"
    local uptime_str=""

    if command -v systemctl >/dev/null 2>&1; then
        if systemctl is-active "xboard-node@${nid}" >/dev/null 2>&1; then
            status="${G}运行中${NC}(systemd)"
            # 获取运行时长
            local start_ts
            start_ts=$(systemctl show "xboard-node@${nid}" --property=ActiveEnterTimestamp 2>/dev/null \
                       | sed 's/ActiveEnterTimestamp=//')
            if [ -n "$start_ts" ] && command -v date >/dev/null 2>&1; then
                local now_ts start_epoch
                now_ts=$(date +%s 2>/dev/null)
                start_epoch=$(date -d "$start_ts" +%s 2>/dev/null || echo "")
                if [ -n "$start_epoch" ] && [ "$start_epoch" -gt 0 ] 2>/dev/null; then
                    local diff=$(( now_ts - start_epoch ))
                    local h=$(( diff/3600 )) m=$(( (diff%3600)/60 ))
                    uptime_str="  已运行: ${h}h ${m}m"
                fi
            fi
        fi
    fi
    if command -v docker >/dev/null 2>&1; then
        if docker inspect -f '{{.State.Running}}' "xboard-node-${nid}" 2>/dev/null | grep -q true; then
            status="${G}运行中${NC}(docker)"
            local started
            started=$(docker inspect -f '{{.State.StartedAt}}' "xboard-node-${nid}" 2>/dev/null | cut -c1-19 | tr 'T' ' ')
            if [ -n "$started" ]; then
                local now_ts start_epoch
                now_ts=$(date +%s 2>/dev/null)
                start_epoch=$(date -d "$started" +%s 2>/dev/null || echo "")
                if [ -n "$start_epoch" ] && [ "$start_epoch" -gt 0 ] 2>/dev/null; then
                    local diff=$(( now_ts - start_epoch ))
                    local h=$(( diff/3600 )) m=$(( (diff%3600)/60 ))
                    uptime_str="  已运行: ${h}h ${m}m"
                fi
            fi
        fi
    fi
    echo "$status|$uptime_str"
}

# ─── 状态总览（主界面展示）──────────────────────────────────
show_status_bar() {
    get_node_ids
    if [ ${#NODE_IDS[@]} -eq 0 ]; then
        echo "  ${Y}暂无节点${NC}  输入 1 安装第一个节点"
        return
    fi
    for nid in "${NODE_IDS[@]}"; do
        local cfg="${CONFIG_DIR}/${nid}/config.yml"
        local panel_url kernel st_raw status uptime_str
        panel_url=$(grep -E '^\s*url:' "$cfg" 2>/dev/null | head -1 | sed "s/.*url:[[:space:]]*[\"']\\?\\([^\"']*\\)[\"']\\?.*/\\1/")
        kernel=$(grep -E '^\s*type:' "$cfg" 2>/dev/null | head -1 | sed "s/.*type:[[:space:]]*[\"']\\?\\([^\"']*\\)[\"']\\?.*/\\1/")
        st_raw=$(node_status "$nid")
        status=$(echo "$st_raw" | cut -d'|' -f1)
        uptime_str=$(echo "$st_raw" | cut -d'|' -f2)
        echo "  节点 ${BOLD}${nid}${NC}  ${status}${uptime_str}"
        echo "  内核: ${kernel:-singbox}  面板: ${panel_url:-未知}"
        echo ""
    done
}

# ─── 交互收集安装参数 ─────────────────────────────────────────
collect_params() {
    step "节点参数配置"; line

    # 面板地址
    while true; do
        printf "  面板地址 (https://...): "
        read -r PANEL_URL; PANEL_URL="${PANEL_URL%/}"
        echo "$PANEL_URL" | grep -qE '^https?://' && break
        warn "格式不正确，需包含 http:// 或 https://"
    done

    # 连通性检测
    check_panel "$PANEL_URL"

    # Token
    while true; do
        printf "  服务器 Token: "
        read -r PANEL_TOKEN
        [ -n "$PANEL_TOKEN" ] && break
        warn "Token 不能为空"
    done

    # 节点 ID
    while true; do
        printf "  节点 ID (正整数): "
        read -r NODE_ID
        echo "$NODE_ID" | grep -qE '^[0-9]+$' && [ "$NODE_ID" -gt 0 ] && break
        warn "必须是正整数"
    done

    # 节点类型
    printf "  节点类型 (可选，回车跳过): "
    read -r NODE_TYPE

    # 内核
    echo ""
    echo "  内核类型:"
    echo "    1) sing-box  (推荐，支持更多协议)"
    echo "    2) xray      (传统方案)"
    printf "  请选择 [1/2，默认1]: "
    read -r _kc
    [ "$_kc" = "2" ] && KERNEL_TYPE="xray" || KERNEL_TYPE="singbox"

    # 部署方式
    echo ""
    echo "  部署方式:"
    echo "    1) systemd  (推荐，系统服务)"
    echo "    2) Docker   (容器化)"
    printf "  请选择 [1/2，默认1]: "
    read -r _dc
    [ "$_dc" = "2" ] && DOCKER_MODE=1 || DOCKER_MODE=0

    # 确认
    echo ""
    line
    echo "  配置确认:"
    echo "  面板地址 : ${PANEL_URL}"
    echo "  Token    : ${PANEL_TOKEN:0:8}********"
    echo "  节点 ID  : ${NODE_ID}"
    [ -n "$NODE_TYPE" ] && echo "  节点类型 : ${NODE_TYPE}"
    echo "  内核     : ${KERNEL_TYPE}"
    [ "$DOCKER_MODE" -eq 1 ] && echo "  部署方式 : Docker" || echo "  部署方式 : systemd"
    line
    printf "  确认安装？[Y/n]: "
    read -r CF
    [ "$CF" = "n" ] || [ "$CF" = "N" ] && { warn "已取消"; exit 0; }
}

# ─── 启动节点（systemd）──────────────────────────────────────
start_node_native() {
    local nid="$1"
    install_systemd_template
    systemctl enable "xboard-node@${nid}" 2>/dev/null
    systemctl start  "xboard-node@${nid}" 2>/dev/null
    ok "节点 ${nid} 已启动 (systemd)"
}

# ─── 启动节点（Docker）───────────────────────────────────────
get_compose_cmd() {
    if docker compose version >/dev/null 2>&1; then echo "docker compose"
    elif command -v docker-compose >/dev/null 2>&1; then echo "docker-compose"
    else echo ""; fi
}

start_node_docker() {
    local nid="$1"
    local cmd; cmd=$(get_compose_cmd)
    if [ -z "$cmd" ]; then
        warn "未找到 docker compose，请手动启动"; return
    fi
    cd "${CONFIG_DIR}" && ${cmd} up -d "node-${nid}"
    ok "节点 ${nid} 已启动 (Docker)"
}

# ─── 安装新节点 ───────────────────────────────────────────────
cmd_add() {
    check_root; detect_arch; detect_os; install_deps
    mkdir -p "$CONFIG_DIR"; migrate_legacy
    collect_params
    step "开始安装..."

    if [ -d "${CONFIG_DIR}/${NODE_ID}" ]; then
        err "节点 ${NODE_ID} 已存在，请先删除再重装"; return
    fi

    if [ "$DOCKER_MODE" -eq 0 ]; then
        install_binary
        write_node_config "$NODE_ID"
        start_node_native "$NODE_ID"
    else
        if ! command -v docker >/dev/null 2>&1; then
            step "安装 Docker..."
            curl -fsSL https://get.docker.com | sh
            systemctl enable docker && systemctl start docker
            ok "Docker 安装完成"
        fi
        write_node_config "$NODE_ID"
        regen_compose
        start_node_docker "$NODE_ID"
    fi

    auto_shortcut
    echo ""
    line
    ok "节点 ${NODE_ID} 安装完成！"
    line
    echo "  快捷操作:"
    echo "  xbn list          查看所有节点状态"
    echo "  xbn log  ${NODE_ID}       实时日志"
    echo "  xbn restart ${NODE_ID}    重启节点"
    echo "  xbn edit ${NODE_ID}       修改配置"
    line; echo ""
}

# ─── 查看节点状态 ─────────────────────────────────────────────
cmd_list() {
    get_node_ids
    echo ""
    title "  节点状态总览"
    line
    if [ ${#NODE_IDS[@]} -eq 0 ]; then
        warn "暂无节点，运行 xbn add 安装"
        line; return
    fi
    for nid in "${NODE_IDS[@]}"; do
        local cfg="${CONFIG_DIR}/${nid}/config.yml"
        local panel_url kernel st_raw status uptime_str
        panel_url=$(grep -E '^\s*url:' "$cfg" 2>/dev/null | head -1 | sed "s/.*url:[[:space:]]*[\"']\\?\\([^\"']*\\)[\"']\\?.*/\\1/")
        kernel=$(grep -E '^\s*type:' "$cfg" 2>/dev/null | head -1 | sed "s/.*type:[[:space:]]*[\"']\\?\\([^\"']*\\)[\"']\\?.*/\\1/")
        st_raw=$(node_status "$nid")
        status=$(echo "$st_raw" | cut -d'|' -f1)
        uptime_str=$(echo "$st_raw" | cut -d'|' -f2)
        echo "  节点 ${BOLD}${nid}${NC}  ${status}${uptime_str}"
        echo "  内核: ${kernel:-singbox}  面板: ${panel_url:-未知}"
        echo "  操作: xbn log ${nid}  xbn restart ${nid}  xbn stop ${nid}  xbn edit ${nid}"
        line
    done
    echo ""
}

# ─── 实时日志 ─────────────────────────────────────────────────
cmd_log() {
    local nid="$1"
    if [ -z "$nid" ]; then
        get_node_ids
        if [ ${#NODE_IDS[@]} -eq 0 ]; then warn "暂无节点"; return; fi
        if [ ${#NODE_IDS[@]} -eq 1 ]; then
            nid="${NODE_IDS[0]}"
        else
            cmd_list
            printf "  请输入节点 ID: "
            read -r nid
        fi
    fi
    echo "  ${C}节点 ${nid} 日志 (Ctrl+C 退出)${NC}"
    line
    if command -v systemctl >/dev/null 2>&1 && \
       systemctl is-active "xboard-node@${nid}" >/dev/null 2>&1; then
        journalctl -u "xboard-node@${nid}" -f --no-pager
    elif command -v docker >/dev/null 2>&1 && \
         docker inspect "xboard-node-${nid}" >/dev/null 2>&1; then
        docker logs -f "xboard-node-${nid}"
    else
        err "节点 ${nid} 未运行或不存在"
    fi
}

# ─── 控制节点（start/stop/restart）──────────────────────────
ctrl_node() {
    local action="$1" nid="$2"

    # nid 为 all 则批量操作
    local targets=()
    if [ "$nid" = "all" ] || [ -z "$nid" ]; then
        get_node_ids; targets=("${NODE_IDS[@]}")
    else
        targets=("$nid")
    fi

    [ ${#targets[@]} -eq 0 ] && { warn "暂无节点"; return; }

    for id in "${targets[@]}"; do
        local svc="xboard-node@${id}"
        case "$action" in
            start)
                if command -v systemctl >/dev/null 2>&1; then
                    systemctl start "$svc" 2>/dev/null && ok "节点 ${id} 已启动" || err "启动失败"
                elif command -v docker >/dev/null 2>&1; then
                    docker start "xboard-node-${id}" 2>/dev/null && ok "节点 ${id} 已启动" || err "启动失败"
                fi
                ;;
            stop)
                if command -v systemctl >/dev/null 2>&1; then
                    systemctl stop "$svc" 2>/dev/null && ok "节点 ${id} 已停止" || err "停止失败"
                elif command -v docker >/dev/null 2>&1; then
                    docker stop "xboard-node-${id}" 2>/dev/null && ok "节点 ${id} 已停止" || err "停止失败"
                fi
                ;;
            restart)
                if command -v systemctl >/dev/null 2>&1; then
                    systemctl restart "$svc" 2>/dev/null && ok "节点 ${id} 已重启" || err "重启失败"
                elif command -v docker >/dev/null 2>&1; then
                    docker restart "xboard-node-${id}" 2>/dev/null && ok "节点 ${id} 已重启" || err "重启失败"
                fi
                ;;
        esac
    done
}

# ─── 修改配置 ─────────────────────────────────────────────────
cmd_edit() {
    local nid="$1"
    if [ -z "$nid" ]; then
        get_node_ids
        if [ ${#NODE_IDS[@]} -eq 0 ]; then warn "暂无节点"; return; fi
        if [ ${#NODE_IDS[@]} -eq 1 ]; then
            nid="${NODE_IDS[0]}"
        else
            cmd_list
            printf "  请输入要编辑的节点 ID: "
            read -r nid
        fi
    fi
    local cfg="${CONFIG_DIR}/${nid}/config.yml"
    [ -f "$cfg" ] || { err "节点 ${nid} 不存在"; return; }

    local editor
    editor=$(command -v nano || command -v vi || command -v vim || echo "")
    if [ -z "$editor" ]; then
        err "未找到编辑器（nano/vi），请手动编辑: $cfg"; return
    fi
    "$editor" "$cfg"
    ok "配置已保存，正在重启节点 ${nid}..."
    ctrl_node restart "$nid"
}

# ─── 删除节点 ─────────────────────────────────────────────────
cmd_del() {
    local nid="$1"
    if [ -z "$nid" ]; then
        cmd_list
        printf "  请输入要删除的节点 ID: "
        read -r nid
    fi
    [ -d "${CONFIG_DIR}/${nid}" ] || { err "节点 ${nid} 不存在"; return; }
    printf "  确认删除节点 %s？[y/N]: " "$nid"
    read -r CF
    [ "$CF" = "y" ] || [ "$CF" = "Y" ] || { warn "已取消"; return; }

    command -v systemctl >/dev/null 2>&1 && {
        systemctl stop    "xboard-node@${nid}" 2>/dev/null || true
        systemctl disable "xboard-node@${nid}" 2>/dev/null || true
    }
    command -v docker >/dev/null 2>&1 && \
        docker rm -f "xboard-node-${nid}" 2>/dev/null || true

    rm -rf "${CONFIG_DIR:?}/${nid}"
    regen_compose
    ok "节点 ${nid} 已删除"
}

# ─── 更新二进制 ───────────────────────────────────────────────
cmd_update() {
    detect_arch
    step "更新 xboard-node..."
    local url="${GITHUB_RAW}/xboard-node-linux-${ARCH}" tmp="/tmp/xbn-update"
    if wget -q "$url" -O "$tmp" 2>/dev/null || curl -fsSL "$url" -o "$tmp" 2>/dev/null; then
        chmod +x "$tmp" && mv "$tmp" "${INSTALL_DIR}/xboard-node"
        ok "二进制已更新"
    else
        err "下载失败"; rm -f "$tmp"; return
    fi
    # 重启所有运行中 systemd 节点
    if command -v systemctl >/dev/null 2>&1; then
        get_node_ids
        for nid in "${NODE_IDS[@]}"; do
            systemctl is-active "xboard-node@${nid}" >/dev/null 2>&1 && {
                systemctl restart "xboard-node@${nid}"
                ok "已重启: 节点 ${nid}"
            }
        done
    fi
    # Docker 提示
    [ -f "${CONFIG_DIR}/docker-compose.yml" ] && command -v docker >/dev/null 2>&1 && {
        ok "Docker 节点请手动更新:"
        echo "  cd ${CONFIG_DIR} && docker compose pull && docker compose up -d"
    }
}

# ─── 完全卸载 ─────────────────────────────────────────────────
cmd_uninstall() {
    warn "此操作将卸载 xboard-node 及所有节点"
    printf "  确认卸载？[y/N]: "
    read -r CF
    [ "$CF" = "y" ] || [ "$CF" = "Y" ] || { warn "已取消"; return; }

    if command -v systemctl >/dev/null 2>&1; then
        get_node_ids
        for nid in "${NODE_IDS[@]}"; do
            systemctl stop    "xboard-node@${nid}" 2>/dev/null || true
            systemctl disable "xboard-node@${nid}" 2>/dev/null || true
        done
        systemctl stop    xboard-node 2>/dev/null || true
        systemctl disable xboard-node 2>/dev/null || true
        rm -f /etc/systemd/system/xboard-node.service
        rm -f "/etc/systemd/system/${SERVICE_TEMPLATE}"
        systemctl daemon-reload
    fi
    command -v docker >/dev/null 2>&1 && {
        get_node_ids
        for nid in "${NODE_IDS[@]}"; do
            docker rm -f "xboard-node-${nid}" 2>/dev/null || true
        done
    }
    rm -f "${INSTALL_DIR}/xboard-node"
    rm -f "$SHORTCUT" "$SELF_PATH"
    ok "程序及快捷指令已删除"

    printf "  同时删除配置文件？(%s) [y/N]: " "$CONFIG_DIR"
    read -r CF2
    [ "$CF2" = "y" ] || [ "$CF2" = "Y" ] && { rm -rf "$CONFIG_DIR"; ok "配置已清除"; } \
        || ok "配置保留在: ${CONFIG_DIR}/"
    ok "卸载完成"
}

# ─── 主菜单（数字版）─────────────────────────────────────────
main_menu() {
    check_root
    auto_shortcut

    while true; do
        clear
        echo ""
        echo "${C}${BOLD}  ==================================${NC}"
        echo "${C}${BOLD}    Xboard-Node  管理面板  v2.0    ${NC}"
        echo "${C}${BOLD}  ==================================${NC}"
        echo ""
        show_status_bar
        line
        echo "  ${Y}提示: 可直接用子命令 → xbn log 1 / xbn restart 1${NC}"
        line
        echo ""
        echo "  请选择操作:"
        echo ""
        echo "    1) 安装新节点"
        echo "    2) 查看节点状态"
        echo "    3) 查看日志"
        echo "    4) 启动节点"
        echo "    5) 停止节点"
        echo "    6) 重启节点"
        echo "    7) 修改配置"
        echo "    8) 删除节点"
        echo "    9) 更新程序"
        echo "   10) 完全卸载"
        echo "    0) 退出"
        echo ""
        line
        printf "  请输入选项 [0-10]: "
        read -r choice
        echo ""

        case "$choice" in
            1)  cmd_add ;;
            2)  cmd_list; printf "  按回车返回..."; read -r _ ;;
            3)  printf "  节点 ID (空=自动选): "; read -r _id; cmd_log "$_id" ;;
            4)  printf "  节点 ID (all=全部): ";  read -r _id; ctrl_node start   "$_id"; printf "  按回车返回..."; read -r _ ;;
            5)  printf "  节点 ID (all=全部): ";  read -r _id; ctrl_node stop    "$_id"; printf "  按回车返回..."; read -r _ ;;
            6)  printf "  节点 ID (all=全部): ";  read -r _id; ctrl_node restart "$_id"; printf "  按回车返回..."; read -r _ ;;
            7)  printf "  节点 ID (空=自动选): "; read -r _id; cmd_edit "$_id";  printf "  按回车返回..."; read -r _ ;;
            8)  cmd_del "" ;;
            9)  cmd_update; printf "  按回车返回..."; read -r _ ;;
            10) cmd_uninstall ;;
            0)  ok "已退出"; exit 0 ;;
            *)  warn "无效选项" ;;
        esac
    done
}

# ─── 子命令入口 ───────────────────────────────────────────────
case "${1:-}" in
    add|install)   check_root; cmd_add ;;
    list|status)   check_root; cmd_list ;;
    log|logs)      check_root; cmd_log "$2" ;;
    start)         check_root; ctrl_node start   "${2:-all}" ;;
    stop)          check_root; ctrl_node stop    "${2:-all}" ;;
    restart)       check_root; ctrl_node restart "${2:-all}" ;;
    edit|config)   check_root; cmd_edit "$2" ;;
    del|remove|rm) check_root; cmd_del  "$2" ;;
    update)        check_root; cmd_update ;;
    uninstall)     check_root; cmd_uninstall ;;
    help|-h|--help)
        echo ""
        title "  Xboard-Node 管理脚本 - 子命令速查"
        line
        echo "  xbn              打开交互菜单"
        echo "  xbn list         查看所有节点状态"
        echo "  xbn add          安装新节点"
        echo "  xbn log  <id>    实时查看日志"
        echo "  xbn start   <id|all>  启动节点"
        echo "  xbn stop    <id|all>  停止节点"
        echo "  xbn restart <id|all>  重启节点"
        echo "  xbn edit <id>    修改节点配置"
        echo "  xbn del  <id>    删除节点"
        echo "  xbn update       更新程序"
        echo "  xbn uninstall    完全卸载"
        line; echo ""
        ;;
    "")            main_menu ;;
    *)             err "未知命令: $1  (运行 xbn help 查看帮助)"; exit 1 ;;
esac

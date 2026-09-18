#!/usr/bin/env bash
# ============================================================
# sing-box 1.14+ 一键部署脚本 (Alpine Linux, musl 静态版)
# 支持三种模式，且模式一/二可在同一进程内同时启用：
#   1) VLESS-REALITY 中转    (本机中转 -> 落地 VPS，支持 NAT 内外端口不一致)
#   2) Cloudflare Tunnel + VLESS-WS  (cloudflared inbound)
#   3) 两者同时运行 (同一个 sing-box 进程里，两个 inbound 并存)
#
# 低内存优化：
#   - 系统内存 <=200MiB 时自动创建 swap，并给 sing-box 设置
#     GOMEMLIMIT/GOGC 软内存上限，降低被 OOM Killer 杀死的概率。
#   - /tmp 在很多 Alpine/Podman 环境下是 tmpfs（内存文件系统）。
#     下载到 /tmp 或解压到 /tmp，产生的文件会被 cgroup 记为
#     不可回收的 anon 内存，和其他常驻进程叠加后很容易冲破
#     低内存限制（如128MB），触发 OOM killer。
#     本脚本会自动探测一个"不是 tmpfs"的工作目录（优先 /root 下），
#     下载、解压全部指向该目录，用完立即整体清理；下载后还会做
#     gzip 完整性校验，避免下载中断导致解压失败或安装到坏文件。
# ============================================================

set -euo pipefail

SB_DIR="/etc/sing-box"
SB_BIN="/usr/local/bin/sing-box"
SERVICE="sing-box"
SERVICE_FILE="/etc/init.d/${SERVICE}"
CONFIG="${SB_DIR}/config.json"
NODE_INFO_FILE="${SB_DIR}/node.txt"
DEPLOY_ENV="${SB_DIR}/deploy.env"
SWAP_FILE="/swapfile"
WORK_DIR=""

RED='\033[31m'
GREEN='\033[32m'
YELLOW='\033[33m'
NC='\033[0m'

info()  { echo -e "${GREEN}[+] $*${NC}"; }
warn()  { echo -e "${YELLOW}[!] $*${NC}"; }
error() { echo -e "${RED}[-] $*${NC}"; }

cleanup() {
    if [[ -n "$WORK_DIR" && -d "$WORK_DIR" ]]; then
        rm -rf "$WORK_DIR"
    fi
}
trap cleanup EXIT

join_by() {
    local d="$1"; shift
    local f="$1"; shift || true
    printf '%s' "$f"
    for x in "$@"; do printf '%s%s' "$d" "$x"; done
}

[[ $EUID -eq 0 ]] || { error "请使用 root 权限运行"; exit 1; }
command -v apk >/dev/null 2>&1 || { error "本脚本仅适用于 Alpine Linux (未检测到 apk 命令)"; exit 1; }

# ------------------------------------------------------------
# 探测一个非 tmpfs 的安全工作目录，用于下载/解压 sing-box
# 优先级: /root -> /var/tmp -> /tmp (兜底，会给出警告)
#
# 文件系统类型直接从 /proc/mounts 读取（取最长前缀匹配的挂载点），
# 而不是用 `df -T`：Alpine 精简版 busybox 的 df 不一定编译了
# FEATURE_DF_FANCY，-T 参数可能不支持，读 /proc/mounts 更可靠。
# ------------------------------------------------------------
fs_type_of() {
    local target="$1" abs
    abs="$(cd "$target" 2>/dev/null && pwd)" || abs="$target"
    awk -v p="$abs" '
        {
            mp = $2
            gsub(/\\040/, " ", mp)
            if (index(p, mp) == 1 && length(mp) > best_len) {
                best_len = length(mp)
                best_type = $3
            }
        }
        END { print (best_type != "" ? best_type : "unknown") }
    ' /proc/mounts
}

pick_work_dir() {
    local bases=("/root" "/var/tmp" "/tmp")
    local b dir fstype avail_kb
    for b in "${bases[@]}"; do
        [[ -d "$b" && -w "$b" ]] || continue
        fstype="$(fs_type_of "$b")"
        if [[ "$fstype" == "tmpfs" || "$fstype" == "ramfs" ]]; then
            continue
        fi
        dir="${b%/}/.sb-install-tmp"
        mkdir -p "$dir" 2>/dev/null || continue
        avail_kb="$(df -Pk "$dir" 2>/dev/null | awk 'NR==2{print $4}')"
        if [[ -n "$avail_kb" && "$avail_kb" -ge 51200 ]]; then
            echo "$dir"
            return 0
        fi
        rmdir "$dir" 2>/dev/null || true
    done
    mkdir -p /tmp/.sb-install-tmp
    echo "/tmp/.sb-install-tmp"
    return 1
}

# ------------------------------------------------------------
# 卸载
# ------------------------------------------------------------
uninstall() {
    echo
    echo "============================================================"
    echo "      sing-box 卸载 (Alpine)"
    echo "============================================================"
    read -rp "确认卸载 sing-box？将删除服务/二进制/配置文件 (y/N): " CONFIRM
    [[ "$CONFIRM" == "y" || "$CONFIRM" == "Y" ]] || { echo "已取消"; exit 0; }

    local hk_port="" created_swap=""
    if [[ -f "$DEPLOY_ENV" ]]; then
        # shellcheck disable=SC1090
        source "$DEPLOY_ENV"
        hk_port="${HK_PORT_INTERNAL:-}"
        created_swap="${CREATED_SWAP:-}"
    fi

    if [[ -f "$SERVICE_FILE" ]]; then
        info "停止并禁用 sing-box 服务..."
        rc-service "$SERVICE" stop 2>/dev/null || true
        rc-update del "$SERVICE" default 2>/dev/null || true
        rm -f "$SERVICE_FILE"
    else
        warn "未找到 OpenRC 服务文件，跳过服务停用"
    fi

    if [[ -n "$hk_port" ]] && command -v iptables >/dev/null 2>&1; then
        info "尝试移除防火墙放行规则 (内部端口 ${hk_port})..."
        iptables -D INPUT -p tcp --dport "${hk_port}" -j ACCEPT 2>/dev/null \
            || warn "iptables 规则移除失败或本容器无网络管理权限，可忽略"
    fi

    if [[ "$created_swap" == "1" && -f "$SWAP_FILE" ]]; then
        info "移除本脚本创建的 swap 文件..."
        swapoff "$SWAP_FILE" 2>/dev/null || true
        sed -i "\|^${SWAP_FILE} |d" /etc/fstab 2>/dev/null || true
        rm -f "$SWAP_FILE"
    fi

    info "删除 sing-box 二进制及配置文件..."
    rm -f "$SB_BIN"
    rm -rf "$SB_DIR"
    rm -f /var/log/sing-box.log
    rm -f /etc/logrotate.d/sing-box
    rm -rf /root/.sb-install-tmp /var/tmp/.sb-install-tmp /tmp/.sb-install-tmp

    info "卸载完成，系统已恢复干净状态。"
    exit 0
}

if [[ "${1:-}" == "--uninstall" || "${1:-}" == "uninstall" ]]; then
    uninstall
fi

echo
echo "============================================================"
echo "      sing-box VLESS 一键部署 (Alpine, 1.14+)"
echo "============================================================"
echo

if [[ -f "$SB_BIN" || -f "$SERVICE_FILE" ]]; then
    warn "检测到 sing-box 可能已安装（二进制或服务已存在）。"
    read -rp "继续将覆盖现有配置，旧节点链接将失效，是否继续？(y/N): " OVERWRITE_CONFIRM
    [[ "$OVERWRITE_CONFIRM" == "y" || "$OVERWRITE_CONFIRM" == "Y" ]] || { echo "已取消"; exit 0; }
fi

# ------------------------------------------------------------
# 选择部署模式
# ------------------------------------------------------------
echo "请选择部署模式："
echo "  1) 仅 VLESS-REALITY 中转   (本机中转到另一台落地 VPS，支持 NAT 内外端口不一致)"
echo "  2) 仅 Cloudflare Tunnel + VLESS-WS  (无需公网入站端口)"
echo "  3) 两者同时运行  (同一个 sing-box 进程里，REALITY 入口 + CF 隧道入口并存)"
read -rp "请输入 1/2/3: " MODE
[[ "$MODE" == "1" || "$MODE" == "2" || "$MODE" == "3" ]] || { error "无效选项"; exit 1; }

HAS_REALITY=false
HAS_CF=false
[[ "$MODE" == "1" || "$MODE" == "3" ]] && HAS_REALITY=true
[[ "$MODE" == "2" || "$MODE" == "3" ]] && HAS_CF=true

if $HAS_REALITY; then
    echo
    echo "--- REALITY 中转参数 ---"
    echo "(若你的 NAT VPS 外部映射端口与容器内部监听端口不一致，请分别填写；一致的话两个都填一样即可)"
    read -rp "请输入【落地 VPS IP】: " LAND_IP
    read -rp "请输入【落地 VPS 端口】: " LAND_PORT
    read -rp "请输入【落地 VPS UUID】: " LAND_UUID
    read -rp "请输入【本机内部监听端口 (容器/系统内实际监听的端口)】: " HK_PORT_INTERNAL
    read -rp "请输入【对外映射端口 (客户端连接用的公网端口，直接回车=与内部端口相同)】: " HK_PORT_EXTERNAL
    HK_PORT_EXTERNAL="${HK_PORT_EXTERNAL:-$HK_PORT_INTERNAL}"

    [[ -n "$LAND_IP" ]] || { error "落地 IP 不能为空"; exit 1; }
    [[ "$LAND_PORT" =~ ^[0-9]+$ ]] || { error "落地端口格式不正确"; exit 1; }
    [[ "$HK_PORT_INTERNAL" =~ ^[0-9]+$ ]] || { error "内部监听端口格式不正确"; exit 1; }
    [[ "$HK_PORT_EXTERNAL" =~ ^[0-9]+$ ]] || { error "对外映射端口格式不正确"; exit 1; }
    [[ "$LAND_UUID" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]] \
        || { error "落地 UUID 格式不正确"; exit 1; }

    if [[ "$HK_PORT_INTERNAL" != "$HK_PORT_EXTERNAL" ]]; then
        info "已启用 NAT 端口分离: 内部监听 ${HK_PORT_INTERNAL} <- NAT -> 外部 ${HK_PORT_EXTERNAL}"
    fi
fi

if $HAS_CF; then
    echo
    echo "--- Cloudflare Tunnel 参数 ---"
    read -rsp "Cloudflare Tunnel Token: " CF_TOKEN
    echo
    [[ -n "$CF_TOKEN" ]] || { error "Token 不能为空"; exit 1; }

    read -rp "你的域名(example.com): " DOMAIN
    [[ -n "$DOMAIN" ]] || { error "域名不能为空"; exit 1; }
    case "$DOMAIN" in
        *" "*|*"/"*|http://*|https://*)
            error "域名格式不正确，请只输入裸域名，例如: example.com"; exit 1 ;;
    esac
    echo "$DOMAIN" | grep -Eq '^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)+$' \
        || { error "域名格式不正确，请检查后重新输入"; exit 1; }

    VLESS_PORT=8080
fi

if $HAS_REALITY && $HAS_CF && [[ "${HK_PORT_INTERNAL}" == "${VLESS_PORT}" ]]; then
    error "REALITY 内部监听端口 (${HK_PORT_INTERNAL}) 与 CF 内部转发端口 (${VLESS_PORT}) 冲突，请重新运行并使用不同端口"
    exit 1
fi

# ------------------------------------------------------------
# 依赖安装 (musl 静态构建，无需 gcompat)
# ------------------------------------------------------------
info "正在安装系统依赖..."
apk add --no-cache curl wget jq tar ca-certificates openrc iproute2
if $HAS_REALITY; then
    apk add --no-cache openssl iptables 2>/dev/null || warn "iptables 不可用，稍后放行端口步骤会跳过"
fi

if $HAS_CF; then
    if command -v ss >/dev/null 2>&1 && ss -ltn 2>/dev/null | grep -q ":${VLESS_PORT} "; then
        error "端口 ${VLESS_PORT} 已被占用，请先释放该端口或修改脚本中的 VLESS_PORT 后重试"
        exit 1
    fi
fi

# ------------------------------------------------------------
# 低内存优化: 检测系统内存，<=200MiB 时自动创建 swap
# ------------------------------------------------------------
GOMEMLIMIT_VAL=""
GOGC_VAL=""
LOG_LEVEL="info"
CREATED_SWAP=0

setup_swap_if_needed() {
    local swap_total_kb avail_kb swap_size_mb=512
    swap_total_kb="$(awk '/SwapTotal/ {print $2}' /proc/meminfo)"

    if [[ "$swap_total_kb" -gt 0 ]]; then
        info "检测到已有 swap ($((swap_total_kb/1024)) MiB)，跳过创建"
        return
    fi
    if [[ -e "$SWAP_FILE" ]]; then
        warn "${SWAP_FILE} 已存在但未启用，跳过自动创建（请自行检查）"
        return
    fi

    avail_kb="$(df -Pk / | awk 'NR==2{print $4}')"
    if [[ "$avail_kb" -lt $(( (swap_size_mb + 100) * 1024 )) ]]; then
        warn "磁盘剩余空间不足，无法创建 ${swap_size_mb}MB swap，跳过（OOM 风险仍然存在，建议清理磁盘或手动加 swap）"
        return
    fi

    info "内存较小且未检测到 swap，正在创建 ${swap_size_mb}MB swap 文件..."
    if dd if=/dev/zero of="$SWAP_FILE" bs=1M count="$swap_size_mb" 2>/dev/null \
        && chmod 600 "$SWAP_FILE" \
        && mkswap "$SWAP_FILE" >/dev/null 2>&1 \
        && swapon "$SWAP_FILE" 2>/dev/null; then
        grep -q "^${SWAP_FILE} " /etc/fstab 2>/dev/null || echo "${SWAP_FILE} none swap sw 0 0" >> /etc/fstab
        info "swap 创建并启用成功"
        CREATED_SWAP=1
    else
        warn "swap 创建/启用失败（容器可能无 swap 操作权限，比如部分 LXC/OpenVZ NAT VPS），跳过"
        rm -f "$SWAP_FILE"
    fi
}

MEM_TOTAL_KB="$(awk '/MemTotal/ {print $2}' /proc/meminfo)"
MEM_TOTAL_MB=$(( MEM_TOTAL_KB / 1024 ))
info "检测到系统内存: ${MEM_TOTAL_MB}MiB"

if (( MEM_TOTAL_MB <= 200 )); then
    warn "内存较小 (${MEM_TOTAL_MB}MiB)，启用低内存优化以降低被 OOM Killer 杀死的风险"
    setup_swap_if_needed
    LIMIT_MB=$(( MEM_TOTAL_MB * 55 / 100 ))
    (( LIMIT_MB < 32 )) && LIMIT_MB=32
    GOMEMLIMIT_VAL="${LIMIT_MB}MiB"
    GOGC_VAL="50"
    LOG_LEVEL="warn"
    info "sing-box 内存软上限 GOMEMLIMIT=${GOMEMLIMIT_VAL}, GOGC=${GOGC_VAL}"
fi

# ------------------------------------------------------------
# 探测非 tmpfs 工作目录，用于下载/解压 (避免占用宝贵的匿名内存)
# ------------------------------------------------------------
if ! WORK_DIR="$(pick_work_dir)"; then
    warn "未找到可用的非 tmpfs 临时目录（或磁盘空间不足），回退使用 ${WORK_DIR}"
    warn "如果 ${WORK_DIR} 也是 tmpfs，低内存设备上下载/解压过程仍有 OOM 风险"
fi
info "使用工作目录: ${WORK_DIR} (文件系统类型: $(fs_type_of "$WORK_DIR"))"

# ------------------------------------------------------------
# 架构探测
# ------------------------------------------------------------
ARCH="$(uname -m)"
case "$ARCH" in
    x86_64)  SB_ARCH="amd64" ;;
    aarch64|arm64) SB_ARCH="arm64" ;;
    armv7l)  SB_ARCH="armv7" ;;
    *) error "不支持的架构: $ARCH"; exit 1 ;;
esac
info "检测到架构: ${ARCH} -> ${SB_ARCH}"

# ------------------------------------------------------------
# 获取 sing-box >= 1.14 版本
# ------------------------------------------------------------
info "获取 sing-box 最新 1.14+ 版本..."

GH_AUTH_HEADER=()
[[ -n "${GITHUB_TOKEN:-}" ]] && GH_AUTH_HEADER=(-H "Authorization: Bearer ${GITHUB_TOKEN}")

GH_RESPONSE="$(curl -fsSL "${GH_AUTH_HEADER[@]}" "https://api.github.com/repos/SagerNet/sing-box/releases?per_page=100" || true)"

if [[ -z "$GH_RESPONSE" ]]; then
    error "调用 GitHub API 失败，可能是网络问题或触发了未认证请求限流(60次/小时)"
    error "可设置环境变量 GITHUB_TOKEN 后重试，或稍后再试"
    exit 1
fi

SB_VERSION="$(echo "$GH_RESPONSE" \
  | jq -r '[.[] | select(.draft==false) | select(.tag_name | test("^v([2-9][0-9]*\\.|1\\.(1[4-9]|[2-9][0-9])\\.)"))][0].tag_name' \
  | sed 's/^v//')"

if [[ -z "$SB_VERSION" || "$SB_VERSION" == "null" ]]; then
    error "未找到 sing-box >= 1.14 的版本，请检查网络或稍后重试"
    exit 1
fi

info "将安装 sing-box ${SB_VERSION}"

SB_ASSET="linux-${SB_ARCH}-musl"
SB_TARBALL_NAME="sing-box-${SB_VERSION}-${SB_ASSET}.tar.gz"
TMP_TARBALL="${WORK_DIR}/${SB_TARBALL_NAME}"

# ------------------------------------------------------------
# 下载 (官方源 -> 备用镜像源，逐个重试；每次下载后做 gzip 完整性校验)
# ------------------------------------------------------------
download_singbox() {
    local urls=(
        "https://github.com/SagerNet/sing-box/releases/download/v${SB_VERSION}/${SB_TARBALL_NAME}"
        "https://github.com/xlsxmp/sing-box/releases/download/Alpine/sing-box-${SB_VERSION}-linux-${SB_ARCH}-musl.tar.gz"
    )
    local url
    for url in "${urls[@]}"; do
        info "尝试下载: ${url}"
        rm -f "$TMP_TARBALL"
        if ! wget -q --timeout=20 --tries=2 -O "$TMP_TARBALL" "$url" || [[ ! -s "$TMP_TARBALL" ]]; then
            warn "该地址下载失败，尝试下一个来源..."
            continue
        fi
        if ! gzip -t "$TMP_TARBALL" 2>/dev/null; then
            warn "下载文件未通过 gzip 完整性校验（可能下载中断/被截断），尝试下一个来源..."
            continue
        fi
        info "下载完成且完整性校验通过: ${url}"
        [[ "$url" == *xlsxmp* ]] && warn "此次使用的是第三方镜像源 (xlsxmp)，非 SagerNet 官方发布，请自行评估信任度"
        return 0
    done
    return 1
}

download_singbox || { error "sing-box 下载失败：官方源与备用镜像源均不可用或文件损坏，请检查网络或手动下载"; exit 1; }

TMP_EXTRACT_DIR="${WORK_DIR}/$(tar tzf "$TMP_TARBALL" | head -1 | cut -f1 -d/)"
tar xf "$TMP_TARBALL" -C "$WORK_DIR"

[[ -f "${TMP_EXTRACT_DIR}/sing-box" ]] || { error "解压后未找到预期的 sing-box 二进制，release 包结构可能已变化"; exit 1; }

mkdir -p "$SB_DIR"
mv "${TMP_EXTRACT_DIR}/sing-box" "$SB_BIN"
chmod +x "$SB_BIN"

# 二进制已复制到最终位置，工作目录里的下载/解压产物用完即删，
# 不等脚本结束才靠 trap 清理，尽快释放内存
rm -rf "${WORK_DIR:?}"/*

if ! "$SB_BIN" version >/dev/null 2>&1; then
    error "sing-box 二进制无法运行，可能与当前系统不兼容"
    exit 1
fi
info "Sing-box 安装成功: $("$SB_BIN" version | head -n1)"

# ------------------------------------------------------------
# 生成配置 (按启用的模式动态拼接 inbounds / outbounds / route.rules)
# ------------------------------------------------------------
INBOUNDS=()
OUTBOUNDS=('{ "type": "direct", "tag": "direct" }' '{ "type": "block", "tag": "block" }')
ROUTE_RULES=()

if $HAS_REALITY; then
    HK_UUID="$(cat /proc/sys/kernel/random/uuid)"

    KEY_PAIR="$("$SB_BIN" generate reality-keypair 2>/dev/null)"
    PRIVATE_KEY="$(echo "$KEY_PAIR" | grep -i "PrivateKey" | awk '{print $2}')"
    PUBLIC_KEY="$(echo "$KEY_PAIR" | grep -i "PublicKey" | awk '{print $2}')"
    [[ -n "$PRIVATE_KEY" && -n "$PUBLIC_KEY" ]] || { error "REALITY 密钥生成失败，请检查 sing-box 版本输出格式"; exit 1; }

    SHORT_ID="$("$SB_BIN" generate rand --hex 8 2>/dev/null || echo "1234567890abcdef")"
    DEST_SNI="www.apple.com"

    INBOUNDS+=("$(cat <<EOF
{
  "type": "vless",
  "tag": "hk-in",
  "listen": "::",
  "listen_port": ${HK_PORT_INTERNAL},
  "users": [ { "uuid": "${HK_UUID}", "flow": "xtls-rprx-vision" } ],
  "tls": {
    "enabled": true,
    "server_name": "${DEST_SNI}",
    "reality": {
      "enabled": true,
      "handshake": { "server": "${DEST_SNI}", "server_port": 443 },
      "private_key": "${PRIVATE_KEY}",
      "short_id": ["${SHORT_ID}"]
    }
  }
}
EOF
)")

    OUTBOUNDS+=("$(cat <<EOF
{
  "type": "vless",
  "tag": "to-landing",
  "server": "${LAND_IP}",
  "server_port": ${LAND_PORT},
  "uuid": "${LAND_UUID}",
  "network": "tcp",
  "tls": { "enabled": true, "server_name": "www.microsoft.com", "insecure": true }
}
EOF
)")

    ROUTE_RULES+=('{ "inbound": ["hk-in"], "action": "route", "outbound": "to-landing" }')
fi

if $HAS_CF; then
    WS_PATH="/$(head -c16 /dev/urandom | od -An -tx1 | tr -d ' \n')"
    UUID="$(cat /proc/sys/kernel/random/uuid)"

    INBOUNDS+=("$(cat <<EOF
{
  "type": "cloudflared",
  "tag": "cf-tunnel",
  "token": "${CF_TOKEN}",
  "protocol": "http2",
  "edge_ip_version": 4,
  "post_quantum": false
}
EOF
)")

    INBOUNDS+=("$(cat <<EOF
{
  "type": "vless",
  "tag": "vless-ws",
  "listen": "127.0.0.1",
  "listen_port": ${VLESS_PORT},
  "users": [ { "uuid": "${UUID}" } ],
  "transport": { "type": "ws", "path": "${WS_PATH}" }
}
EOF
)")

    ROUTE_RULES+=("$(cat <<EOF
{
  "inbound": ["cf-tunnel"],
  "action": "route",
  "outbound": "direct",
  "override_address": "127.0.0.1",
  "override_port": ${VLESS_PORT}
}
EOF
)")
fi

INBOUNDS_JSON="[$(join_by , "${INBOUNDS[@]}")]"
OUTBOUNDS_JSON="[$(join_by , "${OUTBOUNDS[@]}")]"
ROUTE_RULES_JSON="[$(join_by , "${ROUTE_RULES[@]}")]"

RAW_CONFIG=$(cat <<EOF
{
  "log": { "level": "${LOG_LEVEL}", "timestamp": true },
  "inbounds": ${INBOUNDS_JSON},
  "route": {
    "rules": ${ROUTE_RULES_JSON},
    "final": "direct"
  },
  "outbounds": ${OUTBOUNDS_JSON}
}
EOF
)

echo "$RAW_CONFIG" | jq . > "$CONFIG" || { error "生成的配置 JSON 格式有误"; exit 1; }

cat > "$DEPLOY_ENV" <<EOF
MODE=${MODE}
HK_PORT_INTERNAL=${HK_PORT_INTERNAL:-}
HK_PORT_EXTERNAL=${HK_PORT_EXTERNAL:-}
CREATED_SWAP=${CREATED_SWAP}
EOF

chmod 600 "$CONFIG" "$DEPLOY_ENV"

info "检查配置文件语法..."
"$SB_BIN" check -c "$CONFIG"

# ------------------------------------------------------------
# OpenRC 服务托管 (低内存时注入 GOMEMLIMIT/GOGC)
# ------------------------------------------------------------
info "正在配置 OpenRC 服务..."
{
cat <<EOF
#!/sbin/openrc-run

name="sing-box"
description="sing-box service"
command="${SB_BIN}"
command_args="run -c ${CONFIG}"
command_background=true
pidfile="/run/\${RC_SVCNAME}.pid"
output_log="/var/log/sing-box.log"
error_log="/var/log/sing-box.log"
EOF

if [[ -n "$GOMEMLIMIT_VAL" ]]; then
    echo "export GOMEMLIMIT=\"${GOMEMLIMIT_VAL}\""
fi
if [[ -n "$GOGC_VAL" ]]; then
    echo "export GOGC=\"${GOGC_VAL}\""
fi

cat <<'EOF'

depend() {
    need net
    after firewall
}
EOF
} > "$SERVICE_FILE"
chmod +x "$SERVICE_FILE"

if command -v logrotate >/dev/null 2>&1; then
    cat > /etc/logrotate.d/sing-box <<'EOF'
/var/log/sing-box.log {
    weekly
    rotate 4
    missingok
    notifempty
    compress
    copytruncate
}
EOF
fi

rc-update add "$SERVICE" default
rc-service "$SERVICE" restart
sleep 2

if ! rc-service "$SERVICE" status | grep -q started; then
    error "服务启动失败，请查看日志: cat /var/log/sing-box.log"
    exit 1
fi

# ------------------------------------------------------------
# 节点信息汇总
# ------------------------------------------------------------
: > "$NODE_INFO_FILE"
{
    echo "============================================================"
    echo "sing-box ${SB_VERSION} 部署成功 (架构: ${SB_ARCH}, 内存: ${MEM_TOTAL_MB}MiB)"
    echo "生成时间: $(date -u +"%Y-%m-%d %H:%M:%S UTC")"
    [[ -n "$GOMEMLIMIT_VAL" ]] && echo "低内存优化: 已启用 (GOMEMLIMIT=${GOMEMLIMIT_VAL}, GOGC=${GOGC_VAL}, swap=$([[ "$CREATED_SWAP" == "1" ]] && echo 已创建 || echo 未创建/已存在))"
    echo "============================================================"
} >> "$NODE_INFO_FILE"

if $HAS_REALITY; then
    if command -v iptables >/dev/null 2>&1; then
        if iptables -I INPUT -p tcp --dport "${HK_PORT_INTERNAL}" -j ACCEPT 2>/dev/null; then
            info "已放行内部端口 ${HK_PORT_INTERNAL}"
        else
            warn "iptables 规则添加失败（容器可能缺少 NET_ADMIN 权限），请在宿主机 / LXC 配置层面放行端口 ${HK_PORT_INTERNAL}"
        fi
    else
        warn "未检测到 iptables，请确认内部端口 ${HK_PORT_INTERNAL} 已在宿主机层面放行"
    fi

    if [[ "$HK_PORT_INTERNAL" != "$HK_PORT_EXTERNAL" ]]; then
        warn "外部映射端口 ${HK_PORT_EXTERNAL} 的转发规则需要在 NAT VPS 服务商后台 / 宿主机层面自行配置 (转发到内部端口 ${HK_PORT_INTERNAL})，本脚本无法代为设置"
    fi

    PUBLIC_IP=""
    for url in "https://api.ipify.org" "https://ifconfig.me" "https://ipv4.icanhazip.com"; do
        PUBLIC_IP="$(curl -4 -fsSL --max-time 5 "$url" 2>/dev/null || true)"
        [[ -n "$PUBLIC_IP" ]] && break
    done
    [[ -n "$PUBLIC_IP" ]] || PUBLIC_IP="YOUR_PUBLIC_IP"

    CLIENT_URL="vless://${HK_UUID}@${PUBLIC_IP}:${HK_PORT_EXTERNAL}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${DEST_SNI}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp#Relay-REALITY"

    {
        echo
        echo "--- [模式一] VLESS-REALITY 中转节点 ---"
        echo "内部监听端口: ${HK_PORT_INTERNAL}  |  对外映射端口: ${HK_PORT_EXTERNAL}"
        echo "客户端节点链接 (v2rayN / Sing-box / Shadowrocket / Clash Meta):"
        echo "${CLIENT_URL}"
        echo
        echo "网络架构: 客户端(REALITY) -> 本机中转 -> 落地 VPS -> 目标网站"
    } >> "$NODE_INFO_FILE"
fi

if $HAS_CF; then
    VLESS_URI="vless://${UUID}@${DOMAIN}:443?encryption=none&security=tls&type=ws&host=${DOMAIN}&path=${WS_PATH}#CF-Tunnel"

    {
        echo
        echo "--- [模式二] Cloudflare Tunnel + VLESS-WS 节点 ---"
        echo "UUID: ${UUID}"
        echo "WS Path: ${WS_PATH}"
        echo "域名: ${DOMAIN}"
        echo "节点链接: ${VLESS_URI}"
        echo
        echo "提醒: 需提前在 Cloudflare Zero Trust 后台创建好 Tunnel 并生成 Token，"
        echo "并将域名 ${DOMAIN} 的 CNAME 指向该 Tunnel。VPS 无需开放该业务的公网入站端口。"
    } >> "$NODE_INFO_FILE"
fi

{
    echo
    echo "============================================================"
    echo "卸载: bash $(basename "$0") --uninstall"
    echo "============================================================"
} >> "$NODE_INFO_FILE"

chmod 600 "$NODE_INFO_FILE"
echo
cat "$NODE_INFO_FILE"

if $HAS_REALITY; then
    echo
    echo "测试中转到落地 VPS 的 TCP 端口连通性..."
    if command -v timeout >/dev/null 2>&1; then
        timeout 5 bash -c "cat < /dev/null > /dev/tcp/${LAND_IP}/${LAND_PORT}" 2>/dev/null \
            && info "中转 -> 落地端口 TCP 连通成功！" \
            || warn "中转 -> 落地端口无法连接，请检查落地机防火墙或端口映射！"
    fi
fi

echo
info "卸载本部署，请运行: bash $(basename "$0") --uninstall"

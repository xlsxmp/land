#!/usr/bin/env bash
# ============================================================
# sing-box 1.14+ 一键部署脚本 (Alpine Linux, musl 静态版)
# 支持三种模式，且模式一/二可在同一进程内同时启用：
#   1) VLESS-REALITY 中转    (本机中转 -> 落地 VPS)
#   2) Cloudflare Tunnel + VLESS-WS  (cloudflared inbound)
#   3) 两者同时运行 (同一个 sing-box 进程里，两个 inbound 并存)
# ============================================================

set -euo pipefail

SB_DIR="/etc/sing-box"
SB_BIN="/usr/local/bin/sing-box"
SERVICE="sing-box"
SERVICE_FILE="/etc/init.d/${SERVICE}"
CONFIG="${SB_DIR}/config.json"
NODE_INFO_FILE="${SB_DIR}/node.txt"
DEPLOY_ENV="${SB_DIR}/deploy.env"
TMP_TARBALL=""
TMP_EXTRACT_DIR=""

RED='\033[31m'
GREEN='\033[32m'
YELLOW='\033[33m'
NC='\033[0m'

info()  { echo -e "${GREEN}[+] $*${NC}"; }
warn()  { echo -e "${YELLOW}[!] $*${NC}"; }
error() { echo -e "${RED}[-] $*${NC}"; }

cleanup() {
    [[ -n "$TMP_TARBALL" && -f "$TMP_TARBALL" ]] && rm -f "$TMP_TARBALL"
    [[ -n "$TMP_EXTRACT_DIR" && -d "$TMP_EXTRACT_DIR" ]] && rm -rf "$TMP_EXTRACT_DIR"
}
trap cleanup EXIT

# 用逗号拼接数组元素（用于拼 JSON 数组）
join_by() {
    local d="$1"; shift
    local f="$1"; shift || true
    printf '%s' "$f"
    for x in "$@"; do printf '%s%s' "$d" "$x"; done
}

[[ $EUID -eq 0 ]] || { error "请使用 root 权限运行"; exit 1; }
command -v apk >/dev/null 2>&1 || { error "本脚本仅适用于 Alpine Linux (未检测到 apk 命令)"; exit 1; }

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

    local hk_port=""
    if [[ -f "$DEPLOY_ENV" ]]; then
        # shellcheck disable=SC1090
        source "$DEPLOY_ENV"
        hk_port="${HK_PORT:-}"
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
        info "尝试移除防火墙放行规则 (端口 ${hk_port})..."
        iptables -D INPUT -p tcp --dport "${hk_port}" -j ACCEPT 2>/dev/null \
            || warn "iptables 规则移除失败或本容器无网络管理权限，可忽略"
    fi

    info "删除 sing-box 二进制及配置文件..."
    rm -f "$SB_BIN"
    rm -rf "$SB_DIR"
    rm -f /var/log/sing-box.log
    rm -f /etc/logrotate.d/sing-box

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

# 幂等性检测
if [[ -f "$SB_BIN" || -f "$SERVICE_FILE" ]]; then
    warn "检测到 sing-box 可能已安装（二进制或服务已存在）。"
    read -rp "继续将覆盖现有配置，旧节点链接将失效，是否继续？(y/N): " OVERWRITE_CONFIRM
    [[ "$OVERWRITE_CONFIRM" == "y" || "$OVERWRITE_CONFIRM" == "Y" ]] || { echo "已取消"; exit 0; }
fi

# ------------------------------------------------------------
# 选择部署模式
# ------------------------------------------------------------
echo "请选择部署模式："
echo "  1) 仅 VLESS-REALITY 中转   (本机中转到另一台落地 VPS)"
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
    read -rp "请输入【落地 VPS IP】: " LAND_IP
    read -rp "请输入【落地 VPS 端口】: " LAND_PORT
    read -rp "请输入【落地 VPS UUID】: " LAND_UUID
    read -rp "请输入【本机(中转) REALITY 公网映射端口】: " HK_PORT

    [[ -n "$LAND_IP" ]] || { error "落地 IP 不能为空"; exit 1; }
    [[ "$LAND_PORT" =~ ^[0-9]+$ ]] || { error "落地端口格式不正确"; exit 1; }
    [[ "$HK_PORT" =~ ^[0-9]+$ ]] || { error "中转端口格式不正确"; exit 1; }
    [[ "$LAND_UUID" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]] \
        || { error "落地 UUID 格式不正确"; exit 1; }
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

# 若两者同时运行，REALITY 端口和 CF 场景下的本地转发端口不能相同
if $HAS_REALITY && $HAS_CF && [[ "${HK_PORT}" == "${VLESS_PORT}" ]]; then
    error "REALITY 端口 (${HK_PORT}) 与内部转发端口 (${VLESS_PORT}) 冲突，请重新运行并使用不同端口"
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
# 获取 sing-box >= 1.14 版本并下载 (musl 静态版，适配 Alpine)
# 未认证的 GitHub API 请求限额为 60次/小时/IP，如报错请设置
# GITHUB_TOKEN 环境变量以提升限额，或稍后重试。
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
TMP_TARBALL="/tmp/${SB_TARBALL_NAME}"

wget -qO "$TMP_TARBALL" \
    "https://github.com/SagerNet/sing-box/releases/download/v${SB_VERSION}/${SB_TARBALL_NAME}"

[[ -s "$TMP_TARBALL" ]] || { error "sing-box 下载失败，请确认该版本是否提供 ${SB_ASSET} 资产"; exit 1; }

TMP_EXTRACT_DIR="/tmp/$(tar tzf "$TMP_TARBALL" | head -1 | cut -f1 -d/)"
tar xf "$TMP_TARBALL" -C /tmp

[[ -f "${TMP_EXTRACT_DIR}/sing-box" ]] || { error "解压后未找到预期的 sing-box 二进制，release 包结构可能已变化"; exit 1; }

mkdir -p "$SB_DIR"
mv "${TMP_EXTRACT_DIR}/sing-box" "$SB_BIN"
chmod +x "$SB_BIN"

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
  "listen_port": ${HK_PORT},
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
  "log": { "level": "info", "timestamp": true },
  "inbounds": ${INBOUNDS_JSON},
  "route": {
    "rules": ${ROUTE_RULES_JSON},
    "final": "direct"
  },
  "outbounds": ${OUTBOUNDS_JSON}
}
EOF
)

# 用 jq 校验 + 格式化，顺便提前发现拼接错误
echo "$RAW_CONFIG" | jq . > "$CONFIG" || { error "生成的配置 JSON 格式有误"; exit 1; }

cat > "$DEPLOY_ENV" <<EOF
MODE=${MODE}
HK_PORT=${HK_PORT:-}
EOF

chmod 600 "$CONFIG" "$DEPLOY_ENV"

info "检查配置文件语法..."
"$SB_BIN" check -c "$CONFIG"

# ------------------------------------------------------------
# OpenRC 服务托管
# ------------------------------------------------------------
info "正在配置 OpenRC 服务..."
cat > "$SERVICE_FILE" <<EOF
#!/sbin/openrc-run

name="sing-box"
description="sing-box service"
command="${SB_BIN}"
command_args="run -c ${CONFIG}"
command_background=true
pidfile="/run/\${RC_SVCNAME}.pid"
output_log="/var/log/sing-box.log"
error_log="/var/log/sing-box.log"

depend() {
    need net
    after firewall
}
EOF
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
# 节点信息汇总 (REALITY / CF 按启用情况分别追加)
# ------------------------------------------------------------
: > "$NODE_INFO_FILE"
{
    echo "============================================================"
    echo "sing-box ${SB_VERSION} 部署成功 (架构: ${SB_ARCH})"
    echo "生成时间: $(date -u +"%Y-%m-%d %H:%M:%S UTC")"
    echo "============================================================"
} >> "$NODE_INFO_FILE"

if $HAS_REALITY; then
    if command -v iptables >/dev/null 2>&1; then
        if iptables -I INPUT -p tcp --dport "${HK_PORT}" -j ACCEPT 2>/dev/null; then
            info "已放行端口 ${HK_PORT}"
        else
            warn "iptables 规则添加失败（容器可能缺少 NET_ADMIN 权限），请在宿主机 / LXC 配置层面放行端口 ${HK_PORT}"
        fi
    else
        warn "未检测到 iptables，请确认端口 ${HK_PORT} 已在宿主机层面放行"
    fi

    PUBLIC_IP=""
    for url in "https://api.ipify.org" "https://ifconfig.me" "https://ipv4.icanhazip.com"; do
        PUBLIC_IP="$(curl -4 -fsSL --max-time 5 "$url" 2>/dev/null || true)"
        [[ -n "$PUBLIC_IP" ]] && break
    done
    [[ -n "$PUBLIC_IP" ]] || PUBLIC_IP="YOUR_PUBLIC_IP"

    CLIENT_URL="vless://${HK_UUID}@${PUBLIC_IP}:${HK_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${DEST_SNI}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp#Relay-REALITY"

    {
        echo
        echo "--- [模式一] VLESS-REALITY 中转节点 ---"
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

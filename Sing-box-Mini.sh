#!/usr/bin/env bash
# ============================================================
# Sing-box Mini (修复版)
# Alpine(OpenRC) / Debian / Ubuntu(systemd)
#
# 架构:
#   Client --HTTPS--> Cloudflare --Tunnel--> cloudflared
#          --> 127.0.0.1:PORT (sing-box, VLESS + WS) --> Internet
#
# 用法:
#   bash singbox-mini.sh install      安装 / 升级
#   bash singbox-mini.sh reconfig     修改参数(端口/路径/token/域名)并重启, 不重新下载
#   bash singbox-mini.sh info         查看节点(临时隧道会实时读取最新域名)
#   bash singbox-mini.sh status       查看状态
#   bash singbox-mini.sh restart      重启服务
#   bash singbox-mini.sh logs         查看日志
#   bash singbox-mini.sh uninstall    卸载
#
# 临时隧道:
#   bash singbox-mini.sh install
#
# 固定隧道:
#   ARGO_TOKEN='xxx' ARGO_DOMAIN='argo.example.com' bash singbox-mini.sh install
#
# 环境变量(仅 install / reconfig 读取, 之后自动保存到 /etc/sing-box/env):
#   PORT              本地监听端口, 默认 8080
#   WS_PATH           WebSocket 路径, 默认 /ws
#   ARGO_TOKEN        固定隧道 Token(设置后自动切到固定模式)
#   ARGO_DOMAIN       固定隧道对应的域名
#   MODE=quick        从固定模式切回临时模式
#   SB_VERSION        指定 sing-box 版本, 默认最新版
#   EDGE_IP_VERSION   cloudflared 连接边缘节点的 IP 版本: 4 | 6 | auto
#   CF_PROTOCOL       cloudflared 协议: auto | http2 | quic (UDP 被封时用 http2)
#   GH_PROXY          GitHub 下载加速前缀, 如 https://ghfast.top/ (纯 IPv6 机器可用)
# ============================================================

# Alpine 默认没有 bash: 用 sh 运行时自动补装并切换
if [ -z "${BASH_VERSION:-}" ]; then
    if command -v bash >/dev/null 2>&1; then
        exec bash "$0" "$@"
    fi
    if command -v apk >/dev/null 2>&1; then
        apk add --no-cache bash >/dev/null 2>&1 && exec bash "$0" "$@"
    fi
    echo "需要 bash, 请先安装 bash" >&2
    exit 1
fi

set -Eeuo pipefail
export LANG=C LC_ALL=C

# ============================================================
# 常量
# ============================================================

SELF="$0"

WORK_DIR="/etc/sing-box"
SB_BIN="${WORK_DIR}/sing-box"
SB_CONFIG="${WORK_DIR}/config.json"
UUID_FILE="${WORK_DIR}/uuid"
ENV_FILE="${WORK_DIR}/env"
INFO_FILE="${WORK_DIR}/info.txt"
WRAPPER="${WORK_DIR}/cloudflared-run.sh"

CLOUDFLARED_BIN="/usr/local/bin/cloudflared"
CF_LOG="/var/log/cloudflared.log"

LOCAL_HOST="127.0.0.1"

SB_SVC="sing-box"
CF_SVC="cloudflared"

TMP_DIR=""

RED='\033[1;31m'
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
CYAN='\033[1;36m'
RESET='\033[0m'

info() { echo -e "${CYAN}[INFO]${RESET} $*"; }
ok()   { echo -e "${GREEN}[ OK ]${RESET} $*"; }
warn() { echo -e "${YELLOW}[WARN]${RESET} $*"; }
err()  { echo -e "${RED}[ERR ]${RESET} $*" >&2; }
die()  { err "$*"; exit 1; }

cleanup() {
    if [[ -n "${TMP_DIR}" && -d "${TMP_DIR}" ]]; then
        rm -rf "${TMP_DIR}"
    fi
}
trap cleanup EXIT
trap 'rc=$?; err "脚本在第 ${LINENO} 行异常退出 (code ${rc})"' ERR

# ============================================================
# 环境检测
# ============================================================

check_root() {
    [[ "${EUID}" -eq 0 ]] || die "请使用 root 运行"
}

detect_os() {
    if [[ -f /etc/alpine-release ]]; then
        OS="alpine"
        INIT="openrc"
    elif [[ -f /etc/debian_version ]]; then
        OS="debian"
        INIT="systemd"
        [[ -d /run/systemd/system ]] || die "未检测到正在运行的 systemd (容器环境?)"
    else
        die "仅支持 Alpine / Debian / Ubuntu"
    fi
}

detect_arch() {
    case "$(uname -m)" in
        x86_64|amd64)  ARCH="amd64"; CF_ARCH="amd64" ;;
        aarch64|arm64) ARCH="arm64"; CF_ARCH="arm64" ;;
        armv7l|armv7)  ARCH="armv7"; CF_ARCH="arm" ;;
        i386|i686|x86) ARCH="386";   CF_ARCH="386" ;;
        *) die "不支持的 CPU 架构: $(uname -m)" ;;
    esac
}

install_dependencies() {
    info "检查依赖..."

    if [[ "${OS}" == "alpine" ]]; then
        # busybox 已自带 tar/gzip/sed/grep/find, 只补 bash/curl/证书, 不换掉 busybox 工具
        apk add --no-cache bash curl ca-certificates >/dev/null
    else
        local missing=0 c
        for c in curl tar gzip; do
            command -v "$c" >/dev/null 2>&1 || missing=1
        done
        [[ -f /etc/ssl/certs/ca-certificates.crt ]] || missing=1

        if [[ "${missing}" -eq 1 ]]; then
            export DEBIAN_FRONTEND=noninteractive
            apt-get update -y
            apt-get install -y --no-install-recommends curl tar gzip ca-certificates
        fi
    fi
}

# ============================================================
# 下载
# ============================================================

gh_url() {
    printf '%s%s' "${GH_PROXY:-}" "$1"
}

dl() {
    curl -fL --retry 3 --connect-timeout 15 --progress-bar -o "$2" "$1" \
        || die "下载失败: $1 (网络受限可设置 GH_PROXY)"
}

latest_singbox_version() {
    local v="" re='^[0-9]+\.[0-9]+\.[0-9]+$'

    if [[ -n "${SB_VERSION:-}" ]]; then
        printf '%s' "${SB_VERSION#v}"
        return 0
    fi

    # 优先走 releases/latest 跳转, 不占用 API 限流额度
    v="$(curl -fsSL --connect-timeout 10 -o /dev/null -w '%{url_effective}' \
        https://github.com/SagerNet/sing-box/releases/latest 2>/dev/null || true)"
    v="${v##*/}"
    v="${v#v}"

    if ! [[ "${v}" =~ ${re} ]]; then
        v="$(curl -fsSL --connect-timeout 10 \
            https://api.github.com/repos/SagerNet/sing-box/releases/latest 2>/dev/null \
            | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"v\{0,1\}\([^"]*\)".*/\1/p' \
            | sed -n '1p' || true)"
    fi

    if [[ "${v}" =~ ${re} ]]; then
        printf '%s' "${v}"
    fi
}

install_singbox() {
    info "安装 sing-box..."

    local version url bin
    version="$(latest_singbox_version)"
    [[ -n "${version}" ]] || die "无法获取 sing-box 版本, 请用 SB_VERSION=x.y.z 指定"
    info "sing-box 版本: ${version}"

    url="$(gh_url "https://github.com/SagerNet/sing-box/releases/download/v${version}/sing-box-${version}-linux-${ARCH}.tar.gz")"
    dl "${url}" "${TMP_DIR}/sing-box.tar.gz"

    mkdir -p "${TMP_DIR}/sb"
    tar -xzf "${TMP_DIR}/sing-box.tar.gz" -C "${TMP_DIR}/sb"

    bin="$(find "${TMP_DIR}/sb" -type f -name sing-box | sed -n '1p')"
    [[ -n "${bin}" ]] || die "压缩包内未找到 sing-box 可执行文件"
    chmod +x "${bin}"
    "${bin}" version >/dev/null 2>&1 || die "sing-box 无法运行 (架构或系统不匹配?)"

    mkdir -p "${WORK_DIR}"
    # 先落到 .new 再 mv 覆盖, 避免 "Text file busy"
    install -m 0755 "${bin}" "${SB_BIN}.new"
    mv -f "${SB_BIN}.new" "${SB_BIN}"

    ok "sing-box 安装完成: $("${SB_BIN}" version | sed -n '1p')"
}

install_cloudflared() {
    info "安装 cloudflared..."

    local url
    url="$(gh_url "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${CF_ARCH}")"
    dl "${url}" "${TMP_DIR}/cloudflared"

    chmod +x "${TMP_DIR}/cloudflared"
    "${TMP_DIR}/cloudflared" --version >/dev/null 2>&1 || die "cloudflared 无法运行 (架构或系统不匹配?)"

    install -m 0755 "${TMP_DIR}/cloudflared" "${CLOUDFLARED_BIN}.new"
    mv -f "${CLOUDFLARED_BIN}.new" "${CLOUDFLARED_BIN}"

    ok "cloudflared 安装完成: $("${CLOUDFLARED_BIN}" --version | sed -n '1p')"
}

# ============================================================
# 配置: 保存 / 读取 / 校验
# ============================================================

# 生成 POSIX sh 可安全 source 的单引号字符串
sq() {
    local q="'\\''" s="$1"
    s="${s//\'/${q}}"
    printf "'%s'" "${s}"
}

reset_conf() {
    CFG_MODE=""
    CFG_PORT=""
    CFG_WS_PATH=""
    CFG_TOKEN=""
    CFG_DOMAIN=""
    CFG_EDGE_IP_VERSION=""
    CFG_PROTOCOL=""
}

load_saved_conf() {
    reset_conf
    if [[ -f "${ENV_FILE}" ]]; then
        # shellcheck disable=SC1090
        . "${ENV_FILE}"
    fi
}

# 命令行环境变量覆盖已保存的配置(仅 install / reconfig 使用)
apply_overrides() {
    if [[ -n "${PORT:-}" ]]; then CFG_PORT="${PORT}"; fi
    if [[ -n "${WS_PATH:-}" ]]; then CFG_WS_PATH="${WS_PATH}"; fi
    if [[ -n "${ARGO_DOMAIN:-}" ]]; then CFG_DOMAIN="${ARGO_DOMAIN}"; fi
    if [[ -n "${EDGE_IP_VERSION:-}" ]]; then CFG_EDGE_IP_VERSION="${EDGE_IP_VERSION}"; fi
    if [[ -n "${CF_PROTOCOL:-}" ]]; then CFG_PROTOCOL="${CF_PROTOCOL}"; fi

    if [[ -n "${ARGO_TOKEN:-}" ]]; then
        CFG_TOKEN="${ARGO_TOKEN}"
        CFG_MODE="token"
    elif [[ "${MODE:-}" == "quick" ]]; then
        CFG_MODE="quick"
        CFG_TOKEN=""
        CFG_DOMAIN=""
    fi
}

normalize_conf() {
    [[ -n "${CFG_PORT}" ]] || CFG_PORT="8080"
    [[ -n "${CFG_WS_PATH}" ]] || CFG_WS_PATH="/ws"
    [[ "${CFG_WS_PATH}" == /* ]] || CFG_WS_PATH="/${CFG_WS_PATH}"

    # 兼容用户把 "cloudflared service install <token>" 整条命令粘进来
    CFG_TOKEN="${CFG_TOKEN##* }"
    CFG_TOKEN="${CFG_TOKEN//[[:space:]]/}"

    CFG_DOMAIN="${CFG_DOMAIN#http://}"
    CFG_DOMAIN="${CFG_DOMAIN#https://}"
    CFG_DOMAIN="${CFG_DOMAIN%%/*}"

    if [[ -z "${CFG_MODE}" ]]; then
        if [[ -n "${CFG_TOKEN}" ]]; then CFG_MODE="token"; else CFG_MODE="quick"; fi
    fi
}

validate_conf() {
    local path_re='^/[A-Za-z0-9._~/-]*$'

    if ! [[ "${CFG_PORT}" =~ ^[0-9]+$ ]] || (( CFG_PORT < 1 || CFG_PORT > 65535 )); then
        die "PORT 无效: ${CFG_PORT}"
    fi
    if ! [[ "${CFG_WS_PATH}" =~ ${path_re} ]]; then
        die "WS_PATH 只允许字母数字和 . _ ~ / -: ${CFG_WS_PATH}"
    fi
    case "${CFG_EDGE_IP_VERSION}" in ""|4|6|auto) ;; *) die "EDGE_IP_VERSION 只能是 4 / 6 / auto" ;; esac
    case "${CFG_PROTOCOL}" in ""|auto|http2|quic) ;; *) die "CF_PROTOCOL 只能是 auto / http2 / quic" ;; esac

    if [[ "${CFG_MODE}" == "token" && -z "${CFG_TOKEN}" ]]; then
        die "固定模式需要 ARGO_TOKEN"
    fi
}

save_conf() {
    mkdir -p "${WORK_DIR}"
    (
        umask 077
        {
            echo "CFG_MODE=$(sq "${CFG_MODE}")"
            echo "CFG_PORT=$(sq "${CFG_PORT}")"
            echo "CFG_WS_PATH=$(sq "${CFG_WS_PATH}")"
            echo "CFG_TOKEN=$(sq "${CFG_TOKEN}")"
            echo "CFG_DOMAIN=$(sq "${CFG_DOMAIN}")"
            echo "CFG_EDGE_IP_VERSION=$(sq "${CFG_EDGE_IP_VERSION}")"
            echo "CFG_PROTOCOL=$(sq "${CFG_PROTOCOL}")"
        } > "${ENV_FILE}"
    )
    chmod 600 "${ENV_FILE}"
}

# 读取已安装的配置(status / info / restart / logs 用)
load_installed() {
    [[ -f "${ENV_FILE}" && -x "${SB_BIN}" ]] \
        || die "未检测到安装(或是旧版脚本安装的), 请先运行: bash ${SELF} install"
    load_saved_conf
    normalize_conf
    read_uuid
}

read_uuid() {
    UUID=""
    if [[ -s "${UUID_FILE}" ]]; then
        UUID="$(cat "${UUID_FILE}")"
    fi
}

generate_uuid() {
    read_uuid
    if [[ -z "${UUID}" ]]; then
        UUID="$(cat /proc/sys/kernel/random/uuid)"
        echo "${UUID}" > "${UUID_FILE}"
    fi
    chmod 600 "${UUID_FILE}"
}

# ============================================================
# sing-box 配置
# ============================================================

generate_config() {
    info "生成 sing-box 配置..."

    # 不再包含已在 sing-box 1.13 被移除的 block 特殊出站
    cat > "${SB_CONFIG}" <<EOF
{
  "log": {
    "level": "error",
    "timestamp": true
  },
  "inbounds": [
    {
      "type": "vless",
      "tag": "vless-ws",
      "listen": "${LOCAL_HOST}",
      "listen_port": ${CFG_PORT},
      "users": [
        {
          "uuid": "${UUID}"
        }
      ],
      "transport": {
        "type": "ws",
        "path": "${CFG_WS_PATH}"
      }
    }
  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    }
  ]
}
EOF
    chmod 600 "${SB_CONFIG}"

    "${SB_BIN}" check -c "${SB_CONFIG}" || die "sing-box 配置检查失败"
    ok "sing-box 配置检查通过"
}

# ============================================================
# cloudflared 启动包装脚本
# 临时 / 固定两种模式共用同一个服务, 模式由 env 文件决定
# ============================================================

write_wrapper() {
    {
        printf '#!/bin/sh\n'
        printf 'ENV_FILE=%s\nBIN=%s\nLOG=%s\n' "$(sq "${ENV_FILE}")" "$(sq "${CLOUDFLARED_BIN}")" "$(sq "${CF_LOG}")"
        cat <<'EOF'
. "$ENV_FILE"

# 每次启动清空日志, 保证读到的是本次的临时域名
: > "$LOG"

ARGS="--no-autoupdate --loglevel info"
if [ -n "$CFG_EDGE_IP_VERSION" ]; then ARGS="$ARGS --edge-ip-version $CFG_EDGE_IP_VERSION"; fi
if [ -n "$CFG_PROTOCOL" ]; then ARGS="$ARGS --protocol $CFG_PROTOCOL"; fi

if [ "$CFG_MODE" = "token" ]; then
    # token 走环境变量, ps 里看不到
    TUNNEL_TOKEN="$CFG_TOKEN"
    export TUNNEL_TOKEN
    # shellcheck disable=SC2086
    exec "$BIN" tunnel $ARGS run >>"$LOG" 2>&1
fi

# shellcheck disable=SC2086
exec "$BIN" tunnel $ARGS --url "http://127.0.0.1:${CFG_PORT}" >>"$LOG" 2>&1
EOF
    } > "${WRAPPER}"
    chmod 700 "${WRAPPER}"
}

# ============================================================
# 服务管理
# ============================================================

write_services() {
    info "写入服务文件 (${INIT})..."

    if [[ "${INIT}" == "openrc" ]]; then
        cat > "/etc/init.d/${SB_SVC}" <<EOF
#!/sbin/openrc-run

name="sing-box"
description="Sing-box Mini"

command="${SB_BIN}"
command_args="run -c ${SB_CONFIG}"
command_background="yes"
pidfile="/run/sing-box.pid"
output_log="/var/log/sing-box.log"
error_log="/var/log/sing-box.err"

depend() {
    need net
    after firewall
}
EOF
        cat > "/etc/init.d/${CF_SVC}" <<EOF
#!/sbin/openrc-run

name="cloudflared"
description="Cloudflare Tunnel (Argo)"

command="${WRAPPER}"
command_background="yes"
pidfile="/run/cloudflared.pid"

depend() {
    need net
    after sing-box
}
EOF
        chmod +x "/etc/init.d/${SB_SVC}" "/etc/init.d/${CF_SVC}"
    else
        cat > "/etc/systemd/system/${SB_SVC}.service" <<EOF
[Unit]
Description=Sing-box Mini
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${SB_BIN} run -c ${SB_CONFIG}
Restart=always
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
        cat > "/etc/systemd/system/${CF_SVC}.service" <<EOF
[Unit]
Description=Cloudflare Tunnel (Argo)
After=network-online.target ${SB_SVC}.service
Wants=network-online.target

[Service]
Type=simple
ExecStart=${WRAPPER}
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
    fi
}

svc_enable() {
    if [[ "${INIT}" == "openrc" ]]; then
        rc-update add "$1" default >/dev/null 2>&1 || true
    else
        systemctl enable "$1" >/dev/null 2>&1 || true
    fi
}

svc_disable() {
    if [[ "${INIT}" == "openrc" ]]; then
        rc-update del "$1" default >/dev/null 2>&1 || true
    else
        systemctl disable "$1" >/dev/null 2>&1 || true
    fi
}

svc_restart() {
    if [[ "${INIT}" == "openrc" ]]; then
        rc-service "$1" stop >/dev/null 2>&1 || true
        rc-service "$1" start >/dev/null
    else
        systemctl restart "$1"
    fi
}

svc_stop() {
    if [[ "${INIT}" == "openrc" ]]; then
        rc-service "$1" stop >/dev/null 2>&1 || true
    else
        systemctl stop "$1" >/dev/null 2>&1 || true
    fi
}

svc_active() {
    if [[ "${INIT}" == "openrc" ]]; then
        rc-service "$1" status >/dev/null 2>&1
    else
        systemctl is-active --quiet "$1"
    fi
}

# 清理旧版脚本用 nohup 拉起的临时隧道进程
cleanup_legacy() {
    if [[ -f /var/run/cloudflared-quick.pid ]]; then
        kill "$(cat /var/run/cloudflared-quick.pid)" >/dev/null 2>&1 || true
        rm -f /var/run/cloudflared-quick.pid /var/log/cloudflared-quick.log
    fi
    if command -v pkill >/dev/null 2>&1; then
        pkill -f "${CLOUDFLARED_BIN} tunnel" >/dev/null 2>&1 || true
    fi
}

# ============================================================
# 隧道状态
# ============================================================

# 从日志取临时域名; 排除报错信息里出现的 api.trycloudflare.com
extract_quick_domain() {
    [[ -f "${CF_LOG}" ]] || return 0
    { grep -oE 'https://[a-z0-9-]+\.trycloudflare\.com' "${CF_LOG}" 2>/dev/null || true; } \
        | { grep -v '^https://api\.' || true; } \
        | sed -n '1p' \
        | sed 's#^https://##'
}

tunnel_registered() {
    [[ -f "${CF_LOG}" ]] && grep -q 'Registered tunnel connection' "${CF_LOG}" 2>/dev/null
}

current_domain() {
    if [[ "${CFG_MODE}" == "token" ]]; then
        printf '%s' "${CFG_DOMAIN}"
    else
        extract_quick_domain
    fi
}

wait_tunnel() {
    local i domain=""

    if [[ "${CFG_MODE}" == "quick" ]]; then
        info "等待临时隧道分配域名 (最多 45 秒)..."
        for i in $(seq 1 45); do
            domain="$(extract_quick_domain)"
            if [[ -n "${domain}" ]]; then break; fi
            sleep 1
        done
        if [[ -z "${domain}" ]]; then
            warn "没有获取到临时域名, cloudflared 日志末尾:"
            tail -n 20 "${CF_LOG}" 2>/dev/null || true
            warn "常见原因: 机器无法访问 Cloudflare / 需要 EDGE_IP_VERSION=6 或 CF_PROTOCOL=http2"
            return 0
        fi
        ok "临时域名: ${domain}"
    fi

    info "等待隧道连接建立 (最多 30 秒)..."
    for i in $(seq 1 30); do
        if tunnel_registered; then
            ok "隧道已连接到 Cloudflare"
            return 0
        fi
        sleep 1
    done
    warn "隧道暂未连接成功, 日志末尾:"
    tail -n 15 "${CF_LOG}" 2>/dev/null || true
    warn "若日志里有 timeout / 7844, 多半是 UDP 被封, 可执行: CF_PROTOCOL=http2 bash ${SELF} reconfig"
}

# ============================================================
# 节点信息
# ============================================================

urlencode() {
    local s="$1" out="" c i
    for (( i = 0; i < ${#s}; i++ )); do
        c="${s:i:1}"
        case "${c}" in
            [a-zA-Z0-9.~_-]) out+="${c}" ;;
            *) out+="$(printf '%%%02X' "'${c}")" ;;
        esac
    done
    printf '%s' "${out}"
}

generate_node() {
    local domain path
    domain="$(current_domain)"
    [[ -n "${domain}" ]] || return 1
    path="$(urlencode "${CFG_WS_PATH}")"
    printf 'vless://%s@%s:443?encryption=none&security=tls&sni=%s&fp=chrome&type=ws&host=%s&path=%s#VLESS-Argo-Mini' \
        "${UUID}" "${domain}" "${domain}" "${domain}" "${path}"
}

show_hints() {
    echo
    if [[ "${CFG_MODE}" == "quick" ]]; then
        warn "临时隧道: 域名会在 cloudflared 每次重启(包括重启机器)后变化,"
        echo "         变化后运行  bash ${SELF} info  获取新链接。仅建议测试使用。"
        echo "         长期使用请切到固定隧道:"
        echo "         ARGO_TOKEN='xxx' ARGO_DOMAIN='argo.example.com' bash ${SELF} reconfig"
        return 0
    fi

    echo "------------- 固定隧道: 还需要在 Cloudflare 面板配置一次回源 -------------"
    echo "  token 隧道的回源规则只能在面板里设置, 本机配置文件不起作用:"
    echo "  Zero Trust -> Networks -> Tunnels -> 选中该隧道 -> Public Hostname -> Add"
    echo "  (新版界面可能叫 Connectors / Published application routes)"
    echo "     Hostname : ${CFG_DOMAIN:-<你的域名>}"
    echo "     Service  : HTTP"
    echo "     URL      : ${LOCAL_HOST}:${CFG_PORT}"
    echo "  访问出现 1033 = 隧道没连上; 502 = 回源地址/端口填错。"
    echo "------------------------------------------------------------------------"
    if [[ -z "${CFG_DOMAIN}" ]]; then
        warn "未设置 ARGO_DOMAIN, 无法生成节点链接。补充方法:"
        echo "     ARGO_DOMAIN='argo.example.com' bash ${SELF} reconfig"
    fi
}

show_info() {
    local link mode_name

    if [[ "${CFG_MODE}" == "token" ]]; then mode_name="固定隧道"; else mode_name="临时隧道"; fi

    echo
    echo "=============================================="
    echo "                Sing-box Mini"
    echo "=============================================="
    echo "模式         : ${mode_name}"
    echo "UUID         : ${UUID}"
    echo "WS Path      : ${CFG_WS_PATH}"
    echo "本地监听     : ${LOCAL_HOST}:${CFG_PORT}"
    echo "配置文件     : ${SB_CONFIG}"

    if link="$(generate_node)"; then
        echo "Argo 域名    : $(current_domain)"
        echo
        echo "VLESS 链接:"
        echo "${link}"
        echo "${link}" > "${INFO_FILE}"
        chmod 600 "${INFO_FILE}"
        if [[ "${CFG_MODE}" == "quick" ]] && ! tunnel_registered; then
            echo
            warn "隧道当前未连接, 链接可能暂时不可用, 请查看: bash ${SELF} logs"
        fi
    else
        echo
        warn "当前没有可用的 Argo 域名, 无法生成链接"
    fi

    echo "=============================================="
    show_hints
}

# ============================================================
# 状态 / 日志
# ============================================================

port_listening() {
    local out re
    out="$(ss -ltn 2>/dev/null || netstat -ltn 2>/dev/null || true)"
    re="[:.]${CFG_PORT}[[:space:]]"
    [[ "${out}" =~ ${re} ]]
}

status() {
    local s
    load_installed

    echo
    echo "========== Sing-box Mini Status =========="
    echo "模式: ${CFG_MODE}    本地端口: ${CFG_PORT}"

    for s in "${SB_SVC}" "${CF_SVC}"; do
        if svc_active "${s}"; then ok "${s}: 运行中"; else warn "${s}: 未运行"; fi
    done

    if port_listening; then
        ok "端口 ${LOCAL_HOST}:${CFG_PORT} 正在监听"
    else
        warn "端口 ${CFG_PORT} 未监听 (sing-box 可能没起来)"
    fi

    if tunnel_registered; then
        ok "隧道已连接到 Cloudflare"
    else
        warn "隧道未连接 (看日志: bash ${SELF} logs)"
    fi

    local d
    d="$(current_domain)"
    if [[ -n "${d}" ]]; then echo "域名: ${d}"; fi
    echo
}

logs() {
    load_installed

    echo "===== sing-box ====="
    if [[ "${INIT}" == "openrc" ]]; then
        tail -n 50 /var/log/sing-box.log /var/log/sing-box.err 2>/dev/null || true
    else
        journalctl -u "${SB_SVC}" -n 50 --no-pager || true
    fi

    echo
    echo "===== cloudflared (${CF_LOG}) ====="
    tail -n 50 "${CF_LOG}" 2>/dev/null || true
}

# ============================================================
# 应用配置并(重)启动
# ============================================================

apply_config() {
    save_conf
    generate_uuid
    generate_config
    write_wrapper
    write_services

    svc_enable "${SB_SVC}"
    svc_enable "${CF_SVC}"

    info "启动 sing-box..."
    svc_restart "${SB_SVC}"
    sleep 1
    if ! svc_active "${SB_SVC}"; then
        logs || true
        die "sing-box 启动失败, 见上方日志"
    fi
    ok "sing-box 已启动"

    info "启动 cloudflared (${CFG_MODE})..."
    svc_restart "${CF_SVC}"
    wait_tunnel
}

restart_all() {
    load_installed
    info "重启服务..."
    svc_restart "${SB_SVC}"
    svc_restart "${CF_SVC}"
    wait_tunnel
    ok "重启完成"
    show_info
}

reconfig() {
    [[ -x "${SB_BIN}" && -x "${CLOUDFLARED_BIN}" ]] \
        || die "尚未安装, 请先运行: bash ${SELF} install"
    load_saved_conf
    apply_overrides
    normalize_conf
    validate_conf
    read_uuid
    apply_config
    show_info
}

# ============================================================
# 安装 / 卸载
# ============================================================

install_all() {
    check_root
    detect_os
    detect_arch
    install_dependencies

    mkdir -p "${WORK_DIR}"
    TMP_DIR="$(mktemp -d)"

    load_saved_conf
    apply_overrides
    normalize_conf
    validate_conf

    install_singbox
    install_cloudflared

    cleanup_legacy
    apply_config

    echo
    ok "Sing-box Mini 安装完成"
    show_info
}

uninstall() {
    local ans=""
    warn "将卸载 Sing-box Mini (服务、二进制、配置、日志)"
    if [[ -t 0 ]]; then
        read -r -p "确认卸载? [y/N] " ans || true
        [[ "${ans}" == "y" || "${ans}" == "Y" ]] || die "已取消"
    fi

    svc_stop "${CF_SVC}"
    svc_stop "${SB_SVC}"
    svc_disable "${CF_SVC}"
    svc_disable "${SB_SVC}"
    cleanup_legacy

    if [[ "${INIT}" == "openrc" ]]; then
        rm -f "/etc/init.d/${SB_SVC}" "/etc/init.d/${CF_SVC}"
    else
        rm -f "/etc/systemd/system/${SB_SVC}.service" "/etc/systemd/system/${CF_SVC}.service"
        systemctl daemon-reload
    fi

    rm -rf "${WORK_DIR}"
    rm -f "${CLOUDFLARED_BIN}" "${CLOUDFLARED_BIN}.new" \
        "${CF_LOG}" /var/log/sing-box.log /var/log/sing-box.err

    ok "Sing-box Mini 已卸载"
}

# ============================================================
# 帮助
# ============================================================

usage() {
    cat <<EOF

Sing-box Mini (VLESS + WS + Cloudflare Tunnel)

用法:
  bash $0 install       安装 / 升级 (会沿用已保存的配置)
  bash $0 reconfig      修改参数并重启, 不重新下载
  bash $0 info          查看节点信息
  bash $0 status        查看状态
  bash $0 restart       重启服务
  bash $0 logs          查看日志
  bash $0 uninstall     卸载

环境变量 (install / reconfig):
  PORT             本地端口, 默认 8080
  WS_PATH          WebSocket 路径, 默认 /ws
  ARGO_TOKEN       固定隧道 Token (设置后自动切到固定模式)
  ARGO_DOMAIN      固定隧道域名
  MODE=quick       从固定模式切回临时模式
  SB_VERSION       指定 sing-box 版本
  EDGE_IP_VERSION  4 | 6 | auto (纯 IPv6 机器用 6)
  CF_PROTOCOL      auto | http2 | quic (UDP 被封时用 http2)
  GH_PROXY         GitHub 下载加速前缀

示例:
  bash $0 install
  PORT=8081 bash $0 install
  ARGO_TOKEN='xxxx' ARGO_DOMAIN='argo.example.com' bash $0 install
  ARGO_DOMAIN='argo.example.com' bash $0 reconfig
  CF_PROTOCOL=http2 bash $0 reconfig

EOF
}

# ============================================================
# Main
# ============================================================

main() {
    case "${1:-help}" in
        install)   install_all ;;
        reconfig)  check_root; detect_os; reconfig ;;
        status)    check_root; detect_os; status ;;
        info)      check_root; detect_os; load_installed; show_info ;;
        restart)   check_root; detect_os; restart_all ;;
        logs)      check_root; detect_os; logs ;;
        uninstall) check_root; detect_os; uninstall ;;
        help|-h|--help) usage ;;
        *) usage; exit 1 ;;
    esac
}

# 被 source 时不自动执行(方便测试)
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi

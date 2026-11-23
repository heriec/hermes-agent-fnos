#!/bin/bash
# 公共路径与工具函数，生命周期脚本统一 source 本文件。
# 路径从脚本自身位置 / TRIM_* 推导，不硬编码 appname。

SELF_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# installed: .../target/scripts → APP_DIR=.../target ; APP_ROOT=/var/apps/<app>
# project:   <proj>/scripts       → APP_DIR=<proj>
if [ -n "${TRIM_APPDEST:-}" ]; then
    APP_DIR=$TRIM_APPDEST
else
    APP_DIR=$(dirname "$SELF_DIR")
    # 从 cmd/ 被直接调用时，APP_DIR 会是 /var/apps/<app>，而脚本在 .../target/scripts
    [ -d "$APP_DIR/scripts" ] || [ ! -d "$APP_DIR/target/scripts" ] || APP_DIR="$APP_DIR/target"
fi
APP_ROOT=$(dirname "$APP_DIR")
HOME_DIR=${TRIM_PKGHOME:-$APP_ROOT/home}
VAR_DIR=${TRIM_PKGVAR:-$APP_ROOT/var}

DATA_DIR="$HOME_DIR/data"
# 代码只有一份，由 git 管（update = fetch + reset --hard）。
# 源码从包复制到持久目录：target 会被升级整包替换，运行期的写入也不该落在包目录。
SRC_DIR="${HERMES_SRC_DIR:-$HOME_DIR/src}"
DIST_MARK="$DATA_DIR/.dist_commit"   # dist 对应的源码 commit（hermes update 后据此触发重建）
# 入口 = 包内 CPython + 一个 3 行脚本；依赖由 PM 在运行期挂载。
# 包里这份 python 只当解释器用（自带 pip，不含任何依赖）。
PY_BIN="$HOME_DIR/python/bin/python3"
HERMES_BIN="$HOME_DIR/bin/hermes"

# 端口：优先环境变量，其次打包时写入的 config/web_port（缺省 9219）
WEB_PORT=${HERMES_WEB_PORT:-$(cat "$APP_DIR/config/web_port" 2>/dev/null || echo 9219)}
LOG_FILE="$VAR_DIR/info.log"

# fnOS 的 git 来自 git fpk，它的 helper 目录有时指向不存在的路径，
# 于是 git 认不出 remote-https（网页更新就失败）。按"能不能找到 git-remote-https"实测决定。
if command -v git >/dev/null 2>&1; then
    ge=$(git --exec-path 2>/dev/null)
    if [ ! -e "$ge/git-remote-https" ]; then
        for c in /usr/lib/git-core /usr/libexec/git-core /usr/lib/git; do
            [ -e "$c/git-remote-https" ] && { export GIT_EXEC_PATH="$c"; break; }
        done
    fi
    unset ge
fi
export NPM_CONFIG_REGISTRY="${NPM_CONFIG_REGISTRY:-https://registry.npmmirror.com}"

# 包里带预构建终端（没有 node_modules）；node 由 PM 提供，不绑 fnOS 的 nodejs。
configure_bundled_tui() {
    local tui_dir="$SRC_DIR/ui-tui"
    if [ -f "$tui_dir/dist/entry.js" ]; then
        export HERMES_TUI_DIR="${HERMES_TUI_DIR:-$tui_dir}"
    else
        log "WARNING: bundled chat terminal entry missing: $tui_dir/dist/entry.js"
    fi
}

DASHBOARD_PID="$VAR_DIR/dashboard.pid"
GATEWAY_PID="$VAR_DIR/gateway.pid"
WATCHDOG_PID="$VAR_DIR/watchdog.pid"

mkdir -p "$VAR_DIR" 2>/dev/null || true

log() {
    local msg; msg="$(date '+%Y-%m-%d %H:%M:%S') - [${LOG_TAG:-app}] $*"
    echo "$msg"
    echo "$msg" >> "$LOG_FILE" 2>/dev/null || true
}

die() {
    log "ERROR: $*"
    [ -n "${TRIM_TEMP_LOGFILE:-}" ] && echo "$*" > "$TRIM_TEMP_LOGFILE" 2>/dev/null
    exit 1
}

pid_alive() {
    local f=$1 p
    [ -r "$f" ] || return 1
    p=$(head -n1 "$f" 2>/dev/null | tr -d '[:space:]')
    [ -n "$p" ] && kill -0 "$p" 2>/dev/null
}

read_pid() { head -n1 "$1" 2>/dev/null | tr -d '[:space:]'; }

# pid 文件可能指向被系统回收复用的 pid；下手前确认命令行属于本应用
own_pid() {
    local p=$1 cmd
    [ -r "/proc/$p/cmdline" ] || return 1
    cmd=$(tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null)
    case "$cmd" in
        *"$HOME_DIR"*|*"$APP_ROOT"*) return 0 ;;
        *) return 1 ;;
    esac
}

stop_pid_file() {
    local f=$1 p
    p=$(read_pid "$f")
    if [ -n "$p" ] && kill -0 "$p" 2>/dev/null; then
        if ! own_pid "$p"; then
            log "pid $p 不属于本应用（命令行不匹配），跳过不杀"
            rm -f "$f"; return 0
        fi
        kill -TERM "$p" 2>/dev/null || true
        for _ in 1 2 3 4 5; do
            kill -0 "$p" 2>/dev/null || break
            sleep 1
        done
        kill -KILL "$p" 2>/dev/null || true
    fi
    rm -f "$f"
}

# 只清理本安装目录下的进程，绝不误伤同机其它 Hermes。
# 实际进程是 PM 的 python -I -c "sys.path.insert(0, '<home>/src')"，命令行里带的是源码路径。
kill_own_processes() {
    # 三种形态都出现过：包内 python -m hermes_cli.main、python -I -c (sys.path 指向 src)、
    # 以及入口脚本本身。任何一种都不能漏，否则 stop/uninstall 后进程残留。
    local pat
    for pat in "$HOME_DIR/python/bin/python3" "$HOME_DIR/src" "$HOME_DIR/bin/hermes" \
               "$APP_DIR/scripts/watchdog.sh"; do
        pkill -TERM -f "$pat" 2>/dev/null || true
    done
    sleep 1
    for pat in "$HOME_DIR/python/bin/python3" "$HOME_DIR/src" "$HOME_DIR/bin/hermes"; do
        pkill -KILL -f "$pat" 2>/dev/null || true
    done
}

have_src() {
    [ -f "$SRC_DIR/pyproject.toml" ]
}

# 启动 dashboard 的进程需要 HERMES_TUI_DIR，否则会尝试重建 TUI（包里没有 node_modules）。
# 首次安装时 src 还没铺，静默跳过。
if [ -f "$SRC_DIR/ui-tui/dist/entry.js" ]; then
    configure_bundled_tui
fi

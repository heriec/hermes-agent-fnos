#!/bin/bash
# 公共路径与工具函数，生命周期脚本统一 source 本文件。
# 路径从脚本自身位置 / TRIM_* 推导，不硬编码 appname。

SELF_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# installed: .../target/scripts → APP_DIR=.../target ; APP_ROOT=/var/apps/<app>
# project:   <proj>/scripts       → APP_DIR=<proj>
APP_DIR=${TRIM_APPDEST:-$(dirname "$SELF_DIR")}
APP_ROOT=$(dirname "$APP_DIR")
HOME_DIR=${TRIM_PKGHOME:-$APP_ROOT/home}
VAR_DIR=${TRIM_PKGVAR:-$APP_ROOT/var}
ETC_DIR=${TRIM_PKGETC:-$APP_ROOT/etc}

DATA_DIR="$HOME_DIR/data"
# 代码只有一份，由 git 管（update = fetch + reset --hard）；历史只记在 versions.json。
# 源码从包复制到持久目录：target 会被升级整包替换，运行期的写入也不该落在包目录。
SRC_DIR="${HERMES_SRC_DIR:-$HOME_DIR/src}"
LEDGER="$HOME_DIR/versions.json"
DIST_MARK="$DATA_DIR/.dist_commit"   # dist 对应的源码 commit（hermes update 后据此触发重建）
# 入口 = 包内 CPython + 一个 3 行脚本；依赖由 PM 在运行期挂载。
PY_BIN="$HOME_DIR/python/bin/python3"
HERMES_BIN="$HOME_DIR/bin/hermes"

# 端口：优先环境变量，其次打包时写入的 config/web_port（缺省 9219）
WEB_PORT=${HERMES_WEB_PORT:-$(cat "$APP_DIR/config/web_port" 2>/dev/null || echo 9219)}
LOG_FILE="$VAR_DIR/info.log"

# fnOS 的 git 来自 git fpk，--exec-path 指向不存在的目录（git 找不到 remote-https），
# 指回系统的 git-core；npm 走国内镜像。
if command -v git >/dev/null 2>&1 && [ ! -d "$(git --exec-path 2>/dev/null)" ]; then
    export GIT_EXEC_PATH=/usr/lib/git-core
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

stop_pid_file() {
    local f=$1 p
    p=$(read_pid "$f")
    if [ -n "$p" ] && kill -0 "$p" 2>/dev/null; then
        kill -TERM "$p" 2>/dev/null || true
        for _ in 1 2 3 4 5; do
            kill -0 "$p" 2>/dev/null || break
            sleep 1
        done
        kill -KILL "$p" 2>/dev/null || true
    fi
    rm -f "$f"
}

# 只清理本安装目录下的进程，绝不误伤同机其它 Hermes
kill_own_processes() {
    pkill -TERM -f "$HOME_DIR/bin/hermes" 2>/dev/null || true
    sleep 1
    pkill -KILL -f "$HOME_DIR/bin/hermes" 2>/dev/null || true
}

have_src() {
    [ -f "$SRC_DIR/pyproject.toml" ]
}

# 启动 dashboard 的进程需要 HERMES_TUI_DIR，否则会尝试重建 TUI（包里没有 node_modules）。
# 首次安装时 src 还没铺，静默跳过。
[ -f "$SRC_DIR/ui-tui/dist/entry.js" ] && configure_bundled_tui

# ---------------------------------------------------------------- 版本账本 versions.json
ledger_record() {
    local ver="$1" kernel="$2" commit="$3" source="$4"
    local py="$PY_BIN"
    [ -x "$py" ] || py=$(command -v python3 2>/dev/null) || return 0
    "$py" - "$LEDGER" "$ver" "$kernel" "$commit" "$source" <<'PY' >>"$LOG_FILE" 2>&1 || true
import json, os, sys, datetime
path, ver, kernel, commit, source = sys.argv[1:6]
now = datetime.datetime.now().astimezone().isoformat(timespec="seconds")
try:
    db = json.load(open(path))
except Exception:
    db = {"current": {}, "history": []}
entry = {"version": ver, "kernel": kernel, "commit": commit,
         "installed_at": now, "source": source}
hist = [h for h in db.get("history", [])
        if not (h.get("commit") == commit and h.get("version") == ver)]
hist.insert(0, entry)
db["current"] = entry
db["history"] = hist[:30]
tmp = path + ".tmp"
json.dump(db, open(tmp, "w"), ensure_ascii=False, indent=2)
os.replace(tmp, path)
PY
}

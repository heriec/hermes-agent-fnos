#!/bin/bash
# 安装 / 升级共用的内核安装流程。用法: setup-core.sh install|upgrade
#
# 落盘布局（PKGHOME）：
#   python/   包内 CPython（只当解释器，依赖由 PM 提供）
#   src/      内核源码，带 .git；网页「更新 Hermes」在这里 fetch + reset
#   bin/hermes  入口脚本（PYTHONPATH -> src，解释器 -> python/bin/python3）
#   data/     用户数据，安装流程从不写这里（只补 .env 里的 Web 登录凭据）
#
# 依赖由 Hermes 自带的 PM 管理（data/.hermes、data/installs），本脚本只触发一次 pm install。

set -e
MODE=${1:-install}
. "$(dirname "$0")/lib.sh"
LOG_TAG="$MODE"

trap 'die "脚本出错(L$LINENO)"' ERR

# ---------------------------------------------------------------- 路径与版本
for f in hermes-version.env package-version.env; do
    [ -f "$APP_DIR/config/bootstrap/$f" ] || die "缺少 config/bootstrap/$f"
    # shellcheck disable=SC1090
    . "$APP_DIR/config/bootstrap/$f"
done
[ -n "${HERMES_VERSION:-}" ] || die "hermes-version.env 未定义 HERMES_VERSION"
PKG_VER="${PKG_VERSION:-unknown}"
PKG_COMMIT=${PKG_COMMIT:-}
# 包标识 = 版本 + 内核 commit：同版本但换了 commit 也要重铺源码
PKG_MARK="$PKG_VER-${PKG_COMMIT:0:8}"

log "mode=$MODE version=$HERMES_VERSION"
log "APP_DIR=$APP_DIR HOME_DIR=$HOME_DIR DATA_DIR=$DATA_DIR"

# ---------------------------------------------------------------- 数据目录骨架
mkdir -p "$DATA_DIR"/{sessions,skills,memories,workspace,logs,hooks,bin,cron/output,profiles}

# ---------------------------------------------------------------- 系统库依赖
# Hermes 自带的 pm 会下载自己的 node（v26），它需要 libatomic.so.1，而 fnOS 默认不带；
# 缺了以后对话面板 / LSP 都会以「node 退出码 127」失败。安装期（root）顺手补上，失败不阻塞。
# 注意：fnOS 上 ldconfig -p 不一定列出它（实测装了也查不到），所以文件存在也认。
if ls /usr/lib/*/libatomic.so.1 /lib/*/libatomic.so.1 >/dev/null 2>&1 || ldconfig -p 2>/dev/null | grep -q 'libatomic\.so\.1'; then
    log "libatomic.so.1 已存在"
else
    log "缺少 libatomic.so.1（Hermes 自管 node 需要），安装 libatomic1"
    if DEBIAN_FRONTEND=noninteractive apt-get install -y libatomic1 >>"$LOG_FILE" 2>&1; then
        log "libatomic1 安装成功"
    else
        log "WARNING: libatomic1 安装失败——Hermes 自管 node 与 LSP 会起不来，可手动执行 apt-get install -y libatomic1"
    fi
fi
mkdir -p "$VAR_DIR" "$HOME_DIR/bin"

# ---------------------------------------------------------------- 源码落盘（纯复制，不跑 git）
# target 会被升级整包替换，源码放 PKGHOME 才能稳定；运行期会往里写 dist/node_modules。
PKG_SRC_LOCAL="$APP_DIR/src"
[ -f "$PKG_SRC_LOCAL/pyproject.toml" ] || die "安装包缺少 src（pyproject.toml 不存在）"
MARK="$HOME_DIR/.package-version"
# 已有源码比包里这份新（用户点过网页更新）时保留，不覆盖。
# 本脚本以 root 运行，git 需要 safe.directory 才肯读这个仓库。
GIT_SRC=(git -c "safe.directory=$SRC_DIR" -C "$SRC_DIR")
SELF_UPDATED=0
if [ -d "$SRC_DIR/.git" ] && [ -n "$PKG_COMMIT" ]; then
    cur_head=$("${GIT_SRC[@]}" rev-parse HEAD 2>/dev/null || true)
    if [ -n "$cur_head" ] && [ "$cur_head" != "$PKG_COMMIT" ]; then
        # 只有"包内 commit 确实是当前 HEAD 的祖先"才保留：说明用户网页更新过、源码更新。
        # commit 在已装仓库里根本不存在时不算更新（那正是装新包该铺源码的情况）。
        if "${GIT_SRC[@]}" merge-base --is-ancestor "$PKG_COMMIT" "$cur_head" 2>/dev/null; then
            SELF_UPDATED=1
        fi
    fi
fi
if [ "$SELF_UPDATED" = "1" ]; then
    log "keep self-updated source (HEAD ${cur_head:0:10} ahead of pkg ${PKG_COMMIT:0:10}), skip source sync"
    echo "$PKG_MARK" > "$MARK"
elif [ ! -f "$SRC_DIR/pyproject.toml" ] || [ "$(cat "$MARK" 2>/dev/null)" != "$PKG_MARK" ]; then
    log "syncing source: $PKG_SRC_LOCAL -> $SRC_DIR (pkg=$PKG_MARK, prev=$(cat "$MARK" 2>/dev/null || echo none))"
    mkdir -p "$SRC_DIR"
    find "$SRC_DIR" -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null || true
    cp -a --reflink=auto "$PKG_SRC_LOCAL"/. "$SRC_DIR"/ 2>>"$LOG_FILE" || die "源码复制失败"
    echo "$PKG_MARK" > "$MARK"
else
    log "source up to date (pkg=$PKG_MARK): $SRC_DIR"
fi
[ -f "$SRC_DIR/hermes_cli/web_dist/index.html" ] || log "WARNING: 包内 web_dist 缺失（Web 界面会空白）"

# 真实落盘源码的 commit（用户网页更新过时比包内 commit 新）
SRC_HEAD=$("${GIT_SRC[@]}" rev-parse HEAD 2>/dev/null || true)
[ -n "$SRC_HEAD" ] || SRC_HEAD="$PKG_COMMIT"

# ---------------------------------------------------------------- 启动器
# 入口 = 包内 CPython + 一个 3 行脚本。依赖不在这里装：hermes_bootstrap 启动时
# 把 PM 提交的那一代依赖挂到 sys.path。
DRY=${HERMES_FPK_DRY_RUN:-0}
# HERMES_HOME 必须显式给出：不给的话 hermes 会按 $HOME/.hermes 建缓存/日志目录，
# 于是每次安装都在 data/ 下多出一个空的 .hermes/。
export HOME="$DATA_DIR" HERMES_HOME="$DATA_DIR"
if [ "$DRY" = "1" ]; then
    log "DRY RUN: 跳过 launcher/pm"
    mkdir -p "$HOME_DIR/bin"
    printf '#!/bin/sh\nexit 0\n' > "$HERMES_BIN"
    chmod +x "$HERMES_BIN"
else
# 1) 包内 CPython 落到 HOME（版本不同就替换，否则新包要求更高的 python 时会一直用旧的）
if [ -d "$APP_DIR/python" ]; then
    NEW_PY=$("$APP_DIR/python/bin/python3" -V 2>&1 || true)
    CUR_PY=$([ -x "$PY_BIN" ] && "$PY_BIN" -V 2>&1 || true)
    if [ "$NEW_PY" != "$CUR_PY" ]; then
        log "installing bundled python ($NEW_PY) -> $HOME_DIR/python"
        rm -rf "$HOME_DIR/python"
        cp -a --reflink=auto "$APP_DIR/python" "$HOME_DIR/python" >>"$LOG_FILE" 2>&1 \
            || die "包内 python 复制失败"
    fi
fi
[ -x "$PY_BIN" ] || die "找不到包内 CPython（$APP_DIR/python）"

# 2) hermes 入口
mkdir -p "$HOME_DIR/bin"
cat > "$HERMES_BIN" <<WRAP
#!/bin/sh
export PYTHONPATH="$SRC_DIR\${PYTHONPATH:+:\$PYTHONPATH}"
exec "$PY_BIN" -m hermes_cli.main "\$@"
WRAP
chmod +x "$HERMES_BIN"

# 3) 清掉历史遗留的入口 venv（早期版本建过）
[ -d "$HOME_DIR/venv" ] && { rm -rf "$HOME_DIR/venv"; log "removed legacy venv"; }

# 4) 依赖安装（唯一一次）：Python 依赖 + node/npm/ffmpeg/ripgrep 等工具
# pm.cli 是 stdlib-only 入口，依赖还没装时也能运行。
# chromium、cua-driver 是上游"默认但可选"的大件（约 475M），本包默认不装；
# 需要时执行 hermes pm install chromium / cua-driver。
export UV_INDEX_URL="https://pypi.tuna.tsinghua.edu.cn/simple"
pm_run() {
    local sub=$1; shift
    HERMES_HOME="$DATA_DIR" HOME="$DATA_DIR" UV_INDEX_URL="$UV_INDEX_URL" PYTHONPATH="$SRC_DIR" \
        "$PY_BIN" -c "import sys; from pm.cli import main; sys.exit(main(['$sub'] + sys.argv[1:]))" "$@" \
        >>"$LOG_FILE" 2>&1
}
if pm_run install --without agent-browser --without cua-driver; then
    log "pm sync ok"
    pm_run gc && log "pm gc ok" || log "pm gc skipped"
else
    log "WARNING: pm install 失败（依赖缺失；网页更新也会报 NoCommittedEnvironment）"
    [ -n "${TRIM_TEMP_LOGFILE:-}" ] && echo "依赖安装失败，请检查网络后重启应用，或执行 hermes pm install" > "$TRIM_TEMP_LOGFILE" 2>/dev/null
fi

ACTUAL=$("$HERMES_BIN" --version 2>/dev/null | head -1 || echo unknown)
log "launcher ready: $ACTUAL"
fi  # DRY

# ---------------------------------------------------------------- 安装戳兜底
# install-stamp.json 的 commit 若是全零，Hermes 会当占位符 → Web 显示 unknown。
# 校准成真实落盘的 HEAD（用户网页更新过时，它比包内 commit 新）。
STAMP="$SRC_DIR/install-stamp.json"
if [ -n "$SRC_HEAD" ] && ! printf '%s' "$SRC_HEAD" | grep -qE '^0+$'; then
    if "$PY_BIN" - "$STAMP" "$SRC_HEAD" "$HERMES_VERSION" <<'PY' >>"$LOG_FILE" 2>&1
import json, sys, pathlib
path, commit, ver = sys.argv[1:4]
p = pathlib.Path(path)
try:
    d = json.loads(p.read_text())
except Exception:
    d = {}
if (d.get("commit") or "").strip() == commit and d.get("baseVersion") == ver:
    raise SystemExit(0)
d.update({
    "schemaVersion": d.get("schemaVersion", 2),
    "commit": commit, "baseVersion": ver, "displayVersion": ver,
    "source": "fpk", "payload": "bootstrap",
    "updateMechanism": "app-installer",
    "distance": d.get("distance") or 0, "dirty": False,
})
p.write_text(json.dumps(d, indent=2) + "\n")
print("stamp calibrated:", commit[:12], ver)
PY
    then log "版本戳校准完成"
    else log "WARNING: 版本戳校准失败（Web 可能显示 unknown）"
    fi
else
    log "无 PKG_COMMIT，沿用包内 install-stamp.json"
fi

# ---------------------------------------------------------------- Web 登录（basic provider）
# 密码只在第一次安装时确定：既有哈希就一律沿用，升级/重装都不改。
# 只有首次安装且向导没传密码时才生成随机密码，写进安装提示。
ENV_FILE="$DATA_DIR/.env"
DASH_USER=${HERMES_DASH_USER:-${WIZARD_HERMES_DASH_USER:-${hermes_dash_user:-${wizard_hermes_dash_user:-admin}}}}
DASH_USER=${DASH_USER//\'/}     # 值要写进 .env 的单引号里
DASH_PASS=${HERMES_DASH_PASSWORD:-${WIZARD_HERMES_DASH_PASSWORD:-${hermes_dash_password:-${wizard_hermes_dash_password:-}}}}

env_set() {   # env_set KEY=VALUE ...：改已有键、没有就追加，绝不产生重复行
    "$PY_BIN" - "$ENV_FILE" "$@" <<'PY'
import os, sys, pathlib
path = pathlib.Path(sys.argv[1])
items = [a.split("=", 1) for a in sys.argv[2:]]
keys = {k for k, _ in items}
lines = path.read_text(encoding="utf-8").splitlines() if path.exists() else []
kept = [l for l in lines if not any(l.startswith(k + "=") for k in keys)]
path.write_text("\n".join(kept + [f"{k}='{v}'" for k, v in items]) + "\n", encoding="utf-8")
if path.exists():
    os.chmod(path, 0o600)
PY
}

if grep -q '^HERMES_DASHBOARD_BASIC_AUTH_PASSWORD_HASH=' "$ENV_FILE" 2>/dev/null; then
    log "Web 登录密码沿用第一次安装时设置的，不修改"
else
    if [ -z "$DASH_PASS" ]; then
        DASH_PASS=$(openssl rand -base64 18 2>/dev/null | tr -d '\n')
        log "WARNING: 安装时未提供密码，已生成随机密码"
        [ -n "${TRIM_TEMP_LOGFILE:-}" ] && echo "Web 登录：$DASH_USER / $DASH_PASS" >> "$TRIM_TEMP_LOGFILE"
    fi
    if [ "$DRY" = "1" ]; then
        log "DRY: 跳过 Web 凭据写入"
    else
        # 只用标准库算 scrypt，格式与 plugins.dashboard_auth.basic.hash_password 一致
        DASH_HASH=$(printf '%s' "$DASH_PASS" | "$PY_BIN" -c '
import base64, hashlib, secrets, sys
salt = secrets.token_bytes(16)
dk = hashlib.scrypt(sys.stdin.read().encode("utf-8"), salt=salt, n=16384, r=8, p=1, dklen=32, maxmem=0)
print("scrypt$16384$8$1$%s$%s" % (base64.b64encode(salt).decode(), base64.b64encode(dk).decode()))
' 2>>"$LOG_FILE")
        [ -n "$DASH_HASH" ] || die "密码哈希生成失败"
        SECRET=$(openssl rand -base64 32 2>/dev/null | tr -d '\n')
        env_set "HERMES_DASHBOARD_BASIC_AUTH_USERNAME=$DASH_USER" \
                "HERMES_DASHBOARD_BASIC_AUTH_PASSWORD_HASH=$DASH_HASH" \
                "HERMES_DASHBOARD_BASIC_AUTH_SECRET=$SECRET"
        log "Web 登录凭据已写入（user=$DASH_USER）"
    fi
fi

# ---------------------------------------------------------------- 源码指向校验
# 确认入口脚本 import 到的是本次安装的源码。
if [ "$DRY" != "1" ] && [ -x "$PY_BIN" ]; then
    CUR_SRC=$(PYTHONPATH="$SRC_DIR" "$PY_BIN" -c 'import hermes_cli,os;print(os.path.dirname(os.path.dirname(hermes_cli.__file__)))' 2>/dev/null || true)
    log "source -> ${CUR_SRC:-unknown}"
fi

# 包内 dist 是按包内 commit 构建的；源码被网页更新过（HEAD 更新）时，
# marker 要记包内 commit，watchdog 才会重建，否则会拿旧 dist 配新后端。
if [ -d "$SRC_DIR/.git" ] && [ -n "$PKG_COMMIT" ]; then
    if [ -f "$SRC_DIR/hermes_cli/web_dist/index.html" ]; then
        echo "$PKG_COMMIT" > "$DIST_MARK"
        log "dist marker: $(cut -c1-10 "$DIST_MARK") (built) | src HEAD: ${SRC_HEAD:0:10}"
    else
        rm -f "$DIST_MARK"   # dist 不完整就别写 marker，交给 watchdog 重建
        log "WARNING: web_dist 缺失，已清 marker，启动后会自动重建"
    fi
fi

# ---------------------------------------------------------------- 权限
if [ -n "${TRIM_USERNAME:-}" ]; then
    chown -R "$TRIM_USERNAME:$TRIM_USERNAME" "$APP_DIR" 2>>"$LOG_FILE" || log "WARNING: chown app dir failed"
    chown -R "$TRIM_USERNAME:$TRIM_USERNAME" "$HOME_DIR" 2>>"$LOG_FILE" || log "WARNING: chown home failed"
    chown -R "$TRIM_USERNAME:$TRIM_USERNAME" "$VAR_DIR" 2>>"$LOG_FILE" || log "WARNING: chown var failed"
    chmod 775 "$APP_DIR" 2>/dev/null || true
    # 只收紧应用自己写的数据；tools/ 与 installs/ 是 PM 管的（几万个文件），
    # 属主已由上面的 chown -R 修好，这里再递归一遍纯属白等。
    for d in "$DATA_DIR"/*; do
        case "$d" in
            "$DATA_DIR/tools"|"$DATA_DIR/installs"|"$DATA_DIR/cache") continue ;;
        esac
        chmod -R 750 "$d" 2>/dev/null || true
    done
    chmod 750 "$DATA_DIR" 2>/dev/null || true
    chmod 600 "$DATA_DIR/.env" 2>/dev/null || true   # 上面会不会放宽先不管，凭据文件固定 600
else
    log "TRIM_USERNAME 为空，跳过权限修复"
fi

trap - ERR
log "$MODE finished: $HERMES_VERSION"
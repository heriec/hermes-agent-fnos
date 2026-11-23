#!/bin/bash
# 安装 / 升级共用的内核安装流程。用法: setup-core.sh install|upgrade
#
# 落盘布局（PKGHOME）：
#   python/   包内 CPython 解释器
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
        # 包内 commit 是 HEAD 的祖先（shallow 里缺对象时也算）→ 保留现有源码
        if "${GIT_SRC[@]}" merge-base --is-ancestor "$PKG_COMMIT" "$cur_head" 2>/dev/null \
           || ! "${GIT_SRC[@]}" cat-file -e "$PKG_COMMIT" 2>/dev/null; then
            SELF_UPDATED=1
        fi
    fi
fi
if [ "$SELF_UPDATED" = "1" ] && [ -f "$SRC_DIR/pyproject.toml" ]; then
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

# ---------------------------------------------------------------- 启动器
# 入口 = 包内 CPython + 一个 3 行脚本。依赖不在这里装：hermes_bootstrap 启动时
# 把 PM 提交的 generation 挂到 sys.path。
DRY=${HERMES_FPK_DRY_RUN:-0}
export HOME="$DATA_DIR"
if [ "$DRY" = "1" ]; then
    log "DRY RUN: 跳过 launcher/pm"
    mkdir -p "$HOME_DIR/bin"
    printf '#!/bin/sh\nexit 0\n' > "$HERMES_BIN"
    chmod +x "$HERMES_BIN"
else
# 1) 包内 CPython 落到 HOME
if [ ! -x "$PY_BIN" ] && [ -d "$APP_DIR/python" ]; then
    log "installing bundled python -> $HOME_DIR/python"
    rm -rf "$HOME_DIR/python"
    cp -a --reflink=auto "$APP_DIR/python" "$HOME_DIR/python" >>"$LOG_FILE" 2>&1 \
        || die "包内 python 复制失败"
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
# 按包内 package-version.env 的 PKG_COMMIT 校准（用包内 CPython，不依赖系统 python）。
STAMP="$SRC_DIR/install-stamp.json"
if [ -n "$PKG_COMMIT" ] && ! printf '%s' "$PKG_COMMIT" | grep -qE '^0+$'; then
    if "$PY_BIN" - "$STAMP" "$PKG_COMMIT" "$HERMES_VERSION" <<'PY' >>"$LOG_FILE" 2>&1
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
ENV_FILE="$DATA_DIR/.env"
if grep -q '^HERMES_DASHBOARD_BASIC_AUTH_PASSWORD_HASH=' "$ENV_FILE" 2>/dev/null; then
    log "dashboard auth already configured, skip"
else
    # 向导字段：fnOS 不同版本传进来的变量名大小写不一致（实测 mefrp 同时兼容 WIZARD_* / wizard_*），
    # 这里全部兜一遍，避免「向导里明明填了密码却没生效」。
    DASH_USER=${HERMES_DASH_USER:-${WIZARD_HERMES_DASH_USER:-${hermes_dash_user:-${wizard_hermes_dash_user:-admin}}}}
    DASH_PASS=${HERMES_DASH_PASSWORD:-${WIZARD_HERMES_DASH_PASSWORD:-${hermes_dash_password:-${wizard_hermes_dash_password:-}}}}
    if [ -z "$DASH_PASS" ]; then
        DASH_PASS=$(openssl rand -base64 18 2>/dev/null | tr -d '\n')
        log "WARNING: 未提供密码，已生成随机密码"
        [ -n "${TRIM_TEMP_LOGFILE:-}" ] && echo "Web 登录：$DASH_USER / $DASH_PASS" >> "$TRIM_TEMP_LOGFILE"
    fi
    if [ "$DRY" = "1" ]; then
        DASH_HASH='scrypt$dryrun'
    else
        # 只用标准库算 scrypt（格式与 plugins.dashboard_auth.basic.hash_password 一致），
        # 避免安装阶段因 httpx 等运行时依赖未就绪而失败
        DASH_HASH=$(printf '%s' "$DASH_PASS" | "$PY_BIN" -c '
import base64, hashlib, secrets, sys
pw = sys.stdin.read()
salt = secrets.token_bytes(16)
dk = hashlib.scrypt(pw.encode("utf-8"), salt=salt, n=16384, r=8, p=1, dklen=32, maxmem=0)
print("scrypt$16384$8$1$%s$%s" % (base64.b64encode(salt).decode(), base64.b64encode(dk).decode()))
' 2>>"$LOG_FILE")
    fi
    [ -n "$DASH_HASH" ] || die "密码哈希生成失败"
    SECRET=$(openssl rand -base64 32 2>/dev/null | tr -d '\n')
    {
        echo ""
        echo "# Hermes Web 登录（dashboard basic provider）"
        echo "HERMES_DASHBOARD_BASIC_AUTH_USERNAME='$DASH_USER'"
        echo "HERMES_DASHBOARD_BASIC_AUTH_PASSWORD_HASH='$DASH_HASH'"
        echo "HERMES_DASHBOARD_BASIC_AUTH_SECRET='$SECRET'"
    } >> "$ENV_FILE"
    chmod 600 "$ENV_FILE" 2>/dev/null || true
    log "dashboard auth configured for user=$DASH_USER"
fi

# ---------------------------------------------------------------- 源码指向校验
# 确认入口脚本 import 到的是本次安装的源码。
if [ "$DRY" != "1" ] && [ -x "$PY_BIN" ]; then
    CUR_SRC=$(PYTHONPATH="$SRC_DIR" "$PY_BIN" -c 'import hermes_cli,os;print(os.path.dirname(os.path.dirname(hermes_cli.__file__)))' 2>/dev/null || true)
    log "source -> ${CUR_SRC:-unknown}"
fi

# 包内 dist 就是为当前 HEAD 构建的：写 marker，启动时不会白触发一次重建
if [ -d "$SRC_DIR/.git" ]; then
    "${GIT_SRC[@]}" rev-parse HEAD 2>/dev/null > "$DIST_MARK" || true
    log "dist marker: $(cat "$DIST_MARK" 2>/dev/null | cut -c1-10)"
fi

# ---------------------------------------------------------------- 版本账本
ACTUAL_HEAD=$("${GIT_SRC[@]}" rev-parse HEAD 2>/dev/null || true)
[ -n "$ACTUAL_HEAD" ] || ACTUAL_HEAD="$PKG_COMMIT"
ledger_record "$PKG_VER" "$HERMES_VERSION" "$ACTUAL_HEAD" "fpk"
log "version ledger: $(grep -c '' "$LEDGER" 2>/dev/null || echo 0) lines @ $LEDGER"

# ---------------------------------------------------------------- 权限
if [ -n "${TRIM_USERNAME:-}" ]; then
    chown -R "$TRIM_USERNAME:$TRIM_USERNAME" "$APP_DIR" 2>>"$LOG_FILE" || log "WARNING: chown app dir failed"
    chown -R "$TRIM_USERNAME:$TRIM_USERNAME" "$HOME_DIR" 2>>"$LOG_FILE" || log "WARNING: chown home failed"
    # PM 状态目录里若残留 root 文件，应用用户建 .leases 会失败（install state is not writable）。
    for pd in "$DATA_DIR/.hermes" "$DATA_DIR/installs"; do
        [ -d "$pd" ] || continue
        n=$(find "$pd" -user root 2>/dev/null | wc -l)
        [ "$n" -gt 0 ] && { log "perms: 修复 $pd 下 $n 个 root 条目"; chown -R "$TRIM_USERNAME:$TRIM_USERNAME" "$pd" 2>>"$LOG_FILE" || true; }
    done
    chown -R "$TRIM_USERNAME:$TRIM_USERNAME" "$VAR_DIR" 2>>"$LOG_FILE" || log "WARNING: chown var failed"
    chmod 775 "$APP_DIR" 2>/dev/null || true
    chmod -R 750 "$DATA_DIR" 2>/dev/null || true
else
    log "TRIM_USERNAME 为空，跳过权限修复"
fi

echo "$HERMES_VERSION" > "$VAR_DIR/installed_version"
trap - ERR
log "$MODE finished: $HERMES_VERSION"
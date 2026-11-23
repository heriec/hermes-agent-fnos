#!/bin/bash
# 打包脚本：把指定 Hermes 源码版本打成 fpk。
#
#   ./build.sh --from /vol1/@appcenter/hermes-agent/hermes-src --no-web   # 用本机已构建源码
#   ./build.sh --tag 2026.10.30                                          # 克隆并构建前端（需网络）
#
# 可选: --appname <name> --version <pkgver> --kernel-version <tag> --port <port> --no-web
#
# 产物: <项目根>/<appname>.fpk
# 说明: 所有组装都在 .build/pkg 里做，项目目录只保留脚本与配置。
set -euo pipefail

ROOT=$(cd "$(dirname "$0")" && pwd)
# node 优先用 PATH 里的（CI/开发机）
NODE_BIN=${NODE_BIN:-$(dirname "$(command -v node 2>/dev/null || echo /usr/bin/node)")}
# fnOS 的 git fpk 有 --exec-path 指向不存在的目录，指回系统 git-core
if [ ! -d "$(git --exec-path 2>/dev/null)" ]; then export GIT_EXEC_PATH=/usr/lib/git-core; fi
WORK="$ROOT/.build"
PKG="$WORK/pkg"

SRC=""
TAG=""
DO_WEB=1
APPNAME="hermes-agent"
VERSION="0.0.0"
KERNEL_VERSION=""
COMMIT=""
COMMIT_DATE=""
PORT="9219"

while [ $# -gt 0 ]; do
    case "$1" in
        --from) SRC="$2"; shift 2 ;;
        --tag) TAG="$2"; shift 2 ;;
        --no-web) DO_WEB=0; shift ;;
        --appname) APPNAME="$2"; shift 2 ;;
        --version) VERSION="$2"; shift 2 ;;
        --kernel-version) KERNEL_VERSION="$2"; shift 2 ;;
        --commit) COMMIT="$2"; shift 2 ;;
        --commit-date) COMMIT_DATE="$2"; shift 2 ;;
        --port) PORT="$2"; shift 2 ;;
        -h|--help) sed -n '2,10p' "$0"; exit 0 ;;
        *) echo "unknown arg: $1" >&2; exit 2 ;;
    esac
done

[ -n "$SRC" ] || [ -n "$TAG" ] || { echo "需要 --from <dir> 或 --tag <tag>" >&2; exit 2; }

rm -rf "$WORK"
mkdir -p "$PKG/app"

# ---------------------------------------------------------------- 源码
if [ -n "$TAG" ]; then
    echo ">>> clone tag $TAG"
    SRC="$WORK/src"
    ok=0
    for URL in \
        "https://ghproxy.net/https://github.com/NousResearch/hermes-agent.git" \
        "https://github.com/NousResearch/hermes-agent.git"
    do
        if git clone --depth 1 --branch "$TAG" "$URL" "$SRC" 2>/dev/null; then ok=1; break; fi
    done
    [ "$ok" = 1 ] || { echo "clone failed (tag=$TAG)"; exit 1; }
fi
[ -f "$SRC/pyproject.toml" ] || { echo "not a hermes source tree: $SRC" >&2; exit 1; }

# ---------------------------------------------------------------- 前端构建
if [ "$DO_WEB" = 1 ]; then
    export PATH="$NODE_BIN:$PATH"
    command -v node >/dev/null || { echo "node not found ($NODE_BIN)"; exit 1; }
    node -v
    echo ">>> build ui-tui"
    ( cd "$SRC/ui-tui" && npm ci --no-audit --no-fund && npm run build )
    [ -f "$SRC/ui-tui/dist/entry.js" ] || { echo "ui-tui dist missing"; exit 1; }
    echo ">>> build web"
    ( cd "$SRC/web" && npm ci --no-audit --no-fund && npm run build )
    [ -f "$SRC/hermes_cli/web_dist/index.html" ] || { echo "web_dist missing"; exit 1; }
fi
[ -f "$SRC/hermes_cli/web_dist/index.html" ] || {
    echo "WARNING: 源码里没有 web_dist，装完 Web 界面会 404" >&2
}

[ -s "$SRC/ui-tui/dist/entry.js" ] || { echo "缺少预构建终端 ui-tui/dist/entry.js，停止打包" >&2; exit 1; }

# ---------------------------------------------------------------- 组装包根
echo ">>> assemble package"
cp -r "$ROOT/manifest" "$ROOT/cmd" "$ROOT/config" "$ROOT/wizard" \
      "$ROOT/ICON.PNG" "$ROOT/ICON_256.PNG" "$PKG/"
cp -r "$ROOT/app/ui" "$ROOT/app/scripts" "$ROOT/app/config" "$PKG/app/"

# 内置 Python 3.14（Hermes 0.21+ 依赖全部以 >=3.14 为条件，系统 3.11 会装出空依赖）
PYSRC=${HERMES_PYTHON_DIR:-$ROOT/.cache/python314}
if [ -x "$PYSRC/bin/python3" ]; then
    echo ">>> bundling python: $PYSRC"
    cp -a "$PYSRC" "$PKG/app/python"
else
    echo "ERROR: 未找到内置 Python 3.14（$PYSRC）；没有它安装必失败，先放到该路径或设 HERMES_PYTHON_DIR" >&2; exit 1
fi
mkdir -p "$PKG/app/src"

# 源码带 .git 时用 sparse 把 tests/website 从工作区拿掉，让索引与工作区一致，
# 包里 .git 的 status 才是干净的（网页更新不会因脏树拒绝）。
if [ -d "$SRC/.git" ] && { [ -d "$SRC/tests" ] || [ -d "$SRC/website" ]; }; then
    ( set +e
      git -C "$SRC" config core.fileMode false
      git -C "$SRC" checkout -- . 2>/dev/null
      echo ">>> preparing sparse checkout (exclude tests/apps/website)"
      git -C "$SRC" sparse-checkout init --no-cone
      printf '/*\n!/tests/\n!/website/\n' > "$SRC/.git/info/sparse-checkout"
      git -C "$SRC" read-tree -mu HEAD 2>&1 | grep -v "not uptodate" | head -3
      git -C "$SRC" sparse-checkout reapply 2>&1 | grep -v "not uptodate" | head -3
      git -C "$SRC" checkout -- . 2>/dev/null
      # apps/ 必须保留：npm workspaces 要扫 apps/* 才能链好 @hermes/shared，
      # 排掉它用户机器上任何一次 dist 重建都会挂在 Cannot find module '@hermes/shared'。
      rm -rf "$SRC/tests" "$SRC/website" 2>/dev/null
      echo ">>> source: files=$(git -C "$SRC" ls-files | wc -l) dirty=$(git -C "$SRC" status --porcelain | wc -l)"
      set -e
    )
fi

tar -C "$SRC" -cf - \
    --exclude='node_modules' \
    --exclude='*/node_modules' \
    --exclude='__pycache__' \
    --exclude='*.pyc' \
    --exclude='.venv' \
    --exclude='.mypy_cache' \
    --exclude='.pytest_cache' \
    . | tar -C "$PKG/app/src" -xf -

# ---------------------------------------------------------------- 包内 .git
# 包里带上游真 .git（真分支、真历史），Web 的「更新 Hermes」靠它 fetch。
# 安装期不跑 git，纯复制；代价是 .git 里带上游对象。
if [ -d "$PKG/app/src/.git" ]; then
    # 国内直连 GitHub 很慢：配一条 insteadOf 加速前缀，origin 地址不用改。
    if [ -n "${PKG_GIT_ACCEL:-}" ]; then
        git -C "$PKG/app/src" config "url.${PKG_GIT_ACCEL}/https://github.com/.insteadOf" "https://github.com/"
        echo ">>> accel -> $PKG_GIT_ACCEL"
    fi
    ( cd "$PKG/app/src" || exit 0
      git config core.fileMode false
      git config commit.gpgsign false
      echo ">>> embedded .git: HEAD=$(git rev-parse --short HEAD 2>/dev/null) status=$(git status --porcelain 2>/dev/null | wc -l) dirty"
    )
fi

# ---------------------------------------------------------------- manifest / 版本
sed -i -E "s/^appname[[:space:]]*=.*/appname               = $APPNAME/; s/^version[[:space:]]*=.*/version               = $VERSION/; s/^service_port[[:space:]]*=.*/service_port          = $PORT/; s/^desktop_applaunchname[[:space:]]*=.*/desktop_applaunchname = $APPNAME.Application/" "$PKG/manifest"
sed -i -E "s/\"port\": *\"[0-9]+\"/\"port\": \"$PORT\"/" "$PKG/app/ui/config"
echo "$PORT" > "$PKG/app/config/web_port"

if [ -z "$KERNEL_VERSION" ]; then KERNEL_VERSION="${TAG:-}"; fi
if [ -z "$KERNEL_VERSION" ] && [ -d "$SRC/.git" ]; then
    KERNEL_VERSION=$(git -C "$SRC" describe --tags --always 2>/dev/null || true)
fi
[ -n "$KERNEL_VERSION" ] || KERNEL_VERSION=$(date +%Y.%m.%d)

# 内核 commit：--commit 显式给 > 源码 .git > 源码里已有的有效 install-stamp.json。
# 这一步必须做对：Hermes 的 get_version_info() 把全零 commit 当「占位符」，
# 直接掉到 unknown（踩过：从解包后的 src 打包，Web 一直显示 version: unknown）。
if [ -z "$COMMIT" ] && [ -d "$SRC/.git" ]; then
    COMMIT=$(git -C "$SRC" rev-parse HEAD 2>/dev/null || true)
    [ -n "$COMMIT_DATE" ] || COMMIT_DATE=$(git -C "$SRC" log -1 --format=%ct 2>/dev/null || true)
fi
if [ -z "$COMMIT" ] && [ -f "$SRC/install-stamp.json" ]; then
    COMMIT=$(python3 -c 'import json,sys
d=json.load(open(sys.argv[1]))
c=(d.get("commit") or "").strip()
print("" if not c or set(c)<={"0"} else c)' "$SRC/install-stamp.json" 2>/dev/null || true)
    [ -n "$COMMIT_DATE" ] || COMMIT_DATE=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("commitDate") or "")' "$SRC/install-stamp.json" 2>/dev/null || true)
fi
mkdir -p "$PKG/app/config/bootstrap"
printf 'HERMES_VERSION=%s\n' "$KERNEL_VERSION" > "$PKG/app/config/bootstrap/hermes-version.env"
# 包自身版本：安装期 appcenter 还没把 manifest 落到 /var/apps/<app>/，只能自带一份
{
    printf 'PKG_VERSION=%s\n' "$VERSION"
    printf 'PKG_COMMIT=%s\n' "$COMMIT"
} > "$PKG/app/config/bootstrap/package-version.env"
if [ -n "$COMMIT" ]; then
    printf '%s\n' "$COMMIT" > "$PKG/app/config/bootstrap/hermes-commit"
fi
echo ">>> kernel=$KERNEL_VERSION package=$VERSION appname=$APPNAME port=$PORT"

# ---------------------------------------------------------------- 安装戳（版本溯源）
# Hermes 的 get_version_info() 取 install-stamp.json → .git → unknown；pyproject 里是 0.0.0，
# 不写戳 Web 界面会显示 unknown。
# 用上游自带的 scripts/write_install_stamp.py 生成，updateMechanism 用 app-installer（应用中心装）。
if [ -f "$SRC/scripts/write_install_stamp.py" ]; then
    STAMP_ARGS=(--base-version "$KERNEL_VERSION" --distance 0 --update-mechanism app-installer --source fpk)
    [ -n "$COMMIT" ] && STAMP_ARGS+=(--commit "$COMMIT")
    [ -n "$COMMIT_DATE" ] && STAMP_ARGS+=(--commit-date "$COMMIT_DATE")
    if ( cd "$SRC" && python3 scripts/write_install_stamp.py \
            -o "$PKG/app/src/install-stamp.json" "${STAMP_ARGS[@]}" ) >>"$WORK/build.log" 2>&1; then
        echo ">>> install-stamp: $(sed -n 's/.*"commit": "\(.\{8\}\).*/\1/p' "$PKG/app/src/install-stamp.json") @ $KERNEL_VERSION"
    else
        echo "NOTE: 上游 stamp 脚本失败，改用下面的兜底写入（$(tail -1 "$WORK/build.log" 2>/dev/null | cut -c1-80)）"
    fi
else
    echo "WARNING: 源码里没有 scripts/write_install_stamp.py，跳过版本戳" >&2
fi

# 兜底校验：戳里的 commit 必须非全零，否则 Hermes 当占位符 → Web 显示 unknown。
# 这里直接按 $COMMIT 重写关键字段，不依赖上游脚本的入参行为。
python3 - "$PKG/app/src/install-stamp.json" "$COMMIT" "$COMMIT_DATE" "$KERNEL_VERSION" <<'PY'
import json, sys, pathlib
path, commit, cdate, ver = sys.argv[1:5]
p = pathlib.Path(path)
d = json.loads(p.read_text()) if p.is_file() else {}
if not commit or set(commit) <= {"0"}:
    sys.exit("build.sh: 没有可用的内核 commit（用 --commit 指定，或从带 .git 的源码打包）")
d["commit"] = commit
if cdate:
    try:
        d["commitDate"] = int(cdate)
    except ValueError:
        pass
d.setdefault("schemaVersion", 2)
d["baseVersion"] = ver
d["displayVersion"] = ver
d["source"] = "fpk"
d["payload"] = "bootstrap"
d["updateMechanism"] = "app-installer"
d.setdefault("distance", 0)
d["dirty"] = False
p.write_text(json.dumps(d, indent=2) + "\n")
print(">>> stamp ok: commit=%s baseVersion=%s" % (commit[:12], ver))
PY

# ---------------------------------------------------------------- 图标约束
python3 - "$PKG" <<'PY'
import struct, sys, os
root = sys.argv[1]
for name, size in (("ICON.PNG", 64), ("ICON_256.PNG", 256)):
    d = open(os.path.join(root, name), "rb").read(33)
    w, h = struct.unpack(">II", d[16:24])
    if (w, h) != (size, size):
        sys.exit(f"{name} 必须是 {size}x{size}，实际 {w}x{h}")
print(">>> icons OK")
PY

chmod +x "$PKG"/cmd/* "$PKG"/app/scripts/*.sh

# ---------------------------------------------------------------- 打包（自带实现）
# fpk 就是一个 gzip tar：app.tgz + manifest + cmd/ + config/ + wizard/ + 图标；
# manifest.checksum 必须等于 md5(app.tgz)，fnOS 安装时会校验。
# 不用 fnpack：它是 fnOS 的闭源 SDK 二进制，CI（GitHub 跑 Ubuntu）里没有它，
# 而 CI 出包是我们要的能力，所以这里自己拼——格式由解包实测得出。
echo ">>> packaging (self-contained)"
AT="$WORK/app.tgz"
# 必须含点文件（.git、.package-version…）：用 . 而不是 ls，ls -A 会漏掉它们
( cd "$PKG/app" && tar -czf "$AT" --transform 's|^\./||' . )
SUM=$(md5sum "$AT" | awk '{print $1}')
sed -i -E "s|^checksum[[:space:]]*=.*|checksum              = $SUM|" "$PKG/manifest"
cp -f "$AT" "$PKG/app.tgz"
FPK="$ROOT/$APPNAME.fpk"
( cd "$PKG" && tar -czf "$FPK" app.tgz manifest cmd config wizard ICON.PNG ICON_256.PNG )

# 自检：解包核对 checksum 与成员
X="$WORK/fpkx"; rm -rf "$X"; mkdir -p "$X"; tar xf "$FPK" -C "$X"
SUM2=$(md5sum "$X/app.tgz" | awk '{print $1}')
GOT=$(sed -n 's/^checksum[[:space:]]*=[[:space:]]*//p' "$X/manifest" | tr -d '\r[:space:]')
[ "$SUM" = "$SUM2" ] && [ "$SUM" = "$GOT" ] || {
    echo "自检失败: 计算=$SUM 归档内=$SUM2 manifest=$GOT" >&2; exit 1; }
echo ">>> checksum OK: $SUM"
echo ">>> done: $ROOT/$APPNAME.fpk ($(du -h "$ROOT/$APPNAME.fpk" | cut -f1))"
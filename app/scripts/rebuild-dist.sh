#!/bin/bash
# 源码提交变了（hermes update 之后）→ 后台重建 web / tui 的 dist。
# 由 watchdog.sh 在检测到 $SRC_DIR 的 HEAD 与 $DIST_MARK 不一致时拉起。
# 用 flock 保证同时只有一个重建在跑；重建期间旧 dist 继续服务，成功后写回 marker。
set -u
. "$(dirname "$0")/lib.sh"
LOG_TAG=rebuild-dist

export HOME="$DATA_DIR"
export HERMES_HOME="$DATA_DIR"
export PATH="$HOME_DIR/bin:/usr/local/bin:/usr/bin:/bin"
# 重建脚本直接用包内 CPython 跑（不经过 hermes 入口），要自己把源码挂上 sys.path
export PYTHONPATH="$SRC_DIR${PYTHONPATH:+:$PYTHONPATH}"

[ -x "$PY_BIN" ] || { log "no python, skip rebuild"; exit 0; }
have_src || { log "no src, skip rebuild"; exit 0; }

HEAD=$(git -c "safe.directory=$SRC_DIR" -C "$SRC_DIR" rev-parse HEAD 2>/dev/null) || { log "no git HEAD, skip"; exit 0; }
[ "$HEAD" = "$(cat "$DIST_MARK" 2>/dev/null)" ] && exit 0

# 串行化：拿不到锁说明已有重建在跑
exec 9>"$VAR_DIR/rebuild-dist.lock"
flock -n 9 || { log "another rebuild running, skip"; exit 0; }

log "source moved to ${HEAD:0:10}, rebuilding dist"
if "$PY_BIN" - "$SRC_DIR" <<'PY' >> "$VAR_DIR/rebuild-dist.log" 2>&1
import sys
from pathlib import Path
root = Path(sys.argv[1])
from hermes_cli.main_web_build import _build_web_ui
from hermes_cli.source_build import build_source_tui, source_build_env

ok_web = _build_web_ui(root / "web")
print("web build:", ok_web, flush=True)
try:
    build_source_tui(root, env=source_build_env())
    print("tui build: True", flush=True)
except Exception as exc:  # tui 失败不该阻断 web
    print("tui build failed:", exc, flush=True)
sys.exit(0 if ok_web else 1)
PY
then
    echo "$HEAD" > "$DIST_MARK"
    log "dist rebuilt for ${HEAD:0:10}"
else
    log "dist rebuild failed, see $VAR_DIR/rebuild-dist.log"
fi
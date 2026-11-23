#!/bin/bash
# 安装戳与前端标记：戳记真实 HEAD，标记记"构建用 commit"
set -u
. "$(dirname "$0")/helpers.sh"

SB=$(new_sandbox stamp)
trap 'rm -rf "$SB"' EXIT
seed_app "$SB"

echo "== 造两个提交：包内是 A，已装源码 HEAD 是 B =="
G="$SB/git"
mkdir -p "$G" && cd "$G" || exit 1
git init -q && git config user.email t@t.t && git config user.name t
mkdir -p hermes_cli/web_dist ui-tui/dist
touch pyproject.toml; echo x > hermes_cli/web_dist/index.html; echo x > ui-tui/dist/entry.js
git add -A && git commit -qm A && A=$(git rev-parse HEAD)
echo v2 > f.txt && git add -A && git commit -qm B && B=$(git rev-parse HEAD)
cd - >/dev/null || exit 1

rm -rf "$SB/home/src" && cp -a "$G" "$SB/home/src"
printf '{"commit": "%s", "baseVersion": "2026.9.24"}\n' "$A" > "$SB/home/src/install-stamp.json"
sed -i.bak "s/^PKG_COMMIT=.*/PKG_COMMIT=$A/" "$SB/app/config/bootstrap/package-version.env"

out=$(run_setup "$SB" upgrade)
assert_has "保留用户更新过的源码" "$out" "keep self-updated source"

stamp=$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['commit'])" "$SB/home/src/install-stamp.json")
assert_eq "安装戳记真实 HEAD" "$stamp" "$B"
assert_eq "前端标记记包内 commit" "$(cat "$SB/home/data/.dist_commit")" "$A"
[ "$stamp" != "$(cat "$SB/home/data/.dist_commit")" ] \
    && ok "两者不同 → 启动后会重建前端" || bad "两者不同 → 启动后会重建前端"

done_
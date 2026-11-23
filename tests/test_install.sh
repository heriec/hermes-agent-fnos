#!/bin/bash
# 安装流程：源码三分支、包标识、前端标记、Web 登录凭据
set -u
. "$(dirname "$0")/helpers.sh"

SB=$(new_sandbox install)
trap 'rm -rf "$SB"' EXIT

echo "== 首次安装（包内源码带 .git，和线上包一致）=="
seed_app "$SB" git
PKG_C=$SEED_COMMIT
out=$(run_setup "$SB" install hermes_dash_password=Pass111111)
assert_has "按包标识铺源码" "$out" "syncing source"
assert_file "源码已落盘" "$SB/home/src/pyproject.toml"
assert_eq "包标识写入" "$(cat "$SB/home/.package-version")" "0.0.1-${PKG_C:0:8}"
assert_file "入口脚本生成" "$SB/home/bin/hermes"
assert_eq "前端标记=包内 commit" "$(cat "$SB/home/data/.dist_commit")" "$PKG_C"

echo "== 再跑一次：同版本不动 =="
out=$(run_setup "$SB" upgrade)
assert_has "识别为无需重铺" "$out" "source up to date"

echo "== 新包的 commit 不在已装仓库里：必须重铺（否则升级等于没升）=="
sed -i.bak 's/^PKG_COMMIT=.*/PKG_COMMIT=deadbeefdeadbeefdeadbeefdeadbeefdeadbeef/' \
    "$SB/app/config/bootstrap/package-version.env"
out=$(run_setup "$SB" upgrade)
assert_has "未知 commit → 重铺源码" "$out" "syncing source"
assert_eq "包标识跟着变" "$(cat "$SB/home/.package-version")" "0.0.1-deadbeef"

echo "== 用户网页更新过（包内 commit 是 HEAD 的祖先）：保留源码 =="
G="$SB/upstream"
mkdir -p "$G/hermes_cli/web_dist" "$G/ui-tui/dist"
touch "$G/pyproject.toml"
echo x > "$G/hermes_cli/web_dist/index.html"
echo x > "$G/ui-tui/dist/entry.js"
A=$(git_init_commit "$G" A)
echo v2 > "$G/f.txt"
git -C "$G" add -A; git -C "$G" commit -qm B
Bh=$(git -C "$G" rev-parse HEAD)
rm -rf "$SB/home/src"; cp -a "$G" "$SB/home/src"
sed -i.bak "s/^PKG_COMMIT=.*/PKG_COMMIT=$A/" "$SB/app/config/bootstrap/package-version.env"
out=$(run_setup "$SB" upgrade)
assert_has "保留更新过的源码" "$out" "keep self-updated source"
assert_eq "HEAD 没被拉回旧 commit" "$(git -C "$SB/home/src" rev-parse HEAD)" "$Bh"

echo "== Web 登录凭据 =="
SB2=$(new_sandbox creds)
seed_app "$SB2" git
out=$(run_setup "$SB2" install hermes_dash_password=Pass111111)
assert_has "首次安装写入凭据" "$out" "凭据已写入"
password_matches "$SB2/home/data/.env" Pass111111 && ok "首次密码可登录" || bad "首次密码可登录"

out=$(run_setup "$SB2" upgrade hermes_dash_password=Pass222222)
assert_has "升级不改密码" "$out" "不修改"
password_matches "$SB2/home/data/.env" Pass111111 && ok "旧密码仍然有效" || bad "旧密码仍然有效"
password_matches "$SB2/home/data/.env" Pass222222 && bad "新密码不该生效" || ok "新密码不生效"
assert_eq "哈希只有一行" \
    "$(grep -c '^HERMES_DASHBOARD_BASIC_AUTH_PASSWORD_HASH=' "$SB2/home/data/.env")" "1"
rm -rf "$SB2"

done_
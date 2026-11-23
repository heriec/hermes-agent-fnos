#!/bin/bash
# 修复 PM 状态目录的属主（root 跑过 hermes pm / pm repair 之后会踩到）。
# 症状：pm 报 "install state is not writable by this user"，
#       gateway / dashboard 起不来，watchdog 每 30 秒空转重试。
# 用法（需要 root）：bash scripts/fix-perms.sh
set -u
# lib.sh 优先找同目录，找不到就去安装目录（脚本被单独拷出来用时）
LIB="$(dirname "$0")/lib.sh"
[ -f "$LIB" ] || LIB="${TRIM_APPDEST:-/var/apps/hermes-agent/target}/scripts/lib.sh"
[ -f "$LIB" ] || { echo "找不到 lib.sh"; exit 1; }
. "$LIB"
LOG_TAG=fix-perms

OWNER="${TRIM_USERNAME:-hermes-agent}"
[ "$(id -u)" = "0" ] || { echo "需要 root 运行"; exit 1; }

fixed=0
for d in "$DATA_DIR/.hermes" "$DATA_DIR/installs" "$HOME_DIR/python" "$HOME_DIR/bin" "$SRC_DIR"; do
    [ -e "$d" ] || continue
    bad=$(find "$d" -user root -print -quit 2>/dev/null)
    if [ -n "$bad" ]; then
        n=$(find "$d" -user root 2>/dev/null | wc -l)
        echo "修复 $d：$n 个 root 拥有的条目（例：$bad）"
        chown -R "$OWNER:$OWNER" "$d" 2>/dev/null || true
        fixed=$((fixed + n))
    fi
done

if [ "$fixed" = "0" ]; then
    echo "属主正常，无需修复"
else
    echo "已修复 $fixed 个条目 -> $OWNER"
    echo "重启应用生效：appcenter-cli stop hermes-agent && appcenter-cli start hermes-agent"
fi
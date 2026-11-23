#!/bin/bash
# 进程处理：APP_DIR 解析、pid 复用保护、停服务时看门狗也要停
set -u
. "$(dirname "$0")/helpers.sh"

SB=$(new_sandbox process)
trap 'rm -rf "$SB"; pkill -f "$SB" 2>/dev/null' EXIT
mkdir -p "$SB/app/target/scripts" "$SB/app/cmd" "$SB/home" "$SB/var"
cp "$REPO/app/scripts/lib.sh" "$SB/app/target/scripts/"

echo "== APP_DIR 解析 =="
out=$(env TRIM_APPDEST="$SB/app/target" TRIM_PKGHOME="$SB/home" TRIM_PKGVAR="$SB/var" \
    bash -c ". '$SB/app/target/scripts/lib.sh'; echo \$APP_DIR")
assert_eq "带 TRIM_APPDEST" "$out" "$SB/app/target"

out=$(env -u TRIM_APPDEST TRIM_PKGHOME="$SB/home" TRIM_PKGVAR="$SB/var" \
    bash -c ". '$SB/app/target/scripts/lib.sh'; echo \$APP_DIR")
assert_eq "无 TRIM_APPDEST 时按脚本位置" "$out" "$SB/app/target"

cp "$REPO/app/scripts/lib.sh" "$SB/app/cmd/"
out=$(env -u TRIM_APPDEST TRIM_PKGHOME="$SB/home" TRIM_PKGVAR="$SB/var" \
    bash -c ". '$SB/app/cmd/lib.sh'; echo \$APP_DIR")
assert_eq "从 cmd/ 直接调用也能找到 target" "$out" "$SB/app/target"

echo "== pid 复用保护 =="
sleep 300 & FOREIGN=$!
sleep 300 & MAIN_PROC=$!
echo "$FOREIGN" > "$SB/var/dashboard.pid"
env TRIM_APPDEST="$SB/app/target" TRIM_PKGHOME="$SB/home" TRIM_PKGVAR="$SB/var" \
    bash -c ". '$SB/app/target/scripts/lib.sh'; LOG_TAG=t; stop_pid_file '$SB/var/dashboard.pid'" >/dev/null 2>&1
kill -0 "$FOREIGN" 2>/dev/null && ok "外来进程没被杀" || bad "外来进程没被杀"
kill "$FOREIGN" 2>/dev/null

echo "== 自己的进程要能停 =="
bash -c "exec -a '$SB/home/python/bin/python3 -m hermes_cli.main gateway' sleep 300" &
MINE=$!
sleep 0.3
echo "$MINE" > "$SB/var/gateway.pid"
env TRIM_APPDEST="$SB/app/target" TRIM_PKGHOME="$SB/home" TRIM_PKGVAR="$SB/var" \
    bash -c ". '$SB/app/target/scripts/lib.sh'; LOG_TAG=t; stop_pid_file '$SB/var/gateway.pid'" >/dev/null 2>&1
sleep 1
kill -0 "$MINE" 2>/dev/null && bad "自己的进程应被停止" || ok "自己的进程被停止"

echo "== 看门狗没有 pid 文件也要清掉，且不误杀 cmd/main =="
bash -c "exec -a '/bin/bash $SB/app/target/scripts/watchdog.sh' sleep 300" &
WD=$!
bash -c "exec -a '$SB/app/cmd/main stop' sleep 300" &
CMD=$!
sleep 0.5
env TRIM_APPDEST="$SB/app/target" TRIM_PKGHOME="$SB/home" TRIM_PKGVAR="$SB/var" \
    bash -c ". '$SB/app/target/scripts/lib.sh'; LOG_TAG=t; kill_own_processes" >/dev/null 2>&1
sleep 1
kill -0 "$WD" 2>/dev/null && bad "看门狗应被清掉" || ok "看门狗被清掉"
kill -0 "$CMD" 2>/dev/null && ok "没有误杀 cmd/main" || bad "没有误杀 cmd/main"
kill -9 "$WD" "$CMD" "$MAIN_PROC" 2>/dev/null

done_
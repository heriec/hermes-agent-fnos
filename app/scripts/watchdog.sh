#!/bin/bash
# 看门狗：服务保活 + 源码变了重建 dist。由 cmd/main 以 setsid 启动。

. "$(dirname "$0")/lib.sh"
LOG_TAG=watchdog

export HOME="$DATA_DIR"
export HERMES_HOME="$DATA_DIR"
export PATH="$HOME_DIR/bin:/usr/local/bin:/usr/bin:/bin"

HOST=${HERMES_WEB_HOST:-0.0.0.0}
INTERVAL=${HERMES_WATCHDOG_INTERVAL:-30}

# 以自身 PID 覆盖 pid 文件（setsid 下 $! 可能不是脚本自身）
echo $$ > "$WATCHDOG_PID"

# 已被主脚本停掉（pid 文件被删）就退出
while [ -f "$WATCHDOG_PID" ] && [ "$(read_pid "$WATCHDOG_PID")" = "$$" ]; do
    if [ -x "$HERMES_BIN" ] && [ -x "$PY_BIN" ] && have_src; then
        # dist 与源码不同步（hermes update 之后）→ 后台重建，旧 dist 继续服务
        cur_head=$(git -c "safe.directory=$SRC_DIR" -C "$SRC_DIR" rev-parse HEAD 2>/dev/null)
        if [ -n "$cur_head" ] && [ "$cur_head" != "$(cat "$DIST_MARK" 2>/dev/null)" ] \
           && [ -x "$APP_DIR/scripts/rebuild-dist.sh" ]; then
            # 拿得到锁才重建（拿不到说明已有重建在跑）
            if flock -n "$VAR_DIR/rebuild-dist.lock" -c true 2>/dev/null; then
                log "dist stale for ${cur_head:0:10}, rebuilding in background"
                setsid nohup "$APP_DIR/scripts/rebuild-dist.sh" >> "$VAR_DIR/rebuild-dist.out" 2>&1 &
            fi
        fi
        if ! pid_alive "$GATEWAY_PID" || ! own_pid "$(read_pid "$GATEWAY_PID")"; then
            gw_ts=$(cat "$VAR_DIR/.last_gw_restart" 2>/dev/null || echo 0)
            if [ $(( $(date +%s) - gw_ts )) -lt 60 ]; then
                sleep "$INTERVAL"; continue
            fi
            echo "$(date +%s)" > "$VAR_DIR/.last_gw_restart"
            log "gateway down, restarting"
            setsid nohup "$HERMES_BIN" gateway run --replace >> "$VAR_DIR/gateway.log" 2>&1 &
            echo $! > "$GATEWAY_PID"
        fi
        # 刚拉起的 dashboard 还在启动：pid 文件 120s 内 + 进程在，就再等一轮，别杀了重开
        if pid_alive "$DASHBOARD_PID" && own_pid "$(read_pid "$DASHBOARD_PID")" \
           && [ $(( $(date +%s) - $(stat -c %Y "$DASHBOARD_PID" 2>/dev/null || echo 0) )) -lt 120 ]; then
            sleep "$INTERVAL"; continue
        fi
        if curl -sf -o /dev/null --max-time 3 "http://127.0.0.1:${WEB_PORT}/"; then
            # 端口能应答就算活着。Hermes 自己重启 dashboard 时 pid 文件会过期，
            # 只看 pid 会让 watchdog 每 30 秒再起一个、抢不到端口、无限循环。
            LP=$(ss -tlnp 2>/dev/null | grep ":${WEB_PORT} " | grep -o 'pid=[0-9]*' | head -1 | cut -d= -f2)
            if [ -n "$LP" ] && [ "$LP" != "$(read_pid "$DASHBOARD_PID")" ]; then
                echo "$LP" > "$DASHBOARD_PID"
                log "dashboard pid refreshed -> $LP (port answering)"
            fi
        else
            # 90s 冷却：安装/更新后 dashboard 启动慢，别每 30s 再拉一个抢端口
            now_ts=$(date +%s); last_ts=$(cat "$VAR_DIR/.last_dash_restart" 2>/dev/null || echo 0)
            if [ $((now_ts - last_ts)) -lt 90 ]; then
                sleep "$INTERVAL"; continue
            fi
            echo "$now_ts" > "$VAR_DIR/.last_dash_restart"
            log "dashboard down or unresponsive, restarting"
            stop_pid_file "$DASHBOARD_PID"
            # --isolated 与 cmd/main 保持一致：避免 data 里残留的 host-dashboard.json 让重启失败
            local_dist="$SRC_DIR/hermes_cli/web_dist"
            [ -f "$local_dist/index.html" ] && export HERMES_WEB_DIST="$local_dist"
            configure_bundled_tui
            setsid nohup "$HERMES_BIN" dashboard --isolated --host "$HOST" --port "$WEB_PORT" \
                --no-open --skip-build >> "$VAR_DIR/dashboard.log" 2>&1 &
            echo $! > "$DASHBOARD_PID"
        fi
    fi
    sleep "$INTERVAL"
done
log "watchdog exiting"
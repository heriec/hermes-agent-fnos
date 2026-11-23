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
    if [ -x "$HERMES_BIN" ] && have_src; then
        # dist 与源码不同步（hermes update 之后）→ 后台重建，旧 dist 继续服务
        cur_head=$(git -c "safe.directory=$SRC_DIR" -C "$SRC_DIR" rev-parse HEAD 2>/dev/null)
        if [ -n "$cur_head" ] && [ "$cur_head" != "$(cat "$DIST_MARK" 2>/dev/null)" ] \
           && [ -x "$APP_DIR/scripts/rebuild-dist.sh" ]; then
            log "dist stale for ${cur_head:0:10}, rebuilding in background"
            setsid nohup "$APP_DIR/scripts/rebuild-dist.sh" >> "$VAR_DIR/rebuild-dist.out" 2>&1 &
        fi
        if ! pid_alive "$GATEWAY_PID"; then
            log "gateway down, restarting"
            setsid nohup "$HERMES_BIN" gateway run --replace >> "$VAR_DIR/gateway.log" 2>&1 &
            echo $! > "$GATEWAY_PID"
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
            # 属主错乱（有人用 root 跑过 pm）会让每次重启都死在同一个地方，先把原因写清楚，
            # 否则日志里只剩无穷尽的 restarting。
            # 直接探测 PM 状态目录能不能写（日志里可能有陈年报错，grep 会误判）
            LEASE_DIR=$(ls -d "$DATA_DIR"/installs/*/.leases 2>/dev/null | head -1)
            # .leases 是懒创建的：还没生成时改探它的父目录（PM 状态根）
            [ -n "$LEASE_DIR" ] || LEASE_DIR=$(ls -d "$DATA_DIR"/installs/* 2>/dev/null | head -1)
            if [ -n "$LEASE_DIR" ] && [ ! -w "$LEASE_DIR" ]; then
                now=$(date +%s); last=$(cat "$VAR_DIR/.perm_warn" 2>/dev/null || echo 0)
                if [ $((now - last)) -gt 600 ]; then   # 10 分钟只提示一次，照常继续重启
                    log "dashboard 起不来：PM 状态目录被 root 占有（install state is not writable）"
                    log "修复：sudo bash $APP_DIR/scripts/fix-perms.sh && appcenter-cli stop/start hermes-agent"
                    echo "$now" > "$VAR_DIR/.perm_warn"
                fi
            fi
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
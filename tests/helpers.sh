#!/bin/bash
# 测试公共部分：沙箱、断言、假解释器（真实 scrypt，但 PM 调用直接成功，不联网）
set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0
FAIL=0

ok()   { PASS=$((PASS + 1)); printf '  \033[32m✓\033[0m %s\n' "$1"; }
bad()  { FAIL=$((FAIL + 1)); printf '  \033[31m✗\033[0m %s\n' "$1"; [ -n "${2:-}" ] && printf '    %s\n' "$2"; }
done_() {  # 用例结束时的汇总，供 run.sh 读取
    echo "RESULT pass=$PASS fail=$FAIL"
    [ "$FAIL" = 0 ]
}

assert_eq()      { [ "$2" = "$3" ] && ok "$1" || bad "$1" "期望 [$3] 实际 [$2]"; }
assert_ne()      { [ "$2" != "$3" ] && ok "$1" || bad "$1" "不应等于 [$3]"; }
assert_file()    { [ -f "$2" ] && ok "$1" || bad "$1" "文件不存在: $2"; }
assert_no_file() { [ ! -e "$2" ] && ok "$1" || bad "$1" "文件不该存在: $2"; }
assert_has()     { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "缺少 [$3]，实际: $(printf '%s' "$2" | tail -3)" ;; esac; }

# 建一个空沙箱，返回路径；$1 名称
new_sandbox() {
    local sb="${TMPDIR:-/tmp}/hermes-fpk-test-$1.$$"
    rm -rf "$sb"
    mkdir -p "$sb"
    echo "$sb"
}

# 铺一个能跑 setup-core 的最小包目录
git_init_commit() {  # git_init_commit <目录> <提交信息> → 输出 HEAD
    local dir=$1
    git -C "$dir" init -q
    git -C "$dir" config user.email t@t.t
    git -C "$dir" config user.name t
    git -C "$dir" add -A
    git -C "$dir" commit -qm "$2"
    git -C "$dir" rev-parse HEAD
}

seed_app() {
    local sb=$1 commit=${2:-0000000000000000000000000000000000000000}
    mkdir -p "$sb/app/scripts" "$sb/app/config/bootstrap" "$sb/home" "$sb/var" "$sb/etc"
    mkdir -p "$sb/app/src/hermes_cli/web_dist" "$sb/app/src/ui-tui/dist"
    cp "$REPO/app/scripts/setup-core.sh" "$REPO/app/scripts/lib.sh" "$sb/app/scripts/"
    printf 'HERMES_VERSION=2026.9.24\n' > "$sb/app/config/bootstrap/hermes-version.env"
    touch "$sb/app/src/pyproject.toml"
    echo x > "$sb/app/src/hermes_cli/web_dist/index.html"
    echo x > "$sb/app/src/ui-tui/dist/entry.js"
    [ "$commit" = "git" ] && commit=$(git_init_commit "$sb/app/src" pkg)
    SEED_COMMIT=$commit
    printf 'PKG_VERSION=0.0.1\nPKG_COMMIT=%s\n' "$commit" \
        > "$sb/app/config/bootstrap/package-version.env"

    # 假解释器：算哈希等操作走真 python3；PM 调用直接返回成功（测试不联网）
    mkdir -p "$sb/home/python/bin"
    cat > "$sb/home/python/bin/python3" <<WRAP
#!/bin/sh
case "\$*" in
  *"from pm.cli import main"*) exit 0 ;;
  *) exec "$(command -v python3)" "\$@" ;;
esac
WRAP
    chmod +x "$sb/home/python/bin/python3"
}

run_setup() {  # run_setup <沙箱> <install|upgrade> [额外环境变量...]
    local sb=$1 mode=$2; shift 2
    env TRIM_APPDEST="$sb/app" TRIM_PKGHOME="$sb/home" TRIM_PKGVAR="$sb/var" TRIM_PKGETC="$sb/etc" \
        "$@" bash "$sb/app/scripts/setup-core.sh" "$mode" 2>&1
}

# 校验 .env 里的 scrypt 哈希能否用给定密码通过
password_matches() {  # password_matches <env文件> <密码>
    python3 - "$1" "$2" <<'PY'
import base64, hashlib, re, sys
env = open(sys.argv[1], encoding="utf-8").read()
pw = sys.argv[2]
m = re.search(r"^HERMES_DASHBOARD_BASIC_AUTH_PASSWORD_HASH='?([^'\n]+)", env, re.M)
if not m:
    raise SystemExit(2)
s, n, r, p, salt, dk = m.group(1).split("$")
calc = hashlib.scrypt(pw.encode(), salt=base64.b64decode(salt),
                      n=int(n), r=int(r), p=int(p), dklen=len(base64.b64decode(dk)))
raise SystemExit(0 if base64.b64encode(calc).decode() == dk else 1)
PY
}
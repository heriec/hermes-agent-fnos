# Hermes Agent for fnOS

在飞牛 fnOS 上一键安装 [Hermes Agent](https://github.com/NousResearch/hermes-agent)，用官方 Web UI 管理，支持在网页里直接更新上游版本。

本仓库只做 fnOS 的安装壳：启停、数据落盘、网页更新、依赖托管。Agent 本体全部来自上游，不做修改。

## 安装

1. 下载最新安装包：

```
https://gh-proxy.com/https://github.com/heriec/hermes-agent-fnos/releases/latest/download/hermes-agent.fpk
```

2. 打开 fnOS「应用中心 → 手动安装」，选择该 fpk。
3. 安装向导里设置 Web 界面的用户名和密码（不是飞牛账号，密码只存 scrypt 哈希）。
4. 安装完成后从桌面图标或 `http://<NAS 地址>:9219` 打开，登录后配置模型与消息渠道。

要求：fnOS 0.9.0 及以上、x86_64；安装过程需要联网（拉取 Python 依赖与 node/ffmpeg 等运行时，约 300 MB）。

## 更新

Web 界面 → 设置 → 检查更新 → 更新 Hermes。流程是 `git fetch` 切到上游 stable → PM 同步依赖 → 重启服务 → 后台重建前端资源，不需要重装应用包。

- 国内网络：包内 git 已配 `gh-proxy.com` 加速前缀，拉取上游不需要代理。不想要可删掉 `$PKGHOME/src/.git/config` 里对应的 `insteadOf`。
- gateway 在更新后 30 秒内由看门狗拉起，Web 界面自动恢复。
- 网页更新过的版本不会被之后安装的 fpk 覆盖降级。

## 目录

```
$PKGHOME = /vol1/@apphome/hermes-agent
$PKGVAR  = /vol1/@appdata/hermes-agent
```

| 路径 | 内容 |
|---|---|
| `$PKGHOME/data/` | 用户数据：`config.yaml`、`.env`、会话、技能、记忆 |
| `$PKGHOME/src/` | 内核源码，带 `.git`，网页更新在这里进行 |
| `$PKGHOME/python/` | 包内 CPython 3.14（只当解释器，依赖由 PM 提供） |
| `$PKGHOME/data/tools/` | PM 装的 CPython 3.14 + node/ffmpeg 等工具 |
| `$PKGHOME/bin/hermes` | 启动入口 |
| `$PKGHOME/data/.hermes/`、`$PKGHOME/data/installs/` | PM 管理的依赖与工具链 |
| `$PKGVAR/` | 日志与 pid：`info.log`、`gateway.log`、`dashboard.log`、`watchdog.log` |

卸载或重装不会删除 `$PKGHOME/data/`，配置、会话与记忆都保留。

## 依赖管理

依赖由 Hermes 自带的 `hermes pm` 统一管理，安装时执行一次：

```bash
hermes pm install --without agent-browser --without cua-driver
```

默认不装浏览器（Chromium，约 400 MB）和计算机操作驱动（cua-driver，约 70 MB）；需要时补装：

```bash
hermes pm install chromium     # 浏览器工具
hermes pm install cua-driver   # 计算机操作
```

`ffmpeg` 是 PM 必装项，用于语音消息转写。

## 常用命令

```bash
su hermes-agent -s /bin/bash
export HOME=/vol1/@apphome/hermes-agent/data HERMES_HOME=/vol1/@apphome/hermes-agent/data
H=/vol1/@apphome/hermes-agent

$H/bin/hermes --version        # 版本
$H/bin/hermes update --check   # 查更新
$H/bin/hermes gateway status   # 网关状态
$H/bin/hermes pm doctor        # 依赖体检
```

服务由 fnOS 应用中心管理，也可用 `appcenter-cli stop|start hermes-agent` 重启。

## 故障排查

**Web 界面打不开**：看 `$PKGVAR/dashboard.log` 和 `$PKGVAR/info.log`，确认 9219 在监听。

**日志出现 `install state is not writable by this user`**：有人用 root 跑过 `hermes pm`，属主被改。重装应用即可（安装流程会重新 chown）。

**网页更新失败**：确认 `$PKGHOME/src/.git` 存在且工作树干净（`git -C $PKGHOME/src status --porcelain`），再看 `$PKGVAR/hermes-update.log`。

**依赖损坏**：`$H/bin/hermes pm repair`，然后重启应用。

## 测试

```bash
bash tests/run.sh
```

覆盖安装/升级的关键判断：源码三分支（首次铺、同版本跳过、包内 commit 未知时重铺、用户网页更新后保留）、包标识、安装戳与前端标记、Web 登录凭据语义、进程 pid 复用保护与看门狗清理。不联网，几十秒跑完；CI 在每次 push / PR 跑一遍。

## 从源码构建

CI 在 GitHub Actions 里完成（`.github/workflows/build-fpk.yml`），打 `v*` tag 即出包。

本地构建：

```bash
./build.sh --tag <上游 tag>               # 克隆并构建前端（需要 node + 网络）
./build.sh --from <已有源码目录> --no-web   # 用现成产物
```

版本号、内核 commit、git 加速前缀在 `build.env` 配置。

## 仓库结构

```
manifest              应用元数据（安装时由 build.sh 写入版本、端口、checksum）
cmd/                  fnOS 生命周期入口：main 启停，install/upgrade/uninstall 回调
app/scripts/          setup-core 安装流程、watchdog 保活、rebuild-dist 前端重建
app/ui/               桌面图标与入口配置
wizard/install        安装向导（Web 登录账号密码）
build.sh / build.env  fpk 打包
```

## 许可

本仓库的安装壳代码可自由使用。Hermes Agent 本体遵循其上游项目授权，见 [NousResearch/hermes-agent](https://github.com/NousResearch/hermes-agent)。
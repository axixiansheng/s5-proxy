# S5 代理一键搭建脚本

基于 **Dante**，面向 NAT VPS，兼容 **Alpine（OpenRC）**、**Debian / Ubuntu（systemd 或 SysV）**。入口使用 `sh`，无需预装 Bash、Python、curl 等工具；安装程序检测并补齐依赖。

脚本风格参考 [vless-reality](https://github.com/axixiansheng/vless-reality)，支持交互菜单、安装、查看信息、状态、连通检查、更新、重启和卸载。

## 一键安装

以 **root** 在 Bash 终端执行，和 vless-reality 一样，填上 NAT 已映射端口即可安装：

```bash
PORT=54352 bash <(curl -fsSL https://raw.githubusercontent.com/axixiansheng/s5-proxy/main/s5.sh) install
```

首次安装自动检测公网 IPv4，外网端口默认等于 `PORT`，用户名密码自动生成。安装程序自动检测并安装自身依赖；重复安装保留原地址、端口和账号。

**Alpine 默认 ash 终端**或没有 Bash 时，使用下面这条同样一步执行的命令（已有 curl）：

```sh
PORT=54352 sh -c 's=$(curl -fsSL https://raw.githubusercontent.com/axixiansheng/s5-proxy/main/s5.sh) && sh -c "$s" s5 install'
```

无需先下载到文件，再分开执行。若 curl 也没有，使用下一节的自动准备命令。

## 极简系统自动准备并安装

这条仍是一步执行：自动补齐下载工具与 CA 证书，下载成功后运行安装。按需修改开头的端口；也可以给它添加其他环境变量。

```sh
PORT=54352 sh -c 'set -eu; umask 077; if command -v apk >/dev/null 2>&1; then apk add --no-cache ca-certificates curl; elif command -v apt-get >/dev/null 2>&1; then apt-get -o Acquire::Retries=3 -o Acquire::http::Timeout=30 -o Acquire::https::Timeout=30 update; DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=60 -o Acquire::Retries=3 install -y --no-install-recommends ca-certificates curl; else echo "错误: 仅支持 Alpine / Debian / Ubuntu" >&2; exit 1; fi; f=$(mktemp); trap "rm -f \"$f\"" EXIT; curl -fSL --retry 3 --connect-timeout 10 --max-time 90 https://raw.githubusercontent.com/axixiansheng/s5-proxy/main/s5.sh -o "$f"; sh "$f" "$@"' s5 install
```

去掉末尾的 `install` 可进入交互菜单。自动检测得到的是本机的公网出口 IPv4；供应商入站映射地址不同或有多个公网地址时，显式填写 `PUBLIC_HOST`。

也可以保存脚本，便于后续管理：

```sh
curl -fSL --retry 3 --connect-timeout 10 --max-time 90 \
  https://raw.githubusercontent.com/axixiansheng/s5-proxy/main/s5.sh -o /root/s5.sh &&
sh /root/s5.sh
```

## 指定 NAT 端口安装

例如供应商映射为 **公网 `203.0.113.10:54352` → 内网 `54352`**：

```sh
PORT=54352 PUBLIC_HOST=203.0.113.10 bash <(curl -fsSL https://raw.githubusercontent.com/axixiansheng/s5-proxy/main/s5.sh) install
```

上面的 `203.0.113.10` 是文档示例地址，请替换成自己的公网 IP。两端端口不同也支持：

```sh
PORT=1080 PUBLIC_PORT=54352 PUBLIC_HOST=203.0.113.10 bash <(curl -fsSL https://raw.githubusercontent.com/axixiansheng/s5-proxy/main/s5.sh) install
```

上述环境变量同样适用于 Alpine ash 的单行命令或极简系统自动准备命令。

首次安装只必须明确 `PORT`；没有默认开放端口。公网 IP 检测有多个后备接口，全部失败时报告原因并提示设置 `PUBLIC_HOST`。脚本检查本机监听冲突，供应商 NAT 映射及已有防火墙规则需要在相应面板配置。

## 特性与行为

- 自动安装缺失依赖，Alpine 缺少 community 时补充同版本源，不混用 edge。Debian 使用 apt，保留原有包服务启动策略。
- 优先使用发行版软件源中的 Dante，按系统架构获取原生软件包。Debian 13 等软件源缺包时，自动补齐编译依赖，从 [Dante 官方](https://www.inet.no/dante/download.html)下载固定 `1.4.4` 源码、验证官方 SHA256 后单线程构建；不混用其他 Debian 版本的软件源。
- 单独管理 `s5-proxy` 服务，不修改 SSH 端口。设置开机启动，并验证服务、监听及 SOCKS5 认证后才报告本机部署成功；公网映射需从另一台机器验证。
- 默认生成随机密码，创建禁止交互登录的专用系统账户；规则仅允许这个账户使用代理，拒绝其他系统账户和匿名连接。
- 重复安装保留账号密码及已有参数；设置 `PORT` / `PUBLIC_PORT` 可修改端口，`REGEN=1` 重新生成密码。
- 配置变更前校验 Dante；切换失败时恢复配置、账户密码、开机启动及原服务。互斥锁防止多个安装同时修改配置。
- 错误报告具体阶段、命令退出码和诊断日志；依赖、下载、配置或服务错误均返回非零状态。

**当前提供 SOCKS5 TCP CONNECT 和远端 DNS，UDP / BIND 已明确关闭。** 单个 NAT TCP 映射无法保证 SOCKS5 UDP 中继可用。客户端使用 SOCKS5 用户名密码认证；`socks5h` 表示让代理解析目标域名。SOCKS5 本身不加密，适合受信网络或配合已有安全隧道使用。

## 环境变量

| 变量 | 默认 / 行为 | 说明 |
| --- | --- | --- |
| `PORT` | 首次必填，之后复用 | 本机内网监听端口，1–65535 |
| `PUBLIC_PORT` | 首次等于 `PORT`，之后复用 | 客户端连接的外网映射端口 |
| `PUBLIC_HOST` | 首次自动检测，之后复用 | 可手动指定 NAT 入站公网 IPv4 或具有 A 记录的域名 |
| `S5_USER` | `s5proxy` | 专用账户名，不允许使用 root / nobody 或接管已有账户 |
| `S5_PASSWORD` | 自动生成，之后复用 | 8–128 字节，不能含冒号、换行、NUL |
| `EXTERNAL_IFACE` | 首次检测 IPv4 默认路由，之后复用 | 出口网卡，如 `eth0`；多网卡时可以明确指定 |
| `REGEN` | `0` | `1` 表示重置随机密码，显式 `S5_PASSWORD` 优先 |
| `ADOPT_EXISTING` | `0` | `1` 明确迁移占用该端口的标准 `sockd` / `danted` 服务 |

密码含 `$`、`&` 等字符时使用单引号；也可以避免把密码写进 shell 历史，使用默认随机密码，然后运行 `info` 查看。密码中的非 ASCII 字符要求客户端使用相同 UTF-8 编码。

## 已经安装过 S5

如果端口由原 `sockd` / `danted` 占用，默认停止并报告冲突，不会直接覆盖。确认要迁移时：

```sh
ADOPT_EXISTING=1 PORT=54352 PUBLIC_HOST=203.0.113.10 sh /root/s5.sh install
```

原配置文件保留，在 `/etc/s5-proxy/original/` 另存恢复资料；切换时停止原服务并取消它的开机启动，由新服务接管同一端口。**迁移会使用新的专用账号密码，已有客户端需要更新。** 失败则尝试恢复原服务，卸载成功时也恢复原服务及原开机启动状态。

只识别标准服务名；对于面板、多实例或自定义进程，请先处理原服务或为新代理选择不同的已映射端口。

## 管理命令

```sh
sh /root/s5.sh info       # 查看地址、内外端口、账户及 Telegram SOCKS5 链接
sh /root/s5.sh status     # 查看服务与监听
sh /root/s5.sh check      # 正确/错误密码、匿名拒绝、SOCKS5 HTTPS 出站及远端 DNS
sh /root/s5.sh restart    # 重启并验证
sh /root/s5.sh update     # 根据发行版软件源更新 Dante，保留配置与账户
sh /root/s5.sh uninstall  # 卸载本脚本服务、配置、专用账户；恢复被迁移的原服务
```

CLI 的 `uninstall` 不再询问；菜单卸载需输入 `yes`。共享的系统依赖、Dante 软件包及后备源码核心不卸载，避免影响原服务。后备核心位于 `/usr/local/lib/s5-proxy-core/danted`，版本固定为 `1.4.4`；`update` 检查 / 补齐此版本，不自动追踪未知源码版本。更新失败时报告错误；系统软件包更新不自动降级。安装失败回滚不卸载已经安装的系统依赖或撤销软件源补充。

安装完成及 `info` 输出 [Telegram SOCKS5 链接](https://core.telegram.org/api/links#socks5-proxy-links)，格式如下：

```text
https://t.me/socks?server=公网地址&port=外网映射端口&user=用户名&pass=密码
```

点击链接可在 Telegram 中导入代理。链接使用实际节点参数，`port` 为 `PUBLIC_PORT`（外网映射端口）；密码等参数中的 `&`、`+`、`#`、空格及非 ASCII 字符会自动进行 URL 编码。其他 SOCKS5 客户端仍可按输出的地址、端口、用户名、密码手动填写。

## 排查问题

安装诊断日志：`/var/log/s5-proxy-installer.log`，仅 root 可读，不记录密码输入。状态文件 `/etc/s5-proxy/state.json` 保存连接密码，权限为 `600`，所在目录为 `700`。`info` 会在终端显示密码，请勿把真实状态文件或输出提交到仓库。

```sh
# Alpine
rc-service s5-proxy status
tail -n 50 /var/log/s5-proxy.log
/usr/sbin/sockd -V -f /etc/s5-proxy/sockd.conf

# Debian / Ubuntu（systemd）
systemctl status s5-proxy --no-pager
journalctl -u s5-proxy -n 50 --no-pager
/usr/sbin/danted -V -f /etc/s5-proxy/sockd.conf

# Debian 软件源缺包、使用后备源码核心时
/usr/local/lib/s5-proxy-core/danted -V -f /etc/s5-proxy/sockd.conf
```

端口本机可用而外网不通时，核对供应商入站公网地址、外网到内网的 **TCP** 映射、防火墙及客户端账号。`check` 验证本机到外网的代理链路，不代表供应商入站映射一定正确。

在另一台机器上进行实际公网测试（将示例地址、端口和账号替换成自己的值）：

```sh
# curl 会提示输入代理密码；避免把密码直接放进命令参数。
curl --proxy socks5h://203.0.113.10:54352 --proxy-user s5proxy \
  --noproxy '' --connect-timeout 10 --max-time 30 --fail --show-error https://api.ipify.org
```

输出代理服务器的出口 IP 才表示 SOCKS5 认证、远端 DNS 和 HTTPS 均已通过。`socks5h` 会让代理服务器解析目标域名。测试时也应确认错误密码和匿名访问被拒绝。

如果本机 `check` 和另一网络的公网测试都通过，但某个网络卡在 SOCKS5 握手，先排查该网络到服务器的链路。TCP 端口连接成功只能证明连接建立；仍需确认 SOCKS5 握手数据是否到达、服务器回复是否返回。安装成功信息会明确说明公网尚未验证，避免将本机自检误认为供应商映射已经通过。

## 自动测试

GitHub Actions 在 Alpine 3.21 / 3.22 / 3.23、Debian 12 / 13 的隔离容器中验证：精简系统依赖补齐、实际服务管理、认证、HTTPS 出站、端口修改、重复安装、端口冲突、启动失败回滚、更新、卸载及原 Dante 迁移恢复。另检查 shell / 内嵌 Python 语法与 ShellCheck。

`tests/integration.py` 只用于一次性测试容器，**不要在生产服务器上运行**。Ubuntu 和无 systemd 的 SysV 分支有适配代码，但当前不在自动测试矩阵中。

## License

[MIT](LICENSE)

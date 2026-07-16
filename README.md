# shell-script

适用于 Ubuntu 24.04 的服务器初始化脚本，同时兼容使用 `dnf`/`yum` 的 CentOS/RHEL 系统。

脚本会完成以下工作：

- 安装 Zsh、Git、Curl、Unzip 和必要系统工具；
- 在物理内存低于约 500MiB 时，于包安装前自动补足至至少 1GiB 的持久 swap；
- 安装 [Oh My Zsh](https://ohmyz.sh/) 与 `zsh-autosuggestions`；
- 创建不会被 Oh My Zsh 更新覆盖的 `node-info` 自定义主题，提示符展示用户、主机名与公网 IP（失败时回退到局域网 IP）；
- 配置 `fq` 与 BBR；
- 通过 Docker 官方脚本安装 Docker Engine、启动服务，并把当前用户加入 `docker` 组；
- 将当前用户的登录 Shell 改为 Zsh。
- 安装阶段询问提示符显示名，例如输入 `bwg11` 后显示为 `[root@bwg11_公网IP]`；不修改操作系统实际主机名。
- 将仓库内置的 SSH Ed25519 公钥以幂等方式写入目标用户的 `~/.ssh/authorized_keys`。

## 安装

先查看脚本内容，再执行：

```bash
curl -fsSLO https://raw.githubusercontent.com/Jannerzhang/shell-script/main/install.sh
less install.sh
bash install.sh
```

确认来源可信后，也可一行安装：

```bash
curl -fsSL https://raw.githubusercontent.com/Jannerzhang/shell-script/main/install.sh | bash
```

国内网络可使用镜像：

```bash
curl -fsSL https://raw.githubusercontent.com/Jannerzhang/shell-script/main/install.sh | bash -s -- --mirror
```

## 选项

| 选项 | 作用 |
| --- | --- |
| `--mirror` | 使用 Gitee 的 Oh My Zsh 与自动补全插件镜像。 |
| `--skip-docker` | 不安装 Docker。 |
| `--skip-bbr` | 不写入 BBR 配置。 |
| `--skip-shell` | 不修改当前用户登录 Shell。 |
| `--skip-swap` | 不在低内存机器上自动创建 swap。 |

示例：仅安装 Zsh 环境，不改 Shell、不安装 Docker 或 BBR：

```bash
bash install.sh --skip-shell --skip-docker --skip-bbr
```

非交互执行时可用环境变量指定提示符显示名：

```bash
SHELL_SCRIPT_NODE_NAME=bwg11 bash install.sh --skip-docker
```

## 注意事项

- 普通用户执行时，脚本会在需要时请求 `sudo`。直接以 root 登录的云服务器也可执行，配置会写入 `/root` 并将 root 的登录 Shell 设为 Zsh。
- Docker 组有近似 root 的权限。加入该组后重新登录，或手动执行 `newgrp docker`。
- 低内存机器默认会创建 `/swapfile.shell-script` 并写入 `/etc/fstab`；仅在总 swap 小于 1GiB 时创建。需要自行管理 swap 时使用 `--skip-swap`。
- BBR 是否可用取决于内核；脚本会打印最终状态，内核不支持时不会伪造成功。
- 脚本可重复执行：已存在的 Oh My Zsh 会跳过安装，插件仓库会执行 fast-forward 更新。
- 默认 Shell 设置在 Docker 与 BBR 之前完成，并会校验 `/etc/passwd` 中的实际 Shell；重新 SSH 登录后应直接进入 Zsh，当前会话可执行 `exec zsh`。
- SSH 公钥写入只会添加指定的公钥，不会删除已有的 `authorized_keys` 内容；请确认该公钥属于受信任的后续登录主体。
- 这是服务器初始化脚本。请先阅读代码，再在生产服务器执行。

## 验证

```bash
bash -n install.sh
zsh --version
docker --version
sysctl net.ipv4.tcp_congestion_control
```

## 许可证

[MIT](LICENSE)

# 自用配置文件备份

## 常用脚本

### 常用配置

```bash
wget -q -O - https://proxy.19890605.xyz/raw.githubusercontent.com/YangRucheng/Config-Backup/refs/heads/main/scripts/init.sh | bash
```

### 更新 Cloudflared

```bash
wget -q -O - https://proxy.19890605.xyz/raw.githubusercontent.com/YangRucheng/Config-Backup/refs/heads/main/scripts/cloudflared-upgrade.sh | bash
```

二进制通过 `proxy.19890605.xyz` 下载：先向 GitHub API 查询最新版本与官方 sha256，
再经代理逐跳解析出真实下载地址（代理对 release 会返回确认页，脚本会自动跟随），
下载后校验 ELF 头与 sha256，失败则回退 `ghfast.top`。

systemd 服务模板同样经代理下载，安装前有两道校验：先比对仓库内置的 sha256 指纹，
再用严格白名单检查结构（只允许 `[Unit]`/`[Service]`/`[Install]` 段与固定指令，
`ExecStart` 必须恰好一条且指向 `/usr/bin/cloudflared`，禁止续行与注释），
避免被篡改的模板以 root 身份执行任意命令。两个模板全部校验通过后才会写入
`/etc/systemd/system`，不会出现只替换一半的情况。

> ⚠️ 修改 `resource/cloudflared/*.service` 后，必须同步更新
> `scripts/cloudflared-upgrade.sh` 中的 `expected_template_hashes`，
> 并先推送模板再运行脚本，否则脚本会在第 3 步拒绝安装（失败关闭）。

可用环境变量：

| 变量 | 默认值 | 说明 |
| --- | --- | --- |
| `GITHUB_TOKEN` | 空 | 建议设置，避免 GitHub API 限流（未设置时通常拿不到独立可信的 sha256） |
| `ASSET_NAME` | 自动识别 | 手动指定下载文件，如 `cloudflared-linux-arm64` |
| `PROXY_BASE` | `https://proxy.19890605.xyz` | GitHub 代理地址 |
| `GHFAST_PREFIX` | `https://ghfast.top/` | 兜底加速地址 |
| `ALLOW_UNVERIFIED_DOWNLOAD` | `0` | 设为 `1` 时，在拿不到官方 sha256 的情况下仅校验 ELF 头后安装（不推荐） |

### 设置语言

```
wget -q -O - https://proxy.19890605.xyz/raw.githubusercontent.com/YangRucheng/Config-Backup/refs/heads/main/scripts/language.sh | bash
```

## 重装系统

[github.com/bin456789/reinstall](https://github.com/bin456789/reinstall)
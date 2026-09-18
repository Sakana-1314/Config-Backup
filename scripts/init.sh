#! /bin/bash
set -euo pipefail

URL="https://proxy.19890605.xyz/raw.githubusercontent.com/YangRucheng/Config-Backup/refs/heads/main/resource"
NEW_HOSTNAME="Host"

fetch() {
  wget -q --tries=10 -O "$2" "$1" || {
    echo "[!] 下载失败: $1" >&2
    exit 1
  }
}

echo "==> 下载常用配置文件"
fetch "$URL/.npmrc" ~/.npmrc
fetch "$URL/.bashrc" ~/.bashrc
fetch "$URL/.tmux.conf" ~/.tmux.conf
fetch "$URL/.bash_profile" ~/.bash_profile
echo "    完成: ~/.npmrc ~/.bashrc ~/.tmux.conf ~/.bash_profile"

echo "==> 安装 Docker 配置"
mkdir -p /etc/docker
fetch "$URL/daemon.json" /etc/docker/daemon.json
echo "    完成: /etc/docker/daemon.json"

echo "==> 安装 Maven 配置"
mkdir -p ~/.m2
fetch "$URL/.m2/settings.xml" ~/.m2/settings.xml
echo "    完成: ~/.m2/settings.xml"

echo "==> 安装 SSH 公钥"
mkdir -p ~/.ssh
chmod 600 ~/.ssh
fetch "$URL/.ssh/authorized_keys" ~/.ssh/authorized_keys
echo "    完成: ~/.ssh/authorized_keys"

echo "==> 设置主机名"
source ~/.bashrc
OLD_HOSTNAME="$(hostname)"
printf '%s\n' "$NEW_HOSTNAME" > /etc/hostname

if [ -n "$OLD_HOSTNAME" ] && [ "$OLD_HOSTNAME" != "$NEW_HOSTNAME" ]; then
  HOSTS_TMP="$(mktemp)"
  awk -v old="$OLD_HOSTNAME" -v new="$NEW_HOSTNAME" '
    {
      out = ""
      pos = 1
      for (i = 1; i <= NF; i++) {
        p = index(substr($0, pos), $i)
        if (p == 0) break
        s = pos + p - 1
        out = out substr($0, pos, s - pos) ($i == old ? new : $i)
        pos = s + length($i)
      }
      print out substr($0, pos)
    }' /etc/hosts > "$HOSTS_TMP"
  cat "$HOSTS_TMP" > /etc/hosts
  rm -f "$HOSTS_TMP"
fi

if ! awk -v h="$NEW_HOSTNAME" '{ for (i = 1; i <= NF; i++) if ($i == h) found = 1 } END { exit !found }' /etc/hosts; then
  printf '127.0.1.1\t%s\n' "$NEW_HOSTNAME" >> /etc/hosts
fi

hostname "$NEW_HOSTNAME"
echo "    完成: 主机名已设置为 $NEW_HOSTNAME，/etc/hosts 中的旧主机名已全部替换"

echo "==> 配置 SSH 允许 root 公钥登录"
sed -i "s/#PermitRootLogin prohibit-password/PermitRootLogin yes/" /etc/ssh/sshd_config
sed -i "s/#PubkeyAuthentication yes/PubkeyAuthentication yes/" /etc/ssh/sshd_config
echo "    完成: /etc/ssh/sshd_config 已更新"

echo "Success! 执行成功！"

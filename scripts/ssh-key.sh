#! /bin/bash

set -euo pipefail

KEY_URL="${KEY_URL:-https://proxy.19890605.xyz/raw.githubusercontent.com/YangRucheng/Config-Backup/refs/heads/main/resource/.ssh/authorized_keys}"

SSH_DIR="$HOME/.ssh"
KEY_FILE="$SSH_DIR/authorized_keys"
TMP_FILE=""

cleanup() {
  if [ -n "$TMP_FILE" ]; then
    rm -f -- "$TMP_FILE"
  fi
}

trap cleanup EXIT

log_step() {
  echo "==> $*"
}

log_info() {
  echo "    $*"
}

die() {
  echo "[!] $*" >&2
  exit 1
}

# 只接受标准 OpenSSH 公钥行。代理返回错误页、内容被截断时直接覆盖
# authorized_keys 会导致无法登录，因此这里失败关闭。
validate_keys() {
  local file="$1"

  if [ ! -s "$file" ]; then
    return 1
  fi

  awk '
    /^[[:space:]]*(#|$)/ { next }
    {
      if ($0 !~ /^(ssh-(rsa|dss|ed25519)|ecdsa-sha2-nistp(256|384|521)|sk-(ssh-ed25519|ecdsa-sha2-nistp256)@openssh\.com)[[:space:]]+[A-Za-z0-9+\/]+=*([[:space:]].*)?$/) {
        bad = 1
      }
      count++
    }
    END {
      exit (bad || count == 0)
    }
  ' "$file"
}

log_step "下载 SSH 公钥"
mkdir -p "$SSH_DIR" || die "无法创建 $SSH_DIR"
chmod 700 "$SSH_DIR"
[ -w "$SSH_DIR" ] || die "$SSH_DIR 不可写，请使用 root 权限运行"

TMP_FILE="$(mktemp "$SSH_DIR/.authorized_keys.XXXXXX")" || die "无法在 $SSH_DIR 创建临时文件"

wget -q --tries=10 -O "$TMP_FILE" "$KEY_URL" || die "下载失败: $KEY_URL"
validate_keys "$TMP_FILE" || die "公钥格式校验失败，已保留原 authorized_keys"
log_info "下载并校验完成"

if [ -f "$KEY_FILE" ] && cmp -s "$TMP_FILE" "$KEY_FILE"; then
  chmod 600 "$KEY_FILE"
  log_info "公钥内容无变化: $KEY_FILE"
else
  if [ -f "$KEY_FILE" ]; then
    BACKUP="$KEY_FILE.bak.$(date +%Y%m%d%H%M%S)"
    cp -p -- "$KEY_FILE" "$BACKUP"
    chmod 600 "$BACKUP"
    log_info "原公钥已备份: $BACKUP"
  fi

  chmod 600 "$TMP_FILE"
  mv -f -- "$TMP_FILE" "$KEY_FILE"
  TMP_FILE=""
  log_info "已覆盖: $KEY_FILE"
fi

# 主机模式通常位于主配置；这里只做提示，不改动 sshd 配置
if [ -f /etc/ssh/sshd_config ]; then
  if awk 'tolower($1) == "pubkeyauthentication" && tolower($2) == "no" { found = 1 } END { exit !found }' /etc/ssh/sshd_config; then
    log_info "[!] sshd_config 中 PubkeyAuthentication 为 no，公钥登录不会生效"
  fi

  if [ "$EUID" -eq 0 ] && awk 'tolower($1) == "permitrootlogin" && tolower($2) == "no" { found = 1 } END { exit !found }' /etc/ssh/sshd_config; then
    log_info "[!] sshd_config 中 PermitRootLogin 为 no，root 无法用公钥登录"
  fi
fi

echo "Success! 执行成功！"

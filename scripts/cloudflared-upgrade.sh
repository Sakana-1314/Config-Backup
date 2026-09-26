#! /bin/bash

set -euo pipefail

API_URL="${API_URL:-https://api.github.com/repos/cloudflare/cloudflared/releases/latest}"
PROXY_BASE="${PROXY_BASE:-https://proxy.19890605.xyz}"
GHFAST_PREFIX="${GHFAST_PREFIX:-https://ghfast.top/}"
ASSET_NAME="${ASSET_NAME:-}"
RESTART_DELAY_SECONDS="${RESTART_DELAY_SECONDS:-10}"
TMP_FILE=""
TMP_DIR=""
TARGET="/usr/bin/cloudflared"
UPDATE_UNITS=("cloudflared-update.service" "cloudflared-update.timer")
SERVICE_UNITS=("cloudflared@quic.service" "cloudflared@http2.service")
SERVICE_UNIT_DIR="${SERVICE_UNIT_DIR:-/etc/systemd/system}"
SERVICE_TEMPLATE_URL_BASE="${SERVICE_TEMPLATE_URL_BASE:-https://proxy.19890605.xyz/raw.githubusercontent.com/YangRucheng/Config-Backup/refs/heads/main/resource/cloudflared}"
TOKEN_PLACEHOLDER="__CLOUDFLARED_TOKEN__"

log_step() {
  echo
  echo "==> $*"
}

log_info() {
  echo "[+] $*"
}

log_warn() {
  echo "[!] $*"
}

die() {
  echo "[!] $*" >&2
  exit 1
}

require_commands() {
  local missing=()
  local cmd

  for cmd in "$@"; do
    if ! command -v "${cmd}" >/dev/null 2>&1; then
      missing+=("${cmd}")
    fi
  done

  if [ "${#missing[@]}" -gt 0 ]; then
    die "缺少依赖: ${missing[*]}"
  fi
}

cleanup() {
  case "${TMP_DIR}" in
    /tmp/cloudflared-upgrade.*)
      rm -rf -- "${TMP_DIR}"
      ;;
  esac
}

make_tmp_file() {
  local name="$1"

  if [ -z "${TMP_DIR}" ]; then
    die "临时目录尚未初始化"
  fi

  mktemp "${TMP_DIR}/${name}.XXXXXX"
}

detect_cloudflared_asset_name() {
  local machine

  machine="$(uname -m)"

  case "${machine}" in
    x86_64|amd64)
      printf '%s' "cloudflared-linux-amd64"
      ;;
    aarch64|arm64)
      printf '%s' "cloudflared-linux-arm64"
      ;;
    *)
      die "不支持的架构: ${machine}；请手动设置 ASSET_NAME=cloudflared-linux-amd64 或 ASSET_NAME=cloudflared-linux-arm64"
      ;;
  esac
}

parse_release_asset() {
  awk -v asset_name="${ASSET_NAME}" '
    /^[[:space:]]*"name":[[:space:]]*"/ {
      name = $0
      sub(/^[[:space:]]*"name":[[:space:]]*"/, "", name)
      sub(/",?[[:space:]]*$/, "", name)
      matched = (name == asset_name)
    }

    matched && /^[[:space:]]*"digest":[[:space:]]*"/ {
      digest = $0
      sub(/^[[:space:]]*"digest":[[:space:]]*"/, "", digest)
      sub(/",?[[:space:]]*$/, "", digest)
    }

    matched && /^[[:space:]]*"browser_download_url":[[:space:]]*"/ {
      url = $0
      sub(/^[[:space:]]*"browser_download_url":[[:space:]]*"/, "", url)
      sub(/",?[[:space:]]*$/, "", url)
      print url
      print digest
      found = 1
    }

    END {
      if (!found) {
        exit 1
      }
    }
  '
}

fetch_latest_url() {
  local headers=(
    -H "Accept: application/vnd.github+json"
    -H "X-GitHub-Api-Version: 2022-11-28"
  )
  local result

  if [ -n "${GITHUB_TOKEN:-}" ]; then
    headers+=(-H "Authorization: Bearer ${GITHUB_TOKEN}")
  fi

  if result="$(curl -fsSL --connect-timeout 15 --max-time 60 --retry 3 \
      "${headers[@]}" \
      "${API_URL}" \
      | parse_release_asset)"; then
    printf '%s' "${result}"
    return 0
  fi

  # 直连 api.github.com 拿到的 digest 才是独立可信的。
  # 代理返回的 digest 与被下载的二进制来自同一个源，只能证明“代理自洽”，
  # 不能作为独立的信任根；这里仍然用它，但明确告知这一点。
  log_warn "直连 GitHub API 失败，改用代理 ${PROXY_BASE} 查询" >&2
  log_warn "此时 digest 与二进制同源，仅能证明代理自洽；设置 GITHUB_TOKEN 可获得独立校验" >&2
  curl -fsSL --connect-timeout 15 --max-time 60 --retry 3 \
    "${headers[@]}" \
    "$(proxy_url "${API_URL}")" \
    | parse_release_asset
}

proxy_url() {
  local target="${1#https://}"
  target="${target#http://}"
  printf '%s/%s' "${PROXY_BASE%/}" "${target}"
}

is_allowed_target_host() {
  case "${1#https://}" in
    github.com/*|release-assets.githubusercontent.com/*|objects.githubusercontent.com/*|raw.githubusercontent.com/*)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

extract_proxy_target() {
  local file="$1"
  local url=""

  if [ ! -f "${file}" ]; then
    return 1
  fi

  url="$(sed -n 's/.*<div class="url">\([^<]*\)<.*/\1/p' "${file}" | head -n 1)"

  if [ -z "${url}" ]; then
    return 1
  fi

  # 注意：bash 5.2 起 ${var//pat/rep} 的 & 默认表示“匹配到的内容”，
  # 这里必须加引号，否则 &amp; 不会被还原成 &
  url="${url//'&amp;'/'&'}"

  if ! is_allowed_target_host "${url}"; then
    # 必须写 stderr：stdout 会被调用方的命令替换捕获
    log_warn "代理返回了非 GitHub 域名，出于安全考虑忽略: ${url}" >&2
    return 1
  fi

  printf '%s' "${url}"
}

is_elf_binary() {
  local file="$1"
  local magic

  if [ ! -s "${file}" ]; then
    return 1
  fi

  magic="$(head -c 4 "${file}" 2>/dev/null | od -An -tx1 | tr -d ' \n')"
  [ "${magic}" = "7f454c46" ]
}

is_sha256_digest() {
  case "$1" in
    *[!0-9a-fA-F]*|"")
      return 1
      ;;
  esac

  [ "${#1}" -eq 64 ]
}

verify_sha256() {
  local file="$1"
  local expected="${2#sha256:}"
  local actual

  # 失败关闭：没有官方校验和时绝不放行，否则被污染的下载会直接覆盖 /usr/bin/cloudflared
  if ! is_sha256_digest "${expected}"; then
    log_warn "没有可用的官方 sha256 校验和，拒绝校验通过"
    return 1
  fi

  actual="$(sha256sum "${file}" | awk '{print $1}')"

  if [ "${actual}" != "${expected}" ]; then
    log_warn "校验和不匹配: 期望 ${expected}，实际 ${actual}"
    return 1
  fi

  log_info "sha256 校验通过: ${actual}"
}

verify_download() {
  local file="$1"
  local expected="$2"

  if ! is_elf_binary "${file}"; then
    log_warn "下载结果不是有效的 ELF 可执行文件"
    return 1
  fi

  if is_sha256_digest "${expected#sha256:}"; then
    verify_sha256 "${file}" "${expected}"
    return
  fi

  # 没有官方校验和时默认拒绝，避免被污染的下载覆盖 /usr/bin/cloudflared。
  # 确需在限流环境下升级时，可显式设置 ALLOW_UNVERIFIED_DOWNLOAD=1。
  if [ "${ALLOW_UNVERIFIED_DOWNLOAD:-0}" = "1" ]; then
    log_warn "ALLOW_UNVERIFIED_DOWNLOAD=1：跳过 sha256 校验，仅依据 ELF 头接受该文件"
    return 0
  fi

  log_warn "没有官方 sha256 可核对，已中止；如需继续请设置 ALLOW_UNVERIFIED_DOWNLOAD=1"
  return 1
}

download_and_verify() {
  local origin="$1"
  local out="$2"
  local digest="$3"

  if download_via_proxy "${origin}" "${out}"; then
    if verify_download "${out}" "${digest}"; then
      return 0
    fi
    log_warn "代理下载的文件未通过校验，改用 ghfast.top 重试"
  else
    log_warn "代理下载失败，改用 ghfast.top 重试"
  fi

  if download_via_ghfast "${origin}" "${out}"; then
    if verify_download "${out}" "${digest}"; then
      return 0
    fi
    log_warn "ghfast.top 下载的文件未通过校验"
  fi

  return 1
}

describe_url() {
  local url="$1"
  local host="${url#https://}"
  local last

  url="${url%%\?*}"
  host="${host%%/*}"
  last="${url##*/}"

  printf '%s/.../%s' "${host}" "${last:0:48}"
}

download_via_proxy() {
  local origin="$1"
  local out="$2"
  local candidate="${origin}"
  local next
  local attempt

  for attempt in 1 2 3 4; do
    log_info "代理请求 (${attempt}/4): $(describe_url "${candidate}")"

    # 先删除旧文件：curl 连接失败或返回 304 时不会截断已存在的文件，
    # 留下上一次的残留内容会绕过后续的 ELF 校验
    rm -f "${out}" || true

    if curl -fsSL --connect-timeout 15 --max-time 600 --retry 3 \
      -o "${out}" \
      "$(proxy_url "${candidate}")" && is_elf_binary "${out}"; then
      return 0
    fi

    next="$(extract_proxy_target "${out}" || true)"

    if [ -z "${next}" ]; then
      log_warn "第 ${attempt} 次代理请求未返回可下载地址"
      return 1
    fi

    if [ "${next}" = "${candidate}" ]; then
      log_warn "代理地址未推进，停止重试: $(describe_url "${next}")"
      return 1
    fi

    log_info "解析到下一跳: $(describe_url "${next}")"
    candidate="${next}"
  done

  log_warn "代理下载重试次数已用尽"
  return 1
}

download_via_ghfast() {
  local origin="$1"
  local out="$2"

  log_warn "改用 ghfast.top 兜底下载"
  log_info "加速链接: ${GHFAST_PREFIX}${origin}"

  rm -f "${out}" || true

  curl -fsSL --connect-timeout 15 --max-time 600 --retry 3 \
    -o "${out}" \
    "${GHFAST_PREFIX}${origin}" && is_elf_binary "${out}"
}

get_unit_fragment_path() {
  local unit="$1"

  systemctl show -p FragmentPath --value "${unit}" 2>/dev/null || true
}

unit_exists() {
  local unit="$1"
  local load_state

  load_state="$(systemctl show -p LoadState --value "${unit}" 2>/dev/null || true)"
  [ -n "${load_state}" ] && [ "${load_state}" != "not-found" ]
}

stop_unit_if_active() {
  local unit="$1"

  if systemctl is-active --quiet "${unit}"; then
    log_info "停止 ${unit}"
    systemctl stop "${unit}"
  else
    log_info "${unit} 未运行，跳过停止"
  fi
}

disable_unit_if_enabled() {
  local unit="$1"
  local enabled_state

  enabled_state="$(systemctl is-enabled "${unit}" 2>/dev/null || true)"

  case "${enabled_state}" in
    enabled|enabled-runtime|linked|linked-runtime|alias)
      log_info "禁用 ${unit}（当前状态: ${enabled_state}）"
      systemctl disable "${unit}"
      ;;
    disabled|static|indirect|generated|transient|masked)
      log_info "${unit} 无需禁用（当前状态: ${enabled_state}）"
      ;;
    not-found)
      log_info "${unit} 未安装，跳过禁用"
      ;;
    *)
      die "无法确认 ${unit} 是否已启用（当前状态: ${enabled_state:-unknown}）"
      ;;
  esac
}

remove_cloudflared_update_units() {
  local unit
  local fragment
  local path
  local unit_paths

  log_step "2/7 移除 cloudflared 自动更新 systemd 任务（如果存在）"

  for unit in "${UPDATE_UNITS[@]}"; do
    log_info "检查 ${unit}"

    if unit_exists "${unit}"; then
      stop_unit_if_active "${unit}"
      disable_unit_if_enabled "${unit}"
    else
      log_info "${unit} 未安装，跳过停止和禁用"
    fi

    fragment="$(get_unit_fragment_path "${unit}")"
    if [ -n "${fragment}" ] && [ "${fragment}" != "n/a" ] && [ -e "${fragment}" ]; then
      case "${fragment}" in
        /etc/systemd/system/*|/run/systemd/system/*|/usr/local/lib/systemd/system/*|/usr/lib/systemd/system/*|/lib/systemd/system/*)
          log_info "删除 ${fragment}"
          rm -f "${fragment}"
          ;;
        *)
          die "发现非标准 systemd 目录中的 unit 文件，无法安全移除: ${fragment}"
          ;;
      esac
    fi

    unit_paths=(
      "/etc/systemd/system/${unit}"
      "/run/systemd/system/${unit}"
      "/usr/local/lib/systemd/system/${unit}"
      "/usr/lib/systemd/system/${unit}"
      "/lib/systemd/system/${unit}"
    )

    for path in "${unit_paths[@]}"; do
      if [ -e "${path}" ]; then
        log_info "删除 ${path}"
        rm -f "${path}"
      else
        log_info "未找到 ${path}"
      fi
    done
  done

  log_info "重新加载 systemd"
  systemctl daemon-reload
  log_info "cloudflared 自动更新任务清理完成"
}

service_token_env_name() {
  local unit="$1"

  case "${unit}" in
    cloudflared@quic.service)
      printf '%s' "CLOUDFLARED_QUIC_TOKEN"
      ;;
    cloudflared@http2.service)
      printf '%s' "CLOUDFLARED_HTTP2_TOKEN"
      ;;
    *)
      printf '%s' "CLOUDFLARED_TOKEN"
      ;;
  esac
}

extract_cloudflared_token() {
  awk '
    function clean(value) {
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
      sub(/\\$/, "", value)
      gsub(/^["\047]|["\047]$/, "", value)
      return value
    }

    function valid(value) {
      return value != "" && value != "\\" && value != "__CLOUDFLARED_TOKEN__" && value != "{{TOKEN}}"
    }

    {
      for (i = 1; i <= NF; i++) {
        field = clean($i)

        if (want_token) {
          if (valid(field)) {
            print field
            exit
          }

          if (field != "" && field != "\\") {
            want_token = 0
          }
        }

        if (field == "--token") {
          want_token = 1
        } else if (field ~ /^--token=/) {
          sub(/^--token=/, "", field)
          field = clean(field)
          if (valid(field)) {
            print field
            exit
          }
        } else if (field ~ /TUNNEL_TOKEN=/) {
          sub(/^.*TUNNEL_TOKEN=/, "", field)
          field = clean(field)
          if (valid(field)) {
            print field
            exit
          }
        }
      }
    }
  '
}

read_existing_service_token() {
  local unit="$1"
  local token
  local path
  local candidate_paths

  token="$({ systemctl cat "${unit}" 2>/dev/null || true; } | extract_cloudflared_token || true)"
  if [ -n "${token}" ]; then
    printf '%s' "${token}"
    return
  fi

  candidate_paths=(
    "${SERVICE_UNIT_DIR}/${unit}"
    "/etc/systemd/system/${unit}"
    "/run/systemd/system/${unit}"
    "/usr/local/lib/systemd/system/${unit}"
    "/usr/lib/systemd/system/${unit}"
    "/lib/systemd/system/${unit}"
  )

  for path in "${candidate_paths[@]}"; do
    if [ -f "${path}" ]; then
      token="$(extract_cloudflared_token < "${path}" || true)"
      if [ -n "${token}" ]; then
        printf '%s' "${token}"
        return
      fi
    fi
  done
}

prompt_for_service_token() {
  local unit="$1"
  local env_name="$2"
  local token=""

  if [ ! -r /dev/tty ] || [ ! -w /dev/tty ]; then
    die "无法读取 ${unit} 的 token，且当前没有可交互的 TTY；请设置环境变量 ${env_name} 后重试"
  fi

  while [ -z "${token}" ]; do
    printf "请输入 %s 的 cloudflared tunnel token: " "${unit}" >/dev/tty
    IFS= read -r -s token </dev/tty || die "读取 ${unit} token 失败"
    printf "\n" >/dev/tty

    if [ -z "${token}" ]; then
      printf "token 不能为空，请重试。\n" >/dev/tty
    fi
  done

  printf '%s' "${token}"
}

expected_template_hashes() {
  printf '%s\n' \
    "cloudflared@quic.service c01081b76f315d15527a2b1355766ef8a239aecea3dc3925edefdd071e05642a" \
    "cloudflared@http2.service 70a7eba123d17ed8eae96065e14f8d6084e9d288b465f7c5f8beb638ca7849b0"
}

expected_template_hash() {
  local unit="$1"

  expected_template_hashes | awk -v u="${unit}" '$1 == u { print $2 }'
}

verify_template_hash() {
  local file="$1"
  local unit="$2"
  local expected
  local actual

  expected="$(expected_template_hash "${unit}")"

  # 失败关闭：没有内置指纹就不允许安装，避免有人往 SERVICE_UNITS 里加了新 unit
  # 却忘了登记校验和时，指纹校验被静默跳过。
  if [ -z "${expected}" ]; then
    log_warn "没有 ${unit} 的内置校验和，拒绝安装（请先在脚本中登记其 sha256）"
    return 1
  fi

  actual="$(sha256sum "${file}" | awk '{print $1}')"

  if [ "${actual}" != "${expected}" ]; then
    log_warn "${unit} 模板指纹与仓库内置值不一致"
    log_warn "期望 ${expected}"
    log_warn "实际 ${actual}"
    log_warn "确认已更新仓库模板后再升级；本次拒绝安装该模板"
    return 1
  fi

  log_info "${unit} 模板指纹校验通过"
}

render_service_template() {
  local token="$1"

  awk -v token="${token}" -v placeholder="${TOKEN_PLACEHOLDER}" '
    function replace_all(value, needle,   pos) {
      while ((pos = index(value, needle)) > 0) {
        value = substr(value, 1, pos - 1) token substr(value, pos + length(needle))
      }
      return value
    }

    {
      line = replace_all($0, placeholder)
      line = replace_all(line, "{{TOKEN}}")
      print line
    }
  '
}

validate_unit_template() {
  local file="$1"
  local unit="$2"
  local reason

  # 模板来自同一个不可信代理，装到 /etc/systemd/system 后由 root 执行。
  # systemd 指令面太大，黑名单无法穷尽（ExecStop / OnSuccess / Environment=LD_PRELOAD
  # / StandardOutput=file:... 都能以 root 执行或写文件），因此改用严格白名单：
  # 只允许固定段落与固定指令，且必须恰好有一条指向 ${TARGET} 的 ExecStart。
  #
  # 注意：这里刻意不支持行末续行（\）与注释。awk 的续行/注释处理与 systemd 自身
  # 的解析器并不完全一致（例如 "\ " 结尾 systemd 不续行，注释里的 \ 也不续行），
  # 任何分歧都能把 ExecStop= 之类的指令偷渡进白名单。直接禁止这两类语法即可
  # 从根上消除该分歧，仓库内的模板也已改为单行 ExecStart。
  reason="$(awk -v target="${TARGET}" -v placeholder="${TOKEN_PLACEHOLDER}" '
    function fail(msg) {
      print msg
      bad = 1
    }

    function allowed(key, list) {
      return index(" " list " ", " " key " ") > 0
    }

    {
      logical[++total] = $0
    }

    END {
      section = ""
      exec_count = 0
      has_token = 0

      for (i = 1; i <= total; i++) {
        line = logical[i]
        sub(/\r$/, "", line)

        if (line ~ /^[[:space:]]*$/) {
          continue
        }

        if (line ~ /\\/) {
          fail("不允许行末续行或反斜杠: " line)
          continue
        }

        if (line ~ /#/) {
          fail("不允许注释: " line)
          continue
        }

        if (line ~ /^\[/) {
          if (line !~ /^\[(Unit|Service|Install)\]$/) {
            fail("不允许的段落: " line)
            continue
          }

          if (seen[line]++) {
            fail("段落重复: " line)
          }

          section = line
          continue
        }

        if (line ~ /^[[:space:]]/) {
          fail("指令不得缩进: " line)
          continue
        }

        if (line !~ /=/) {
          fail("不是 key=value: " line)
          continue
        }

        key = line
        sub(/=.*$/, "", key)
        value = line
        sub(/^[^=]*=/, "", value)

        if (key !~ /^[A-Za-z][A-Za-z0-9]*$/) {
          fail("指令名非法: " key)
          continue
        }

        if (section == "[Unit]") {
          if (!allowed(key, "Description After Wants")) {
            fail("[Unit] 不允许的指令: " key)
          }
        } else if (section == "[Service]") {
          if (!allowed(key, "TimeoutStartSec Type ExecStart Restart RestartSec")) {
            fail("[Service] 不允许的指令: " key)
          }

          if (key == "Type" && value != "simple") {
            fail("Type 只允许 simple，实际: " value)
          }

          if (key == "ExecStart") {
            exec_count++

            if (substr(value, 1, length(target)) != target) {
              fail("ExecStart 未指向 " target)
            } else if (substr(value, length(target) + 1, 1) != " ") {
              fail("ExecStart 缺少参数")
            } else if (value ~ /[`$|&;<>()]/) {
              fail("ExecStart 含 shell 元字符")
            }

            if (index(value, placeholder) > 0) {
              has_token = 1
            }
          }
        } else if (section == "[Install]") {
          if (!allowed(key, "WantedBy")) {
            fail("[Install] 不允许的指令: " key)
          }
        } else {
          fail("指令出现在任何段落之外: " key)
        }
      }

      if (!seen["[Unit]"]) {
        fail("缺少 [Unit] 段")
      }

      if (!seen["[Service]"]) {
        fail("缺少 [Service] 段")
      }

      if (exec_count != 1) {
        fail("必须恰好有一条 ExecStart，实际: " exec_count)
      }

      if (!has_token) {
        fail("ExecStart 未包含 token 占位符 " placeholder)
      }

      exit bad ? 1 : 0
    }
  ' "${file}")" || {
    if [ -n "${reason}" ]; then
      while IFS= read -r line; do
        [ -n "${line}" ] && log_warn "${unit} 模板校验失败: ${line}" >&2
      done <<< "${reason}"
    fi
    return 1
  }
}

install_cloudflared_service_units() {
  local unit
  local env_name
  local token
  local tmp_template
  local tmp_unit
  local target_path

  log_step "3/7 同步 cloudflared systemd 服务文件"

  mkdir -p "${SERVICE_UNIT_DIR}"

  # 两阶段：先把两个模板全部下载并校验，全部通过后才写入 SERVICE_UNIT_DIR。
  # 这样任一模板失败都不会留下“一个已替换、一个未替换”的半成品状态。
  local staged_templates=()

  for unit in "${SERVICE_UNITS[@]}"; do
    env_name="$(service_token_env_name "${unit}")"
    token="${!env_name-}"

    if [ -n "${token}" ]; then
      log_info "${unit} 使用环境变量 ${env_name} 中的 token"
    else
      token="$(read_existing_service_token "${unit}")"

      if [ -n "${token}" ]; then
        log_info "${unit} 沿用已有服务文件中的 token"
      else
        log_warn "${unit} 未找到已有 token"
        token="$(prompt_for_service_token "${unit}" "${env_name}")"
      fi
    fi

    tmp_template="$(make_tmp_file "${unit}.template")"
    tmp_unit="$(make_tmp_file "${unit}")"

    log_info "下载模板到临时文件 ${tmp_template}"
    curl -fsSL --connect-timeout 15 --max-time 60 --retry 3 \
      -o "${tmp_template}" \
      "${SERVICE_TEMPLATE_URL_BASE}/${unit}"

    if ! verify_template_hash "${tmp_template}" "${unit}"; then
      die "${unit} 模板指纹校验失败，已中止安装（如已更新仓库模板，请同步更新脚本内置校验和）"
    fi

    if ! validate_unit_template "${tmp_template}" "${unit}"; then
      die "${unit} 模板未通过安全校验，已中止安装"
    fi

    log_info "渲染服务文件 ${tmp_unit}"
    render_service_template "${token}" < "${tmp_template}" > "${tmp_unit}"

    if grep -q "${TOKEN_PLACEHOLDER}" "${tmp_unit}" || grep -q "{{TOKEN}}" "${tmp_unit}"; then
      die "${unit} 模板渲染后仍包含 token 占位符"
    fi

    chmod 0644 "${tmp_unit}"

    staged_templates+=("${unit} ${tmp_unit}")
  done

  # 所有模板均已在临时目录中就绪，此处才真正写入
  for entry in "${staged_templates[@]}"; do
    unit="${entry%% *}"
    tmp_unit="${entry#* }"
    target_path="${SERVICE_UNIT_DIR}/${unit}"
    log_info "更新 ${target_path}"
    mv -f "${tmp_unit}" "${target_path}"
  done

  log_info "重新加载 systemd"
  systemctl daemon-reload
  log_info "cloudflared systemd 服务文件同步完成"
}

find_cloudflared_services() {
  local unit_files
  local units

  unit_files="$(systemctl list-unit-files --type=service --no-legend --no-pager)"
  units="$(systemctl list-units --type=service --all --no-legend --no-pager)"

  {
    printf '%s\n' "${unit_files}" | awk '{print $1}'
    printf '%s\n' "${units}" | awk '{if ($1 ~ /\.service$/) print $1; else print $2}'
  } | awk '
      /^cloudflared.*\.service$/ && $0 != "cloudflared-update.service" {
        print
      }
    ' | sort -u
}

schedule_cloudflared_restart() {
  local restart_job="cloudflared-upgrade-restart-$$"
  local systemctl_bin

  systemctl_bin="$(command -v systemctl)"

  log_info "提交后台延迟重启任务: ${restart_job}"
  log_info "${RESTART_DELAY_SECONDS} 秒后重启服务: $*"

  systemd-run \
    --unit="${restart_job}" \
    --description="Restart cloudflared services after upgrade" \
    --on-active="${RESTART_DELAY_SECONDS}s" \
    "${systemctl_bin}" restart "$@"

  log_info "后台重启任务已提交；当前脚本将先退出，避免 SSH 映射中断影响重启"
}

log_step "1/7 检查运行环境"
require_commands curl awk grep sed systemctl systemd-run chmod mkdir mv rm mktemp sort uname sha256sum od
log_info "依赖检查通过"

if [ -z "${ASSET_NAME}" ]; then
  ASSET_NAME="$(detect_cloudflared_asset_name)"
  log_info "自动选择下载文件: ${ASSET_NAME}"
else
  log_info "使用指定下载文件: ${ASSET_NAME}"
fi

systemctl list-unit-files --type=service --no-legend --no-pager >/dev/null
log_info "systemd 查询检查通过"

if [ "${EUID}" -ne 0 ]; then
  die "请使用 root 权限运行"
fi
log_info "root 权限检查通过"

TMP_DIR="$(mktemp -d /tmp/cloudflared-upgrade.XXXXXX)"
trap cleanup EXIT
log_info "临时目录: ${TMP_DIR}"

TMP_FILE="$(make_tmp_file cloudflared)"
log_info "临时文件: ${TMP_FILE}"

remove_cloudflared_update_units

install_cloudflared_service_units

log_step "4/7 获取最新 ${ASSET_NAME} 下载链接"

API_RESULT="$(fetch_latest_url || true)"
ORIGIN_URL="$(printf '%s\n' "${API_RESULT}" | sed -n '1p')"
EXPECTED_DIGEST="$(printf '%s\n' "${API_RESULT}" | sed -n '2p')"

if ! is_sha256_digest "${EXPECTED_DIGEST#sha256:}"; then
  EXPECTED_DIGEST=""
fi

if [ -z "${ORIGIN_URL}" ]; then
  # GitHub API 未认证时经常限流；此时退回 canonical 的 latest 链接，
  # 由代理逐跳解析出真实 tag，仍然可以完成下载（但没有官方校验和可核对）
  ORIGIN_URL="https://github.com/cloudflare/cloudflared/releases/latest/download/${ASSET_NAME}"
  log_warn "未能通过 GitHub API 获取链接，退回 latest 链接: ${ORIGIN_URL}"
fi

log_info "原始链接: ${ORIGIN_URL}"
if [ -n "${EXPECTED_DIGEST}" ]; then
  log_info "官方校验和: ${EXPECTED_DIGEST}"
else
  log_warn "本次拿不到官方 sha256；默认会拒绝安装，建议设置 GITHUB_TOKEN"
  log_warn "如确需在限流环境下升级，可显式设置 ALLOW_UNVERIFIED_DOWNLOAD=1 跳过校验"
fi

log_step "5/7 通过 ${PROXY_BASE} 下载最新 cloudflared"

if ! download_and_verify "${ORIGIN_URL}" "${TMP_FILE}" "${EXPECTED_DIGEST}"; then
  die "下载 ${ASSET_NAME} 失败或未通过校验（代理与 ghfast.top 均已尝试）"
fi

log_info "下载完成: ${TMP_FILE}"
chmod +x "${TMP_FILE}"

log_step "6/7 安装二进制到 ${TARGET}"
mv -f "${TMP_FILE}" "${TARGET}"
log_info "安装完成: ${TARGET}"

log_step "7/7 启用 cloudflared 服务并提交延迟重启任务"

SERVICES_TEXT="$(find_cloudflared_services)"

if [ -n "${SERVICES_TEXT}" ]; then
  mapfile -t SERVICES <<< "${SERVICES_TEXT}"
else
  SERVICES=()
fi

if [ "${#SERVICES[@]}" -eq 0 ]; then
  log_warn "没有找到 cloudflared 开头的服务"
  exit 0
fi

log_info "发现服务: ${SERVICES[*]}"

for svc in "${SERVICES[@]}"; do
  log_info "启用 ${svc}"
  systemctl enable "${svc}"
done

schedule_cloudflared_restart "${SERVICES[@]}"

echo
log_info "完成；cloudflared 将在 ${RESTART_DELAY_SECONDS} 秒后由 systemd 后台重启"

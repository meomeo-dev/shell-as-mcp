#!/usr/bin/env bash
set -euo pipefail

# macOS only — requires osascript (AppleScript runner) and pbpaste (clipboard reader)
if ! command -v osascript > /dev/null 2>&1; then
  printf 'ERROR: osascript not found. This tool requires macOS.\n' >&2
  exit 1
fi
if ! command -v pbpaste > /dev/null 2>&1; then
  printf 'ERROR: pbpaste not found. This tool requires macOS.\n' >&2
  exit 1
fi

_ENC_COOKIES="${HOME}/.config/shell-as-mcp/ytdlp_cookies.enc"
_COOKIE_KEY="shell-as-mcp-$(hostname)-ytdlp-v1"
TOOL_OVERWRITE="${TOOL_OVERWRITE:-true}"

# overwrite=false: skip silently if cookies already exist
if [[ "$TOOL_OVERWRITE" != "true" && -f "$_ENC_COOKIES" ]]; then
  printf 'Cookies already stored. Set overwrite=true to replace.\n'
  exit 0
fi

# 检测系统语言 / Detect system language (zh = Chinese, others = English)
_SYS_LANG="$(defaults read -g AppleLanguages 2>/dev/null | grep -oE '"[a-z]{2}' | head -1 | tr -d '"')"
_IS_ZH=false
[[ "$_SYS_LANG" == "zh" ]] && _IS_ZH=true

# AppleScript 临时文件（避免多行 -e 转义问题）
_AS_SCRIPT="$(mktemp /tmp/.mcp_ytdlp_as_XXXXXX)"
trap 'rm -f "${_AS_SCRIPT}"' EXIT

# --- Step 1-3: 最多尝试 3 次（1次初始 + 2次重试）---
# Up to 3 attempts total (1 initial + 2 retries); attempt number shown in dialog title
_MAX_ATTEMPTS=3
COOKIES_CONTENT=""
for (( _ATTEMPT=1; _ATTEMPT<=_MAX_ATTEMPTS; _ATTEMPT++ )); do

  # 标题后缀：第 2、3 次起显示重试次数 / Show retry count from attempt 2 onward
  if [[ "$_ATTEMPT" -gt 1 ]]; then
    if [[ "$_IS_ZH" == "true" ]]; then
      _TITLE_SUFFIX="（第 ${_ATTEMPT}/${_MAX_ATTEMPTS} 次）"
    else
      _TITLE_SUFFIX=" (Attempt ${_ATTEMPT}/${_MAX_ATTEMPTS})"
    fi
  else
    _TITLE_SUFFIX=""
  fi

  # Step 1: 展示操作指引对话框
  if [[ "$_IS_ZH" == "true" ]]; then
    cat > "${_AS_SCRIPT}" << ASEOF
set msg to "yt-dlp Cookie 配置" & return & return & ¬
  "操作步骤：" & return & ¬
  "1. 打开浏览器并登录 YouTube" & return & ¬
  "2. 安装「Get cookies.txt LOCALLY」扩展程序" & return & ¬
  "3. 在 YouTube 任意页面点击该扩展图标" & return & ¬
  "4. 点击扩展中的「复制」按钮，将 cookies.txt 发送到剪贴板" & return & ¬
  "5. 点击下方确定按钮继续保存"
display dialog msg ¬
  buttons {"取消", "确定 – 已复制到剪贴板"} ¬
  default button "确定 – 已复制到剪贴板" ¬
  with title "yt-dlp Cookie 配置${_TITLE_SUFFIX}"
ASEOF
  else
    cat > "${_AS_SCRIPT}" << ASEOF
set msg to "yt-dlp Cookie Setup" & return & return & ¬
  "Steps:" & return & ¬
  "1. Open your browser and log in to YouTube" & return & ¬
  "2. Install the 'Get cookies.txt LOCALLY' extension" & return & ¬
  "3. While on any YouTube page, click the extension icon" & return & ¬
  "4. Click the 'Copy' button to send cookies.txt to clipboard" & return & ¬
  "5. Click OK below to continue and save"
display dialog msg ¬
  buttons {"Cancel", "OK – cookies are in clipboard"} ¬
  default button "OK – cookies are in clipboard" ¬
  with title "yt-dlp Cookie Setup${_TITLE_SUFFIX}"
ASEOF
  fi

  # 用户点取消则退出
  if ! osascript "${_AS_SCRIPT}" > /dev/null 2>&1; then
    printf 'Setup cancelled by user.\n' >&2
    exit 1
  fi

  # Step 2: 读取剪贴板
  COOKIES_CONTENT="$(pbpaste)"

  if [[ -z "$COOKIES_CONTENT" ]]; then
    if [[ "$_IS_ZH" == "true" ]]; then
      cat > "${_AS_SCRIPT}" << ASEOF
display alert "配置失败${_TITLE_SUFFIX}" message ¬
  "剪贴板为空。请先在「Get cookies.txt LOCALLY」扩展中点击「复制」按钮。" ¬
  as warning
ASEOF
    else
      cat > "${_AS_SCRIPT}" << ASEOF
display alert "Setup failed${_TITLE_SUFFIX}" message ¬
  "Clipboard is empty. Please click the Copy button in the 'Get cookies.txt LOCALLY' extension first." ¬
  as warning
ASEOF
    fi
    osascript "${_AS_SCRIPT}" > /dev/null 2>&1 || true
    continue
  fi

  # Step 3a: 验证 Netscape cookies 文件头
  FIRST_LINE="$(printf '%s\n' "$COOKIES_CONTENT" | head -1)"
  if ! printf '%s\n' "$FIRST_LINE" | grep -qiE "^#.*(netscape|http cookie|generated)"; then
    if [[ "$_IS_ZH" == "true" ]]; then
      cat > "${_AS_SCRIPT}" << ASEOF
display alert "格式无效${_TITLE_SUFFIX}" message ¬
  "剪贴板内容不是有效的 cookies.txt 文件。" & return & ¬
  "请确认已点击「Get cookies.txt LOCALLY」扩展的「复制」按钮。" ¬
  as warning
ASEOF
    else
      cat > "${_AS_SCRIPT}" << ASEOF
display alert "Invalid format${_TITLE_SUFFIX}" message ¬
  "Clipboard does not appear to contain a valid cookies.txt file." & return & ¬
  "Make sure you clicked the 'Copy' button in the 'Get cookies.txt LOCALLY' extension." ¬
  as warning
ASEOF
    fi
    osascript "${_AS_SCRIPT}" > /dev/null 2>&1 || true
    continue
  fi

  # Step 3b: 校验数据行结构（tab 分隔字段 / TRUE|FALSE / 数字 expiry）
  # Validate data rows: 6-7 tab fields; fields 2/4=TRUE|FALSE; field 5=numeric expiry
  INVALID_ROW_COUNT="$(printf '%s\n' "$COOKIES_CONTENT" | awk -F'\t' '
    /^[[:space:]]*$/ || /^#/ { next }
    {
      ok = 1
      if (NF < 6 || NF > 7) ok = 0
      else {
        if ($2 != "TRUE" && $2 != "FALSE") ok = 0
        if ($4 != "TRUE" && $4 != "FALSE") ok = 0
        if ($5 !~ /^[0-9]+$/) ok = 0
      }
      if (!ok) count++
    }
    END { print count+0 }
  ')"

  if [[ "$INVALID_ROW_COUNT" -gt 0 ]]; then
    if [[ "$_IS_ZH" == "true" ]]; then
      cat > "${_AS_SCRIPT}" << ASEOF
display alert "格式校验失败${_TITLE_SUFFIX}" message "${INVALID_ROW_COUNT} 行数据格式不正确，请重新从「Get cookies.txt LOCALLY」扩展复制 cookies 后再试。" as warning
ASEOF
    else
      cat > "${_AS_SCRIPT}" << ASEOF
display alert "Invalid format${_TITLE_SUFFIX}" message "${INVALID_ROW_COUNT} row(s) have an invalid format. Please copy cookies again from the 'Get cookies.txt LOCALLY' extension and retry." as warning
ASEOF
    fi
    osascript "${_AS_SCRIPT}" > /dev/null 2>&1 || true
    continue
  fi

  break  # 验证全部通过，退出循环
done

# 超出最大重试次数仍未通过
if [[ -z "$COOKIES_CONTENT" ]] || \
   ! printf '%s\n' "$COOKIES_CONTENT" | head -1 | grep -qiE "^#.*(netscape|http cookie|generated)"; then
  printf 'ERROR: setup failed after %s attempts.\n' "$_MAX_ATTEMPTS" >&2
  exit 1
fi

# --- Step 4: 加密保存（AES-128-CBC + PBKDF2, machine-local key）---
mkdir -p "$(dirname "$_ENC_COOKIES")"
if ! printf '%s\n' "$COOKIES_CONTENT" | \
     openssl enc -aes-128-cbc -pbkdf2 \
       -pass "pass:${_COOKIE_KEY}" \
       -out "$_ENC_COOKIES" 2>/dev/null; then
  printf 'ERROR: failed to encrypt cookies. Ensure openssl is installed.\n' >&2
  exit 1
fi
chmod 600 "$_ENC_COOKIES"

# 统计域条目数（忽略注释行）
if ! ENTRY_COUNT="$(printf '%s\n' "$COOKIES_CONTENT" | grep -c '^[^#]' 2>/dev/null)"; then
  ENTRY_COUNT="0"
fi

# --- Step 5: 成功提示 ---
if [[ "$_IS_ZH" == "true" ]]; then
  cat > "${_AS_SCRIPT}" << 'ASEOF'
display dialog ¬
  "Cookies 已加密保存！" & return & return & ¬
  "所有 ytdlp__ 工具将在未配置指定路径时自动使用这些 cookies。" ¬
  buttons {"确定"} default button "确定" ¬
  with title "yt-dlp Cookie 配置完成"
ASEOF
else
  cat > "${_AS_SCRIPT}" << 'ASEOF'
display dialog ¬
  "Cookies saved and encrypted successfully!" & return & return & ¬
  "All ytdlp__ tools will now use these cookies automatically when no explicit cookies path is configured." ¬
  buttons {"OK"} default button "OK" ¬
  with title "yt-dlp Cookie Setup Complete"
ASEOF
fi
osascript "${_AS_SCRIPT}" > /dev/null 2>&1 || true

printf 'Cookies saved: %s\n' "$_ENC_COOKIES"
printf 'Domain entries stored: %s\n' "$ENTRY_COUNT"
printf 'All ytdlp__ tools will now use these cookies automatically.\n'

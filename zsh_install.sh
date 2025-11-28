#!/bin/bash
set -euo pipefail

if [ "$(id -u)" -eq 0 ]; then
  CURRENT_USER=${SUDO_USER:-$(logname 2>/dev/null || echo root)}
else
  CURRENT_USER=$(id -un)
fi

HOME_DIR=$(eval echo "~$CURRENT_USER")
if [ -z "$HOME_DIR" ] || [ ! -d "$HOME_DIR" ]; then
  echo "错误：无法确定用户 $CURRENT_USER 的家目录，请检查环境。"
  exit 1
fi

TARGET_GROUP=$(id -gn "$CURRENT_USER")
ZSHRC="$HOME_DIR/.zshrc"
OH_MY_ZSH_DIR="$HOME_DIR/.oh-my-zsh"
OH_MY_ZSH_CUSTOM="${ZSH_CUSTOM:-$OH_MY_ZSH_DIR/custom}"
PLUGIN_DIR="$OH_MY_ZSH_CUSTOM/plugins"
PLUGINS_STRING="git zsh-autosuggestions zsh-syntax-highlighting autojump zsh-history-substring-search"
ZSH_THEME="ys"
APT_UPDATED=0

echo "目标用户：$CURRENT_USER"
echo "家目录：$HOME_DIR"

run_as_target_user() {
  local CMD="$1"
  if [ "$(id -u)" -eq 0 ] && [ "$CURRENT_USER" != "root" ]; then
    if command -v sudo >/dev/null 2>&1; then
      sudo -u "$CURRENT_USER" bash -lc "$CMD"
    elif command -v su >/dev/null 2>&1; then
      su - "$CURRENT_USER" -c "$CMD"
    else
      echo "警告：无法切换到用户 $CURRENT_USER 执行命令：$CMD"
      return 1
    fi
  else
    bash -lc "$CMD"
  fi
}

run_with_privilege() {
  if [ "$(id -u)" -eq 0 ]; then
    "$@"
  elif command -v sudo >/dev/null 2>&1; then
    sudo "$@"
  else
    return 1
  fi
}

detect_package_manager() {
  for mgr in apt-get dnf yum pacman brew; do
    if command -v "$mgr" >/dev/null 2>&1; then
      echo "$mgr"
      return 0
    fi
  done
  echo ""
}
PKG_MANAGER=$(detect_package_manager)

install_package() {
  local pkg="$1"
  local brew_name="${2:-$pkg}"

  case "$PKG_MANAGER" in
    apt-get)
      if [ "$APT_UPDATED" -eq 0 ]; then
        if ! run_with_privilege apt-get update; then
          echo "警告：无法执行 apt-get update，请手动安装 ${pkg}。"
          return 1
        fi
        APT_UPDATED=1
      fi
      if ! run_with_privilege apt-get install -y "$pkg"; then
        echo "警告：无法使用 apt-get 安装 ${pkg}。"
        return 1
      fi
      ;;
    dnf)
      if ! run_with_privilege dnf install -y "$pkg"; then
        echo "警告：无法使用 dnf 安装 ${pkg}。"
        return 1
      fi
      ;;
    yum)
      if ! run_with_privilege yum install -y "$pkg"; then
        echo "警告：无法使用 yum 安装 ${pkg}。"
        return 1
      fi
      ;;
    pacman)
      if ! run_with_privilege pacman -S --noconfirm "$pkg"; then
        echo "警告：无法使用 pacman 安装 ${pkg}。"
        return 1
      fi
      ;;
    brew)
      if ! command -v brew >/dev/null 2>&1; then
        echo "警告：未检测到 Homebrew。macOS 用户请先安装 Homebrew: https://brew.sh"
        return 1
      fi
      if ! run_as_target_user "brew list --versions '$brew_name' >/dev/null 2>&1 || brew install '$brew_name'"; then
        echo "警告：无法使用 brew 安装 ${brew_name}。"
        return 1
      fi
      ;;
    *)
      echo "警告：未识别的包管理器，无法自动安装 ${pkg}。"
      return 1
      ;;
  esac

  return 0
}

install_plugin_repo() {
  local name="$1"
  local repo="$2"
  local target="$PLUGIN_DIR/$name"

  if [ -d "$target/.git" ]; then
    echo "更新插件 $name..."
    if ! run_as_target_user "cd '$target' && git pull --ff-only"; then
      echo "警告：插件 $name 更新失败。"
      return 1
    fi
  elif [ -d "$target" ]; then
    echo "警告：检测到 $target 目录但不是 Git 仓库，跳过。"
    return 1
  else
    echo "安装插件 $name..."
    if ! run_as_target_user "git clone '$repo' '$target'"; then
      echo "警告：插件 $name 安装失败。"
      return 1
    fi
  fi
  return 0
}

append_block_if_missing() {
  local file="$1"
  local marker="$2"
  local block="$3"

  if ! grep -Fq "$marker" "$file"; then
    printf '\n%s\n' "$block" >> "$file"
  fi
}

get_current_shell() {
  if command -v getent >/dev/null 2>&1; then
    getent passwd "$CURRENT_USER" | cut -d: -f7
  elif command -v dscl >/dev/null 2>&1; then
    dscl . -read "/Users/$CURRENT_USER" UserShell 2>/dev/null | awk '/UserShell:/ {print $2}'
  else
    grep "^$CURRENT_USER:" /etc/passwd 2>/dev/null | cut -d: -f7
  fi
}

ensure_shell_registered() {
  local shell_path="${1:-}"
  if [ -z "$shell_path" ]; then
    return 1
  fi

  if grep -Fxq "$shell_path" /etc/shells 2>/dev/null; then
    return 0
  fi

  echo "将 $shell_path 写入 /etc/shells..."
  if run_with_privilege sh -c "echo '$shell_path' >> /etc/shells" 2>/dev/null; then
    echo "/etc/shells 已更新。"
    return 0
  fi

  echo "警告：无法写入 /etc/shells，请手动添加 ${shell_path}。"
  return 0
}

change_default_shell() {
  local shell_path="${1:-}"
  local current_shell="${2:-}"

  if [ -n "$current_shell" ] && [ "$current_shell" = "$shell_path" ]; then
    echo "默认 shell 已是 ${shell_path}。"
    return 0
  fi

  if [ -n "$current_shell" ]; then
    echo "将默认 shell 从 $current_shell 切换为 $shell_path..."
  else
    echo "将默认 shell 切换为 $shell_path..."
  fi
  if [ "$(id -u)" -eq 0 ]; then
    if chsh -s "$shell_path" "$CURRENT_USER"; then
      echo "默认 shell 已更新为 ${shell_path}。"
      return 0
    fi
  else
    if chsh -s "$shell_path"; then
      echo "默认 shell 已更新为 ${shell_path}。"
      return 0
    fi
  fi

  if command -v sudo >/dev/null 2>&1; then
    if sudo chsh -s "$shell_path" "$CURRENT_USER"; then
      echo "默认 shell 已更新为 ${shell_path}。"
      return 0
    fi
  fi

  echo "警告：自动切换默认 shell 失败，请手动执行：chsh -s $shell_path $CURRENT_USER"
  return 1
}

ensure_autojump() {
  if command -v autojump >/dev/null 2>&1; then
    echo "autojump 已安装。"
    return 0
  fi

  echo "未检测到 autojump，尝试自动安装..."
  if install_package autojump autojump; then
    if command -v autojump >/dev/null 2>&1; then
      echo "autojump 安装完成。"
      return 0
    fi
  fi

  echo "警告：自动安装 autojump 失败，将跳过 autojump 配置。"
  echo "您可以稍后手动安装：https://github.com/wting/autojump"
  return 1
}

# 确保下载工具可用（curl 或 wget）
if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
  echo "未检测到 curl 或 wget，尝试自动安装 curl..."
  if ! install_package curl curl; then
    echo "警告：无法自动安装下载工具，后续安装 Oh My Zsh 可能失败。"
  fi
fi

# 确保 git 可用
if ! command -v git >/dev/null 2>&1; then
  echo "未检测到 git，尝试自动安装..."
  if ! install_package git git; then
    echo "错误：git 未安装，脚本无法继续。"
    exit 1
  fi
fi

# 安装或确认 zsh
if ! command -v zsh >/dev/null 2>&1; then
  echo "未检测到 zsh，尝试自动安装..."
  if ! install_package zsh zsh; then
    echo "错误：无法自动安装 zsh，请手动安装后重试。"
    exit 1
  fi
fi
hash -r
ZSH_BIN=$(command -v zsh)
echo "已检测到 zsh 可执行文件：$ZSH_BIN"

ensure_shell_registered "$ZSH_BIN"

CURRENT_LOGIN_SHELL=$(get_current_shell || echo "")
change_default_shell "$ZSH_BIN" "$CURRENT_LOGIN_SHELL"

# 安装 Oh My Zsh
if [ ! -d "$OH_MY_ZSH_DIR" ]; then
  echo "未检测到 Oh My Zsh，尝试自动安装..."
  INSTALL_SCRIPT_URL="https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh"
  if command -v curl >/dev/null 2>&1; then
    if ! run_as_target_user "set -e; export RUNZSH=no CHSH=no KEEP_ZSHRC=yes; curl -fsSL '$INSTALL_SCRIPT_URL' | sh"; then
      echo "错误：Oh My Zsh 安装失败，请检查网络或手动安装。"
      exit 1
    fi
  elif command -v wget >/dev/null 2>&1; then
    if ! run_as_target_user "set -e; export RUNZSH=no CHSH=no KEEP_ZSHRC=yes; wget -qO- '$INSTALL_SCRIPT_URL' | sh"; then
      echo "错误：Oh My Zsh 安装失败，请检查网络或手动安装。"
      exit 1
    fi
  else
    echo "错误：缺少 curl 或 wget，无法自动安装 Oh My Zsh。"
    exit 1
  fi
else
  echo "Oh My Zsh 已安装。"
fi

# 确保 .zshrc 存在并备份
if [ -f "$ZSHRC" ]; then
  BACKUP_FILE="$ZSHRC.$(date +%Y%m%d%H%M%S).bak"
  cp "$ZSHRC" "$BACKUP_FILE"
  if [ "$(id -u)" -eq 0 ]; then
    chown "$CURRENT_USER":"$TARGET_GROUP" "$BACKUP_FILE"
  fi
  echo "已备份 $ZSHRC 到 $BACKUP_FILE"
else
  echo "未找到 ${ZSHRC}，创建默认文件..."
  touch "$ZSHRC"
fi

# 确保插件目录
if [ ! -d "$PLUGIN_DIR" ]; then
  echo "创建插件目录：$PLUGIN_DIR"
  run_as_target_user "mkdir -p '$PLUGIN_DIR'"
fi

# 安装插件并收集失败信息
FAILED_PLUGINS=""

if ! install_plugin_repo "zsh-autosuggestions" "https://github.com/zsh-users/zsh-autosuggestions.git"; then
  FAILED_PLUGINS="$FAILED_PLUGINS zsh-autosuggestions"
fi

if ! install_plugin_repo "zsh-syntax-highlighting" "https://github.com/zsh-users/zsh-syntax-highlighting.git"; then
  FAILED_PLUGINS="$FAILED_PLUGINS zsh-syntax-highlighting"
fi

if ! install_plugin_repo "zsh-history-substring-search" "https://github.com/zsh-users/zsh-history-substring-search.git"; then
  FAILED_PLUGINS="$FAILED_PLUGINS zsh-history-substring-search"
fi

AUTOJUMP_INSTALLED=0
if ensure_autojump; then
  AUTOJUMP_INSTALLED=1
fi

# 更新 plugins 和主题配置
if grep -q '^plugins=' "$ZSHRC"; then
  perl -0pi -e "s/^plugins=.*/plugins=($PLUGINS_STRING)/m" "$ZSHRC"
else
  printf '\nplugins=(%s)\n' "$PLUGINS_STRING" >> "$ZSHRC"
fi

if grep -q '^ZSH_THEME=' "$ZSHRC"; then
  perl -0pi -e "s/^ZSH_THEME=.*/ZSH_THEME=\"$ZSH_THEME\"/m" "$ZSHRC"
else
  printf '\nZSH_THEME="%s"\n' "$ZSH_THEME" >> "$ZSHRC"
fi

# 清理旧的键绑定并写入最新配置
perl -0pi -e 's/^.*history-substring-search-up.*\n//mg' "$ZSHRC"
perl -0pi -e 's/^.*history-substring-search-down.*\n//mg' "$ZSHRC"

AUTOJUMP_BLOCK=$(cat <<'EOF'
# autojump 配置
[[ -s $HOME/.autojump/etc/profile.d/autojump.sh ]] && source $HOME/.autojump/etc/profile.d/autojump.sh
if [ -f /usr/share/autojump/autojump.sh ]; then
  source /usr/share/autojump/autojump.sh
elif [ -f /usr/local/share/autojump/autojump.sh ]; then
  source /usr/local/share/autojump/autojump.sh
elif [ -f /opt/homebrew/etc/profile.d/autojump.sh ]; then
  source /opt/homebrew/etc/profile.d/autojump.sh
elif [ -f /usr/local/etc/profile.d/autojump.sh ]; then
  source /usr/local/etc/profile.d/autojump.sh
fi
EOF
)

HISTORY_BLOCK=$(cat <<'EOF'
# zsh-history-substring-search 快捷键绑定（使用 terminfo）
bindkey "${terminfo[kcuu1]}" history-substring-search-up
bindkey "${terminfo[kcud1]}" history-substring-search-down
EOF
)

append_block_if_missing "$ZSHRC" "autojump 配置" "$AUTOJUMP_BLOCK"
append_block_if_missing "$ZSHRC" "history-substring-search 快捷键绑定" "$HISTORY_BLOCK"

if [ "$(id -u)" -eq 0 ]; then
  chown "$CURRENT_USER":"$TARGET_GROUP" "$ZSHRC"
  if [ -d "$OH_MY_ZSH_CUSTOM" ]; then
    chown -R "$CURRENT_USER":"$TARGET_GROUP" "$OH_MY_ZSH_CUSTOM"
  fi
fi

echo "验证 plugins 配置..."
if grep -q "plugins=($PLUGINS_STRING)" "$ZSHRC"; then
  echo "plugins 配置已更新：$PLUGINS_STRING"
else
  echo "警告：plugins 配置未成功写入，请手动检查 ${ZSHRC}。"
fi

echo "验证 ZSH_THEME 配置..."
if grep -q "ZSH_THEME=\"$ZSH_THEME\"" "$ZSHRC"; then
  echo "ZSH_THEME 已设置为 $ZSH_THEME"
else
  echo "警告：ZSH_THEME 配置未成功写入，请手动检查 ${ZSHRC}。"
fi

echo "验证 zsh-history-substring-search 键绑定..."
if grep -q 'bindkey "${terminfo\[kcuu1\]}" history-substring-search-up' "$ZSHRC" && \
   grep -q 'bindkey "${terminfo\[kcud1\]}" history-substring-search-down' "$ZSHRC"; then
  echo "键绑定已设置为 terminfo[kcuu1] / terminfo[kcud1]"
else
  echo "警告：键绑定未成功写入，请手动检查 ${ZSHRC}。"
fi

if [ -n "${TERM:-}" ]; then
  echo "当前 TERM 变量：$TERM"
else
  echo "当前未检测到 TERM 变量。"
fi
echo "建议使用 TERM=xterm-256color，可在 $ZSHRC 中添加：export TERM=xterm-256color"

echo ""
echo "========================================"
echo "           安装报告"
echo "========================================"
echo ""

# 核心组件
echo "✓ Zsh: 已安装并配置"
echo "✓ Oh My Zsh: 已安装"
echo "✓ 主题: $ZSH_THEME"

# 插件状态
echo ""
echo "插件状态："
if [ -z "$FAILED_PLUGINS" ]; then
  echo "  ✓ zsh-autosuggestions"
  echo "  ✓ zsh-syntax-highlighting"
  echo "  ✓ zsh-history-substring-search"
else
  [ -z "${FAILED_PLUGINS##* zsh-autosuggestions*}" ] && echo "  ✗ zsh-autosuggestions (安装失败)" || echo "  ✓ zsh-autosuggestions"
  [ -z "${FAILED_PLUGINS##* zsh-syntax-highlighting*}" ] && echo "  ✗ zsh-syntax-highlighting (安装失败)" || echo "  ✓ zsh-syntax-highlighting"
  [ -z "${FAILED_PLUGINS##* zsh-history-substring-search*}" ] && echo "  ✗ zsh-history-substring-search (安装失败)" || echo "  ✓ zsh-history-substring-search"
fi

if [ "$AUTOJUMP_INSTALLED" -eq 1 ]; then
  echo "  ✓ autojump"
else
  echo "  ✗ autojump (安装失败或未安装)"
fi

# 失败项处理建议
if [ -n "$FAILED_PLUGINS" ] || [ "$AUTOJUMP_INSTALLED" -eq 0 ]; then
  echo ""
  echo "失败项手动安装建议："
  if [ -n "$FAILED_PLUGINS" ]; then
    for plugin in $FAILED_PLUGINS; do
      case "$plugin" in
        zsh-autosuggestions)
          echo "  - zsh-autosuggestions: git clone https://github.com/zsh-users/zsh-autosuggestions.git $PLUGIN_DIR/zsh-autosuggestions"
          ;;
        zsh-syntax-highlighting)
          echo "  - zsh-syntax-highlighting: git clone https://github.com/zsh-users/zsh-syntax-highlighting.git $PLUGIN_DIR/zsh-syntax-highlighting"
          ;;
        zsh-history-substring-search)
          echo "  - zsh-history-substring-search: git clone https://github.com/zsh-users/zsh-history-substring-search.git $PLUGIN_DIR/zsh-history-substring-search"
          ;;
      esac
    done
  fi
  if [ "$AUTOJUMP_INSTALLED" -eq 0 ]; then
    echo "  - autojump: 访问 https://github.com/wting/autojump 查看安装说明"
  fi
fi

echo ""
echo "========================================"
echo "配置完成！请执行以下命令应用更改："
echo "  source $ZSHRC"
echo "或重新打开终端。"
echo "========================================"


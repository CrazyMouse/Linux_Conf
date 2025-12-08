#!/usr/bin/env bash
set -euo pipefail

#############################################
# 参数说明：
#   $1 = DB 文件路径（为空字符串表示全新安装）
#   $2 = 老域名（为空字符串表示全新安装）
#   $3 = 新域名（必填，用于证书和替换）
#
# 用法示例：
#   全新安装：
#     ./s-ui-install-or-migrate.sh "" "" new.example.com
#
#   从旧 DB 迁移并更换域名：
#     ./s-ui-install-or-migrate.sh /root/s-ui-old.db old.example.com new.example.com
#############################################

if [[ $EUID -ne 0 ]]; then
  echo "!! 请使用 root 运行本脚本"
  exit 1
fi

if [[ $# -lt 3 ]]; then
  echo "用法：$0 <db_path_or_empty> <old_domain_or_empty> <new_domain>"
  echo "示例："
  echo "  全新安装：$0 \"\" \"\" new.example.com"
  echo "  迁移安装：$0 /root/s-ui-old.db old.example.com new.example.com"
  exit 1
fi

DB_PATH="$1"
OLD_DOMAIN="$2"
NEW_DOMAIN="$3"

if [[ -z "$NEW_DOMAIN" ]]; then
  echo "!! new_domain 不能为空"
  exit 1
fi

echo "==> 参数检查"
echo "    DB 路径：${DB_PATH:-<空>}"
echo "    老域名：${OLD_DOMAIN:-<空>}"
echo "    新域名：$NEW_DOMAIN"
echo

SUI_DIR="/usr/local/s-ui"
SUI_DB="$SUI_DIR/db/s-ui.db"

#############################################
# 函数：自动安装 sqlite3（如未安装）
#############################################
install_sqlite_if_needed() {
  if command -v sqlite3 >/dev/null 2>&1; then
    echo "==> sqlite3 已安装"
    return
  fi

  echo "==> 未检测到 sqlite3，准备自动安装"

  if command -v apt >/dev/null 2>&1; then
    apt update
    apt install -y sqlite3
  else
    echo "!! 当前系统不是 Debian/Ubuntu，无法自动安装 sqlite3"
    echo "   请手动安装 sqlite3 后重试"
    exit 1
  fi

  if ! command -v sqlite3 >/dev/null 2>&1; then
    echo "!! sqlite3 安装失败，请检查网络或包管理器"
    exit 1
  fi
}

#############################################
# 函数：安装 S-UI（如果未安装）
#############################################
install_sui_if_needed() {
  if [[ ! -d "$SUI_DIR" ]]; then
    echo "==> 未检测到 S-UI，开始用官方脚本安装"
    bash <(curl -Ls https://raw.githubusercontent.com/alireza0/s-ui/master/install.sh)
  else
    echo "==> 已检测到 S-UI 安装目录：$SUI_DIR"
  fi

  if ! command -v s-ui >/dev/null 2>&1; then
    echo "!! 未找到 s-ui 命令，请确认安装脚本执行成功，且 /usr/bin 在 PATH 中"
    exit 1
  fi
}

#############################################
# 函数：安装 acme.sh + socat + 签证书 / 安装证书
# 逻辑：
#   1. 如果 acme.sh 中已经存在该域名目录 -> 跳过 --issue，只执行 --installcert
#   2. 否则：先 --issue 再 --installcert
#   3. 续期/安装完成后执行：s-ui restart
#############################################
setup_acme_and_cert() {
  local domain="$1"
  local cert_dir="/root/cert/$domain"
  local acme_home="/root/.acme.sh"
  local acme_domain_dir="$acme_home/$domain"
  local acme_domain_ecc_dir="${acme_domain_dir}_ecc"

  echo "==> 检查 acme.sh"
  if [[ ! -d "$acme_home" ]]; then
    curl https://get.acme.sh | sh
  else
    echo "    已存在 acme.sh"
  fi

  echo "==> 检查 socat"
  if ! command -v socat >/dev/null 2>&1; then
    if command -v apt >/dev/null 2>&1; then
      apt update
      apt install -y socat
    else
      echo "!! 当前系统不是 Debian/Ubuntu，无法自动安装 socat"
      echo "   请手动安装 socat 后重试"
      exit 1
    fi
  else
    echo "    已检测到 socat"
  fi

  echo "==> 设置 CA = Let's Encrypt"
  "$acme_home/acme.sh" --set-default-ca --server letsencrypt

  # 判断是否已经存在该域名的证书目录
  local has_existing_cert="false"
  if [[ -d "$acme_domain_dir" || -d "$acme_domain_ecc_dir" ]]; then
    has_existing_cert="true"
    echo "==> 检测到 acme.sh 中已有 $domain 的证书目录，跳过重新签发，只做安装"
  fi

  if [[ "$has_existing_cert" == "false" ]]; then
    echo
    echo "==> 为域名申请证书：$domain"
    echo "    请确保："
    echo "      1) $domain 已解析到本机 IP"
    echo "      2) 80 端口未被其他服务占用（nginx/caddy/apache 等）"
    echo

    "$acme_home/acme.sh" --issue -d "$domain" --standalone --httpport 80
  else
    echo "==> 跳过 acme.sh --issue 步骤（已有证书）"
  fi

  echo "==> 安装证书到：$cert_dir"
  mkdir -p "$cert_dir"

  "$acme_home/acme.sh" --installcert -d "$domain" \
    --key-file "$cert_dir/privkey.pem" \
    --fullchain-file "$cert_dir/fullchain.pem" \
    --reloadcmd "s-ui restart >/dev/null 2>&1 || true"

  echo
  echo "✔ 证书已安装 / 更新："
  echo "  fullchain.pem：$cert_dir/fullchain.pem"
  echo "  privkey.pem  ：$cert_dir/privkey.pem"
  echo "  续期/安装后会自动执行：s-ui restart"
  echo
}

#############################################
# 函数：迁移 DB + 全库替换域名
#############################################
migrate_db_and_replace_domain() {
  local src_db="$1"
  local old_domain="$2"
  local new_domain="$3"

  if [[ ! -f "$src_db" ]]; then
    echo "!! 指定的 DB 文件不存在：$src_db"
    exit 1
  fi

  echo "==> 尝试停止 S-UI（如果正在运行）"
  if command -v s-ui >/dev/null 2>&1; then
    s-ui stop >/dev/null 2>&1 || true
  fi

  mkdir -p "$(dirname "$SUI_DB")"

  if [[ -f "$SUI_DB" ]]; then
    echo "==> 备份当前 S-UI 数据库：$SUI_DB"
    cp "$SUI_DB" "${SUI_DB}.bak.$(date +%Y%m%d-%H%M%S)" || true
  fi

  echo "==> 覆盖 DB 到：$SUI_DB"
  cp "$src_db" "$SUI_DB"

  echo "==> 开始执行 dump → 全局替换域名 → 重建数据库"

  install_sqlite_if_needed

  local tmp_dir
  tmp_dir="$(mktemp -d)"
  local dump_sql="$tmp_dir/s-ui.dump.sql"
  local new_dump_sql="$tmp_dir/s-ui.dump.new.sql"

  echo "==> 导出原 DB 为 SQL：$dump_sql"
  sqlite3 "$SUI_DB" .dump > "$dump_sql"

  if command -v perl >/dev/null 2>&1; then
    echo "==> 使用 perl 安全替换域名（\\Q...\\E 避免正则误伤）"
    perl -pe "s/\Q$old_domain\E/$new_domain/g" "$dump_sql" > "$new_dump_sql"
  else
    echo "!! 未检测到 perl，将使用 sed 替换（如域名中含有正则特殊字符可能有风险）"
    sed "s|$old_domain|$new_domain|g" "$dump_sql" > "$new_dump_sql"
  fi

  echo "==> 备份替换前的 DB：$SUI_DB"
  cp "$SUI_DB" "${SUI_DB}.before_replace.$(date +%Y%m%d-%H%M%S)" || true

  echo "==> 删除原 DB 并用新 SQL 重建"
  rm -f "$SUI_DB"
  sqlite3 "$SUI_DB" < "$new_dump_sql"

  rm -rf "$tmp_dir"

  echo "✔ DB 全局域名替换完成：$old_domain -> $new_domain"
}

#############################################
# 主流程
#############################################
install_sui_if_needed

if [[ -z "$DB_PATH" && -z "$OLD_DOMAIN" ]]; then
  echo "==> 模式：全新安装"
  setup_acme_and_cert "$NEW_DOMAIN"
else
  echo "==> 模式：迁移 + 域名替换"
  if [[ -z "$DB_PATH" || -z "$OLD_DOMAIN" ]]; then
    echo "!! 迁移模式下，DB_PATH 和 OLD_DOMAIN 都不能为空"
    exit 1
  fi

  migrate_db_and_replace_domain "$DB_PATH" "$OLD_DOMAIN" "$NEW_DOMAIN"
  setup_acme_and_cert "$NEW_DOMAIN"
fi

echo "==> 重启 S-UI 使配置与证书生效"
s-ui restart >/dev/null 2>&1 || true

echo
echo "=== 完成 ==="
echo "域名：$NEW_DOMAIN"
echo "证书路径：/root/cert/$NEW_DOMAIN/fullchain.pem"
echo "私钥路径：/root/cert/$NEW_DOMAIN/privkey.pem"
echo
echo "说明："
echo "  - 如果之前 acme.sh 已经签过 $NEW_DOMAIN，但 /root/cert/$NEW_DOMAIN 里没有文件，"
echo "    脚本会跳过重新签发，直接从 acme.sh 安装证书到该目录。"
echo "  - 之后 acme.sh 续期时会自动执行：s-ui restart"
echo "  - 你只需要在 S-UI 面板里确认域名和证书路径即可。"


#!/bin/bash

# WordPress 安装清理脚本
# 用于回滚 wordpress-setup.sh 做过的全部改动，便于干净地重新安装。

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

log() { echo -e "${GREEN}[INFO]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

if [ "$EUID" -ne 0 ]; then
    error "此脚本必须以管理员权限运行，请使用 sudo。"
fi

FULL=0
if [ "$1" = "--full" ]; then
    FULL=1
fi

echo -e "${YELLOW}即将执行以下清理操作:${NC}"
echo "  1) 删除 WordPress 站点目录 /var/www/wordpress"
echo "  2) 删除 Nginx 站点配置 wordpress，并恢复默认站点"
echo "  3) 彻底卸载并重装 MariaDB（会清空所有数据库数据）"
echo "  4) 删除 wp-setup-config.conf 与 wp-setup-*.log"
if [ "$FULL" = 1 ]; then
    echo "  5) 同时卸载并重装 Nginx 与 PHP 8.2（--full 模式）"
fi
echo ""
read -p "确认请输入 yes (其它任意输入将取消): " confirm
if [ "$confirm" != "yes" ]; then
    echo "已取消，未做任何改动。"
    exit 0
fi

# 停止 Nginx
log "正在停止 Nginx..."
systemctl stop nginx 2>/dev/null

# 删除 WordPress 站点文件
log "正在删除 WordPress 站点文件..."
rm -rf /var/www/wordpress

# 清理 Nginx 配置
log "正在清理 Nginx 站点配置..."
rm -f /etc/nginx/sites-enabled/wordpress /etc/nginx/sites-available/wordpress
if [ -f /etc/nginx/sites-available/default ] && [ ! -e /etc/nginx/sites-enabled/default ]; then
    ln -s /etc/nginx/sites-available/default /etc/nginx/sites-enabled/default
    log "已恢复 Nginx 默认站点。"
fi

# 彻底重装 MariaDB，恢复 root 为 unix_socket 免密认证
log "正在彻底重装 MariaDB..."
systemctl stop mariadb 2>/dev/null
apt purge -y mariadb-server mariadb-client mariadb-common
rm -rf /var/lib/mysql /etc/mysql
apt-get autoremove -y
apt-get install -y mariadb-server mariadb-client || error "MariaDB 重装失败"
systemctl enable --now mariadb
sleep 5
mysql -e "SELECT VERSION(); SHOW DATABASES;" || error "重装后仍无法连接 MariaDB，请检查服务状态"
log "MariaDB 已恢复初始状态（root 使用 socket 认证，免密登录）。"

# 可选：重装 Nginx 与 PHP
if [ "$FULL" = 1 ]; then
    log "正在重装 Nginx 与 PHP 8.2..."
    systemctl stop php8.2-fpm 2>/dev/null
    apt purge -y 'php8.2*' nginx nginx-common
    rm -rf /etc/php /etc/nginx
    apt-get autoremove -y
    apt-get install -y nginx php8.2-fpm php8.2-mysql php8.2-curl php8.2-gd php8.2-mbstring php8.2-xml php8.2-xmlrpc php8.2-soap php8.2-intl php8.2-zip || error "Nginx/PHP 重装失败"
    log "Nginx 与 PHP 8.2 已重装。"
fi

# 清理脚本生成的配置与日志
log "正在清理安装配置与日志..."
rm -f ./wp-setup-config.conf ~/wordpress/wp-setup-config.conf ~/wp-setup-config.conf
rm -f ./wp-setup-*.log ~/wordpress/wp-setup-*.log ~/wp-setup-*.log

# 恢复服务
log "正在恢复服务..."
nginx -t && systemctl start nginx
systemctl reload php8.2-fpm 2>/dev/null || true

systemctl status nginx mariadb --no-pager

echo ""
echo -e "${GREEN}清理完成。${NC}"
echo "现在可以重新运行安装脚本:"
echo "  sudo bash wordpress-setup.sh"
echo ""
echo -e "${YELLOW}提示：数据库密码请只使用字母和数字${NC}"
echo "（例如 Ndc2026wp），不要包含 & / \$ ! \\ 等特殊字符。"

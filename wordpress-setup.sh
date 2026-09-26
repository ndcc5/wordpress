#!/bin/bash

# WordPress 自动安装脚本
# 用于在 Oracle VM 上快速安装 WordPress 的脚本。

# 非交互模式：避免 apt/needrestart 弹出对话框中断安装
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 日志函数
log() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1"
    exit 1
}

# 用户输入函数
get_input() {
    local prompt="$1"
    local default="$2"
    local result

    if [ -n "$default" ]; then
        read -p "$prompt [$default]: " result
        result=${result:-$default}
    else
        read -p "$prompt: " result
    fi

    echo "$result"
}

get_password() {
    local prompt="$1"
    local password
    local confirm_password
    
    while true; do
        read -s -p "$prompt: " password
        echo
        read -s -p "请再次输入密码: " confirm_password
        echo
        
        if [ "$password" = "$confirm_password" ]; then
            break
        else
            warn "两次输入的密码不一致，请重新输入。"
        fi
    done
    
    echo "$password"
}

# 加载已保存的配置文件
load_config() {
    local config_file="$1"
    if [ -f "$config_file" ]; then
        log "正在加载配置文件: $config_file"
        source "$config_file"
        return 0
    else
        return 1
    fi
}

# 保存配置文件
save_config() {
    local config_file="$1"
    
    cat > "$config_file" << EOF
# WordPress 安装配置文件
# 生成日期: $(date)

# 域名设置
domain="$domain"

# 数据库设置
db_name="$db_name"
db_user="$db_user"
db_password="$db_password"

# DDNS 设置
use_ddns="$use_ddns"
ddns_provider="$ddns_provider"
ddns_login="$ddns_login"
ddns_password="$ddns_password"
ddns_domain="$ddns_domain"
EOF

    chmod 600 "$config_file"
    log "配置已保存到文件: $config_file"
}

# 检查管理员权限
if [ "$EUID" -ne 0 ]; then
    error "此脚本必须以管理员权限运行，请使用 sudo。"
fi

clear
echo -e "${BLUE}==============================================${NC}"
echo -e "${BLUE}       WordPress 自动安装脚本         ${NC}"
echo -e "${BLUE}==============================================${NC}"
echo ""
echo "此脚本将在 Ubuntu 服务器上自动安装 WordPress。"
echo ""

# 选择或创建配置文件
config_file="wp-setup-config.conf"
if [ "$1" ]; then
    config_file="$1"
fi

if load_config "$config_file"; then
    echo -e "已加载以下配置:"
    echo "域名: $domain"
    echo "数据库名称: $db_name"
    echo "数据库用户: $db_user"
    echo "是否使用 DDNS: $use_ddns"
    
    use_loaded_config=$(get_input "是否使用这些配置? (y/n)" "y")
    if [ "$use_loaded_config" != "y" ] && [ "$use_loaded_config" != "Y" ]; then
        # 用户选择不使用已有配置，改为输入新配置
        config_loaded=false
    else
        config_loaded=true
    fi
else
    echo "配置文件不存在或无法读取，请输入新的配置。"
    config_loaded=false
fi

# 需要输入新配置的情况
if [ "$config_loaded" = false ]; then
    # 收集基本信息
    domain=$(get_input "请输入域名 (例如: example.com)" "example.com")
    db_name=$(get_input "数据库名称" "wordpress")
    db_user=$(get_input "数据库用户名" "wordpress")
    db_password=$(get_password "数据库密码")

    # 是否使用 DDNS
    use_ddns=$(get_input "是否使用 DDNS? (y/n)" "n")

    if [ "$use_ddns" = "y" ] || [ "$use_ddns" = "Y" ]; then
        ddns_provider=$(get_input "DDNS 服务商 (cloudflare)" "cloudflare")
        ddns_login=$(get_input "DDNS 登录邮箱 (Cloudflare 邮箱)")
        ddns_password=$(get_password "DDNS API 令牌/密码")
        ddns_domain=$(get_input "要更新的 DDNS 域名" "$domain")
    fi

    # 确认是否保存配置
    save_settings=$(get_input "是否将这些配置保存到文件? (y/n)" "y")
    if [ "$save_settings" = "y" ] || [ "$save_settings" = "Y" ]; then
        save_config "$config_file"
    fi
fi

echo ""
log "开始安装..."
sleep 1

# 系统更新
log "正在更新系统..."

# 尝试禁用不可达的第三方源（例如 deb.nodesource.com，本脚本并不需要 Node.js）
disable_node_source() {
    rm -f /etc/apt/sources.list.d/nodesource.list /etc/apt/sources.list.d/nodesource.sources
    sed -i '/deb\.nodesource\.com/d' /etc/apt/sources.list
    log "已移除 NodeSource 软件源。"
}

if ! apt update -y; then
    warn "apt update 失败，3 秒后重试一次..."
    sleep 3
    if ! apt update -y; then
        warn "仍然失败，常见原因是第三方软件源不可达（如 deb.nodesource.com）。"
        drop_src=$(get_input "是否禁用 NodeSource 源并继续? (安装 WordPress 不需要 Node.js) (y/n)" "y")
        if [ "$drop_src" = "y" ] || [ "$drop_src" = "Y" ]; then
            disable_node_source
            apt update -y || error "apt update 仍然失败，请手动检查 /etc/apt/sources.list.d/ 下的软件源"
        else
            error "请修复软件源后重新运行本脚本。"
        fi
    fi
fi

if ! apt upgrade -y; then
    warn "部分软件包升级失败（通常是第三方源不可达，例如 deb.nodesource.com）。"
    cont=$(get_input "是否忽略升级错误，继续安装 WordPress? (y/n)" "y")
    if [ "$cont" = "y" ] || [ "$cont" = "Y" ]; then
        warn "已跳过系统升级，继续执行安装。"
    else
        error "已中止安装。请修复软件源后重新运行本脚本。"
    fi
fi

# 设置时区
log "正在设置时区..."
timedatectl set-timezone Asia/Seoul
timedatectl status | grep "Time zone"

# 防火墙设置
log "正在配置防火墙..."
ufw allow 22/tcp
ufw allow 80/tcp
ufw allow 443/tcp
ufw --force enable
ufw status

# 设置交换内存
log "正在设置交换内存..."
if [ ! -f /swapfile ]; then
    fallocate -l 4G /swapfile
    chmod 600 /swapfile
    mkswap /swapfile
    swapon /swapfile
    echo "/swapfile none swap sw 0 0" >> /etc/fstab
    swapon --show
    free -h
else
    warn "交换文件已存在，跳过。"
fi

# 安装必要的软件包
log "正在安装必要的软件包..."
apt install -y mariadb-server mariadb-client nginx software-properties-common || error "软件包安装失败"

# 安装 PHP 8.2
log "正在安装 PHP 8.2..."
add-apt-repository ppa:ondrej/php -y
apt update
apt install -y php8.2-fpm php8.2-mysql php8.2-curl php8.2-gd php8.2-mbstring php8.2-xml php8.2-xmlrpc php8.2-soap php8.2-intl php8.2-zip || error "PHP 安装失败"

# PHP 配置
log "正在修改 PHP 配置..."
php_ini="/etc/php/8.2/fpm/php.ini"
sed -i '0,/short_open_tag = Off/{s/short_open_tag = Off/short_open_tag = On/}' $php_ini
sed -i 's/memory_limit = .*/memory_limit = 2048M/g' $php_ini
sed -i 's/;cgi.fix_pathinfo=1/cgi.fix_pathinfo=0/g' $php_ini
sed -i 's/upload_max_filesize = .*/upload_max_filesize = 100M/g' $php_ini
sed -i 's/post_max_size = .*/post_max_size = 101M/g' $php_ini
sed -i 's/max_execution_time = .*/max_execution_time = 360/g' $php_ini
sed -i 's/;date.timezone.*/date.timezone = Asia\/Seoul/g' $php_ini

systemctl reload php8.2-fpm

# DDNS 设置（可选）
if [ "$use_ddns" = "y" ] || [ "$use_ddns" = "Y" ]; then
    log "正在安装并配置 ddclient..."
    apt install -y ddclient
    
    # Cloudflare 配置
    if [ "$ddns_provider" = "cloudflare" ]; then
        cat > /etc/ddclient.conf << EOF
daemon=300
syslog=yes
ssl=yes
use=web

protocol=cloudflare
zone=$ddns_domain
login=$ddns_login
password=$ddns_password
$ddns_domain
EOF
    fi
    
    systemctl restart ddclient
    systemctl enable ddclient
    log "ddclient 配置完成，请在 Cloudflare 中检查 DNS 记录。"
fi

# MariaDB 安全设置
log "正在进行 MariaDB 安全设置..."
mysql --user=root <<EOF
ALTER USER 'root'@'localhost' IDENTIFIED BY '$db_password';
DELETE FROM mysql.user WHERE User='';
DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost', '127.0.0.1', '::1');
DROP DATABASE IF EXISTS test;
DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';
FLUSH PRIVILEGES;
EOF

# 创建数据库和用户
log "正在创建 WordPress 数据库..."
mysql --user=root --password="$db_password" <<EOF
CREATE DATABASE $db_name DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER '$db_user'@'localhost' IDENTIFIED BY '$db_password';
GRANT ALL ON $db_name.* TO '$db_user'@'localhost';
FLUSH PRIVILEGES;
EOF

# 下载并安装 WordPress
log "正在下载并安装 WordPress..."
cd /tmp
wget https://wordpress.org/latest.tar.gz
tar -xvzf latest.tar.gz
rm -rf /var/www/wordpress
mv wordpress /var/www/wordpress

# 权限设置
chown -R www-data:www-data /var/www/wordpress/
chmod -R 755 /var/www/wordpress/

# 生成 wp-config.php
log "正在生成 WordPress 配置文件..."
cp /var/www/wordpress/wp-config-sample.php /var/www/wordpress/wp-config.php
sed -i "s/database_name_here/$db_name/g" /var/www/wordpress/wp-config.php
sed -i "s/username_here/$db_user/g" /var/www/wordpress/wp-config.php
sed -i "s/password_here/$db_password/g" /var/www/wordpress/wp-config.php

# 生成安全密钥
log "正在生成安全密钥..."
KEYS=$(curl -s https://api.wordpress.org/secret-key/1.1/salt/)
KEYS=$(echo "$KEYS" | sed "s/[\']/\\\'/g")
sed -i "/define( 'AUTH_KEY'/,/define( 'NONCE_SALT'/ { d; }" /var/www/wordpress/wp-config.php
echo "$KEYS" >> /var/www/wordpress/wp-config.php

# 添加内存限制
echo "define('WP_MEMORY_LIMIT', '1024M');" >> /var/www/wordpress/wp-config.php

# 配置 Nginx
log "正在配置 Nginx..."
cat > /etc/nginx/sites-available/wordpress << EOF
server {
    listen 80;
    listen [::]:80;
    server_name $domain www.$domain;

    root /var/www/wordpress;

    index index.php;

    location ~ \.(gif|jpg|png)$ {
        add_header Vary "Accept-Encoding";
        add_header Cache-Control "public, no-transform, max-age=31536000";
    }
    location ~* \.(css|js)$ {
        add_header Cache-Control "public, max-age=604800";
        log_not_found off;
        access_log off;
    }
    location ~*.(mp4|ogg|ogv|svg|svgz|eot|otf|woff|woff2|ttf|rss|atom|ico|zip|tgz|gz|rar|bz2|doc|xls|exe|ppt|tar|mid|midi|wav|bmp|rtf|cur)$ {
        add_header Cache-Control "max-age=31536000";
        access_log off;
    }
    charset utf-8;
    server_tokens off;
    client_max_body_size 100M;
    
    # 添加 REST API 支持
    location /wp-json/ {
        try_files \$uri \$uri/ /index.php?\$args;
    }
    
    # WordPress 默认设置
    location / {
        try_files \$uri \$uri/ /index.php?\$args;
    }
    
    location ~ /\.ht {
        deny all;
    }
    
    location ~ \.php$ {
         include snippets/fastcgi-php.conf;
         fastcgi_pass unix:/run/php/php8.2-fpm.sock;
         fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
         include fastcgi_params;
    }
}
EOF

ln -s /etc/nginx/sites-available/wordpress /etc/nginx/sites-enabled/
rm -f /etc/nginx/sites-enabled/default
nginx -t && systemctl restart nginx

# 安装 Certbot
log "正在安装 Certbot..."
apt install -y python3-certbot-nginx

log "安装完成！"
echo ""
echo -e "${BLUE}==============================================${NC}"
echo -e "${GREEN}WordPress 安装摘要${NC}"
echo -e "${BLUE}==============================================${NC}"
echo "域名: $domain"
echo "数据库名称: $db_name"
echo "数据库用户: $db_user"
echo "WordPress 目录: /var/www/wordpress"
echo ""
echo "后续步骤:"
echo "1. DNS 设置完成后，请使用以下命令安装 SSL 证书:"
echo "   sudo certbot --nginx -d $domain -d www.$domain"
echo ""
echo "2. 在浏览器中访问 http://$domain 完成 WordPress 设置。"
echo -e "${BLUE}==============================================${NC}"

if [ "$use_ddns" = "y" ] || [ "$use_ddns" = "Y" ]; then
    echo ""
    echo -e "${YELLOW}DDNS 注意事项:${NC}"
    echo "如果使用 Cloudflare，请在签发 SSL 证书前将 DNS 记录设置为仅 DNS 模式（灰色云朵）。"
    echo "证书签发后，可按需改回代理模式（橙色云朵）。"
    echo ""
fi

# 保存安装日志
log_file="wp-setup-$(date +%Y%m%d%H%M%S).log"
{
    echo "WordPress 安装日志"
    echo "安装时间: $(date)"
    echo "域名: $domain"
    echo "数据库名称: $db_name"
    echo "数据库用户: $db_user"
    echo "WordPress 目录: /var/www/wordpress"
    echo "是否使用 DDNS: $use_ddns"
    if [ "$use_ddns" = "y" ] || [ "$use_ddns" = "Y" ]; then
        echo "DDNS 服务商: $ddns_provider"
        echo "DDNS 域名: $ddns_domain"
    fi
} > "$log_file"
log "安装日志已保存到 $log_file 文件。"

# 确认是否重启系统
restart=$(get_input "是否需要重启系统以完成安装? (y/n)" "y")
if [ "$restart" = "y" ] || [ "$restart" = "Y" ]; then
    log "正在重启系统..."
    sleep 3
    reboot
fi

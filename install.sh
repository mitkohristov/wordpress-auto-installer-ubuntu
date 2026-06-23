#!/usr/bin/env bash
set -Eeuo pipefail

# WordPress Auto Installer for Ubuntu
# Apache2 MPM Event + PHP-FPM + MariaDB + WP-CLI + optional Let's Encrypt SSL
# Tested logic for Ubuntu 22.04/24.04 style systems.

RED="\e[31m"
GREEN="\e[32m"
YELLOW="\e[33m"
NC="\e[0m"

# Print where things broke instead of dying silently. With `set -E` this trap
# is inherited by functions and subshells, so any unguarded failure is visible.
trap 'rc=$?; echo -e "${RED}ERROR:${NC} command failed (exit ${rc}) on line ${LINENO}: ${BASH_COMMAND}" >&2; exit "${rc}"' ERR

die() {
  echo -e "${RED}ERROR:${NC} $1" >&2
  exit 1
}

info() {
  echo -e "${GREEN}==>${NC} $1"
}

warn() {
  echo -e "${YELLOW}WARNING:${NC} $1"
}

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    die "Run this script as root: sudo ./wp-auto-install.sh"
  fi
}

random_hex() {
  openssl rand -hex "${1:-18}"
}

# IMPORTANT: do NOT pipe an infinite stream (/dev/urandom) into `head`.
# `head` closes the pipe after N bytes, the upstream process gets SIGPIPE and
# exits 141, and under `pipefail`+`set -e` in an assignment that kills the whole
# script. We use a finite source (openssl) and slice in bash instead.
random_admin_pass() {
  local raw
  raw="$(openssl rand -base64 48 | LC_ALL=C tr -dc 'A-Za-z0-9_@#%+=')"
  printf '%s' "${raw:0:24}"
}

sanitize_domain() {
  echo "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's#^https?://##; s#/.*$##; s/[^a-z0-9.-]//g'
}

make_slug() {
  echo "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/_/g; s/^_+//; s/_+$//' | cut -c1-24
}

valid_domain() {
  [[ "$1" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+$ ]]
}

require_root

echo
echo "WordPress Auto Installer - Apache2 MPM Event + PHP-FPM + MariaDB"
echo

read -rp "Domain, example example.com: " DOMAIN_RAW
DOMAIN="$(sanitize_domain "$DOMAIN_RAW")"
valid_domain "$DOMAIN" || die "Invalid domain: $DOMAIN_RAW"

read -rp "WordPress site title [${DOMAIN}]: " SITE_TITLE
SITE_TITLE="${SITE_TITLE:-$DOMAIN}"

read -rp "WordPress admin username [admin]: " WP_ADMIN_USER
WP_ADMIN_USER="${WP_ADMIN_USER:-admin}"

read -rp "WordPress admin email [admin@${DOMAIN}]: " WP_ADMIN_EMAIL
WP_ADMIN_EMAIL="${WP_ADMIN_EMAIL:-admin@$DOMAIN}"

read -rp "WordPress locale [bg_BG]: " WP_LOCALE
WP_LOCALE="${WP_LOCALE:-bg_BG}"

read -rp "PHP version [8.3]: " PHP_VERSION
PHP_VERSION="${PHP_VERSION:-8.3}"

read -rp "Install Let's Encrypt SSL now? Domain DNS must already point to this server. [y/N]: " USE_SSL
USE_SSL="${USE_SSL:-N}"

LE_EMAIL=""
if [[ "$USE_SSL" =~ ^[Yy]$ ]]; then
  read -rp "Let's Encrypt email [${WP_ADMIN_EMAIL}]: " LE_EMAIL
  LE_EMAIL="${LE_EMAIL:-$WP_ADMIN_EMAIL}"
fi

SITE_SLUG="$(make_slug "$DOMAIN")"
SITE_USER="wp_${SITE_SLUG}"
SITE_USER="$(echo "$SITE_USER" | cut -c1-31)"

WEBROOT="/var/www/${DOMAIN}/public"
LOGROOT="/var/log/apache2/${DOMAIN}"
POOL_NAME="${SITE_SLUG}"
POOL_CONF="/etc/php/${PHP_VERSION}/fpm/pool.d/${POOL_NAME}.conf"
VHOST_CONF="/etc/apache2/sites-available/${DOMAIN}.conf"
CRED_FILE="/root/wordpress-install-credentials.txt"

DB_NAME="wp_$(echo "$SITE_SLUG" | cut -c1-40)"
DB_USER="u_$(echo "$SITE_SLUG" | cut -c1-24)"
DB_PASS="$(random_hex 18)"
MYSQL_ROOT_PASSWORD="$(random_hex 20)"
WP_ADMIN_PASS="$(random_admin_pass)"

# Memory-derived sizing, computed once and reused for both PHP-FPM and MariaDB.
MEM_MB="$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)"

# PHP-FPM pool sizing: ~64MB per worker, target roughly half of RAM, clamped.
FPM_MAX_CHILDREN=$(( (MEM_MB / 2) / 64 ))
if (( FPM_MAX_CHILDREN < 6 ));  then FPM_MAX_CHILDREN=6;  fi
if (( FPM_MAX_CHILDREN > 40 )); then FPM_MAX_CHILDREN=40; fi
FPM_START=$(( FPM_MAX_CHILDREN / 4 ))
if (( FPM_START < 2 )); then FPM_START=2; fi
FPM_MIN_SPARE="$FPM_START"
FPM_MAX_SPARE=$(( FPM_MAX_CHILDREN / 2 ))
if (( FPM_MAX_SPARE < FPM_START )); then FPM_MAX_SPARE="$FPM_START"; fi

# MariaDB InnoDB buffer pool: ~1/4 of RAM, clamped to a sane range.
DB_BUFFER_POOL="$(( MEM_MB / 4 ))"
if (( DB_BUFFER_POOL < 256 ));  then DB_BUFFER_POOL=256;  fi
if (( DB_BUFFER_POOL > 2048 )); then DB_BUFFER_POOL=2048; fi

info "Updating system packages..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y software-properties-common ca-certificates apt-transport-https curl wget unzip gnupg2 lsb-release openssl

info "Adding PHP repository for modern PHP packages..."
add-apt-repository -y ppa:ondrej/php
apt-get update -y

info "Installing Apache2, MariaDB, PHP-FPM, extensions and tools..."
apt-get install -y \
  apache2 \
  mariadb-server mariadb-client \
  "php${PHP_VERSION}-fpm" \
  "php${PHP_VERSION}-cli" \
  "php${PHP_VERSION}-mysql" \
  "php${PHP_VERSION}-curl" \
  "php${PHP_VERSION}-gd" \
  "php${PHP_VERSION}-imagick" \
  "php${PHP_VERSION}-intl" \
  "php${PHP_VERSION}-mbstring" \
  "php${PHP_VERSION}-xml" \
  "php${PHP_VERSION}-zip" \
  "php${PHP_VERSION}-bcmath" \
  "php${PHP_VERSION}-soap" \
  "php${PHP_VERSION}-readline" \
  "php${PHP_VERSION}-opcache" \
  certbot python3-certbot-apache

info "Configuring Apache2 MPM Event..."
a2dismod php8.4 php8.3 php8.2 php8.1 php8.0 php7.4 mpm_prefork mpm_worker >/dev/null 2>&1 || true
a2enmod mpm_event proxy proxy_fcgi setenvif rewrite headers expires ssl http2 >/dev/null
a2dissite 000-default >/dev/null 2>&1 || true

cat > /etc/apache2/conf-available/servername.conf <<EOF
ServerName 127.0.0.1
EOF
a2enconf servername >/dev/null

cat > /etc/apache2/mods-available/mpm_event.conf <<'EOF'
<IfModule mpm_event_module>
    StartServers             2
    MinSpareThreads          25
    MaxSpareThreads          75
    ThreadLimit              64
    ThreadsPerChild          25
    MaxRequestWorkers        150
    ServerLimit              6
    MaxConnectionsPerChild   10000
</IfModule>
EOF

info "Configuring PHP-FPM and OPcache..."
cat > "/etc/php/${PHP_VERSION}/fpm/conf.d/99-wordpress-opcache.ini" <<EOF
opcache.enable=1
opcache.enable_cli=0
opcache.memory_consumption=192
opcache.interned_strings_buffer=16
opcache.max_accelerated_files=20000
opcache.validate_timestamps=1
opcache.revalidate_freq=60
opcache.save_comments=1
opcache.jit=0
EOF

cat > "/etc/php/${PHP_VERSION}/fpm/conf.d/99-wordpress-limits.ini" <<EOF
upload_max_filesize=64M
post_max_size=64M
memory_limit=256M
max_execution_time=300
max_input_vars=5000
realpath_cache_size=4096K
realpath_cache_ttl=600
EOF

systemctl enable "php${PHP_VERSION}-fpm" >/dev/null

info "Creating system user and web directory..."
if id "$SITE_USER" >/dev/null 2>&1; then
  warn "User $SITE_USER already exists. Continuing."
else
  useradd --system --create-home --home-dir "/home/${SITE_USER}" --shell /usr/sbin/nologin "$SITE_USER"
fi

mkdir -p "$WEBROOT" "$LOGROOT"
chown -R "${SITE_USER}:www-data" "/var/www/${DOMAIN}"
chmod 750 "/var/www/${DOMAIN}"
chmod 750 "$WEBROOT"

info "Creating dedicated PHP-FPM pool (max_children=${FPM_MAX_CHILDREN})..."
cat > "$POOL_CONF" <<EOF
[${POOL_NAME}]
user = ${SITE_USER}
group = ${SITE_USER}

listen = /run/php/${POOL_NAME}.sock
listen.owner = www-data
listen.group = www-data
listen.mode = 0660

pm = dynamic
pm.max_children = ${FPM_MAX_CHILDREN}
pm.start_servers = ${FPM_START}
pm.min_spare_servers = ${FPM_MIN_SPARE}
pm.max_spare_servers = ${FPM_MAX_SPARE}
pm.max_requests = 500

catch_workers_output = yes
decorate_workers_output = no

php_admin_value[error_log] = /var/log/php${PHP_VERSION}-fpm-${DOMAIN}.log
php_admin_flag[log_errors] = on

php_value[upload_max_filesize] = 64M
php_value[post_max_size] = 64M
php_value[memory_limit] = 256M
php_value[max_execution_time] = 300
php_value[max_input_vars] = 5000
EOF

systemctl restart "php${PHP_VERSION}-fpm"

info "Configuring MariaDB..."
systemctl enable mariadb >/dev/null
systemctl start mariadb

cat > /etc/mysql/mariadb.conf.d/99-wordpress.cnf <<EOF
[mysqld]
innodb_buffer_pool_size=${DB_BUFFER_POOL}M
innodb_log_file_size=256M
max_connections=150
tmp_table_size=64M
max_heap_table_size=64M
table_open_cache=2048
skip-name-resolve
EOF

systemctl restart mariadb

info "Creating database and database user, securing root password..."
# Critical block: must succeed. Root authenticates via unix_socket on a fresh
# install (we run as root), so no password is needed for this first connection.
mysql <<SQL
ALTER USER 'root'@'localhost' IDENTIFIED BY '${MYSQL_ROOT_PASSWORD}';
CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';
GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'localhost';
FLUSH PRIVILEGES;
SQL

cat > /root/.my.cnf <<EOF
[client]
user=root
password=${MYSQL_ROOT_PASSWORD}
EOF
chmod 600 /root/.my.cnf

# Best-effort hardening. On modern Ubuntu MariaDB there are usually no anonymous
# users or test DB to begin with, and mysql.user may be a non-deletable view on
# 10.4+, so this is non-fatal (--force keeps going, failure only warns).
info "Hardening MariaDB (best effort)..."
mysql --force <<'SQL' || warn "MariaDB hardening had non-fatal issues; continuing."
DELETE FROM mysql.global_priv WHERE User='';
DROP DATABASE IF EXISTS test;
DELETE FROM mysql.db WHERE Db='test' OR Db LIKE 'test\_%';
FLUSH PRIVILEGES;
SQL

info "Installing WP-CLI..."
if ! command -v wp >/dev/null 2>&1; then
  curl -fsSL -o /tmp/wp-cli.phar https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar
  chmod +x /tmp/wp-cli.phar
  mv /tmp/wp-cli.phar /usr/local/bin/wp
fi

info "Downloading and installing WordPress..."
sudo -u "$SITE_USER" -H wp core download \
  --path="$WEBROOT" \
  --locale="$WP_LOCALE" \
  --force

sudo -u "$SITE_USER" -H wp config create \
  --path="$WEBROOT" \
  --dbname="$DB_NAME" \
  --dbuser="$DB_USER" \
  --dbpass="$DB_PASS" \
  --dbhost="localhost" \
  --dbcharset="utf8mb4" \
  --dbcollate="utf8mb4_unicode_ci" \
  --skip-check \
  --extra-php <<'PHP'
define('FS_METHOD', 'direct');
define('DISALLOW_FILE_EDIT', true);
define('WP_AUTO_UPDATE_CORE', 'minor');
PHP

sudo -u "$SITE_USER" -H wp core install \
  --path="$WEBROOT" \
  --url="http://${DOMAIN}" \
  --title="$SITE_TITLE" \
  --admin_user="$WP_ADMIN_USER" \
  --admin_password="$WP_ADMIN_PASS" \
  --admin_email="$WP_ADMIN_EMAIL"

sudo -u "$SITE_USER" -H wp rewrite structure '/%postname%/' --path="$WEBROOT"
sudo -u "$SITE_USER" -H wp option update timezone_string 'Europe/Sofia' --path="$WEBROOT" >/dev/null
sudo -u "$SITE_USER" -H wp option update blog_public 1 --path="$WEBROOT" >/dev/null

info "Fixing WordPress permissions..."
chown -R "${SITE_USER}:www-data" "/var/www/${DOMAIN}"
find "$WEBROOT" -type d -exec chmod 750 {} \;
find "$WEBROOT" -type f -exec chmod 640 {} \;
chmod 640 "${WEBROOT}/wp-config.php"

info "Creating Apache virtual host..."
cat > "$VHOST_CONF" <<EOF
<VirtualHost *:80>
    ServerName ${DOMAIN}
    DocumentRoot ${WEBROOT}

    Protocols h2 http/1.1

    ErrorLog ${LOGROOT}/error.log
    CustomLog ${LOGROOT}/access.log combined

    DirectoryIndex index.php index.html

    <Directory ${WEBROOT}>
        Options FollowSymLinks
        AllowOverride All
        Require all granted
    </Directory>

    <FilesMatch "\\.php$">
        SetHandler "proxy:unix:/run/php/${POOL_NAME}.sock|fcgi://localhost/"
    </FilesMatch>

    <DirectoryMatch "^${WEBROOT}/(?:\\.git|\\.svn|\\.hg)">
        Require all denied
    </DirectoryMatch>

    <FilesMatch "^(wp-config\\.php|\\.env|composer\\.(json|lock)|package(-lock)?\\.json)$">
        Require all denied
    </FilesMatch>

    Header always set X-Content-Type-Options "nosniff"
    Header always set X-Frame-Options "SAMEORIGIN"
    Header always set Referrer-Policy "strict-origin-when-cross-origin"

    <IfModule mod_expires.c>
        ExpiresActive On
        ExpiresByType image/jpg "access plus 30 days"
        ExpiresByType image/jpeg "access plus 30 days"
        ExpiresByType image/png "access plus 30 days"
        ExpiresByType image/gif "access plus 30 days"
        ExpiresByType image/webp "access plus 30 days"
        ExpiresByType image/svg+xml "access plus 30 days"
        ExpiresByType text/css "access plus 7 days"
        ExpiresByType application/javascript "access plus 7 days"
        ExpiresByType text/javascript "access plus 7 days"
    </IfModule>
</VirtualHost>
EOF

a2ensite "${DOMAIN}.conf" >/dev/null

apache2ctl configtest
systemctl restart apache2

SSL_STATUS="not_enabled"
WP_FINAL_URL="http://${DOMAIN}"

if [[ "$USE_SSL" =~ ^[Yy]$ ]]; then
  info "Requesting Let's Encrypt certificate..."
  # certbot returning non-zero must NOT abort the script via the ERR trap; we
  # handle the failure explicitly and keep the HTTP site working.
  if certbot --apache \
    -d "$DOMAIN" \
    --non-interactive \
    --agree-tos \
    -m "$LE_EMAIL" \
    --redirect; then

    SSL_STATUS="enabled"
    WP_FINAL_URL="https://${DOMAIN}"

    sudo -u "$SITE_USER" -H wp option update home "$WP_FINAL_URL" --path="$WEBROOT" >/dev/null
    sudo -u "$SITE_USER" -H wp option update siteurl "$WP_FINAL_URL" --path="$WEBROOT" >/dev/null

    systemctl reload apache2
  else
    warn "Let's Encrypt failed. WordPress remains available on http://${DOMAIN}"
    SSL_STATUS="failed"
  fi
fi

info "Final service checks..."
systemctl is-active --quiet apache2 || die "Apache2 is not running"
systemctl is-active --quiet "php${PHP_VERSION}-fpm" || die "PHP-FPM is not running"
systemctl is-active --quiet mariadb || die "MariaDB is not running"

MPM_ACTIVE="$(apache2ctl -M 2>/dev/null | grep -o 'mpm_[a-z]*' | head -n1 || true)"
PHP_FPM_ACTIVE="$(systemctl is-active "php${PHP_VERSION}-fpm" || true)"

cat > "$CRED_FILE" <<EOF
WordPress installation credentials
==================================

Site URL:
${WP_FINAL_URL}

WordPress Admin:
${WP_FINAL_URL}/wp-admin

WordPress admin username:
${WP_ADMIN_USER}

WordPress admin password:
${WP_ADMIN_PASS}

Database root user:
root

Database root password:
${MYSQL_ROOT_PASSWORD}

WordPress database name:
${DB_NAME}

WordPress database user:
${DB_USER}

WordPress database password:
${DB_PASS}

System user:
${SITE_USER}

Web root:
${WEBROOT}

Apache MPM:
${MPM_ACTIVE}

PHP-FPM:
php${PHP_VERSION}-fpm / ${PHP_FPM_ACTIVE}

SSL:
${SSL_STATUS}
EOF

chmod 600 "$CRED_FILE"

clear
cat "$CRED_FILE"

echo
echo "Credentials file saved to: $CRED_FILE"
echo

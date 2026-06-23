# WordPress Auto Installer for Ubuntu

A production-style WordPress auto installer for Ubuntu servers.

This script installs and configures a complete WordPress stack using:

* Apache2
* Apache MPM Event
* PHP-FPM
* MariaDB
* WP-CLI
* Optional Let's Encrypt SSL
* Dedicated PHP-FPM pool per domain
* Secure random passwords
* Automatic WordPress installation
* Final credentials file similar to hosting-provider auto installers

The goal of this project is to provide a clean, fast, and reliable WordPress installation script for fresh Ubuntu servers.

---

## Why Apache MPM Event + PHP-FPM?

Apache can run PHP in different ways.

This installer uses the modern and recommended production approach:

```text
User Request
    ↓
Apache2 with MPM Event
    ↓
proxy_fcgi
    ↓
PHP-FPM dedicated pool
    ↓
WordPress
    ↓
MariaDB
```

It does **not** use `mod_php`.

This is important because `mod_php` usually requires Apache Prefork MPM, while this script uses Apache Event MPM for better concurrency and performance.

---

## Features

* Interactive installation
* Domain-based setup
* Apache2 virtual host creation
* Apache MPM Event configuration
* PHP-FPM installation and tuning
* Dedicated PHP-FPM pool for each WordPress site
* MariaDB installation and basic tuning
* Automatic database creation
* Automatic secure password generation
* WordPress download and installation via WP-CLI
* Bulgarian locale support by default
* Europe/Sofia timezone by default
* Optional Let's Encrypt SSL certificate
* HTTP to HTTPS redirect when SSL is enabled
* Basic security headers
* WordPress file permission hardening
* Final credentials saved in a root-only file

---

## Supported Systems

Tested design target:

* Ubuntu 22.04 LTS
* Ubuntu 24.04 LTS

The script is intended for fresh Ubuntu servers.

---

## Requirements

Before running the installer, you need:

* A fresh Ubuntu server
* Root or sudo access
* A valid domain name
* DNS A record pointing to the server IP
* Open ports:

  * 80/tcp
  * 443/tcp

Example DNS record:

```text
example.com    A    YOUR_SERVER_IP
```

---

## Quick Install

Clone the repository:

```bash
git clone https://github.com/YOUR-USERNAME/wordpress-auto-installer-ubuntu.git
cd wordpress-auto-installer-ubuntu
```

Make the installer executable:

```bash
chmod +x install.sh
```

Run the installer:

```bash
sudo ./install.sh
```

The script will ask for:

* Domain name
* WordPress site title
* WordPress admin username
* WordPress admin email
* WordPress locale
* PHP version
* Whether to install Let's Encrypt SSL

---

## Example Installation Flow

```text
Domain, example example.com: example.com
WordPress site title [example.com]: My WordPress Site
WordPress admin username [admin]: admin
WordPress admin email [admin@example.com]: admin@example.com
WordPress locale [bg_BG]: bg_BG
PHP version [8.3]: 8.3
Install Let's Encrypt SSL now? [y/N]: y
Let's Encrypt email [admin@example.com]: admin@example.com
```

---

## Credentials Output

At the end of the installation, the script creates:

```bash
/root/wordpress-install-credentials.txt
```

This file contains:

```text
Site URL
WordPress admin URL
WordPress admin username
WordPress admin password
Database root password
WordPress database name
WordPress database user
WordPress database password
System user
Web root
Apache MPM status
PHP-FPM status
SSL status
```

The file is protected with:

```bash
chmod 600 /root/wordpress-install-credentials.txt
```

Only the root user can read it.

---

## Installed Stack

The installer sets up:

```text
Apache2
MariaDB
PHP-FPM
PHP CLI
PHP MySQL extension
PHP cURL extension
PHP GD extension
PHP Imagick extension
PHP Intl extension
PHP Mbstring extension
PHP XML extension
PHP ZIP extension
PHP BCMath extension
PHP SOAP extension
PHP OPcache
WP-CLI
Certbot
```

---

## Apache Configuration

The script enables:

```text
mpm_event
proxy
proxy_fcgi
setenvif
rewrite
headers
expires
ssl
http2
```

It disables incompatible PHP Apache modules and Prefork/Worker MPM where necessary.

The generated Apache virtual host uses:

```apache
<FilesMatch "\.php$">
    SetHandler "proxy:unix:/run/php/example_com.sock|fcgi://localhost/"
</FilesMatch>
```

This sends PHP requests to the dedicated PHP-FPM pool.

---

## PHP-FPM Pool

Each domain gets its own PHP-FPM pool.

Example:

```text
/etc/php/8.3/fpm/pool.d/example_com.conf
```

Example socket:

```text
/run/php/example_com.sock
```

This improves isolation and makes it easier to tune each WordPress site separately.

---

## File Structure

For a domain like `example.com`, the installer creates:

```text
/var/www/example.com/public
/var/log/apache2/example.com
/home/wp_example_com
```

WordPress files are installed in:

```text
/var/www/example.com/public
```

---

## WordPress Defaults

The installer configures:

```text
Permalink structure: /%postname%/
Locale: bg_BG by default
Timezone: Europe/Sofia
File editor disabled
Direct filesystem method
Minor core updates enabled
```

The script adds the following to `wp-config.php`:

```php
define('FS_METHOD', 'direct');
define('DISALLOW_FILE_EDIT', true);
define('WP_AUTO_UPDATE_CORE', 'minor');
```

---

## Security Notes

This script applies basic hardening:

* Random database passwords
* Random WordPress admin password
* WordPress file editor disabled
* WordPress files owned by a dedicated system user
* Apache blocks access to sensitive files
* Credentials file is readable only by root
* Basic HTTP security headers
* Optional HTTPS with Let's Encrypt

Blocked files include:

```text
wp-config.php
.env
composer.json
composer.lock
package.json
package-lock.json
```

---

## Important Warning

Do not commit the credentials file to GitHub.

Never upload:

```text
/root/wordpress-install-credentials.txt
/root/.my.cnf
wp-config.php from a real production site
database dumps
private SSL keys
```

---

## .gitignore Recommendation

Use this `.gitignore`:

```gitignore
*.log
*.sql
*.sql.gz
*.tar
*.tar.gz
*.zip
.env
wp-config.php
wordpress-install-credentials.txt
credentials.txt
secrets.txt
.DS_Store
```

---

## Basic Server Firewall Example

If you use UFW:

```bash
sudo ufw allow OpenSSH
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw enable
```

---

## Useful Commands

Check Apache modules:

```bash
apache2ctl -M
```

Check active Apache MPM:

```bash
apache2ctl -V | grep -i mpm
```

Check Apache configuration:

```bash
apache2ctl configtest
```

Restart Apache:

```bash
systemctl restart apache2
```

Restart PHP-FPM:

```bash
systemctl restart php8.3-fpm
```

Check PHP-FPM status:

```bash
systemctl status php8.3-fpm
```

Check MariaDB status:

```bash
systemctl status mariadb
```

Read generated credentials:

```bash
sudo cat /root/wordpress-install-credentials.txt
```

---

## Updating WordPress

After installation, you can update WordPress using WP-CLI:

```bash
cd /var/www/example.com/public
sudo -u wp_example_com wp core update
sudo -u wp_example_com wp plugin update --all
sudo -u wp_example_com wp theme update --all
```

---

## Uninstall Notes

This project does not currently include an automatic uninstall script.

Manual cleanup example:

```bash
a2dissite example.com.conf
rm /etc/apache2/sites-available/example.com.conf
rm -rf /var/www/example.com
rm -rf /var/log/apache2/example.com
rm /etc/php/8.3/fpm/pool.d/example_com.conf
systemctl restart php8.3-fpm
systemctl restart apache2
```

Remove database manually:

```sql
DROP DATABASE wp_example_com;
DROP USER 'u_example_com'@'localhost';
FLUSH PRIVILEGES;
```

---

## Roadmap

Possible future improvements:

* Non-interactive mode with CLI parameters
* Nginx version
* Redis object cache support
* Fail2Ban profile
* Cloudflare DNS API support
* Multiple WordPress sites on one server
* Automatic backup script
* Automatic staging environment
* Uninstall script
* GitHub Actions shellcheck validation

---

## Project Status

Initial release.

Use carefully on test servers before production deployment.

---

## License

MIT License.

You are free to use, modify, and distribute this project.

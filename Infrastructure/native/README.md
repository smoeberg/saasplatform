# Native Deployment Server - Opstningsguide

## Overblik

Native deployment server til SellYourSaaS for lavrisiko-apps (PIM, kataloger, markedsfringsvrktjer) uden persondata.

**Arkitektur:**
- Unix-bruger + chroot + FPM + Apache-vhost
- Separat MariaDB-DB pr. instans
- Billigt (<0,50 USD/instans iflge DoliCloud)
- Moderat risiko (ingen persondata)

## Forudstninger

- Ubuntu 22.04 LTS server
- Apache 2.4+
- PHP 8.2 + FPM
- MariaDB 11.4+
- SSH-adgang fra SellYourSaaS master
- sudo adgang til oprettelse af Unix-brugere

## Server Setup

### 1. Installer Apache + PHP-FPM

```bash
# Opdater system
sudo apt-get update && sudo apt-get upgrade -y

# Installer Apache
sudo apt-get install -y apache2

# Installer PHP 8.2 + FPM
sudo apt-get install -y software-properties-common
sudo add-apt-repository ppa:ondrej/php -y
sudo apt-get update
sudo apt-get install -y php8.2 php8.2-fpm php8.2-mysql php8.2-curl php8.2-gd php8.2-mbstring php8.2-xml php8.2-zip

# Aktiver Apache moduler
sudo a2enmod proxy_fcgi setenvif rewrite ssl

# Konfigurer PHP-FPM pool
sudo cp /etc/php/8.2/fpm/pool.d/www.conf /etc/php/8.2/fpm/pool.d/www.conf.bak

cat <<'EOF' | sudo tee /etc/php/8.2/fpm/pool.d/www.conf
[www]
user = www-data
group = www-data
listen = /run/php/php8.2-fpm.sock
listen.owner = www-data
listen.group = www-data
listen.mode = 0660
pm = dynamic
pm.max_children = 50
pm.start_servers = 5
pm.min_spare_servers = 5
pm.max_spare_servers = 10
pm.max_requests = 500
php_admin_value[error_log] = /var/log/php8.2-fpm.log
php_admin_flag[log_errors] = on
php_admin_flag[catch_workers_output] = on
EOF

# Genstart PHP-FPM
sudo systemctl restart php8.2-fpm

# Genstart Apache
sudo systemctl restart apache2
```

### 2. Konfigurer Apache Virtual Host Template

```bash
# Opret mappestruktur
sudo mkdir -p /etc/apache2/sites-available
sudo mkdir -p /etc/apache2/sites-enabled

# Opret template for tenant vhosts
cat <<'EOF' | sudo tee /etc/apache2/templates/tenant-vhost.conf
<VirtualHost *:80>
    ServerName {{DOMAIN}}
    ServerAlias www.{{DOMAIN}}
    ServerAdmin webmaster@{{DOMAIN}}
    
    DocumentRoot /home/{{USER}}/public_html
    
    <Directory /home/{{USER}}/public_html>
        Options -Indexes +FollowSymLinks
        AllowOverride All
        Require all granted
    </Directory>
    
    <FilesMatch \.php$>
        SetHandler "proxy:unix:/run/php/php8.2-fpm-{{USER}}.sock|fcgi://localhost"
    </FilesMatch>
    
    ErrorLog /var/log/apache2/{{USER}}-error.log
    CustomLog /var/log/apache2/{{USER}}-access.log combined
    
    # Health check endpoint
    <Location /healthz>
        SetHandler "proxy:unix:/run/php/php8.2-fpm-{{USER}}.sock|fcgi://localhost"
        ScriptAlias /healthz /home/{{USER}}/public_html/healthz.php
    </Location>
</VirtualHost>
EOF

# Opret healthz.php template
cat <<'EOF' | sudo tee /etc/apache2/templates/healthz.php
<?php
header('Content-Type: text/plain');
echo "OK";
exit(0);
?>
EOF
```

### 3. Konfigurer chroot Milj

```bash
# Opret chroot base directory
sudo mkdir -p /var/www/chroot

# Opret ndvendige mapper i chroot
for dir in bin dev etc lib lib64 proc sys tmp usr var; do
    sudo mkdir -p /var/www/chroot/$dir
    sudo chmod 755 /var/www/chroot/$dir
done

# Kopier systemfiler
sudo cp -r /bin /var/www/chroot/bin
sudo cp -r /dev /var/www/chroot/dev
sudo cp -r /etc /var/www/chroot/etc
sudo cp -r /lib /var/www/chroot/lib
sudo cp -r /lib64 /var/www/chroot/lib64
sudo cp -r /usr /var/www/chroot/usr
sudo cp -r /var /var/www/chroot/var

# Opret symlinks
sudo ln -s /var/www/chroot/usr/bin /var/www/chroot/bin
sudo ln -s /var/www/chroot/usr/lib /var/www/chroot/lib
sudo ln -s /var/www/chroot/usr/lib64 /var/www/chroot/lib64

# Kopier PHP til chroot
sudo mkdir -p /var/www/chroot/usr/bin
sudo cp /usr/bin/php /var/www/chroot/usr/bin/php
sudo cp /usr/bin/php8.2 /var/www/chroot/usr/bin/php8.2

# Kopier PHP libraries
sudo mkdir -p /var/www/chroot/usr/lib/php/8.2
sudo cp -r /usr/lib/php/8.2/* /var/www/chroot/usr/lib/php/8.2/

# Kopier timezonedata
sudo mkdir -p /var/www/chroot/usr/share/zoneinfo
sudo cp -r /usr/share/zoneinfo/* /var/www/chroot/usr/share/zoneinfo/

# St permissions
sudo chmod -R u+rwX /var/www/chroot
```

### 4. Installer SellYourSaaS Remote Agent

```bash
# Opret SellYourSaaS bruger
sudo useradd -r -s /bin/bash -m sellyourssas
sudo usermod -aG sudo sellyourssas

# Opret mapper
sudo mkdir -p /opt/sellyoursaas
sudo chown sellyourssas:sellyoursaas /opt/sellyoursaas

# Download og installer agent
cd /opt/sellyoursaas
sudo -u sellyourssas git clone https://github.com/DoliCloud/sellyoursaas.git
cd sellyoursaas
sudo -u sellyourssas git checkout v23.0.0  # Brug seneste version

# Konfigurer agent
sudo -u sellyourssas cp remote_server_launcher.config.php.dist remote_server_launcher.config.php

# Rediger konfiguration
sudo -u sellyourssas cat <<'EOF' | tee -a remote_server_launcher.config.php
<?php
// SellYourSaaS Remote Server Configuration
$SELLYOURSAAS_REMOTE_SERVER_PORT = 8080;
$SELLYOURSAAS_REMOTE_SERVER_HOST = '0.0.0.0';
$SELLYOURSAAS_REMOTE_SERVER_HTTPS = false;  // Til test, brug HTTPS i produktion
$SELLYOURSAAS_REMOTE_SERVER_SSL_CERT = '';
$SELLYOURSAAS_REMOTE_SERVER_SSL_KEY = '';

// Database configuration (for agent's own database)
$SELLYOURSAAS_REMOTE_DB_HOST = 'localhost';
$SELLYOURSAAS_REMOTE_DB_NAME = 'sellyoursaas';
$SELLYOURSAAS_REMOTE_DB_USER = 'sellyoursaas';
$SELLYOURSAAS_REMOTE_DB_PASSWORD = '';

// Master server connection
$SELLYOURSAAS_MASTER_URL = 'https://saasplatform-master.dk';
$SELLYOURSAAS_MASTER_API_KEY = '';  // St i SellYourSaaS admin

// Logging
$SELLYOURSAAS_REMOTE_LOG_LEVEL = 'INFO';
$SELLYOURSAAS_REMOTE_LOG_FILE = '/var/log/sellyoursaas/remote_server.log';

// Packages directory
$SELLYOURSAAS_REMOTE_PACKAGES_DIR = '/opt/sellyoursaas/packages';
EOF

# Opret log directory
sudo mkdir -p /var/log/sellyoursaas
sudo chown sellyourssas:sellyoursaas /var/log/sellyoursaas

# Opret systemd service
cat <<'EOF' | sudo tee /etc/systemd/system/sellyoursaas-remote-server.service
[Unit]
Description=SellYourSaaS Remote Server Agent
After=network.target apache2.php8.2-fpm

[Service]
User=sellyoursaas
Group=sellyoursaas
WorkingDirectory=/opt/sellyoursaas/sellyoursaas
ExecStart=/usr/bin/php /opt/sellyoursaas/sellyoursaas/remote_server_launcher.php
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

# Aktiver og start service
sudo systemctl daemon-reload
sudo systemctl enable sellyoursaas-remote-server
sudo systemctl start sellyoursaas-remote-server

# Tjek status
sudo systemctl status sellyoursaas-remote-server
```

### 5. Konfigurer Firewall

```bash
# Tillad HTTP/HTTPS
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp

# Tillad SellYourSaaS agent port
sudo ufw allow 8080/tcp

# Tillad SSH
sudo ufw allow 22/tcp

# Aktiver firewall
sudo ufw enable
```

## PIM Package Setup

### 1. Opret Package Definition

I SellYourSaaS admin:

1. G til "Deployment Servers & Packages"
2. Klik "Add Package"
3. Udfyld felter:

```
Package Name: pim-native
Type: native
Version: 1.0.0
Description: PIM application for native deployment

Sources:
- Git Repository: https://github.com/smoeberg/pim-app.git
- Branch: main
- Directory: /

Config Templates:
- main: templates/pim-config.php
- nginx: templates/pim-nginx.conf

Cron Templates:
- hourly: templates/pim-cron-hourly.sh
- daily: templates/pim-cron-daily.sh

Remote Actions:
- deploy: /opt/sellyoursaas/scripts/native/deploy.sh
- undeploy: /opt/sellyoursaas/scripts/native/undeploy.sh
- suspend: /opt/sellyoursaas/scripts/native/suspend.sh
- unsuspend: /opt/sellyoursaas/scripts/native/unsuspend.sh
- refresh: /opt/sellyoursaas/scripts/native/refresh.sh
- recreateauthorizedkeys: /opt/sellyoursaas/scripts/native/recreateauthorizedkeys.sh
```

### 2. Opret Scripts

Se [Scripts/native/](../../Scripts/native/) for implementeringer.

### 3. Opret Database

```bash
# Opret MariaDB database for PIM
sudo mysql -u root -p

CREATE DATABASE pim_db;
CREATE USER 'pim_user'@'localhost' IDENTIFIED BY '<password>';
GRANT ALL PRIVILEGES ON pim_db.* TO 'pim_user'@'localhost';
FLUSH PRIVILEGES;

# For remote adgang (hvis ndvendigt)
CREATE USER 'pim_user'@'%' IDENTIFIED BY '<password>';
GRANT ALL PRIVILEGES ON pim_db.* TO 'pim_user'@'%';
FLUSH PRIVILEGES;
```

## Native Deployment Scripts

Se [Scripts/native/](../../Scripts/native/) for:
- `deploy.sh` - Opret Unix-bruger, chroot, FPM pool, vhost
- `undeploy.sh` - Slet bruger, database, vhost
- `suspend.sh` - Deaktiver vhost, stop FPM pool
- `unsuspend.sh` - Reaktiver vhost, start FPM pool
- `refresh.sh` - Genindls config, restart services
- `recreateauthorizedkeys.sh` - Roter SSH-keys

## Test Deployment

### 1. Manually Test

```bash
# Opret test bruger
sudo /opt/sellyoursaas/scripts/native/deploy.sh test1

# Tjek at bruger er oprettet
id test1

# Tjek at home directory findes
ls -la /home/test1/

# Tjek at vhost findes
ls -la /etc/apache2/sites-enabled/ | grep test1

# Tjek at FPM pool findes
ls -la /etc/php/8.2/fpm/pool.d/ | grep test1

# Genstart Apache og FPM
sudo systemctl restart apache2
sudo systemctl restart php8.2-fpm

# Test healthz
curl -fsS -o /dev/null -m 5 "http://test1.localhost/healthz"
```

### 2. SellYourSaaS Test

1. G til SellYourSaaS admin
2. Opret ny kunde
3. Tilknytt PIM package
4. Verificer at tenant deployes automatisk
5. Test adgang til tenant

## Drift

### Monitoring

```bash
# Tjek Apache status
sudo systemctl status apache2

# Tjek PHP-FPM status
sudo systemctl status php8.2-fpm

# Tjek SellYourSaaS agent
sudo systemctl status sellyoursaas-remote-server

# Tjek logs
sudo tail -f /var/log/apache2/error.log
sudo tail -f /var/log/php8.2-fpm.log
sudo tail -f /var/log/sellyoursaas/remote_server.log
```

### Backup

```bash
# Backup af alle tenant data
sudo tar -czvf /backup/native-tenants-$(date +%Y%m%d).tar.gz /home/*/public_html /etc/apache2/sites-enabled/*

# Backup af databases
sudo mysqldump -u root -p --all-databases > /backup/native-dbs-$(date +%Y%m%d).sql
```

### Vedligeholdelse

```bash
# Roter logs
sudo logrotate -f /etc/logrotate.d/apache2
sudo logrotate -f /etc/logrotate.d/php8.2-fpm

# Opdater PIM application
cd /opt/sellyoursaas/sellyoursaas
sudo -u sellyourssas git pull
```

## Fejlfinding

### Apache fejler

```bash
# Tjek syntax
sudo apache2ctl configtest

# Tjek error logs
sudo tail -f /var/log/apache2/error.log

# Genstart Apache
sudo systemctl restart apache2
```

### PHP-FPM fejler

```bash
# Tjek syntax
sudo php-fpm8.2 -t

# Tjek error logs
sudo tail -f /var/log/php8.2-fpm.log

# Genstart PHP-FPM
sudo systemctl restart php8.2-fpm
```

### SellYourSaaS agent fejler

```bash
# Tjek logs
sudo tail -f /var/log/sellyoursaas/remote_server.log

# Genstart agent
sudo systemctl restart sellyoursaas-remote-server
```

### Tenant specifikke fejler

```bash
# Tjek tenant vhost syntax
sudo apache2ctl -S | grep test1

# Tjek tenant FPM pool
sudo cat /etc/php/8.2/fpm/pool.d/test1.conf

# Tjek tenant logs
sudo tail -f /var/log/apache2/test1-error.log
sudo tail -f /var/log/apache2/test1-access.log
```

## Sikkerhed

### Chroot Isolation

- Alle tenants krer i separate chroot miljer
- Separate Unix-brugere
- Separate PHP-FPM pools
- Ingen adgang mellem tenants

### Permissions

```bash
# St korrekte permissions
sudo chown -R test1:test1 /home/test1
sudo chmod -R 750 /home/test1
sudo chmod 710 /home/test1/public_html
```

### Firewall

- Kun port 80, 443, 8080, 22 bne
- Ingen direkte adgang til tenant data
- SSH kun fra trusted IPs

## Ressourcer

- [SellYourSaaS Dokumentation](https://github.com/DoliCloud/sellyoursaas)
- [Apache Dokumentation](https://httpd.apache.org/docs/)
- [PHP-FPM Dokumentation](https://www.php.net/manual/en/install.fpm.php)
- [chroot Guide](https://www.thegeekstuff.com/2011/05/chroot-jail/)

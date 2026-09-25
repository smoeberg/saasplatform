# PIM Native Package - Dokumentation

## Overblik

PIM (Product Information Management) package til **native deployment** p SellYourSaaS.

**Type**: Native (Unix-bruger + chroot + FPM + Apache-vhost)
**Risiko**: Lav (ingen persondata)
**Omkostning**: <0,50 USD/instans
**Brug**: PIM, kataloger, markedsfringsvrktjer

## Package Struktur

```
Package: pim-native
├── sources/              # PIM application code
│   └── (kopieres til /home/{INSTANCE}/public_html)
├── config_templates/    # Konfigurationsfiler
│   ├── main/            # Main application config
│   ├── database/        # Database config
│   ├── apache/          # Apache vhost
│   └── php-fpm/         # PHP-FPM pool
└── cron_templates/      # Cron jobs
    ├── hourly/          # Timebaserede jobs
    └── daily/           # Daglige jobs
```

## Installation

### 1. Opret Package i SellYourSaaS

1. G til SellYourSaaS admin
2. Naviger til "Deployment Servers & Packages"
3. Klik "Import Package"
4. Upload `Packages/pim-native.yaml`

### 2. Konfigurer Deployment Server

1. G til "Deployment Servers"
2. Vlg din native server
3. Tilknyt `pim-native` package
4. Gem indstillinger

### 3. Opret Service

1. G til "Services"
2. Klik "Add Service"
3. Vlg `pim-native` package
4. Konfigurer:
   - **Name**: PIM Standard
   - **Plan**: standard (eller professional)
   - **Price**: 99 DKK/mned
   - **Billing Cycle**: Monthly
   - **Options**: Standard features

## Remote Actions

| Action | Script | Beskrivelse |
|--------|--------|-------------|
| beforedeploy | `Scripts/native/beforedeploy.sh` | Pre-flight checks |
| afterdeploy | `Scripts/native/afterdeploy.sh` | Post-deploy status |
| beforeundeploy | - | (Ikke brugt) |
| afterundeploy | `Scripts/native/undeploy.sh` | Nedlggelse |
| aftersuspend | `Scripts/native/aftersuspend.sh` | Post-suspend status |
| beforeunsuspend | - | (Ikke brugt) |
| afterunsuspend | `Scripts/native/afterunsuspend.sh` | Post-unsuspend status |
| refresh | `Scripts/native/refresh.sh` | Genindls config |
| recreateauthorizedkeys | `Scripts/native/recreateauthorizedkeys.sh` | Roter SSH-keys |

## Konfiguration

### Main Config Template (`templates/pim-config.php`)

```php
<?php
// PIM Application Configuration
$config = [
    'app_name' => 'PIM',
    'app_version' => '1.0.0',
    'environment' => 'production',
    'debug' => false,
    
    // Database (hentes fra db-config.php)
    'db_driver' => 'mysql',
    
    // Cache
    'cache_driver' => 'file',
    'cache_path' => __DIR__ . '/../storage/cache',
    
    // Session
    'session_driver' => 'file',
    'session_path' => __DIR__ . '/../storage/sessions',
    
    // Uploads
    'upload_path' => __DIR__ . '/../storage/uploads',
    'max_upload_size' => 10485760, // 10MB
    'allowed_extensions' => ['jpg', 'jpeg', 'png', 'gif', 'pdf', 'csv'],
    
    // API
    'api_enabled' => true,
    'api_rate_limit' => 100, // requests per minute
    
    // Security
    'csrf_protection' => true,
    'xss_clean' => true,
];

return $config;
```

### Database Config Template (`templates/pim-db-config.php`)

```php
<?php
// Database Configuration (genereret af deploy.sh)
$db_host = '{{DB_HOST}}';
$db_name = '{{DB_NAME}}';
$db_user = '{{DB_USER}}';
$db_password = '{{DB_PASSWORD}}';

return [
    'mysql' => [
        'driver' => 'mysql',
        'host' => $db_host,
        'database' => $db_name,
        'username' => $db_user,
        'password' => $db_password,
        'unix_socket' => '',
        'port' => 3306,
        'charset' => 'utf8mb4',
        'collation' => 'utf8mb4_unicode_ci',
        'prefix' => '',
        'strict' => true,
        'engine' => null,
    ],
];
```

### Apache Vhost Template (`templates/pim-apache.conf`)

```apache
<VirtualHost *:80>
    ServerName {{DOMAIN}}
    ServerAlias www.{{DOMAIN}}
    ServerAdmin webmaster@{{DOMAIN}}
    
    DocumentRoot {{USER_HOME}}/public_html
    
    <Directory {{USER_HOME}}/public_html>
        Options -Indexes +FollowSymLinks
        AllowOverride All
        Require all granted
    </Directory>
    
    <FilesMatch \.php$>
        SetHandler "proxy:unix:/run/php/php8.2-fpm-{{INSTANCE}}.sock|fcgi://localhost"
    </FilesMatch>
    
    ErrorLog /var/log/apache2/{{INSTANCE}}-error.log
    CustomLog /var/log/apache2/{{INSTANCE}}-access.log combined
    
    <Location /healthz>
        SetHandler "proxy:unix:/run/php/php8.2-fpm-{{INSTANCE}}.sock|fcgi://localhost"
    </Location>
</VirtualHost>
```

### PHP-FPM Pool Template (`templates/pim-fpm-pool.conf`)

```ini
[{{INSTANCE}}]
user = {{INSTANCE}}
group = {{INSTANCE}}
listen = /run/php/php8.2-fpm-{{INSTANCE}}.sock
listen.owner = {{INSTANCE}}
listen.group = www-data
listen.mode = 0660

pm = dynamic
pm.max_children = 10
pm.start_servers = 2
pm.min_spare_servers = 1
pm.max_spare_servers = 3
pm.max_requests = 500

chroot = /var/www/chroot/{{INSTANCE}}
chdir = /

php_admin_value[error_log] = /var/log/php8.2-fpm-{{INSTANCE}}.log
php_admin_flag[log_errors] = on
php_admin_flag[catch_workers_output] = on

; Security
php_admin_flag[disable_functions] = exec,passthru,shell_exec,system
php_admin_flag[allow_url_fopen] = off
php_admin_flag[expose_php] = off

; Performance
php_admin_value[memory_limit] = 256M
php_admin_value[max_execution_time] = 30
php_admin_value[upload_max_filesize] = 10M
php_admin_value[post_max_size] = 12M
```

## Cron Jobs

### Hourly Cron (`templates/pim-cron-hourly.sh`)

```bash
#!/bin/bash
# PIM Hourly Cron Job
# Krer hver time for at rydde op i midlertidige filer

cd /home/{{INSTANCE}}/public_html

# Ryd op i cache
rm -rf storage/cache/*

# Ryd op i sessions (older than 1 hour)
find storage/sessions -type f -mtime +1 -delete

# Ryd op i logs (older than 7 days)
find storage/logs -type f -mtime +7 -delete
```

### Daily Cron (`templates/pim-cron-daily.sh`)

```bash
#!/bin/bash
# PIM Daily Cron Job
# Krer dagligt for backup og vedligeholdelse

cd /home/{{INSTANCE}}/public_html

# Database backup
if command -v mysqldump &> /dev/null; then
    mysqldump -u {{DB_USER}} -p'{{DB_PASSWORD}}' {{DB_NAME}} > /home/{{INSTANCE}}/backups/db-$(date +%Y%m%d).sql
    gzip /home/{{INSTANCE}}/backups/db-$(date +%Y%m%d).sql
fi

# Ryd op i gamle backups (older than 7 days)
find /home/{{INSTANCE}}/backups -type f -mtime +7 -delete

# Optimize database
if command -v mysql &> /dev/null; then
    mysql -u {{DB_USER}} -p'{{DB_PASSWORD}}' {{DB_NAME}} -e "OPTIMIZE TABLE pim_products, pim_categories;"
fi
```

## Deployment Flow

### 1. beforedeploy

```bash
# Kres af SellYourSaaS fr deploy
# Validerer:
# - Apache krer
# - PHP-FPM krer
# - Ndvendige mapper findes
# - Diskplads
# - Memory
/opt/sellyoursaas/scripts/native/beforedeploy.sh
```

### 2. deploy

```bash
# Kres af SellYourSaaS
# Opretter:
# - Unix-bruger
# - Chroot miljø
# - public_html directory
# - Apache vhost
# - PHP-FPM pool
# - Database
/opt/sellyoursaas/scripts/native/deploy.sh
```

### 3. afterdeploy

```bash
# Kres af SellYourSaaS efter deploy
# Skriver statusfil
/opt/sellyoursaas/scripts/native/afterdeploy.sh
```

### 4. refresh

```bash
# Kres af SellYourSaaS ved config ndringer
# Genindlser:
# - Apache vhost
# - PHP-FPM pool
/opt/sellyoursaas/scripts/native/refresh.sh
```

### 5. suspend

```bash
# Kres af SellYourSaaS ved suspension
# Deaktiverer:
# - Apache vhost
# - PHP-FPM pool
/opt/sellyoursaas/scripts/native/suspend.sh
```

### 6. unsuspend

```bash
# Kres af SellYourSaaS ved unsuspension
# Reaktiverer:
# - Apache vhost
# - PHP-FPM pool
/opt/sellyoursaas/scripts/native/unsuspend.sh
```

### 7. afterunsuspend

```bash
# Kres af SellYourSaaS efter unsuspend
# Skriver statusfil
/opt/sellyoursaas/scripts/native/afterunsuspend.sh
```

### 8. recreateauthorizedkeys

```bash
# Kres af SellYourSaaS ved password reset
# Roterer SSH-keys
/opt/sellyoursaas/scripts/native/recreateauthorizedkeys.sh
```

### 9. undeploy

```bash
# Kres af SellYourSaaS ved nedlggelse
# Sletter:
# - Unix-bruger
# - Chroot miljø
# - Apache vhost
# - PHP-FPM pool
# - Database
/opt/sellyoursaas/scripts/native/undeploy.sh
```

## Monitoring

### Health Check

```bash
# Healthz endpoint
curl http://<domain>/healthz

# Forventet response: OK
```

### Logs

```bash
# Apache logs
sudo tail -f /var/log/apache2/{INSTANCE}-error.log
sudo tail -f /var/log/apache2/{INSTANCE}-access.log

# PHP-FPM logs
sudo tail -f /var/log/php8.2-fpm-{INSTANCE}.log

# Application logs
sudo tail -f /home/{INSTANCE}/public_html/storage/logs/*.log
```

## Backup

### Manuel Backup

```bash
# Backup af tenant data
sudo tar -czvf /backup/pim-{INSTANCE}-$(date +%Y%m%d).tar.gz \
  /home/{INSTANCE}/public_html \
  /etc/apache2/sites-available/{INSTANCE}.conf \
  /etc/php/8.2/fpm/pool.d/{INSTANCE}.conf

# Backup af database
sudo mysqldump -u root -p pim_{INSTANCE} > /backup/pim-db-{INSTANCE}-$(date +%Y%m%d).sql
```

### Restore

```bash
# Restore af tenant data
sudo tar -xzvf /backup/pim-{INSTANCE}-*.tar.gz -C /

# Restore af database
sudo mysql -u root -p pim_{INSTANCE} < /backup/pim-db-{INSTANCE}-*.sql

# Genstart services
sudo systemctl restart apache2
sudo systemctl restart php8.2-fpm
```

## Fejlfinding

### Tenant deploy fejler

```bash
# Tjek deploy logs
sudo tail -f /var/log/sellyoursaas/remote_server.log

# Tjek Apache syntax
sudo apache2ctl configtest

# Tjek PHP-FPM syntax
sudo php-fpm8.2 -t

# Tjek at bruger findes
id {INSTANCE}

# Tjek at vhost findes
ls -la /etc/apache2/sites-enabled/ | grep {INSTANCE}

# Tjek at FPM pool findes
ls -la /etc/php/8.2/fpm/pool.d/ | grep {INSTANCE}
```

### Tenant ikke tilgngelig

```bash
# Tjek Apache status
sudo systemctl status apache2

# Tjek PHP-FPM status
sudo systemctl status php8.2-fpm

# Tjek vhost er aktiveret
sudo apache2ctl -S | grep {INSTANCE}

# Tjek FPM pool krer
sudo service php8.2-fpm status | grep {INSTANCE}

# Test healthz
curl http://{domain}/healthz
```

### Database fejler

```bash
# Tjek database connection
mysql -u {INSTANCE}_dbuser -p -e "USE pim_{INSTANCE}; SHOW TABLES;"

# Tjek database logs
sudo tail -f /var/log/mysql/error.log

# Test database connection fra PHP
php -r "\$db = new PDO('mysql:host=localhost;dbname=pim_{INSTANCE}', '{INSTANCE}_dbuser', '<password>'); print \$db->getAttribute(PDO::ATTR_CONNECTION_STATUS);"
```

## Performance Optimization

### Apache

```apache
# Juster MaxRequestWorkers baseret p server capacity
<IfModule mpm_prefork_module>
    StartServers 5
    MinSpareServers 5
    MaxSpareServers 10
    MaxRequestWorkers 150
    MaxConnectionsPerChild 1000
</IfModule>
```

### PHP-FPM

```ini
# Juster FPM pool settings
pm = dynamic
pm.max_children = 20
pm.start_servers = 5
pm.min_spare_servers = 5
pm.max_spare_servers = 10
pm.max_requests = 1000
```

### MySQL/MariaDB

```sql
-- Optimize for PIM workload
SET GLOBAL innodb_buffer_pool_size = 1G;
SET GLOBAL innodb_log_file_size = 256M;
SET GLOBAL query_cache_size = 64M;
SET GLOBAL tmp_table_size = 64M;
SET GLOBAL max_heap_table_size = 64M;
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
sudo chown -R {INSTANCE}:{INSTANCE} /home/{INSTANCE}
sudo chmod -R 750 /home/{INSTANCE}
sudo chmod 710 /home/{INSTANCE}/public_html
```

### Firewall

```bash
# Tillad kun ndvendige ports
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 22/tcp

# Bloker direkte adgang til tenant data
sudo ufw deny 22/tcp comment "Block direct tenant access"
```

## Skalering

### Horisontal skalering

```bash
# Tilfj ny native deployment server
# 1. Installer Apache + PHP-FPM + chroot
# 2. Konfigurer SellYourSaaS deployment server
# 3. Flyt tenants til ny server

# Flyt tenant til ny server
# 1. Tag backup p gammel server
# 2. Deploy p ny server
# 3. Restore backup
# 4. Opdater DNS
```

### Vertikal skalering

```bash
# g server ressourcer
# CPU: g vCPU count
# RAM: g memory
# Disk: g disk size

# Juster FPM settings
pm.max_children = 50  # g fra 10
pm.max_requests = 2000  # g fra 500
```

## Ressourcer

- [SellYourSaaS Dokumentation](https://github.com/DoliCloud/sellyoursaas)
- [Apache Dokumentation](https://httpd.apache.org/docs/)
- [PHP-FPM Dokumentation](https://www.php.net/manual/en/install.fpm.php)
- [chroot Guide](https://www.thegeekstuff.com/2011/05/chroot-jail/)
- [MariaDB Optimization](https://mariadb.com/kb/en/mariadb-optimization/)

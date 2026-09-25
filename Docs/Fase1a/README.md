# Fase 1a - Installationstjekliste: Native Deployment

## Forml

Bevise forretningsflowet (registrering  deploy  betaling  suspension) med **PIM som frste native package**.

**Exit-kriterier:**
- 10 fulde gennemlb
- 2 med fejl-injektion (betaling fejler midt i deploy, deploy fejler)

## Checkliste

###  1. Master-server (Dolibarr + SellYourSaaS-modul)

- [ ] **LAMP/LEMP-stack**
  - [ ] PHP 8.2 installeret
  - [ ] MariaDB installeret
  - [ ] Nginx/Apache + TLS konfigureret
  - [ ] Cron-jobs aktiveret

- [ ] **Dolibarr**
  - [ ] Dolibarr (nyeste stabile, 23.x) installeret
  - [ ] Database konfigureret
  - [ ] Admin bruger oprettet

- [ ] **SellYourSaaS-modul**
  - [ ] `git clone https://github.com/DoliCloud/sellyoursaas`  `custom/sellyoursaas`
  - [ ] Modul aktiveret
  - [ ] Master-tilstand = "master (hosting)" sat
  - [ ] HTTPS + gyldigt certifikat

- [ ] **Betaling**
  - [ ] Stripe-konto (test-mode) koblet
  - [ ] `SELLYOURSAAS_STRIPE_*` konstanter sat
  - [ ] SEPA (GoCardless) koblet  eller udskudt til fase 2

###  2. Native deployment-server

- [ ] **Server opstning**
  - [ ] Server oprettet i masteren (Remote server: FQDN, IP, port 8080)
  - [ ] Flg [Infrastructure/native/README.md](../../Infrastructure/native/README.md)

- [ ] **Remote launcher-agent**
  - [ ] Agent installeret (`remote_server_launcher`)
  - [ ] Port 8080 + TLS konfigureret
  - [ ] Systemd service oprettet og aktiveret

- [ ] **SSH-adgang**
  - [ ] SSH-adgang fra master til serveren oprettet
  - [ ] sudo-adgang til oprettelse af Unix-brugere
  - [ ] SSH-key authentication konfigureret

- [ ] **Web-server**
  - [ ] Apache/PHP-FPM installeret
  - [ ] chroot-ramme verifikeret
  - [ ] Test-instans deployet manuelt

- [ ] **Blacklists/kvoter**
  - [ ] Blacklists sat i SellYourSaaS-konfigurationen
  - [ ] Kvoter konfigureret (CPU, memory, storage)

###  3. PIM-package

- [ ] **Package definition**
  - [ ] Package oprettet: `pim-native`
  - [ ] Type: native
  - [ ] Version: 1.0.0
  - [ ] Se [Packages/pim-native.yaml](../../Packages/pim-native.yaml)

- [ ] **Sources**
  - [ ] Git repository konfigureret
  - [ ] Branch: main
  - [ ] Deploy path: `/home/{INSTANCE}/public_html`

- [ ] **Config templates**
  - [ ] Main config template oprettet
  - [ ] Database config template oprettet
  - [ ] Apache vhost template oprettet
  - [ ] PHP-FPM pool template oprettet

- [ ] **Cron templates**
  - [ ] Hourly cron template oprettet
  - [ ] Daily cron template oprettet

- [ ] **Remote actions**
  - [ ] beforedeploy: `Scripts/native/beforedeploy.sh`
  - [ ] afterdeploy: `Scripts/native/afterdeploy.sh`
  - [ ] beforeundeploy: (Ikke brugt)
  - [ ] afterundeploy: `Scripts/native/undeploy.sh`
  - [ ] aftersuspend: `Scripts/native/aftersuspend.sh`
  - [ ] beforeunsuspend: (Ikke brugt)
  - [ ] afterunsuspend: `Scripts/native/afterunsuspend.sh`
  - [ ] refresh: `Scripts/native/refresh.sh`
  - [ ] recreateauthorizedkeys: `Scripts/native/recreateauthorizedkeys.sh`

- [ ] **Scripts**
  - [ ] Alle scripts kopieret til `/opt/sellyoursaas/scripts/native/`
  - [ ] Execute permissions sat
  - [ ] Testet manuelt

- [ ] **Service**
  - [ ] Service oprettet: PIM Standard
  - [ ] Plan: standard
  - [ ] Pris: 99 DKK/mned
  - [ ] Billing cycle: monthly

- [ ] **Database**
  - [ ] Separat MariaDB-DB pr. instans
  - [ ] DB bruger oprettet
  - [ ] DB permissions sat

###  4. Kundecenter + flow-test

- [ ] **myaccount**
  - [ ] myaccount aktiveret
  - [ ] register.php fungerer
  - [ ] login fungerer
  - [ ] instans-oversigt vises

- [ ] **Testkunde 1**
  - [ ] Kunde registreret via web
  - [ ] Instans provisioneret automatisk
  - [ ] Faktura genereret
  - [ ] Betaling gennemfrt (Stripe test-kort)
  - [ ] Kontrakt aktiv

- [ ] **Testkunde 2**
  - [ ] Kunde registreret via web
  - [ ] Instans provisioneret automatisk
  - [ ] Faktura genereret
  - [ ] Betaling gennemfrt
  - [ ] Kontrakt aktiv

- [ ] **Testkunde 3**
  - [ ] Kunde registreret via web
  - [ ] Instans provisioneret automatisk
  - [ ] Faktura genereret
  - [ ] Betaling gennemfrt
  - [ ] Kontrakt aktiv

- [ ] **Testkunde 4**
  - [ ] Kunde registreret via web
  - [ ] Instans provisioneret automatisk
  - [ ] Faktura genereret
  - [ ] Betaling gennemfrt
  - [ ] Kontrakt aktiv

- [ ] **Testkunde 5**
  - [ ] Kunde registreret via web
  - [ ] Instans provisioneret automatisk
  - [ ] Faktura genereret
  - [ ] Betaling gennemfrt
  - [ ] Kontrakt aktiv

###  5. Fejl-injektion (2 af 10 gennemlb)

- [ ] **Fejl-injektion 1: Betaling fejler midt i deploy**
  - [ ] Testkunde registreret
  - [ ] Betaling afvist midt i deploy
  - [ ] Tenant-tilstand korrekt (ingen halvfrdig instans)
  - [ ] Ingen faktura genereret
  - [ ] Fejl logget i SellYourSaaS

- [ ] **Fejl-injektion 2: Deploy fejler**
  - [ ] Testkunde registreret
  - [ ] Deploy fejler (fx sources ikke tilgngelige)
  - [ ] Agenten rapporterer fejl
  - [ ] Admin-override kan re-kre
  - [ ] Ingen halvfrdig instans

###  6. Yderligere 5 testkunder

- [ ] **Testkunde 6** - Fuldt flow
- [ ] **Testkunde 7** - Fuldt flow
- [ ] **Testkunde 8** - Fuldt flow
- [ ] **Testkunde 9** - Fuldt flow
- [ ] **Testkunde 10** - Fuldt flow

###  7. Suspension tests

- [ ] **Suspension test 1**
  - [ ] Betaling afvist
  - [ ] Dunning e-mail sendt
  - [ ] Tenant suspenderet (vhost deaktiveret, FPM pool stoppet)
  - [ ] Data bevaret

- [ ] **Suspension test 2**
  - [ ] Betaling afvist
  - [ ] Dunning e-mail sendt
  - [ ] Tenant suspenderet
  - [ ] Data bevaret

- [ ] **Unsuspension test**
  - [ ] Betaling genoptaget
  - [ ] Tenant unsuspenderet
  - [ ] Healthz check OK

###  8. Opsigelse tests

- [ ] **Opsigelse test 1**
  - [ ] Kontrakt opsagt
  - [ ] Undeploy krt
  - [ ] DB + filer fjernet pr. retention

- [ ] **Opsigelse test 2**
  - [ ] Kontrakt opsagt
  - [ ] Undeploy krt
  - [ ] DB + filer fjernet pr. retention

## Test Scenarier

### Scenarie 1: Normal Flow

```
1. Kunde registrerer sig via myaccount
2. SellYourSaaS opretter kontrakt
3. SellYourSaaS kalder beforedeploy
4. beforedeploy validerer systemet
5. SellYourSaaS kalder deploy
6. deploy opretter bruger, chroot, vhost, FPM pool, DB
7. SellYourSaaS kalder afterdeploy
8. afterdeploy skriver status
9. Kunde kan tilg sin instans
10. Faktura genereres
11. Betaling gennemfres
12. Kontrakt aktiveres
```

### Scenarie 2: Betaling fejler midt i deploy

```
1. Kunde registrerer sig
2. SellYourSaaS opretter kontrakt
3. SellYourSaaS kalder beforedeploy
4. beforedeploy validerer OK
5. SellYourSaaS kalder deploy
6. deploy starter
7. Betaling fejler midt i deploy
8. SellYourSaaS afbryder deploy
9. deploy script rydder op (sletter bruger, DB, etc.)
10. Kontrakt markeres som fejlet
11. Ingen faktura genereres
12. Fejl logges
```

### Scenarie 3: Deploy fejler (sources ikke tilgngelige)

```
1. Kunde registrerer sig
2. SellYourSaaS opretter kontrakt
3. SellYourSaaS kalder beforedeploy
4. beforedeploy validerer OK
5. SellYourSaaS kalder deploy
6. deploy prver at klone sources
7. Git repository ikke tilgngelig
8. deploy fejler
9. SellYourSaaS modtager fejl
10. Agenten rapporterer fejl
11. Admin-override kan re-kre
12. Ingen halvfrdig instans
```

### Scenarie 4: Suspension

```
1. Kunde har aktiv kontrakt
2. Betaling udlber
3. SellYourSaaS sender dunning e-mail
4. Betaling ikke modtaget
5. SellYourSaaS kalder suspend
6. suspend deaktiverer vhost og FPM pool
7. Tenant er suspended
8. Data bevaret
9. Kunde kan ikke tilg instansen
```

### Scenarie 5: Unsuspension

```
1. Tenant er suspended
2. Kunde betaler
3. SellYourSaaS modtager betaling
4. SellYourSaaS kalder unsuspend
5. unsuspend reaktiverer vhost og FPM pool
6. SellYourSaaS kalder afterunsuspend
7. afterunsuspend skriver status
8. Tenant er aktiv igen
9. Healthz check OK
```

### Scenarie 6: Opsigelse

```
1. Kunde opsiger kontrakt
2. SellYourSaaS kalder beforeundeploy (hvis konfigureret)
3. SellYourSaaS kalder undeploy
4. undeploy sletter bruger, chroot, vhost, FPM pool, DB
5. Kontrakt markeres som opsagt
6. Data slettes pr. retention policy
```

## Verificeringskommander

### Tjek system status

```bash
# Tjek Apache
sudo systemctl status apache2

# Tjek PHP-FPM
sudo systemctl status php8.2-fpm

# Tjek SellYourSaaS agent
sudo systemctl status sellyoursaas-remote-server

# Tjek logs
sudo tail -f /var/log/sellyoursaas/remote_server.log
```

### Tjek tenant status

```bash
# Tjek at bruger findes
id pim-test1

# Tjek at home directory findes
ls -la /home/pim-test1/

# Tjek at vhost findes
ls -la /etc/apache2/sites-enabled/ | grep pim-test1

# Tjek at FPM pool findes
ls -la /etc/php/8.2/fpm/pool.d/ | grep pim-test1

# Tjek at database findes
mysql -u root -p -e "SHOW DATABASES;" | grep pim_test1

# Test healthz
curl http://pim-test1.localhost/healthz
```

### Tjek SellYourSaaS status

```bash
# G til SellYourSaaS admin
# Tjek kontrakter
# Tjek instanser
# Tjek fakturaer
# Tjek betalinger
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

# Tjek at port 8080 lytter
sudo netstat -tulnp | grep 8080
```

### Tenant specifikke fejler

```bash
# Tjek tenant vhost syntax
sudo apache2ctl -S | grep pim-test1

# Tjek tenant FPM pool
sudo cat /etc/php/8.2/fpm/pool.d/pim-test1.conf

# Tjek tenant logs
sudo tail -f /var/log/apache2/pim-test1-error.log
sudo tail -f /var/log/php8.2-fpm-pim-test1.log
```

## Acceptance Criteria

### Minimum (for at g videre til fase 1b)

- [ ] 10 fulde gennemlb bestet
- [ ] 2 fejl-injektion tests bestet
- [ ] Ingen halvfrdige instanser
- [ ] Alle kontrakter i korrekt tilstand
- [ ] Alle fakturaer korrekte

### Fuldt (anbefalet)

- [ ] Alle 10+2 tests bestet
- [ ] Suspension tests bestet
- [ ] Unsuspension tests bestet
- [ ] Opsigelse tests bestet
- [ ] Healthz checks fungerer for alle tenants

## Nste Skridt

Nr fase 1a er frdig:
1. G videre til [Fase 1b](../Fase%201b%20Installationstjekliste.md) - K8s-grundintegration
2. Verificer at alle exit-kriterier er opfyldt
3. Dokumenter eventuelle issues

## Ressourcer

- [SellYourSaaS Dokumentation](https://github.com/DoliCloud/sellyoursaas)
- [Infrastructure/native/README.md](../../Infrastructure/native/README.md) - Native server setup
- [Packages/pim-native.yaml](../../Packages/pim-native.yaml) - Package definition
- [Scripts/native/](../../Scripts/native/) - Native deployment scripts
- [Dokumentation: Arkitektur.md](../../Docs/Arkitektur.md) - System arkitektur

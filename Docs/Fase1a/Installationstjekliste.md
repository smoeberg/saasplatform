# Fase 1a — Installationstjekliste: Dolibarr + SellYourSaaS (dev)

Formål: bevise forretningsflowet (registrering → deploy → betaling → suspension) med PIM som første native package. Exit: 10 gennemløb + 2 med fejl-injektion.

## 1. Master-server (Dolibarr + SellYourSaaS-modul)

- [ ] LAMP/LEMP-stack (PHP 8.2, MariaDB, Nginx/Apache + TLS)
- [ ] Dolibarr (nyeste stabile, 23.x) installeret
- [ ] SellYourSaaS-modul: `git clone https://github.com/DoliCloud/sellyoursaas` → `custom/sellyoursaas`
- [ ] Modul aktiveret; master-tilstand = "master (hosting)" sat
- [ ] HTTPS + gyldigt certifikat; cron-jobs for batch-fakturering aktiveret
- [ ] Stripe-konto (test-mode) koblet: `SELLYOURSAAS_STRIPE_*`-konstanter
- [ ] SEPA (GoCardless) koblet — eller udskudt til fase 2 (dokumenteres)

## 2. Native deployment-server

- [ ] Server oprettet i masteren (Remote server: FQDN, IP, port 8080)
- [ ] Remote launcher-agent installeret (`remote_server_launcher`), port 8080 + TLS
- [ ] SSH-adgang fra master til serveren oprettet; sudo-adgang til oprettelse af Unix-brugere
- [ ] Apache/PHP-FPM + chroot-ramme verifikeret (test-instans deployet manuelt)
- [ ] Blacklists/kvoter sat i SellYourSaaS-konfigurationen

## 3. PIM-package

- [ ] Package oprettet: `sources` (Git-URL), `config-templates`, `cron-templates`
- [ ] Service type Application + plan (pris, options, kvoter)
- [ ] DB-adgang: separat MariaDB-DB pr. instans (native-server eller fælles DB-server)
- [ ] Test-deploy: ny instans deployet via admin-override; `/healthz`-svar verificeret

## 4. Kundecenter + flow-test

- [ ] myaccount aktiveret (register.php, login, instans-oversigt)
- [ ] Testkunde registreret via web → instans provisioneret automatisk → faktura genereret
- [ ] Betaling gennemført (Stripe test-kort) → kontrakt aktiv
- [ ] Suspension: betaling afvist → dunning → suspend (instans låst, data bevaret)
- [ ] Opsigelse → undeploy → DB + filer fjernet pr. retention

## 5. Fejl-injektion (2 af 10 gennemløb)

- [ ] Betaling fejler midt i deploy → tenant-tilstand korrekt (ingen halvfærdig instans, ingen faktura, fejl logget)
- [ ] Deploy fejler (fx sources ikke tilgængelige) → agenten rapporterer fejl; admin-override kan re-køre

## Dev-instans

- [ ] Denne dev-instans kører altid nyeste SellYourSaaS (opdateres ved hver release) — brud opdages her først.

# Déploiement — kofidouhadji.com

Site vitrine statique de Kofi Douhadji, déployé via Docker + Nginx + Let's Encrypt.

---

## Architecture multi-sites

Ce projet est conçu pour coexister avec d'autres sites sur le **même VPS**.  
W-circle joue le rôle de **reverse proxy partagé** : il écoute sur les ports 80/443
et distribue le trafic vers chaque site selon le nom de domaine.

```
Internet → VPS (ports 80 / 443)
                  │
          ┌───────┴────────┐
          │  wcercle nginx  │  ← reverse proxy partagé
          └───────┬────────┘
                  │
       ┌──────────┼──────────┐
       ▼          ▼          ▼
  wcircle.com  kofidouhadji.com  futur-site.com
  (wcercle)    (vitrine)         (futur conteneur)
                  │
             wcercle_net  ← réseau Docker partagé
```

Les certificats SSL de **tous** les domaines sont gérés par le certbot de w-circle.

---

## Prérequis

| Élément | Détail |
|---|---|
| Serveur | Debian 11/12 ou Ubuntu 22.04+ |
| Accès | `root` ou `sudo` |
| DNS | `kofidouhadji.com` et `www.kofidouhadji.com` pointent vers l'IP du VPS |
| W-circle | Déployé et actif sur `/opt/wcercle` (mode coexistence) |

> **DNS obligatoire avant de lancer le script** — Let's Encrypt valide le domaine
> en HTTP. Si le DNS ne pointe pas encore vers le VPS, le certificat échouera.

---

## Fichiers du projet

```
vitrine/
├── Dockerfile                # Image nginx:alpine + fichiers statiques
├── docker-compose.yml        # Mode standalone (VPS sans autre site)
├── docker-compose.vps.yml    # Mode coexistence (w-circle actif)
├── deploy.sh                 # Script de déploiement (détecte le mode auto)
├── vitrine.html              # Page principale → /usr/share/nginx/html/index.html
├── img/                      # Assets images
└── docs/
    ├── nginx-http.conf       # Config nginx phase 1 (HTTP, challenge ACME)
    ├── nginx-https.conf      # Config nginx phase 2 (HTTPS, template DOMAIN)
    └── nginx-active.conf     # Config active générée par deploy.sh (ignorée par git)
```

---

## Déploiement

### 1. Copier le projet sur le VPS

```bash
scp -r ./vitrine root@<IP_VPS>:/tmp/vitrine
```

Ou via git :

```bash
ssh root@<IP_VPS>
git clone https://github.com/cendrinozus/vitrine.git /tmp/vitrine
```

### 2. Lancer le script

```bash
ssh root@<IP_VPS>
sudo bash /tmp/vitrine/deploy.sh
```

Le script demande uniquement l'**email Let's Encrypt** (pour les alertes d'expiration).  
Il détecte automatiquement si w-circle est actif et choisit le bon mode.

---

## Mode coexistence (w-circle actif) — déroulement

Aucune coupure de service sur w-circle.

| Étape | Action |
|---|---|
| 1 | Détecte le conteneur `wcercle` → active le mode coexistence |
| 2 | Build de l'image Docker vitrine |
| 3 | Obtient le cert SSL via **le certbot de w-circle** (port 80 reste ouvert) |
| 4 | Démarre vitrine **sans port binding** sur `wcercle_net` |
| 5 | Injecte les server blocks `kofidouhadji.com` dans `/opt/wcercle/docs/nginx-active.conf` |
| 6 | Valide la config (`nginx -t`) puis recharge w-circle nginx |

Le certificat est stocké dans le volume `certbot_certs` de w-circle et renouvelé
automatiquement par son certbot (toutes les 12h).

---

## Mode standalone (aucun autre site) — déroulement

Pour un VPS vierge ou si w-circle n'est pas actif.

| Phase | Action |
|---|---|
| 1 — HTTP | Nginx démarre sur le port 80, sert le challenge ACME |
| 2 — Cert | Certbot obtient le certificat pour `kofidouhadji.com` et `www.kofidouhadji.com` |
| 3 — HTTPS | Config nginx mise à jour, HTTPS activé, `www` redirige vers l'apex |
| 4 — Renouvellement | Certbot daemon + cron hôte pour le reload nginx post-renouvellement |

---

## Commandes utiles

### Mode coexistence

```bash
# Logs du conteneur vitrine
docker compose -f /opt/vitrine/docker-compose.vps.yml logs -f web

# Redémarrer vitrine
docker compose -f /opt/vitrine/docker-compose.vps.yml restart web

# Arrêter vitrine
docker compose -f /opt/vitrine/docker-compose.vps.yml down

# Mettre à jour le site (nouveau build)
bash /opt/vitrine/deploy.sh
```

### Mode standalone

```bash
# Logs Nginx
docker compose -f /opt/vitrine/docker-compose.yml logs -f web

# Logs Certbot
docker compose -f /opt/vitrine/docker-compose.yml logs -f certbot

# Arrêter
docker compose -f /opt/vitrine/docker-compose.yml down

# Redéployer
bash /opt/vitrine/deploy.sh
```

### Vérifier les certificats SSL

```bash
# Depuis w-circle (mode coexistence)
cd /opt/wcercle && docker compose exec certbot certbot certificates

# Forcer un renouvellement manuel
cd /opt/wcercle && docker compose exec certbot certbot renew --force-renewal
```

---

## Ajouter un nouveau site plus tard

Chaque nouveau site suit le même schéma que vitrine. Sur le VPS :

```bash
# 1. Déployer le conteneur sans port binding sur wcercle_net
docker compose -f /opt/nouveau-site/docker-compose.vps.yml up -d

# 2. Obtenir le cert via w-circle
cd /opt/wcercle && docker compose run --rm certbot certbot certonly \
    --webroot --webroot-path /var/www/certbot \
    --email <email> --agree-tos --no-eff-email \
    -d nouveau-site.com -d www.nouveau-site.com

# 3. Injecter les server blocks dans w-circle nginx
# (ajouter à /opt/wcercle/docs/nginx-active.conf)

# 4. Recharger w-circle nginx
cd /opt/wcercle && docker compose exec web nginx -t && docker compose exec web nginx -s reload
```

---

## Résolution de problèmes

### Le certificat échoue

- Vérifier que le DNS est propagé : `dig kofidouhadji.com` doit retourner l'IP du VPS
- Vérifier que le port 80 est ouvert dans le firewall : `ufw allow 80`

### Nginx ne démarre pas après injection des server blocks

```bash
# Tester la config avant de recharger
cd /opt/wcercle && docker compose exec web nginx -t

# Voir les erreurs détaillées
cd /opt/wcercle && docker compose logs web
```

### Le conteneur vitrine est inaccessible depuis w-circle nginx

```bash
# Vérifier que vitrine est bien sur wcercle_net
docker network inspect wcercle_net | grep vitrine

# Vérifier que le conteneur tourne
docker ps | grep vitrine
```

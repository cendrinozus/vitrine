#!/bin/bash
# deploy.sh — kofidouhadji.com sur Debian + Docker
#
# Deux modes détectés automatiquement :
#
#   COEXISTENCE  — w-circle tourne déjà sur le VPS (cas normal, multi-sites)
#     · Zéro downtime : w-circle reste actif pendant tout le déploiement
#     · Certbot de w-circle obtient le cert kofidouhadji.com via le port 80 de w-circle
#     · Vitrine démarre sans port binding (réseau interne wcercle_net)
#     · Les server blocks kofidouhadji.com sont injectés dans le nginx de w-circle
#     · w-circle nginx fait le proxy : kofidouhadji.com → conteneur vitrine
#
#   STANDALONE   — w-circle absent (premier site sur VPS vierge)
#     · Vitrine prend les ports 80/443 directement
#     · Son propre certbot gère le cert
#
# Usage: sudo bash deploy.sh

set -e
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()    { echo -e "${GREEN}[INFO]${NC}  $1"; }
step()    { echo -e "${CYAN}[STEP]${NC}  $1"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $1"; }
error()   { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }
section() { echo -e "\n${CYAN}══════════════════════════════════════════${NC}"; echo -e "${CYAN}  $1${NC}"; echo -e "${CYAN}══════════════════════════════════════════${NC}"; }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_DIR="/opt/vitrine"
WCERCLE_DIR="/opt/wcercle"
DOMAIN="kofidouhadji.com"
EMAIL=""
WCERCLE_RUNNING=false

# ── Vérifications système ────────────────────────────────────────────────────
if ! command -v apt &>/dev/null; then error "Ce script requiert un système Debian/Ubuntu"; fi
if [[ $EUID -ne 0 ]]; then error "Exécuter en root : sudo bash deploy.sh"; fi

echo ""
echo -e "${GREEN}╔══════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║   Déploiement — kofidouhadji.com             ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════╝${NC}"
echo ""

# ── Détection de w-circle ────────────────────────────────────────────────────
if docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^wcercle$'; then
    WCERCLE_RUNNING=true
    info "w-circle détecté et actif → mode COEXISTENCE (zéro downtime)"
else
    warn "w-circle non détecté → mode STANDALONE"
fi

echo ""
read -rp "Email Let's Encrypt (notifications d'expiration) : " EMAIL
[[ -z "$EMAIL" ]] && error "Email requis"

# ── Installation Docker ──────────────────────────────────────────────────────
section "Installation Docker"
if ! command -v docker &>/dev/null; then
    info "Installation de Docker..."
    apt update -qq
    apt install -y -qq ca-certificates curl gnupg
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/debian/gpg \
        | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
        https://download.docker.com/linux/debian $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
        > /etc/apt/sources.list.d/docker.list
    apt update -qq
    apt install -y -qq docker-ce docker-ce-cli containerd.io docker-compose-plugin
    systemctl enable --now docker
    info "Docker installé ✓"
else
    info "Docker déjà présent : $(docker --version)"
fi

# ── Copie du projet ──────────────────────────────────────────────────────────
section "Copie des fichiers"
info "Destination : $APP_DIR"
if [ "$(realpath "$SCRIPT_DIR")" = "$(realpath "$APP_DIR")" ]; then
    warn "Script lancé depuis $APP_DIR — recréation sur place..."
    TMP_DIR=$(mktemp -d)
    cp -r "$SCRIPT_DIR/." "$TMP_DIR/"
    cd /tmp
    rm -rf "$APP_DIR"
    mkdir -p "$APP_DIR"
    cp -r "$TMP_DIR/." "$APP_DIR/"
    rm -rf "$TMP_DIR"
else
    mkdir -p "$APP_DIR"
    cp -r "$SCRIPT_DIR/." "$APP_DIR/"
fi
cd "$APP_DIR"
info "Fichiers copiés ✓"

# ════════════════════════════════════════════════════════════════════════════
#  MODE COEXISTENCE — w-circle tourne en parallèle
#  Architecture : w-circle nginx = reverse proxy partagé pour tous les sites
# ════════════════════════════════════════════════════════════════════════════
if $WCERCLE_RUNNING; then

    section "Mode coexistence — w-circle nginx comme reverse proxy"

    # ── Build de l'image vitrine ─────────────────────────────────────────────
    step "Build de l'image Docker vitrine..."
    docker compose -f docker-compose.vps.yml build --quiet
    info "Image construite ✓"

    # ── Certificat SSL via w-circle ──────────────────────────────────────────
    # w-circle nginx sert déjà /.well-known/acme-challenge/ sur le port 80.
    # Quand kofidouhadji.com arrive sur ce port, Nginx l'accepte via le bloc
    # default (premier server_name) et sert le challenge depuis son volume
    # certbot_webroot — aucun arrêt de service n'est nécessaire.
    step "Obtention du certificat Let's Encrypt via w-circle (sans coupure)..."
    (cd "$WCERCLE_DIR" && docker compose run --rm certbot certbot certonly \
        --webroot \
        --webroot-path /var/www/certbot \
        --email "$EMAIL" \
        --agree-tos \
        --no-eff-email \
        -d "$DOMAIN" \
        -d "www.$DOMAIN")
    info "Certificat obtenu dans le volume certbot_certs de w-circle ✓"

    # ── Démarrage de vitrine (réseau interne, sans ports) ────────────────────
    step "Démarrage du conteneur vitrine sur wcercle_net..."
    docker compose -f docker-compose.vps.yml up -d web
    sleep 2
    docker compose -f docker-compose.vps.yml ps | grep -q "Up" \
        || error "Le conteneur vitrine n'a pas démarré. Vérifiez : docker compose -f $APP_DIR/docker-compose.vps.yml logs"
    info "Conteneur vitrine actif ✓"

    # ── Injection des server blocks dans w-circle nginx ──────────────────────
    WCERCLE_NGINX="$WCERCLE_DIR/docs/nginx-active.conf"
    if ! grep -q "kofidouhadji.com" "$WCERCLE_NGINX"; then
        step "Injection des server blocks kofidouhadji.com dans w-circle nginx..."
        cat >> "$WCERCLE_NGINX" << NGINX_BLOCK

# ── kofidouhadji.com — ajouté par /opt/vitrine/deploy.sh ────────────────────
# Redirection HTTP → HTTPS (apex + www)
server {
    listen 80;
    server_name $DOMAIN www.$DOMAIN;
    location /.well-known/acme-challenge/ { root /var/www/certbot; }
    location / { return 301 https://$DOMAIN\$request_uri; }
}
# Redirection www → apex en HTTPS
server {
    listen 443 ssl;
    http2 on;
    server_name www.$DOMAIN;
    ssl_certificate     /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;
    return 301 https://$DOMAIN\$request_uri;
}
# HTTPS — proxy vers le conteneur vitrine
server {
    listen 443 ssl;
    http2 on;
    server_name $DOMAIN;
    ssl_certificate     /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 1d;
    # DNS Docker interne — Nginx démarre même si vitrine n'est pas encore lancé
    resolver 127.0.0.11 valid=10s ipv6=off;
    location / {
        set \$upstream http://vitrine;
        proxy_pass         \$upstream;
        proxy_http_version 1.1;
        proxy_set_header Host              \$host;
        proxy_set_header X-Real-IP         \$remote_addr;
        proxy_set_header X-Forwarded-For   \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_read_timeout 30s;
        proxy_connect_timeout 5s;
    }
    server_tokens off;
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-XSS-Protection "1; mode=block" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;
    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
    access_log /dev/stdout;
    error_log  /dev/stderr warn;
}
# ────────────────────────────────────────────────────────────────────────────
NGINX_BLOCK
        info "Server blocks injectés ✓"
    else
        warn "Server blocks kofidouhadji.com déjà présents dans w-circle nginx — ignoré"
    fi

    # ── Reload de w-circle nginx ─────────────────────────────────────────────
    step "Reload de w-circle nginx..."
    (cd "$WCERCLE_DIR" && docker compose exec web nginx -t) \
        || error "Config nginx invalide — vérifiez $WCERCLE_NGINX"
    (cd "$WCERCLE_DIR" && docker compose exec web nginx -s reload)
    info "w-circle nginx rechargé ✓"

    # ── Résumé ───────────────────────────────────────────────────────────────
    section "Déploiement terminé — mode coexistence"
    info "Site         : https://$DOMAIN"
    info "Proxy        : w-circle nginx → conteneur vitrine (wcercle_net)"
    info "Cert         : volume certbot_certs de w-circle (renouvellement auto)"
    info ""
    warn "Ajouter d'autres sites plus tard : même schéma"
    warn "  1. Déployer le conteneur sans ports sur wcercle_net"
    warn "  2. Obtenir le cert via w-circle certbot"
    warn "  3. Injecter les server blocks dans $WCERCLE_NGINX"
    warn "  4. Recharger w-circle nginx"
    info ""
    warn "Commandes utiles :"
    warn "  Logs vitrine  : docker compose -f $APP_DIR/docker-compose.vps.yml logs -f web"
    warn "  Redémarrer    : docker compose -f $APP_DIR/docker-compose.vps.yml restart web"
    warn "  Arrêter       : docker compose -f $APP_DIR/docker-compose.vps.yml down"
    warn "  Redéployer    : bash $APP_DIR/deploy.sh"

# ════════════════════════════════════════════════════════════════════════════
#  MODE STANDALONE — w-circle absent (VPS vierge ou premier site)
# ════════════════════════════════════════════════════════════════════════════
else

    section "Mode standalone"

    # Réseau Docker
    if ! docker network ls --format '{{.Name}}' | grep -q '^vitrine_net$'; then
        info "Création du réseau Docker vitrine_net..."
        docker network create vitrine_net
        info "Réseau vitrine_net créé ✓"
    fi

    # Phase 1 — HTTP
    step "Phase 1 — Démarrage Nginx HTTP (port 80)..."
    cp docs/nginx-http.conf docs/nginx-active.conf
    docker compose build --quiet
    docker compose up -d web
    sleep 3
    docker compose ps | grep -q "Up" \
        || error "Nginx n'a pas démarré. Vérifiez : docker compose logs web"
    info "Nginx HTTP actif ✓"

    # Phase 2 — Certificat
    step "Phase 2 — Obtention du certificat Let's Encrypt..."
    docker compose pull certbot
    docker compose run --rm certbot certbot certonly \
        --webroot --webroot-path /var/www/certbot \
        --email "$EMAIL" --agree-tos --no-eff-email \
        -d "$DOMAIN" -d "www.$DOMAIN"
    info "Certificat obtenu ✓"

    # Phase 3 — HTTPS
    step "Phase 3 — Activation HTTPS..."
    sed "s/DOMAIN/$DOMAIN/g" docs/nginx-https.conf > docs/nginx-active.conf
    docker compose exec web nginx -s reload
    info "Nginx HTTPS actif ✓"

    # Phase 4 — Renouvellement automatique
    step "Phase 4 — Renouvellement automatique..."
    docker compose up -d certbot
    CRON_JOB="0 4 * * * cd $APP_DIR && docker compose exec web nginx -s reload >> /var/log/vitrine-ssl-reload.log 2>&1"
    (crontab -l 2>/dev/null | grep -qF "vitrine-ssl-reload") || \
        (crontab -l 2>/dev/null; echo "$CRON_JOB") | crontab -
    info "Cron SSL configuré ✓"

    section "Déploiement terminé — mode standalone"
    info "Site     : https://$DOMAIN"
    docker compose ps
    info ""
    warn "Commandes utiles (depuis $APP_DIR) :"
    warn "  Logs Nginx   : docker compose logs -f web"
    warn "  Logs Certbot : docker compose logs -f certbot"
    warn "  Arrêter      : docker compose down"
    warn "  Redéployer   : bash $APP_DIR/deploy.sh"

fi

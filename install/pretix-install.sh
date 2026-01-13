#!/usr/bin/env bash
# Copyright (c) 2021-2026 community-scripts ORG
# Author: YourGitHubUsername
# License: MIT | https://github.com/community-scripts/ProxmoxVE/raw/main/LICENSE
# Source: https://pretix.eu/about/en/

# --- DEBUG MODE ON ---
set -x
# ---------------------

source /dev/stdin <<<"$FUNCTIONS_FILE_PATH"
color
verb_ip6
catch_errors
setting_up_container
network_check
update_os

# --- Defaults ---
INSTANCE_NAME="${INSTANCE_NAME:-Pretix}"
CURRENCY="${CURRENCY:-EUR}"
BIND_ADDR="127.0.0.1:8345"

msg_info "Installing Dependencies (VERBOSE)"
# Postfix pre-configuration
echo "postfix postfix/main_mailer_type string 'Internet Site'" | debconf-set-selections
echo "postfix postfix/mailname string $(hostname)" | debconf-set-selections

# REMOVED >/dev/null to see errors
$STD apt-get install -y \
  git \
  build-essential \
  cron \
  gettext \
  python3 \
  python3-dev \
  python3-venv \
  python3-pip \
  libxml2-dev \
  libxslt1-dev \
  libffi-dev \
  zlib1g-dev \
  libssl-dev \
  libpq-dev \
  libjpeg-dev \
  libopenjp2-7-dev \
  redis-server \
  postfix \
  nginx \
  ufw \
  openssl
msg_ok "Installed Dependencies"

msg_info "Installing Node.js"
NODE_VERSION="22" setup_nodejs
msg_ok "Installed Node.js"

msg_info "Installing PostgreSQL"
setup_postgresql
msg_ok "Installed PostgreSQL"

msg_info "Creating pretix Unix User"
if ! id -u pretix >/dev/null 2>&1; then
  adduser --gecos "" --disabled-password --home /var/pretix pretix
fi
msg_ok "Created pretix Unix User"

msg_info "Creating Database"
# REMOVED >/dev/null to see errors
sudo -u postgres createuser pretix || true
sudo -u postgres createdb -O pretix -E UTF8 pretix || true
msg_ok "Created Database"

msg_info "Writing Pretix Configuration"
mkdir -p /etc/pretix
touch /etc/pretix/pretix.cfg
chown -R pretix:pretix /etc/pretix
chmod 0600 /etc/pretix/pretix.cfg

import_local_ip

cat >/etc/pretix/pretix.cfg <<EOF
[pretix]
instance_name=${INSTANCE_NAME}
url=https://${LOCAL_IP}
currency=${CURRENCY}
datadir=/var/pretix/data
trust_x_forwarded_for=on
trust_x_forwarded_proto=on

[database]
backend=postgresql
name=pretix
user=pretix
password=
host=

[mail]
from=tickets@localhost
host=127.0.0.1

[redis]
location=redis://127.0.0.1/0
sessions=true

[celery]
backend=redis://127.0.0.1/1
broker=redis://127.0.0.1/2
EOF
msg_ok "Wrote Pretix Configuration"

msg_info "Creating Virtualenv"
sudo -u pretix -s bash -lc "python3 -m venv /var/pretix/venv"
msg_ok "Created Virtualenv"

msg_info "Installing Pretix (PyPI) + Gunicorn (VERBOSE)"
# REMOVED >/dev/null to see compilation errors
sudo -u pretix -s bash -lc "source /var/pretix/venv/bin/activate && pip3 install -U pip setuptools wheel"
sudo -u pretix -s bash -lc "source /var/pretix/venv/bin/activate && pip3 install pretix gunicorn"
msg_ok "Installed Pretix"

msg_info "Preparing Data Directories"
sudo -u pretix -s bash -lc "mkdir -p /var/pretix/data/media"
chmod +x /var/pretix
msg_ok "Prepared Data Directories"

msg_info "Initializing Database & Assets"
sudo -u pretix -s bash -lc "source /var/pretix/venv/bin/activate && cd /var/pretix && python -m pretix migrate"
sudo -u pretix -s bash -lc "source /var/pretix/venv/bin/activate && cd /var/pretix && python -m pretix rebuild"
msg_ok "Initialized Pretix"

msg_info "Generating Self-Signed SSL Certificate"
mkdir -p /etc/nginx/ssl
openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
  -keyout /etc/nginx/ssl/pretix.key \
  -out /etc/nginx/ssl/pretix.crt \
  -subj "/C=DE/ST=State/L=City/O=Pretix/OU=IT/CN=${LOCAL_IP}"
msg_ok "Generated SSL Certificate"

msg_info "Configuring Nginx"
rm -f /etc/nginx/sites-enabled/default

cat >/etc/nginx/sites-available/pretix <<EOF
server {
    listen 80 default_server;
    listen [::]:80 ipv6only=on default_server;
    server_name _;
    location / {
        return 301 https://\$host\$request_uri;
    }
}
server {
    listen 443 ssl default_server;
    listen [::]:443 ipv6only=on ssl default_server;
    server_name _;

    ssl_certificate /etc/nginx/ssl/pretix.crt;
    ssl_certificate_key /etc/nginx/ssl/pretix.key;

    add_header Referrer-Policy same-origin;
    add_header X-Content-Type-Options nosniff;

    location / {
        proxy_pass http://127.0.0.1:8345;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_set_header Host \$http_host;
    }

    location /media/ {
        alias /var/pretix/data/media/;
        expires 7d;
        access_log off;
    }

    location ^~ /media/cachedfiles {
        deny all;
        return 404;
    }
    location ^~ /media/invoices {
        deny all;
        return 404;
    }

    location /static/staticfiles.json {
        deny all;
        return 404;
    }
    location /static/CACHE/manifest.json {
        deny all;
        return 404;
    }
    
    location /static/ {
        alias /var/pretix/venv/lib/python3.*/site-packages/pretix/static.dist/;
        access_log off;
        expires 365d;
        add_header Cache-Control "public";
    }
}
EOF

ln -s /etc/nginx/sites-available/pretix /etc/nginx/sites-enabled/ || true

# DEBUG: Check Nginx Config
msg_info "Testing Nginx Configuration"
nginx -t
if [ $? -ne 0 ]; then
    msg_error "Nginx configuration failed!"
    exit 1
fi

systemctl restart nginx
msg_ok "Configured Nginx"

msg_info "Creating systemd Services"
cat >/etc/systemd/system/pretix-web.service <<EOF
[Unit]
Description=pretix web service
After=network.target postgresql.service redis-server.service

[Service]
User=pretix
Group=pretix
Environment="VIRTUAL_ENV=/var/pretix/venv"
Environment="PATH=/var/pretix/venv/bin:/usr/local/bin:/usr/bin:/bin"
ExecStart=/var/pretix/venv/bin/gunicorn pretix.wsgi \\
  --name pretix --workers 3 \\
  --max-requests 1200 --max-requests-jitter 50 \\
  --log-level=info --bind=${BIND_ADDR}
WorkingDirectory=/var/pretix
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

cat >/etc/systemd/system/pretix-worker.service <<EOF
[Unit]
Description=pretix background worker
After=network.target redis-server.service

[Service]
User=pretix
Group=pretix
Environment="VIRTUAL_ENV=/var/pretix/venv"
Environment="PATH=/var/pretix/venv/bin:/usr/local/bin:/usr/bin:/bin"
ExecStart=/var/pretix/venv/bin/celery -A pretix.celery_app worker -l info
WorkingDirectory=/var/pretix
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
if ! systemctl enable --now pretix-web pretix-worker; then
    msg_error "Failed to start services. Checking logs:"
    journalctl -xe | tail -n 50
    exit 1
fi
msg_ok "Created & Started systemd Services"

msg_info "Setting up Cron (runperiodic)"
cat >/etc/cron.d/pretix-runperiodic <<'EOF'
SHELL=/bin/bash
PATH=/var/pretix/venv/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
*/15 * * * * pretix cd /var/pretix && python -m pretix runperiodic >/dev/null 2>&1
EOF
chmod 0644 /etc/cron.d/pretix-runperiodic
msg_ok "Cron Configured"

msg_info "Configuring Firewall"
ufw allow 22/tcp
ufw allow 80/tcp
ufw allow 443/tcp
ufw --force enable
msg_ok "Firewall Configured"

msg_info "Recording Installed Version"
# This redirection was fixed in the previous step, ensuring it is correct here
sudo -u pretix -s bash -lc "source /var/pretix/venv/bin/activate && python -c 'import pretix; print(pretix.__version__)'" >/opt/pretix_version.txt
msg_ok "Recorded Installed Version"

motd_ssh
customize
cleanup_lxc
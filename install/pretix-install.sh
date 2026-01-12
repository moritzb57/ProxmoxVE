#!/usr/bin/env bash
# Copyright (c) 2021-2026 community-scripts ORG
# Author: YourGitHubUsername
# License: MIT | https://github.com/community-scripts/ProxmoxVE/raw/main/LICENSE
# Source: https://pretix.eu/about/en/

source /dev/stdin <<<"$FUNCTIONS_FILE_PATH"
color
verb_ip6
catch_errors
setting_up_container
network_check
update_os

# --- Defaults (can be overridden via container env if you extend later) ---
INSTANCE_NAME="${INSTANCE_NAME:-Pretix}"
CURRENCY="${CURRENCY:-EUR}"
BIND_ADDR="${BIND_ADDR:-0.0.0.0:8345}"

msg_info "Installing Dependencies"
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
  postfix
msg_ok "Installed Dependencies"

msg_info "Installing Node.js"
NODE_VERSION="22" setup_nodejs
msg_ok "Installed Node.js"

msg_info "Installing PostgreSQL"
setup_postgresql
msg_ok "Installed PostgreSQL"

msg_info "Creating pretix Unix User"
if ! id -u pretix >/dev/null 2>&1; then
  adduser --gecos "" --disabled-password --home /var/pretix pretix >/dev/null
fi
msg_ok "Created pretix Unix User"

msg_info "Creating Database"
# Debian/PG defaults allow peer auth on local socket; we keep it simple (no DB password needed)
sudo -u postgres createuser pretix >/dev/null 2>&1 || true
sudo -u postgres createdb -O pretix pretix >/dev/null 2>&1 || true
msg_ok "Created Database"

msg_info "Writing Pretix Configuration"
mkdir -p /etc/pretix
touch /etc/pretix/pretix.cfg
chown -R pretix:pretix /etc/pretix
chmod 0600 /etc/pretix/pretix.cfg

# Determine URL based on container IP (HTTP, since no reverse proxy/HTTPS here)
import_local_ip

cat >/etc/pretix/pretix.cfg <<EOF
[pretix]
instance_name=${INSTANCE_NAME}
url=http://${LOCAL_IP}:8345
currency=${CURRENCY}
datadir=/var/pretix/data
trust_x_forwarded_for=off
trust_x_forwarded_proto=off

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

msg_info "Installing Pretix (PyPI) + Gunicorn"
sudo -u pretix -s bash -lc "source /var/pretix/venv/bin/activate && pip3 install -U pip setuptools wheel >/dev/null"
sudo -u pretix -s bash -lc "source /var/pretix/venv/bin/activate && pip3 install pretix gunicorn >/dev/null"
msg_ok "Installed Pretix"

msg_info "Preparing Data Directories"
sudo -u pretix -s bash -lc "mkdir -p /var/pretix/data/media"
chmod +x /var/pretix
msg_ok "Prepared Data Directories"

msg_info "Initializing Database & Assets"
sudo -u pretix -s bash -lc "source /var/pretix/venv/bin/activate && cd /var/pretix && python -m pretix migrate >/dev/null"
sudo -u pretix -s bash -lc "source /var/pretix/venv/bin/activate && cd /var/pretix && python -m pretix rebuild >/dev/null"
msg_ok "Initialized Pretix"

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
systemctl enable --now pretix-web pretix-worker >/dev/null
msg_ok "Created & Started systemd Services"

msg_info "Setting up Cron (runperiodic)"
cat >/etc/cron.d/pretix-runperiodic <<'EOF'
SHELL=/bin/bash
PATH=/var/pretix/venv/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
*/15 * * * * pretix cd /var/pretix && python -m pretix runperiodic >/dev/null 2>&1
EOF
chmod 0644 /etc/cron.d/pretix-runperiodic
msg_ok "Cron Configured"

msg_info "Recording Installed Version"
sudo -u pretix -s bash -lc "source /var/pretix/venv/bin/activate && python -c 'import pretix; print(pretix.__version__)' >/opt/pretix_version.txt"
msg_ok "Recorded Installed Version"

motd_ssh
customize
cleanup_lxc

#!/usr/bin/env bash
source <(curl -fsSL https://raw.githubusercontent.com/moritzb57/ProxmoxVE/feat/add-pretix/misc/build.func)
# Copyright (c) 2021-2026 community-scripts ORG
# Author: YourGitHubUsername
# License: MIT | https://github.com/community-scripts/ProxmoxVE/raw/main/LICENSE
# Source: https://pretix.eu/about/en/

# App Default Values
APP="Pretix"
var_tags="${var_tags:-tickets;events}"
var_cpu="${var_cpu:-2}"
var_ram="${var_ram:-4096}"
var_disk="${var_disk:-20}"
var_os="${var_os:-debian}"
var_version="${var_version:-12}"
var_unprivileged="${var_unprivileged:-1}"

header_info "$APP"
variables
color
catch_errors

function update_script() {
  header_info
  check_container_storage
  check_container_resources

  if ! pct exec "$CTID" -- test -f /opt/pretix_version.txt; then
    msg_error "No ${APP} Installation Found!"
    exit 1
  fi

  msg_info "Updating OS (Container)"
  pct exec "$CTID" -- bash -lc "apt-get update >/dev/null && apt-get -y upgrade >/dev/null"
  msg_ok "Updated OS (Container)"

  msg_info "Stopping Pretix Services"
  pct exec "$CTID" -- bash -lc "systemctl stop pretix-web pretix-worker"
  msg_ok "Stopped Pretix Services"

  msg_info "Upgrading Pretix (pip)"
  pct exec "$CTID" -- bash -lc "source /var/pretix/venv/bin/activate && pip3 install -U --upgrade-strategy eager pretix gunicorn >/dev/null"
  msg_ok "Upgraded Pretix"

  msg_info "Running Pretix Maintenance"
  pct exec "$CTID" -- bash -lc "source /var/pretix/venv/bin/activate && cd /var/pretix && python -m pretix migrate >/dev/null"
  pct exec "$CTID" -- bash -lc "source /var/pretix/venv/bin/activate && cd /var/pretix && python -m pretix rebuild >/dev/null"
  pct exec "$CTID" -- bash -lc "source /var/pretix/venv/bin/activate && cd /var/pretix && python -m pretix updateassets >/dev/null || true"
  msg_ok "Pretix Maintenance Done"

  msg_info "Starting Pretix Services"
  pct exec "$CTID" -- bash -lc "systemctl start pretix-web pretix-worker"
  msg_ok "Started Pretix Services"

  msg_info "Recording Version"
  pct exec "$CTID" -- bash -lc "source /var/pretix/venv/bin/activate && python -c 'import pretix; print(pretix.__version__)' >/opt/pretix_version.txt"
  msg_ok "Recorded Version"

  msg_ok "Updated successfully!"
  exit
}

start
build_container

msg_info "Running Pretix install script inside container"
pct exec "$CTID" -- bash -c "
  curl -fsSL https://raw.githubusercontent.com/moritzb57/ProxmoxVE/feat/add-pretix/install/pretix-install.sh | bash
"
msg_ok "Pretix install script executed"

description

msg_ok "Completed successfully!"


msg_ok "Completed successfully!\n"
echo -e "${CREATING}${GN}${APP} setup has been successfully initialized!${CL}"
echo -e "${INFO}${YW} Access it here (HTTP, no reverse proxy):${CL}"
echo -e "${TAB}${GATEWAY}${BGN}http://${IP}:8345/control/${CL}"
echo -e "${INFO}${YW} Default login (change immediately):${CL}"
echo -e "${TAB}${BGN}admin@localhost${CL} / ${BGN}admin${CL}"
echo -e "${INFO}${YW} Note: HTTPS is strongly recommended for production.${CL}"

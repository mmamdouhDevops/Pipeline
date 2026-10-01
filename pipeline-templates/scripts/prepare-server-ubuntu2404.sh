#!/usr/bin/env bash
# =============================================================================================
#  prepare-server-ubuntu2404.sh – prepare an Ubuntu 24.04 LTS server for the pipeline (run as root).
#
#    sudo scripts/prepare-server-ubuntu2404.sh --roles web,api,integration,db,ci --env test \
#         [--deploy-key "ssh-ed25519 AAAA… github-deploy"] [--server-names a.example.com,b.example.com] \
#         [--tls-cert /path/fullchain.pem --tls-key /path/privkey.pem] [--db-allow-from 10.0.0.0/16] \
#         [--sa-password '…'] [--sql-edition Developer|Express|Standard|Enterprise]
#
#  Roles
#    web          Nginx (static Angular sites)                     ports 80/443
#    api          Nginx + ASP.NET Core 10 runtime (ABP backend)    ports 80/443
#    integration  Nginx + ASP.NET Core 10 runtime (integration API)
#    db           SQL Server 2025 + backup dir                     port 1433 (only from --db-allow-from)
#    ai           Nginx + Python 3 venv (uvicorn); GPU drivers are NOT installed (see docs/RUNBOOK.md)
#    ci           CI/deploy runner toolchain: .NET 10 SDK, Node 24, Docker (ZAP/DAST), sqlcmd, EF tools
#
#  Every role gets: base packages, chrony, unattended-upgrades, ufw, the 'deploy' user (SSH target of the
#  runner, may run ONLY /usr/local/sbin/app-deploy with sudo), and app-deploy itself.
#  Single-VM test setup (my device):  --roles web,api,integration,db,ci --env test
#  Alibaba Cloud: one ECS per role (or combine), plus a runner ECS with --roles ci in the same VPC.
# =============================================================================================
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROLES=""; ENVIRONMENT=""; DEPLOY_KEY=""; SERVER_NAMES=""; TLS_CERT_SRC=""; TLS_KEY_SRC=""
DB_ALLOW_FROM=""; SA_PASSWORD="${MSSQL_SA_PASSWORD:-}"; SQL_EDITION="Developer"; DEPLOY_USER=deploy
while [[ $# -gt 0 ]]; do
  case "$1" in
    --roles) ROLES="$2"; shift 2 ;;
    --env) ENVIRONMENT="$2"; shift 2 ;;
    --deploy-key) DEPLOY_KEY="$2"; shift 2 ;;
    --deploy-user) DEPLOY_USER="$2"; shift 2 ;;
    --server-names) SERVER_NAMES="$2"; shift 2 ;;
    --tls-cert) TLS_CERT_SRC="$2"; shift 2 ;;
    --tls-key) TLS_KEY_SRC="$2"; shift 2 ;;
    --db-allow-from) DB_ALLOW_FROM="$2"; shift 2 ;;
    --sa-password) SA_PASSWORD="$2"; shift 2 ;;
    --sql-edition) SQL_EDITION="$2"; shift 2 ;;
    -h|--help) sed -n '2,22p' "$0" | sed 's/^#  \{0,1\}//'; exit 0 ;;
    *) echo "unknown option $1"; exit 1 ;;
  esac
done
[[ $EUID -eq 0 ]] || { echo "run with sudo"; exit 1; }
[[ -n "$ROLES" && -n "$ENVIRONMENT" ]] || { echo "--roles and --env are required (see --help)"; exit 1; }
[[ "$ENVIRONMENT" =~ ^(test|staging|production)$ ]] || { echo "--env must be test|staging|production"; exit 1; }
. /etc/os-release
UNSUPPORTED=0
if [[ "$ID" != "ubuntu" || "$VERSION_ID" != "24.04" ]]; then
  if [[ "${ALLOW_UNSUPPORTED:-0}" == "1" ]]; then
    UNSUPPORTED=1; echo "WARNING: $PRETTY_NAME is not Ubuntu 24.04 – continuing (ALLOW_UNSUPPORTED=1); SQL Server install is skipped"
  else
    echo "Ubuntu 24.04 LTS required (found $PRETTY_NAME). Existing test VM on another release: ALLOW_UNSUPPORTED=1"; exit 1
  fi
fi

has() { [[ ",$ROLES," == *",$1,"* ]]; }
step() { echo; echo "==> $*"; }
export DEBIAN_FRONTEND=noninteractive
apt_i() { apt-get install -y -qq "$@" >/dev/null; }
MS_KEYRING=/usr/share/keyrings/microsoft-prod.gpg
ms_key() {
  [[ -f $MS_KEYRING ]] || curl -fsSL https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor -o $MS_KEYRING
}

# ------------------------------------------------------------------ base
step "Base packages ($PRETTY_NAME, roles: $ROLES, env: $ENVIRONMENT)"
apt-get update -qq
apt_i ca-certificates curl gnupg jq rsync unzip git acl ufw chrony unattended-upgrades \
      python3 python3-yaml python3-venv openssh-server
systemctl enable --now chrony >/dev/null 2>&1 || true
dpkg-reconfigure -f noninteractive unattended-upgrades >/dev/null 2>&1 || true
timedatectl set-timezone UTC 2>/dev/null || true
echo "$ENVIRONMENT" > /etc/app-environment

# ------------------------------------------------------------------ deploy user + app-deploy
step "Deploy user '$DEPLOY_USER' and app-deploy"
id "$DEPLOY_USER" >/dev/null 2>&1 || useradd --create-home --shell /bin/bash "$DEPLOY_USER"
install -d -m 700 -o "$DEPLOY_USER" -g "$DEPLOY_USER" "/home/$DEPLOY_USER/.ssh"
if [[ -n "$DEPLOY_KEY" ]]; then
  ak="/home/$DEPLOY_USER/.ssh/authorized_keys"
  touch "$ak"; grep -qxF "$DEPLOY_KEY" "$ak" || echo "$DEPLOY_KEY" >> "$ak"
  chown "$DEPLOY_USER:$DEPLOY_USER" "$ak"; chmod 600 "$ak"
fi
cat > /etc/sudoers.d/90-app-deploy <<EOF
# managed by prepare-server-ubuntu2404.sh – the deploy user may run app-deploy only
$DEPLOY_USER ALL=(root) NOPASSWD: /usr/local/sbin/app-deploy
EOF
chmod 440 /etc/sudoers.d/90-app-deploy; visudo -cf /etc/sudoers.d/90-app-deploy >/dev/null
install -o root -g root -m 755 "$HERE/server/app-deploy" /usr/local/sbin/app-deploy
install -d -m 750 /etc/app-deploy /var/lib/app-deploy
install -d -m 755 /var/www
# SSH hardening (key only)
cat > /etc/ssh/sshd_config.d/60-app.conf <<'EOF'
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin prohibit-password
EOF
if [[ -s "/home/$DEPLOY_USER/.ssh/authorized_keys" ]] || [[ -n "$(ls -A /root/.ssh/authorized_keys 2>/dev/null)" ]]; then
  systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || true
else
  rm -f /etc/ssh/sshd_config.d/60-app.conf
  echo "    (no SSH keys installed yet – password login left enabled; re-run with --deploy-key)"
fi

ufw allow OpenSSH >/dev/null

# ------------------------------------------------------------------ Nginx + TLS
if has web || has api || has integration || has ai; then
  step "Nginx + TLS"
  apt_i nginx
  rm -f /etc/nginx/sites-enabled/default
  install -d -m 755 /etc/ssl/app
  if [[ -n "$TLS_CERT_SRC" && -n "$TLS_KEY_SRC" ]]; then
    install -m 644 "$TLS_CERT_SRC" /etc/ssl/app/server.crt
    install -m 600 "$TLS_KEY_SRC"  /etc/ssl/app/server.key
    echo "    certificate installed from $TLS_CERT_SRC"
  elif [[ ! -f /etc/ssl/app/server.crt ]]; then
    names="${SERVER_NAMES:-$(hostname -f)}"
    san=$(tr ',' '\n' <<<"$names" | sed 's/^/DNS:/' | paste -sd, -)
    openssl req -x509 -nodes -newkey rsa:2048 -days 825 -subj "/CN=${names%%,*}" \
      -addext "subjectAltName=$san" -keyout /etc/ssl/app/server.key -out /etc/ssl/app/server.crt 2>/dev/null
    chmod 600 /etc/ssl/app/server.key
    echo "    self-signed certificate for $names (replace with a real one for staging/production)"
  fi
  cat > /etc/nginx/conf.d/00-app-defaults.conf <<'EOF'
# managed by prepare-server-ubuntu2404.sh
server_tokens off;
client_max_body_size 50m;
proxy_buffer_size 128k;
proxy_buffers 4 256k;
proxy_busy_buffers_size 256k;
gzip on;
gzip_types text/css application/javascript application/json image/svg+xml;
EOF
  nginx -t >/dev/null 2>&1 && systemctl enable --now nginx >/dev/null && systemctl reload nginx
  ufw allow 'Nginx Full' >/dev/null
fi

# ------------------------------------------------------------------ .NET 10
install_dotnet() {   # $1 = package
  if ! apt-cache show "$1" >/dev/null 2>&1; then
    apt_i software-properties-common
    add-apt-repository -y ppa:dotnet/backports >/dev/null
    apt-get update -qq
  fi
  apt_i "$1"
}
if has api || has integration; then
  step "ASP.NET Core 10 runtime"
  install_dotnet aspnetcore-runtime-10.0
  dotnet --list-runtimes | grep AspNetCore
fi

# ------------------------------------------------------------------ Python (AI / VLM)
if has ai; then
  step "Python runtime for AI services"
  apt_i python3-pip python3-dev build-essential libgl1 libglib2.0-0
  if lspci 2>/dev/null | grep -qi nvidia; then
    echo "    NVIDIA GPU detected – install the driver/CUDA matching your model (ubuntu-drivers autoinstall), then reboot"
  fi
fi

# ------------------------------------------------------------------ SQL Server 2025
if has db && [[ $UNSUPPORTED -eq 1 ]]; then
  step "SQL Server: skipped on $PRETTY_NAME – keep the existing instance (e.g. Docker) and set DB_SERVER accordingly"
  install -d -m 777 /var/opt/mssql/backup 2>/dev/null || true
elif has db; then
  step "SQL Server 2025 ($SQL_EDITION)"
  ms_key
  curl -fsSL https://packages.microsoft.com/config/ubuntu/24.04/mssql-server-2025.list \
    -o /etc/apt/sources.list.d/mssql-server-2025.list
  apt-get update -qq
  apt_i mssql-server
  if [[ ! -f /var/opt/mssql/mssql.conf ]] || ! systemctl is-active --quiet mssql-server; then
    [[ -n "$SA_PASSWORD" ]] || { echo "    --sa-password (or env MSSQL_SA_PASSWORD) is required for the first setup"; exit 1; }
    MSSQL_SA_PASSWORD="$SA_PASSWORD" MSSQL_PID="$SQL_EDITION" ACCEPT_EULA=Y \
      /opt/mssql/bin/mssql-conf -n setup accept-eula >/dev/null
  fi
  install -d -o mssql -g mssql -m 750 /var/opt/mssql/backup
  /opt/mssql/bin/mssql-conf set filelocation.defaultbackupdir /var/opt/mssql/backup >/dev/null
  systemctl restart mssql-server
  if [[ -n "$DB_ALLOW_FROM" ]]; then
    IFS=',' read -ra cidrs <<<"$DB_ALLOW_FROM"
    for c in "${cidrs[@]}"; do ufw allow from "$c" to any port 1433 proto tcp >/dev/null; done
    echo "    port 1433 open for $DB_ALLOW_FROM"
  else
    echo "    port 1433 not opened in ufw (local access only; use --db-allow-from for remote runners/APIs)"
  fi
fi

# ------------------------------------------------------------------ sqlcmd (db + ci)
if has db || has ci; then
  step "mssql-tools18 (sqlcmd)"
  ms_key
  curl -fsSL https://packages.microsoft.com/config/ubuntu/24.04/prod.list \
    -o /etc/apt/sources.list.d/microsoft-prod.list
  apt-get update -qq
  ACCEPT_EULA=Y apt_i mssql-tools18 unixodbc-dev
  ln -sf /opt/mssql-tools18/bin/sqlcmd /usr/local/bin/sqlcmd
fi

# ------------------------------------------------------------------ runner toolchain
if has ci; then
  step "Runner toolchain: .NET 10 SDK, Node 24, Docker"
  install_dotnet dotnet-sdk-10.0
  if ! command -v node >/dev/null || [[ "$(node -v | cut -d. -f1)" != "v24" ]]; then
    curl -fsSL https://deb.nodesource.com/setup_24.x | bash - >/dev/null
    apt_i nodejs
  fi
  apt_i docker.io
  systemctl enable --now docker >/dev/null
  id gh-runner >/dev/null 2>&1 && usermod -aG docker gh-runner
  echo "    dotnet $(dotnet --version) · node $(node -v) · $(docker --version)"
  echo "    next: sudo scripts/install-runner.sh --url … --token … --labels ci,env-$ENVIRONMENT"
fi

# ------------------------------------------------------------------ firewall
step "Firewall"
ufw --force enable >/dev/null
ufw status | sed 's/^/    /'

echo
echo "Server ready for roles [$ROLES] in '$ENVIRONMENT'."
echo "Check: sudo app-deploy version && sudo app-deploy status"

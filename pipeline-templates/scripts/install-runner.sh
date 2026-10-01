#!/usr/bin/env bash
# =============================================================================================
#  install-runner.sh – install a self-hosted GitHub Actions runner on Ubuntu 24.04 (run as root).
#
#  Get a registration token first (expires after 1 hour):
#    repo : gh api -X POST repos/<owner>/<repo>/actions/runners/registration-token -q .token
#    org  : gh api -X POST orgs/<org>/actions/runners/registration-token -q .token
#
#    sudo scripts/install-runner.sh --url https://github.com/mmamdouhDevops/TaskManager-backend \
#         --token <TOKEN> --labels ci,env-test [--name vm-mmostafa] [--group Default] [--ephemeral] [--instance 1]
#
#  Typical labels
#    my VM (now)           ci,env-test          → CI jobs + test deployments (DEPLOY_MODE=local)
#    Alibaba runner ECS    env-staging          → staging deployments over SSH to the staging servers
#    Alibaba runner ECS    env-production       → production deployments over SSH
#  Several runners (one per repo) can live on one machine: use --instance 2, 3 …
#  For org-wide runners use --url https://github.com/<org> (needs a GitHub organization).
# =============================================================================================
set -euo pipefail
URL=""; TOKEN=""; LABELS=""; NAME="$(hostname)"; GROUP="Default"; EPHEMERAL=0; INSTANCE=1
RUNNER_USER=gh-runner; RUNNER_VERSION="${RUNNER_VERSION:-latest}"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --url) URL="$2"; shift 2 ;;
    --token) TOKEN="$2"; shift 2 ;;
    --labels) LABELS="$2"; shift 2 ;;
    --name) NAME="$2"; shift 2 ;;
    --group) GROUP="$2"; shift 2 ;;
    --instance) INSTANCE="$2"; shift 2 ;;
    --ephemeral) EPHEMERAL=1; shift ;;
    --user) RUNNER_USER="$2"; shift 2 ;;
    -h|--help) sed -n '2,20p' "$0" | sed 's/^#  \{0,1\}//'; exit 0 ;;
    *) echo "unknown option $1"; exit 1 ;;
  esac
done
[[ $EUID -eq 0 ]] || { echo "run with sudo"; exit 1; }
[[ -n "$URL" && -n "$TOKEN" && -n "$LABELS" ]] || { echo "--url, --token and --labels are required"; exit 1; }
. /etc/os-release
[[ "$VERSION_ID" == "24.04" ]] || echo "WARNING: tested on Ubuntu 24.04 (found $VERSION_ID)"

apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq curl jq tar git unzip rsync openssh-client python3 python3-yaml >/dev/null

# ------------------------------------------------------------------ runner user
if ! id "$RUNNER_USER" >/dev/null 2>&1; then
  useradd --create-home --shell /bin/bash "$RUNNER_USER"
  echo "created user $RUNNER_USER"
fi
getent group docker >/dev/null && usermod -aG docker "$RUNNER_USER" && echo "$RUNNER_USER added to docker group (DAST)"

# The runner may call app-deploy with sudo (local deploy mode) and nothing else.
cat > /etc/sudoers.d/90-gh-runner <<EOF
# managed by install-runner.sh
$RUNNER_USER ALL=(root) NOPASSWD: /usr/local/sbin/app-deploy
EOF
chmod 440 /etc/sudoers.d/90-gh-runner
visudo -cf /etc/sudoers.d/90-gh-runner >/dev/null

# ------------------------------------------------------------------ download
DIR="/home/$RUNNER_USER/actions-runner-$INSTANCE"
if [[ "$RUNNER_VERSION" == "latest" ]]; then
  RUNNER_VERSION=$(curl -fsSL https://api.github.com/repos/actions/runner/releases/latest | jq -r .tag_name | sed 's/^v//')
fi
ARCH=$(uname -m); case "$ARCH" in x86_64) ARCH=x64 ;; aarch64) ARCH=arm64 ;; esac
if [[ ! -x "$DIR/config.sh" ]]; then
  mkdir -p "$DIR"
  curl -fsSL -o /tmp/runner.tgz \
    "https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/actions-runner-linux-${ARCH}-${RUNNER_VERSION}.tar.gz"
  tar xzf /tmp/runner.tgz -C "$DIR" && rm -f /tmp/runner.tgz
  "$DIR/bin/installdependencies.sh" >/dev/null
  chown -R "$RUNNER_USER:$RUNNER_USER" "$DIR"
  echo "runner $RUNNER_VERSION unpacked in $DIR"
fi

# ------------------------------------------------------------------ configure + service
if [[ -f "$DIR/.runner" ]]; then
  echo "runner already configured in $DIR – remove it first with: sudo -u $RUNNER_USER $DIR/config.sh remove --token <TOKEN>"
else
  args=(--unattended --url "$URL" --token "$TOKEN" --name "$NAME-$INSTANCE" --labels "$LABELS"
        --runnergroup "$GROUP" --work _work --replace)
  [[ $EPHEMERAL -eq 1 ]] && args+=(--ephemeral)
  sudo -u "$RUNNER_USER" bash -c "cd '$DIR' && ./config.sh $(printf '%q ' "${args[@]}")"
fi
cd "$DIR"
./svc.sh install "$RUNNER_USER" >/dev/null 2>&1 || true
./svc.sh start
./svc.sh status | head -5

cat <<EOF

Runner '$NAME-$INSTANCE' online with labels: self-hosted, linux, $LABELS
Repository/org variables that select it:
  RUNNER_CI                 ["self-hosted","linux","ci"]
  RUNNER_DEPLOY_TEST        ["self-hosted","linux","env-test"]
  RUNNER_DEPLOY_STAGING     ["self-hosted","linux","env-staging"]
  RUNNER_DEPLOY_PRODUCTION  ["self-hosted","linux","env-production"]
Note: --ephemeral runners take one job and unregister; pair them with an autoscaler
      (e.g. a systemd loop or Actions Runner Controller) when you need dynamic capacity.
EOF

#!/usr/bin/env bash
#
# Provisions the case-engines VM (run inside the VM as root, via
# measure/engines-vm-up.sh). Installs the two measured container platforms
# — Docker Engine + compose v2 and Podman — plus the measurement tooling,
# and quiets the periodic apt jobs that would perturb idle CPU sampling.
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

apt-get update -q
apt-get install -yq docker.io docker-compose-v2 podman sysstat jq curl

systemctl enable --now docker

# No background package activity during measurement windows.
systemctl disable --now apt-daily.timer apt-daily-upgrade.timer 2>/dev/null || true
systemctl stop unattended-upgrades 2>/dev/null || true

# Dedicated netavark network for podman kube play: unlike podman's default
# network, user-defined networks have DNS, so pods resolve each other by
# pod name (artemis/postgres/keycloak — the compose service-name parity).
podman network exists measure-net || podman network create measure-net

echo "== engines VM provisioned =="
docker --version
docker compose version
podman --version
pidstat -V 2>&1 | head -1

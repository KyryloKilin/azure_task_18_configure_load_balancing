#!/bin/bash
set -euo pipefail

apt-get update -yq
apt-get install -yq python3-pip git

rm -rf /tmp/todoapp-repo
git clone https://github.com/KyryloKilin/azure_task_18_configure_load_balancing.git /tmp/todoapp-repo

mkdir -p /app
cp -r /tmp/todoapp-repo/app/* /app

if [ ! -f /app/todoapp.service ]; then
  echo "todoapp.service not found in /app" >&2
  exit 1
fi

mv /app/todoapp.service /etc/systemd/system/todoapp.service
systemctl daemon-reload
systemctl enable --now todoapp

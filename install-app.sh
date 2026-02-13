#!/bin/bash
set -e

apt-get update -yq
apt-get install -yq python3-pip git

mkdir -p /app

git clone https://github.com/KyryloKilin/azure_task_18_configure_load_balancing.git
cp -r azure_task_18_configure_load_balancing/app/* /app

mv /app/todoapp.service /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now todoapp

#!/bin/bash
set -e
TOKEN=$(kubectl get secret claude-readonly-token -n kube-system -o jsonpath='{.data.token}' | base64 -d)
CA=$(kubectl get secret claude-readonly-token -n kube-system -o jsonpath='{.data.ca\.crt}')
cat > ~/claude-projects/kubeconfig <<EOF
apiVersion: v1
kind: Config
clusters:
- cluster:
    certificate-authority-data: $CA
    server: https://172.16.20.80:6443
  name: homelab
contexts:
- context:
    cluster: homelab
    user: claude-readonly
  name: homelab
current-context: homelab
users:
- name: claude-readonly
  user:
    token: $TOKEN
EOF
echo "kubeconfig written to ~/claude-projects/kubeconfig"

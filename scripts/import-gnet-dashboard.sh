#!/usr/bin/env bash
# Download a grafana.com dashboard and wrap it as a ConfigMap
# the grafana sidecar will load (label grafana_dashboard=1).
# usage: import-gnet-dashboard.sh <gnet-id> <cm-name> [revision]
set -euo pipefail

ID=${1:?gnet id required}
NAME=${2:?configmap name required (e.g. navidrome)}
REV=${3:-1}
OUT=gitops/infra/grafana-dashboards/${NAME}.yaml

JSON=$(curl -sfS "https://grafana.com/api/dashboards/${ID}/revisions/${REV}/download") || {
  echo "download failed"; exit 1; }

# 1) drop "uid" from prometheus datasource objects -> grafana resolves to default
# 2) rewrite datasource-type template variables to default to our "Prometheus" DS
CLEAN=$(echo "$JSON" | jq '
  walk(if type == "object" and .type == "prometheus" and has("uid") then del(.uid) else . end) |
  (.templating.list[]? | select(.type == "datasource")) |= (
    .current = {selected: false, text: "Prometheus", value: "Prometheus"} |
    .query = "prometheus"
  )')

{
  echo "---"
  echo "apiVersion: v1"
  echo "kind: ConfigMap"
  echo "metadata:"
  echo "  name: grafana-dashboard-${NAME}"
  echo "  namespace: monitoring"
  echo "  labels:"
  echo "    grafana_dashboard: \"1\""
  echo "data:"
  echo "  ${NAME}.json: |-"
  echo "$CLEAN" | sed 's/^/    /'
} > "$OUT"

echo "wrote $OUT"

#!/usr/bin/env bash
# Valide NOS manifestes contre les schémas Kubernetes (et ceux des CRD :
# Application Argo CD, Certificate, ClusterIssuer, SopsSecret) avant qu'Argo CD
# ne les reçoive. Mode strict : un champ inconnu (faute de frappe) = erreur.
set -euo pipefail
cd "$(dirname "$0")/.."

K8S_VERSION="${K8S_VERSION:-1.36.0}"
CRDS='https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json'

kubeconform -strict -summary -output text \
  -kubernetes-version "$K8S_VERSION" \
  -schema-location default -schema-location "$CRDS" \
  bootstrap/root.yaml clusters platform apps

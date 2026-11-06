#!/usr/bin/env bash
# Rend chaque chart Helm référencé dans clusters/demo/, distant ou local
# (charts/), avec la même version et les mêmes valeurs qu'Argo CD, et valide
# le résultat avec kubeconform. Attrape avant le merge : une version de chart
# inexistante, une valeur mal placée qui casse le rendu, un objet invalide.
# Prérequis : helm, yq (mikefarah, v4), kubeconform.
set -euo pipefail
cd "$(dirname "$0")/.."

K8S_VERSION="${K8S_VERSION:-1.36.0}"
CRDS='https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json'
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

count=0
for app in clusters/demo/*.yaml; do
  # Source du chart : `spec.source` ou la première entrée de `spec.sources`.
  src='(.spec.source // .spec.sources[0])'
  chart="$(yq "$src.chart // \"\"" "$app")"
  path="$(yq "$src.path // \"\"" "$app")"
  # Chart distant (repoURL + chart) ou chart de CE dépôt (path contenant Chart.yaml).
  if [ -z "$chart" ] && { [ -z "$path" ] || [ ! -f "$path/Chart.yaml" ]; }; then
    continue
  fi

  name="$(yq '.metadata.name' "$app")"
  repo="$(yq "$src.repoURL" "$app")"
  version="$(yq "$src.targetRevision" "$app")"
  release="$(yq "$src.helm.releaseName // \"$name\"" "$app")"
  namespace="$(yq '.spec.destination.namespace' "$app")"

  args=()
  # Valeurs en ligne (valuesObject)…
  if [ "$(yq "$src.helm | has(\"valuesObject\")" "$app")" = "true" ]; then
    yq "$src.helm.valuesObject" "$app" > "$work/$name-values.yaml"
    args+=(--values "$work/$name-values.yaml")
  fi
  # … ou fichiers de valeurs de ce dépôt ($values/chemin).
  while IFS= read -r vf; do
    [ -n "$vf" ] && args+=(--values "${vf#\$values/}")
  done < <(yq "$src.helm.valueFiles // [] | .[]" "$app")

  if [ -n "$chart" ]; then
    echo "==> $name : $chart $version ($repo)"
    helm template "$release" "$chart" --repo "$repo" --version "$version" \
      --namespace "$namespace" --kube-version "$K8S_VERSION" --include-crds \
      "${args[@]}" > "$work/$name.yaml"
  else
    echo "==> $name : chart local $path"
    helm lint --strict "$path" --namespace "$namespace" "${args[@]}"
    helm template "$release" "$path" \
      --namespace "$namespace" --kube-version "$K8S_VERSION" \
      "${args[@]}" > "$work/$name.yaml"
  fi

  # Non strict : les charts tiers ont parfois des champs tolérés par l'API.
  kubeconform -summary -output text -ignore-missing-schemas \
    -kubernetes-version "$K8S_VERSION" \
    -schema-location default -schema-location "$CRDS" \
    "$work/$name.yaml"
  count=$((count + 1))
done

[ "$count" -gt 0 ] || { echo "Aucun chart trouvé dans clusters/demo/" >&2; exit 1; }
echo "OK : $count chart(s) rendu(s) et validé(s)."

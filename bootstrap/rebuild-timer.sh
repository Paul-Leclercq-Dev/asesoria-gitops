#!/usr/bin/env bash
# Chronomètre le test de reconstruction de la phase 4 (critère : toute la
# plateforme recréée depuis zéro en MOINS D'UNE HEURE) et vérifie le résultat
# comme le ferait un visiteur : HTTPS, API prête, connexion d'un compte de démo.
#
#   bootstrap/rebuild-timer.sh start           # T0, juste avant `terraform apply` (serveur éteint)
#   bootstrap/rebuild-timer.sh lap "<étape>"   # note un temps intermédiaire (ex. "kubeconfig")
#   bootstrap/rebuild-timer.sh verify          # attend que tout soit prêt, teste, affiche le rapport
#
# Compatible avec le bash de macOS (3.2). Journal : ~/.config/tramelya/rebuild.log
set -euo pipefail

HOST="${HOST:-app.tramelya.es}"
NAMESPACE=acrm-demo
STATE_DIR="$HOME/.config/tramelya"
LOG="$STATE_DIR/rebuild.log"
TIMEOUT_MIN="${TIMEOUT_MIN:-60}"
# Applications attendues (bootstrap/root.yaml + clusters/demo/).
EXPECTED_APPS=8

die() { printf 'ERREUR : %s\n' "$*" >&2; exit 1; }
now() { date +%s; }
mmss() { printf '%02d:%02d' $(($1 / 60)) $(($1 % 60)); }
t0() { [ -r "$LOG" ] || die "pas de T0 : lancer d'abord « $0 start »"; head -1 "$LOG" | cut -d' ' -f1; }
lap() { local t; t="$(now)"; echo "$t $*" >> "$LOG"; printf '[%s] %s\n' "$(mmss $((t - $(t0))))" "$*"; }

case "${1:-}" in
  start)
    mkdir -p "$STATE_DIR"
    echo "$(now) start" > "$LOG"
    echo "T0 enregistré ($(date '+%H:%M:%S')). Lance maintenant : terraform apply (asesoria-infra/envs/demo)."
    ;;
  lap)
    [ -n "${2:-}" ] || die "usage : $0 lap \"<étape>\""
    lap "$2"
    ;;
  verify)
    command -v kubectl >/dev/null || die "kubectl introuvable"
    command -v curl >/dev/null || die "curl introuvable"
    kubectl get nodes >/dev/null 2>&1 || die "cluster injoignable (tunnel SSH ouvert ? KUBECONFIG exporté ?)"
    start="$(t0)"
    deadline=$((start + TIMEOUT_MIN * 60))

    echo "==> Attente : $EXPECTED_APPS Applications Argo CD « Synced » + « Healthy »"
    while :; do
      status="$(kubectl -n argocd get applications --no-headers \
        -o custom-columns=N:.metadata.name,S:.status.sync.status,H:.status.health.status 2>/dev/null || true)"
      total="$(printf '%s\n' "$status" | grep -c . || true)"
      ready="$(printf '%s\n' "$status" | grep -c ' Synced *Healthy$' || true)"
      if [ "$total" -ge "$EXPECTED_APPS" ] && [ "$ready" -eq "$total" ]; then break; fi
      [ "$(now)" -lt "$deadline" ] || { printf '%s\n' "$status"; die "délai de $TIMEOUT_MIN min dépassé"; }
      printf '  [%s] %s/%s prêtes\r' "$(mmss $(($(now) - start)))" "$ready" "$total"
      sleep 15
    done
    echo; lap "Applications Argo CD Synced + Healthy"

    echo "==> Attente : données de démo (Job acrm-seed)"
    kubectl -n "$NAMESPACE" wait --for=condition=complete job/acrm-seed --timeout=15m >/dev/null \
      || die "le seed n'a pas fini : kubectl -n $NAMESPACE logs job/acrm-seed"
    lap "Données de démo chargées"

    echo "==> Tests depuis Internet (via Cloudflare)"
    code() { curl -s -o /dev/null -w '%{http_code}' --max-time 15 "$@"; }
    [ "$(code "https://$HOST/healthz")" = "200" ] || die "front : https://$HOST/healthz ne répond pas 200"
    echo "  front            200"
    [ "$(code "https://$HOST/v1/health/ready")" = "200" ] || die "API : /v1/health/ready ne répond pas 200 (base ou Redis ?)"
    echo "  API prête        200"
    email="$(kubectl -n "$NAMESPACE" logs job/acrm-seed 2>/dev/null | grep -m1 -oE '[^ ]+\.owner@demo-levante\.example' || true)"
    [ -n "$email" ] || die "compte titulaire de démo introuvable dans les logs du seed"
    password="$(kubectl -n "$NAMESPACE" get secret acrm-demo-seed -o jsonpath='{.data.SEED_DEMO_PASSWORD}' | base64 -d)"
    login="$(code -X POST "https://$HOST/v1/auth/login" -H 'Content-Type: application/json' \
      -H "Origin: https://$HOST" -d "{\"email\":\"$email\",\"password\":\"$password\"}")"
    [ "$login" = "200" ] || die "connexion de $email : HTTP $login (attendu 200)"
    echo "  connexion        200 ($email)"
    lap "Application vérifiée de bout en bout"

    requests="$(kubectl -n "$NAMESPACE" get certificaterequest --no-headers 2>/dev/null | grep -c . || true)"
    if [ "$requests" -eq 0 ]; then tls="certificat restauré (aucune demande à Let's Encrypt)"; else tls="certificat NEUF demandé ($requests demande·s)"; fi

    total_s=$(($(now) - start))
    echo
    echo "==================== Rapport de reconstruction ===================="
    prev="$start"
    while read -r t label; do
      [ "$label" = "start" ] && continue
      printf '  %-45s +%s  (cumul %s)\n' "$label" "$(mmss $((t - prev)))" "$(mmss $((t - start)))"
      prev="$t"
    done < "$LOG"
    echo "  TLS : $tls"
    if [ "$total_s" -lt 3600 ]; then verdict="RÉUSSI (< 1 h)"; else verdict="ÉCHEC (≥ 1 h)"; fi
    printf '  TOTAL : %s  →  %s\n' "$(mmss "$total_s")" "$verdict"
    echo "==================================================================="
    echo "Journal : $LOG (à coller dans le PLAN)."
    ;;
  *)
    sed -n '2,12p' "$0"; exit 1 ;;
esac

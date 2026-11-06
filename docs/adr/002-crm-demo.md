# ADR-002 — Le CRM sur la plateforme de démo (phase 4.2b)

- Statut : accepté, 2026-11-04
- Contexte : plateforme 4.2a en place (Argo CD, SOPS, cert-manager, opérateur CloudNativePG) ; un nœud k3s jetable de 8 Go ; données fictives uniquement ; critère de la phase 4 : tout recréer depuis zéro en moins d'une heure.

## Décisions

1. **Un chart Helm local `charts/acrm`** (dans ce dépôt, pas dans celui du CRM) : front, API, worker, Job de migration ; base, Redis, Mailpit et données de démo activables. Un environnement = une Application qui surcharge les valeurs (`valuesObject`). Écarté : chart publié depuis le dépôt du CRM (deux dépôts à faire évoluer ensemble pour chaque réglage) ; Kustomize (moins demandé, et moins lisible pour les variantes par environnement).
2. **Application à deux sources** : le chart + `apps/acrm-demo/` (le `SopsSecret` chiffré). Le chart reste réutilisable et sans secret ; il ne fait que **nommer** des Secret existants.
3. **Ordre par vagues et hooks** : secrets (-1) → base, Redis, Mailpit, certificat (0) → migrations (hook `Sync`, 1) → API, worker, front, Ingress (2) → données de démo (hook `PostSync`). Une migration en échec arrête la synchronisation : l'ancienne version reste en ligne.
4. **PostgreSQL 17 par CloudNativePG**, 1 instance, image du catalogue « standard » figée par digest, `en_US.UTF-8` (même tri que la CI). Rôles `acrm_app` et `acrm_worker` déclarés dans le `Cluster` (`managed.roles`, mots de passe dans des Secret `basic-auth`) ; `acrm_admin` propriétaire (migrations seulement). Le Job de migration **attend que les deux rôles existent** : sinon une migration `GRANT … TO acrm_app` échoue et reste bloquée (P3009). Pas de TLS entre l'API et la base pour l'instant (trafic interne au nœud ; NetworkPolicies en 4.3). Pas de sauvegarde : phase 5.
5. **Redis 7 sans persistance**, `noeviction` (BullMQ). Files perdues au redémarrage : acceptable pour une démo (les jobs planifiés sont recréés par le worker).
6. **Mailpit** comme serveur SMTP : aucun e-mail ne sort du cluster (les adresses du seed sont fictives, mais un test d'invitation pourrait viser une vraie adresse).
7. **Images privées GHCR** tirées avec un jeton GitHub classic `read:packages`, chiffré SOPS (secret `ghcr-pull`). Version figée (`image.tag`), publiée par `release.yml` du CRM (Trivy, signature cosign).
8. **Données de démo** : image `acrm-api-seeder` (le seed importe `src/` et des dépendances de dev, absentes du migrator), Job idempotent ; mot de passe des comptes **tiré d'un secret** et jamais écrit dans les logs, car l'URL est publique. `SIGNUP_ENABLED=false`.
9. **Secrets générés une fois** par `scripts/acrm-secrets.sh` (aléatoires + sorties Terraform du bucket), chiffrés et commités : chaque reconstruction les réutilise, rien à ressaisir.
10. **IP réelle des visiteurs** : Traefik garde le `X-Forwarded-For` reçu (`forwardedHeaders.insecure` via un `HelmChartConfig` k3s), et l'API compte 2 relais (`TRUST_PROXY_HOPS=2`). Sans risque d'usurpation ici car le pare-feu n'ouvre le 443 qu'aux plages de Cloudflare (asesoria-infra ADR-001 §5). Écarté : `trustedIPs` = plages Cloudflare (le relais ServiceLB de k3s peut masquer l'adresse source : Traefik ne verrait pas une IP Cloudflare et effacerait l'en-tête). À revoir si l'origine devient joignable autrement que par Cloudflare (ex. Cloudflare Tunnel : l'en-tête serait alors écrit par `cloudflared`).
11. **Pods durcis** sans attendre 4.3 : non-root (uid explicite), `seccomp RuntimeDefault`, aucune capacité, système de fichiers en lecture seule (sauf le Job de migration : la CLI Prisma écrit son cache), pas de jeton d'API Kubernetes monté, requêtes et limites de mémoire.

## Conséquences

- Déployer une version du CRM = un tag dans `asesoria-crm`, puis une PR qui change `image.tag` ici.
- La base vit sur le disque du nœud (`local-path`) : détruire le serveur la détruit. Les données de démo reviennent seules (seed) ; les documents envoyés restent orphelins dans le bucket (asesoria-infra ADR-001 §13).
- Restent pour 4.3 : NetworkPolicies, PodSecurity `restricted` imposé par namespace, PodDisruptionBudget, HPA de l'API, mise à jour automatique de `image.tag` par la CI du CRM.

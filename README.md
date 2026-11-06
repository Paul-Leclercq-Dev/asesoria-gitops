# asesoria-gitops

État souhaité du cluster Kubernetes de **Tramelya** (CRM SaaS pour asesorías), appliqué par **Argo CD** (GitOps).
Le serveur et le DNS sont créés par Terraform dans [`asesoria-infra`](https://github.com/Paul-Leclercq-Dev/asesoria-infra) ; ce dépôt décrit tout ce qui tourne **dans** le cluster.

> Dépôt public, sans aucun secret en clair : les secrets sont chiffrés avec **SOPS + age** et déchiffrés dans le cluster.

## Principe

```
Git (ce dépôt) ──lu par──▶ Argo CD ──applique──▶ cluster k3s (OVHcloud SBG7)
     ▲                                                   │
     └──────── une PR = un changement ◀── écart corrigé ─┘  (selfHeal)
```

- `bootstrap/` : la seule partie lancée à la main, une fois par cluster neuf (`install.sh`).
- `clusters/demo/` : une Application Argo CD par composant (« app-of-apps »), installées par vagues.
- `platform/` : configuration des composants de plateforme (émetteurs de certificats…).
- `charts/acrm/` : le chart Helm du CRM (front, API, worker, migrations ; en option PostgreSQL CloudNativePG, Redis, Mailpit, données de démo).
- `apps/` : ce qui est propre à un environnement et n'est pas du chart (ex. `apps/acrm-demo/` : secrets chiffrés de la démo).

| Vague | Composant | Rôle |
|---|---|---|
| 0 | sops-secrets-operator | déchiffre les `SopsSecret` en Secrets Kubernetes |
| 0 | cert-manager | certificats Let's Encrypt (DNS-01 Cloudflare) |
| 0 | CloudNativePG | opérateur PostgreSQL |
| 0 | traefik-config | Traefik garde l'IP réelle des visiteurs transmise par Cloudflare |
| 1 | cert-manager-config | émetteurs + jeton Cloudflare chiffré |
| 2 | acrm-demo | le CRM sur `https://app.tramelya.es` : base, Redis, Mailpit, migrations, API, worker, front, données de démo |
| 3 | argocd | Argo CD se gère lui-même après l'installation initiale |

## Démarrer

Runbook pas à pas (en français, pédagogique) : [`docs/bootstrap.fr.md`](docs/bootstrap.fr.md), dont le CRM (étape 10) et le test de reconstruction chronométré (étape 11). Décisions : [`docs/adr/`](docs/adr/).

## Vérifications en CI

`check-encrypted.sh` (aucun secret en clair), yamllint, shellcheck, kubeconform strict sur nos manifestes, `helm lint` + `helm template` + kubeconform sur chaque chart, distant ou local (mêmes versions et valeurs qu'Argo CD), Trivy (mauvaises configurations + secrets). Actions épinglées par SHA.

## Mettre à jour un composant

Changer `targetRevision` dans `clusters/demo/<composant>.yaml`, lire les notes de version, ouvrir une PR (la CI rend le nouveau chart), merger : Argo CD applique. Dependabot ne surveille que les GitHub Actions.

# ADR-001 — Couche GitOps de la plateforme de démo (phase 4.2a)

- Statut : accepté, 2026-11-02
- Contexte : un nœud k3s jetable (`server_enabled=false` détruit le serveur), un seul opérateur qui apprend Kubernetes, dépôt public (portfolio), critère de la phase 4 : recréer toute la plateforme depuis zéro en moins d'une heure.

## Décisions

1. **Argo CD** (et non Flux) : interface visuelle utile pour apprendre et montrer, très demandé sur le marché. Coût mémoire acceptable (≈ 6,5 Go libres sur le nœud). Dex et notifications désactivés.
2. **App-of-apps** : une Application racine (`bootstrap/root.yaml`) lit `clusters/demo/`, qui contient une Application par composant. Ordre par **sync-waves** ; la santé des Applications est réactivée dans `argocd-cm` pour qu'une vague attende la précédente.
3. **Argo CD se gère lui-même** : installation initiale par Helm (`install.sh`), puis Application `argocd` sur le même chart, même version, même fichier de valeurs (`bootstrap/argocd-values.yaml`). `prune: false` sur cette Application (prudence). La version est lue par `install.sh` dans l'Application : une seule source de vérité.
4. **Secrets : SOPS + age, déchiffrés par `sops-secrets-operator`** dans le cluster.
   - Écartés : *Sealed Secrets* (sa clé est générée DANS le cluster : perdue à chaque destruction du nœud, sauf sauvegarde manuelle) ; *KSOPS / helm-secrets* (plugin à greffer dans le repo-server d'Argo CD, plus fragile) ; *External Secrets* (demande un coffre externe, hors budget démo).
   - La clé privée age est le **secret zéro** : dans le gestionnaire de mots de passe de l'opérateur, déposée par `install.sh` (jamais dans Git, ni dans cloud-init : les métadonnées d'instance sont lisibles depuis les pods).
   - Seules les valeurs `data` / `stringData` sont chiffrées (`.sops.yaml`), le reste reste lisible en revue.
5. **Certificats : cert-manager + Let's Encrypt, défi DNS-01 Cloudflare.** Le port 80 est fermé et l'origine n'est joignable que par Cloudflare : HTTP-01 impossible. Jeton Cloudflare limité à `Zone.DNS:Edit` + `Zone.Zone:Read` sur `tramelya.es`, chiffré SOPS. Ensuite, SSL Cloudflare → origine en **`strict`** (asesoria-infra).
6. **Limite Let's Encrypt** (5 certificats identiques par 7 jours) face à un nœud recréé souvent : `bootstrap/tls-backup.sh` sauvegarde le secret TLS **chiffré pour la clé age, hors du dépôt**, avant l'extinction ; `install.sh` le restaure avant Argo CD, et cert-manager le réutilise au lieu d'en redemander un. Plan B : émetteur `letsencrypt-staging` + SSL Cloudflare `full`.
7. **Aucune interface d'administration exposée** : Argo CD par `kubectl port-forward` à travers le tunnel SSH de l'API (6443 jamais ouvert).
8. **Versions figées** (charts : Argo CD 10.11.6 / v3.5.6, cert-manager v1.21.3, sops-secrets-operator 0.28.1, CloudNativePG 0.29.1 / 1.30.1). Montées à la main par PR ; la CI rend chaque chart (`helm template` + kubeconform) avant le merge.
9. **Projet Argo CD `default`** pour la démo. Durcissement (AppProject par domaine, sources autorisées, NetworkPolicies, PodSecurity `restricted`) : phase 4.3.

## Conséquences

- Recréer le cluster = `terraform apply` + récupérer le kubeconfig + `bootstrap/install.sh` ; tout le reste vient de Git.
- Perdre la clé age = ne plus pouvoir déchiffrer les secrets du dépôt : il faudrait recréer chaque secret (rotation) avec une nouvelle clé. D'où sa place dans le gestionnaire de mots de passe.
- Le dépôt public montre l'architecture complète sans rien exposer d'exploitable.
- Les données d'un cluster détruit sont perdues (base comprise) tant que les sauvegardes hors site n'existent pas (phase 5) : acceptable pour une démo aux données fictives, pas pour un pilote.

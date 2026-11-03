# Amorcer la plateforme GitOps (phase 4.2a)

Ce runbook se suit **dans l'ordre**, une étape à la fois. Chaque étape dit ce qu'elle fait, pourquoi, ce qu'elle crée (sur le Mac, sur GitHub, sur le serveur payant) et ce que tu dois voir. Les étapes 1 à 4 ne se font **qu'une fois** ; les étapes 5 à 9 se refont à chaque cluster neuf.

## 0. Les notions, en une phrase chacune

| Notion | Ce que c'est | Analogie |
|---|---|---|
| **GitOps** | Git décrit l'état voulu du cluster ; un robot compare en permanence et corrige les écarts. | Un plan d'architecte que le chef de chantier fait respecter tout seul. |
| **Argo CD** | Le robot : il lit ce dépôt et applique ce qu'il contient dans Kubernetes. | Le chef de chantier. |
| **Application** (Argo CD) | Une fiche « tel dossier de Git, ou tel chart Helm, va dans tel namespace ». | Une ligne du planning. |
| **App-of-apps** | Une Application racine dont le contenu… est une liste d'Applications. | Le planning général qui pointe vers les plannings de chaque corps de métier. |
| **Sync-wave** | Numéro d'ordre : la vague 1 attend que la vague 0 soit en bonne santé. | On coule les fondations avant de monter les murs. |
| **Chart Helm** | Un paquet de manifestes Kubernetes paramétrables (valeurs). | Un meuble en kit + sa notice ; les valeurs = la couleur et la taille choisies. |
| **Opérateur / CRD** | Un programme qui ajoute un nouveau type d'objet à Kubernetes et sait le gérer (ex. `Certificate`, `Cluster` PostgreSQL). | Un artisan spécialisé qu'on embauche avec son propre formulaire de commande. |
| **cert-manager** | Opérateur qui obtient et renouvelle les certificats HTTPS. | Le service qui renouvelle ton passeport avant qu'il expire. |
| **ACME / DNS-01** | Le protocole de Let's Encrypt ; DNS-01 = prouver qu'on possède le domaine en créant un enregistrement TXT temporaire (via l'API Cloudflare). | Prouver qu'on habite une maison en mettant un mot convenu sur la boîte aux lettres. |
| **SOPS + age** | `age` = une paire de clés (publique pour chiffrer, privée pour déchiffrer) ; `sops` = chiffre seulement les valeurs d'un YAML. | Un cadenas que tout le monde peut fermer, mais que toi seul peux ouvrir. |
| **Secret zéro** | La seule chose qu'on ne peut pas mettre dans Git : la clé privée age. Elle est déposée à la main par `install.sh`. | La clé du coffre qui contient toutes les autres clés. |

Où tu en es : le serveur et k3s existent (4.1). Ce runbook ajoute la couche « Git → Argo CD → cluster », puis une page de test en HTTPS sur `https://app.tramelya.es`.

## 1. Outils sur le Mac (une fois)

```bash
brew install helm sops age jq
helm version --short && sops --version && age --version && jq --version && kubectl version --client
```
- **Crée** : des programmes sur ton Mac, rien d'autre. Gratuit.
- **Attendu** : 5 numéros de version (Helm v3 ou v4, sops 3.13 ou plus, age 1.2 ou plus).

## 2. Ta clé age (une fois pour toutes)

```bash
mkdir -p ~/.config/sops/age
age-keygen -o ~/.config/sops/age/keys.txt
chmod 600 ~/.config/sops/age/keys.txt
cat ~/.config/sops/age/keys.txt
```
- **Fait** : crée une paire de clés. Ligne `# public key: age1…` = clé **publique** (partageable). Ligne `AGE-SECRET-KEY-1…` = clé **privée** (le secret zéro).
- **À faire tout de suite** : copier **tout le contenu du fichier** dans ton gestionnaire de mots de passe (entrée « Tramelya — clé age SOPS »). Perdue = plus aucun secret du dépôt déchiffrable.
- Puis indiquer à sops où la trouver, pour toujours :
  ```bash
  echo 'export SOPS_AGE_KEY_FILE="$HOME/.config/sops/age/keys.txt"' >> ~/.zshrc && source ~/.zshrc
  ```
- Enfin, mettre la clé **publique** dans `.sops.yaml` (remplacer `REMPLACER_PAR_LA_CLE_PUBLIQUE_AGE` par `age1…`).

## 3. Jeton Cloudflare pour cert-manager (une fois)

1. Cloudflare → *My Profile* → *API Tokens* → *Create Token* → *Create Custom Token*. Nom : `cert-manager tramelya.es`. Permissions : **Zone · DNS · Edit** et **Zone · Zone · Read**. Zone Resources : *Include · Specific zone · tramelya.es*. Créer, copier le jeton (affiché une seule fois), le ranger aussi dans le gestionnaire de mots de passe.
   - **Pourquoi un jeton à part** (et pas celui de Terraform) : moindre privilège. Celui-ci ne peut que toucher aux enregistrements DNS de `tramelya.es`.
2. Créer le fichier chiffré, depuis la racine du dépôt, en **une seule commande** (le jeton est demandé sans s'afficher, passe directement à sops et n'est jamais écrit en clair sur le disque) :
   ```bash
   cd ~/dev/asesoria-gitops && F=platform/cert-manager-config/cloudflare-api-token.sops.yaml
   printf 'Jeton Cloudflare : ' && read -rs CF_TOKEN && echo && [ -n "$CF_TOKEN" ] \
     && sed "s|COLLER_ICI_LE_JETON_CLOUDFLARE|$CF_TOKEN|" $F.example \
        | sops encrypt --filename-override $F --input-type yaml --output-type yaml > $F.tmp \
     && mv $F.tmp $F && echo "chiffré" ; unset CF_TOKEN
   scripts/check-encrypted.sh                 # doit finir par « OK : aucun secret en clair. »
   sops decrypt $F | grep -c 'api-token: COLLER\|api-token: null'   # doit afficher 0
   ```
- **Crée** : un fichier dans le dépôt où seule la valeur du jeton est remplacée par `ENC[AES256_GCM,…]`. Le nom et l'espace de noms restent lisibles.
- **Piège vécu (2026-11-03)** : `read` et le chiffrement lancés dans deux terminaux différents → variable vide → `api-token: null` chiffré « avec succès ». D'où la commande unique, le test `[ -n "$CF_TOKEN" ]` et le garde-fou de `check-encrypted.sh`, qui refuse désormais un fichier sans autre valeur chiffrée que le `mac` de sops.

## 4. Le dépôt sur GitHub (une fois)

1. GitHub → *New repository* → `asesoria-gitops`, **Public**, sans README.
2. Sur le Mac :
   ```bash
   cd ~/dev/asesoria-gitops
   git init -b main && git add -A
   git status --short          # vérifier : AUCUN fichier keys.txt, AUCUN jeton en clair
   git commit -m "feat: GitOps platform (Argo CD, cert-manager, SOPS, CloudNativePG)"
   git remote add origin git@github.com:Paul-Leclercq-Dev/asesoria-gitops.git
   git push -u origin main
   ```
- **Pourquoi avant le cluster** : Argo CD lit ce dépôt sur GitHub (pas sur ton Mac). Rien de poussé = rien d'installé.
- **Attendu** : l'onglet *Actions* de GitHub montre le workflow `validate` en vert (3 jobs). Ensuite seulement : protéger `main` (Settings → Branches) et passer par des PR.

## 5. Un cluster joignable depuis le Mac (à chaque cluster neuf)

Si le serveur est éteint : `terraform apply` dans `asesoria-infra/envs/demo` (≈ 5 min avec cloud-init). Puis, comme dans le runbook de l'infra (§7) :

```bash
cd ~/dev/asesoria-infra/envs/demo && IP=$(terraform output -raw server_ipv4)
ssh -i ~/.ssh/tramelya_ed25519 deploy@$IP 'sudo cat /etc/rancher/k3s/k3s.yaml' > ~/.kube/tramelya-demo.yaml && chmod 600 ~/.kube/tramelya-demo.yaml
ssh -i ~/.ssh/tramelya_ed25519 -N -L 6443:127.0.0.1:6443 deploy@$IP &
export KUBECONFIG=~/.kube/tramelya-demo.yaml
kubectl get nodes
```
- **Pourquoi récupérer le kubeconfig à chaque fois** : un cluster neuf a de nouveaux certificats ; l'ancien fichier serait refusé.
- **Attendu** : une ligne `tramelya-demo-1   Ready`.

## 6. Amorçage (à chaque cluster neuf)

```bash
cd ~/dev/asesoria-gitops && ./bootstrap/install.sh
```
Le script affiche 5 étapes : (1) le cluster répond ; (2) il dépose ta clé privée age dans le secret `sops/sops-age-key-file` ; (3) il restaure le certificat sauvegardé s'il existe (étape 9) ; (4) il installe Argo CD avec Helm ; (5) il crée l'Application racine.
- **Crée** : des objets dans le cluster seulement. Coût : rien de plus que le serveur déjà allumé.
- Puis suivre Argo CD travailler :
  ```bash
  kubectl -n argocd get applications -w
  ```
- **Attendu** (≈ 3 à 5 min) : 7 lignes `Synced` + `Healthy` : `root`, `argocd`, `sops-secrets-operator`, `cert-manager`, `cloudnative-pg`, `cert-manager-config`, `hello`. Envoie-moi la sortie si une ligne reste `Progressing` ou `Degraded` plus de 5 minutes.

## 7. Vérifier le certificat puis passer Cloudflare en `strict`

```bash
kubectl -n acrm-demo get certificate      # READY = True (1 à 3 min après « hello »)
curl -sI https://app.tramelya.es | head -1 # HTTP/2 200
```
- `full` (actuel) : Cloudflare chiffre vers ton serveur mais accepte n'importe quel certificat. `strict` : il exige un certificat valide pour `app.tramelya.es`, ce qui empêche une interception entre Cloudflare et le serveur.
- Une fois `READY = True` : `cd ~/dev/asesoria-infra/envs/demo && terraform apply` (la valeur par défaut de `ssl_mode` est désormais `strict`). **Attendu** : les réglages SSL des deux zones passent de `full` à `strict` (ou `No changes` si l'`apply` de l'étape 5 l'a déjà fait), puis `curl` toujours en `200`. Un `526` = certificat pas (encore) valide : voir § Dépannage.
- Désormais, à chaque cluster neuf, Cloudflare est déjà en `strict` : la page répond `526` pendant les 1 à 3 minutes où le certificat n'est pas encore là (ou tout de suite `200` s'il a été restauré, étape 9). C'est normal.

## 8. L'interface d'Argo CD (facultatif, pour voir)

```bash
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo
kubectl -n argocd port-forward svc/argocd-server 8080:443
```
Ouvrir https://localhost:8080 (avertissement de certificat : normal, c'est local), utilisateur `admin`. Rien n'est exposé sur Internet : le port-forward passe par le tunnel SSH. Le mot de passe change à chaque cluster neuf.

## 9. Éteindre et rallumer sans gaspiller de certificats

Let's Encrypt délivre **au plus 5 certificats identiques par 7 jours**. Chaque cluster neuf en redemande un, sauf si on lui rend l'ancien :

```bash
cd ~/dev/asesoria-gitops && ./bootstrap/tls-backup.sh   # AVANT d'éteindre
cd ~/dev/asesoria-infra/envs/demo && terraform apply -var server_enabled=false
```
- **Crée** : `~/.config/tramelya/tls-backup.sops.yaml`, hors du dépôt, chiffré pour ta clé age. `install.sh` le restaure au prochain démarrage.
- Au redémarrage : étapes 5 et 6. **Attendu** à l'étape 6 : « Certificat restauré ». Vérifier : `kubectl -n acrm-demo get certificaterequest` → aucune ligne (rien n'a été redemandé).
- Le certificat dure 90 jours : au-delà, cert-manager le renouvelle seul (et `tls-backup.sh` sauvegarde le nouveau).

**Plan B si la limite est atteinte** (message `too many certificates` dans `kubectl -n acrm-demo describe certificaterequest`) : dans `apps/hello/hello.yaml`, `letsencrypt-prod` → `letsencrypt-staging` (PR), et `terraform apply -var ssl_mode=full` dans l'infra ; revenir en arrière une semaine plus tard.

## Dépannage

| Symptôme | Commande | Cause fréquente |
|---|---|---|
| `install.sh` : « API injoignable » | `jobs` ; `echo $KUBECONFIG` | Tunnel SSH fermé, ou `KUBECONFIG` non exporté dans ce terminal. |
| `sops-secrets-operator` bloqué en `Progressing` | `kubectl -n sops get pods` | Secret `sops-age-key-file` absent : relancer `install.sh`. |
| `cert-manager-config` `Degraded` | `kubectl -n cert-manager get sopssecrets` puis `describe` | Fichier chiffré pour une autre clé que celle déposée (`.sops.yaml` ≠ `keys.txt`). |
| Certificat jamais `READY` | `kubectl -n acrm-demo describe certificate,certificaterequest,order,challenge` | Jeton Cloudflare sans `DNS:Edit` sur `tramelya.es`, ou limite Let's Encrypt atteinte. |
| Erreur Cloudflare **526** | `kubectl -n acrm-demo get certificate` | SSL `strict` mais certificat pas encore prêt (attendre) ou émetteur staging (repasser en `full`). |
| Erreur Cloudflare **522 / 521** | `kubectl -n kube-system get pods` | Traefik pas prêt, ou serveur éteint. |
| Une Application `OutOfSync` en boucle | Interface Argo CD → *Diff* | Un champ réécrit par le cluster ; me montrer le diff. |

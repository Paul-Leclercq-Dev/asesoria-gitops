# Amorcer la plateforme GitOps (phases 4.2a et 4.2b)

Ce runbook se suit **dans l'ordre**, une étape à la fois. Chaque étape dit ce qu'elle fait, pourquoi, ce qu'elle crée (sur le Mac, sur GitHub, sur le serveur payant) et ce que tu dois voir. Les étapes 1 à 4 et 10 ne se font **qu'une fois** ; les étapes 5 à 9 se refont à chaque cluster neuf ; l'étape 11 est le test chronométré de la phase 4.

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

Où tu en es : le serveur et k3s existent (4.1). Ce runbook ajoute la couche « Git → Argo CD → cluster » (4.2a), puis le CRM sur `https://app.tramelya.es` (4.2b, étape 10). Notions propres à 4.2b : tableau en tête de l'étape 10.

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
- **Attendu** : 8 lignes `Synced` + `Healthy` : `root`, `argocd`, `sops-secrets-operator`, `cert-manager`, `cloudnative-pg`, `traefik-config`, `cert-manager-config`, `acrm-demo` (≈ 3 à 5 min pour la plateforme, puis 5 à 10 min de plus pour le CRM au premier démarrage : téléchargement des images, base, migrations, données de démo). Envoie-moi la sortie si une ligne reste `Progressing` ou `Degraded` plus de 10 minutes.
- Avant l'étape 10 (une seule fois), `acrm-demo` reste en erreur : ses secrets et ses images n'existent pas encore. C'est normal.

## 7. Vérifier le certificat puis passer Cloudflare en `strict`

```bash
kubectl -n acrm-demo get certificate      # READY = True (1 à 3 min après la création de « acrm-demo »)
curl -sI https://app.tramelya.es/healthz | head -1 # HTTP/2 200
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

**Plan B si la limite est atteinte** (message `too many certificates` dans `kubectl -n acrm-demo describe certificaterequest`) : dans `clusters/demo/acrm-demo.yaml`, ajouter `tls: { issuer: letsencrypt-staging }` sous `valuesObject` (PR), et `terraform apply -var ssl_mode=full` dans l'infra ; revenir en arrière une semaine plus tard.

## 10. Le CRM sur `https://app.tramelya.es` (phase 4.2b, une fois)

| Notion | Ce que c'est | Analogie |
|---|---|---|
| **Chart local** (`charts/acrm`) | Notre propre chart Helm : les manifestes du CRM (front, API, worker…) avec des trous remplis par des valeurs. L'Application `acrm-demo` lui donne celles de la démo. | Le même meuble en kit, monté dans une autre pièce avec d'autres dimensions. |
| **Deployment / pod** | Un pod = un ou plusieurs conteneurs qui tournent ensemble ; un Deployment garde N pods en vie et les remplace lors d'une nouvelle version. | Un poste de travail ; le Deployment, le chef d'équipe qui veille à ce qu'il soit toujours occupé. |
| **Service / Ingress** | Service = adresse stable d'un groupe de pods dans le cluster ; Ingress = règle « tel nom, tel chemin → tel Service » appliquée par Traefik. | Le standard téléphonique interne ; l'accueil qui oriente les visiteurs. |
| **Job / hook Argo CD** | Un Job lance un conteneur jusqu'au bout puis s'arrête. Un *hook* dit à Argo CD QUAND le lancer : migrations pendant la synchro (avant la nouvelle API), données de démo après. | Le contrôle technique fait avant de rouvrir le bâtiment. |
| **`Cluster` CloudNativePG** | Une base PostgreSQL décrite en YAML ; l'opérateur crée le pod, le disque, les rôles, et les maintient. | Commander une cuisine équipée plutôt que d'acheter chaque appareil. |
| **Rôles `acrm_admin` / `acrm_app` / `acrm_worker`** | Admin : propriétaire du schéma (migrations). App : l'API, soumise à la RLS (chaque cabinet ne voit que ses lignes). Worker : comme App, et peut lister les cabinets. | Le gérant de l'immeuble, les locataires, le gardien. |
| **Secret de pull (GHCR)** | Les images du CRM sont privées sur GHCR : Kubernetes a besoin d'un identifiant pour les télécharger. | Le badge pour entrer dans l'entrepôt. |
| **Probes** | `startup` (a-t-il fini de démarrer ?), `readiness` (peut-il recevoir du trafic : base et Redis joignables ?), `liveness` (est-il bloqué ? sinon on le relance). | Les questions d'un responsable avant d'ouvrir un guichet. |

Ordre dans l'Application `acrm-demo` : secrets → base, Redis, Mailpit, certificat → **migrations** → API, worker, front → **données de démo**. Tout est déclaré dans Git ; rien n'est lancé à la main.

### 10.1 Le bucket des documents (asesoria-infra)

Suivre `asesoria-infra/docs/storage.fr.md` (« Mise en place »). **Attendu** : 4 ressources créées.

### 10.2 Les images du CRM (asesoria-crm)

1. Merger la PR 4.2b du CRM (cible `seeder`), attendre la CI verte sur `main`.
2. Publier la version :
   ```bash
   cd ~/dev/asesoria-crm && git switch main && git pull
   git tag -a v0.2.0 -m "v0.2.0" && git push origin v0.2.0
   ```
3. GitHub → Actions → *Release* : 4 images (`acrm-api`, `acrm-api-migrator`, `acrm-api-seeder`, `acrm-web`) en `0.2.0`. ≈ 10 à 15 min.
- **Pourquoi un tag** : le cluster ne déploie que des versions figées et signées (ADR-016 du CRM). Déployer une nouvelle version plus tard = nouveau tag, puis changer `image.tag` dans `clusters/demo/acrm-demo.yaml` (PR).

### 10.3 Un jeton GitHub pour lire les images

GitHub → *Settings* → *Developer settings* → *Personal access tokens* → **Tokens (classic)** → *Generate new token* : nom `tramelya-ghcr-pull`, expiration 1 an, **une seule case : `read:packages`**. Copier le jeton (`ghp_…`) dans le gestionnaire de mots de passe.
- **Pourquoi « classic »** : GHCR n'accepte pas encore les jetons « fine-grained » pour lire des paquets.
- **Risque si le jeton fuit** : lecture de tes images (pas de ton code, pas d'écriture). Il est stocké chiffré (SOPS) dans le dépôt.

### 10.4 Les secrets (une fois)

```bash
cd ~/dev/asesoria-infra/envs/demo-data && set -a && . ./.env && set +a   # pour lire les clés S3 du state
cd ~/dev/asesoria-gitops   # sur la branche de la PR qui ajoute le CRM (la première fois : celle de la 4.2b)
export GHCR_USER=Paul-Leclercq-Dev
./scripts/acrm-secrets.sh            # demande le jeton GitHub (saisie invisible)
```
- **Crée** : `apps/acrm-demo/acrm-secrets.sops.yaml`, chiffré pour ta clé age (13 valeurs `ENC[…]`). Le fichier en clair n'existe que quelques millisecondes.
- **Attendu** : `OK : … chiffré (13 valeurs)` puis le **mot de passe des comptes de démo** : le ranger dans le gestionnaire (entrée « tramelya – démo CRM »). Il ne sera plus affiché (relire : `sops decrypt apps/acrm-demo/acrm-secrets.sops.yaml | grep SEED`).
- **Ne pas** relancer le script : il refuse d'écraser le fichier, et c'est voulu (mêmes secrets à chaque reconstruction). Rotation = `--force`, seulement juste avant une reconstruction (les mots de passe PostgreSQL sont posés à la création de la base).

```bash
git add apps/acrm-demo/acrm-secrets.sops.yaml && git commit -m "feat(acrm-demo): encrypted secrets" && git push
```
PR → CI verte → merge **après** la publication des images (10.2) : sinon le Job de migration attend une image qui n'existe pas et la synchronisation finit par abandonner (relance : § Dépannage, ligne `root`, avec `acrm-demo`).

### 10.5 Vérifier

```bash
kubectl -n argocd get applications                      # 8 lignes Synced + Healthy
kubectl -n acrm-demo get pods                           # acrm-api, -worker, -web, -redis, -mailpit Running ; acrm-db-1 Running ; jobs Completed
kubectl -n acrm-demo logs job/acrm-migrate | tail -3    # « All migrations have been successfully applied » (ou « No pending migrations »)
kubectl -n acrm-demo logs job/acrm-seed | tail -8       # comptes de démo (le mot de passe n'est PAS affiché)
```
Puis ouvrir https://app.tramelya.es, se connecter avec un compte `…owner@demo-levante.example` et le mot de passe de démo ; envoyer un document sur une fiche client puis l'ouvrir (preuve que le bucket S3 marche). Les e-mails (invitations, rappels) arrivent dans Mailpit, jamais chez un vrai destinataire :
```bash
kubectl -n acrm-demo port-forward svc/acrm-mailpit 8025   # puis http://localhost:8025
```

## 11. Test de reconstruction chronométré (critère de la phase 4 : < 1 h)

But : prouver qu'en partant d'un **serveur détruit**, Terraform + Argo CD recréent tout, CRM compris, en moins d'une heure, sans geste manuel en dehors de ce runbook. Le chronomètre tourne pendant tout le test, temps de réflexion compris.

1. **Avant** (non chronométré) : `./bootstrap/tls-backup.sh`, puis éteindre : `cd ~/dev/asesoria-infra/envs/demo && terraform apply -var server_enabled=false`. Vérifier : `terraform output server_ipv4` → `null`.
2. **Top départ** : `cd ~/dev/asesoria-gitops && ./bootstrap/rebuild-timer.sh start`
3. Étape 5 (`terraform apply`, kubeconfig, tunnel). Quand `kubectl get nodes` répond `Ready` : `./bootstrap/rebuild-timer.sh lap "nœud k3s Ready"`.
4. Étape 6 (`./bootstrap/install.sh`), puis : `./bootstrap/rebuild-timer.sh lap "amorçage Argo CD"`.
5. `./bootstrap/rebuild-timer.sh verify` : attend les 8 Applications, puis le seed, puis teste depuis Internet le front, l'API (base + Redis) et une **vraie connexion** d'un compte de démo. Il affiche le rapport (temps par étape, total, `RÉUSSI` / `ÉCHEC`).
6. M'envoyer le rapport : il va dans le journal du PLAN (preuve pour le portfolio).

Ce que le test ne couvre PAS (volontairement) : le bucket et les zones DNS, qui survivent au serveur (`envs/demo-data`, zones Cloudflare) ; les données saisies pendant la démo précédente (la base repart des données fictives).

## Dépannage

| Symptôme | Commande | Cause fréquente |
|---|---|---|
| `install.sh` : « API injoignable » | `jobs` ; `echo $KUBECONFIG` | Tunnel SSH fermé, ou `KUBECONFIG` non exporté dans ce terminal. |
| `sops-secrets-operator` bloqué en `Progressing` | `kubectl -n sops get pods` | Secret `sops-age-key-file` absent : relancer `install.sh`. |
| `cert-manager-config` `Degraded` | `kubectl -n cert-manager get sopssecrets` puis `describe` | Fichier chiffré pour une autre clé que celle déposée (`.sops.yaml` ≠ `keys.txt`). |
| Certificat jamais `READY` | `kubectl -n acrm-demo describe certificate,certificaterequest,order,challenge` | Jeton Cloudflare sans `DNS:Edit` sur `tramelya.es`, ou limite Let's Encrypt atteinte. |
| Erreur Cloudflare **526** | `kubectl -n acrm-demo get certificate` | SSL `strict` mais certificat pas encore prêt (attendre) ou émetteur staging (repasser en `full`). |
| Erreur Cloudflare **522 / 521** | `kubectl -n kube-system get pods` | Traefik pas prêt, ou serveur éteint. |
| `root` reste `OutOfSync`, des Applications manquent (`acrm-demo`, `argocd`) | `kubectl -n argocd get application root -o jsonpath='{.status.operationState.message}'` | « retried N times » : Argo CD a abandonné pendant qu'une vague devenait saine, et ne réessaie pas seul la même version de Git. Une fois les vagues précédentes `Healthy`, relancer (= bouton « Sync ») : `kubectl -n argocd patch application root --type merge -p '{"operation":{"initiatedBy":{"username":"paul"},"sync":{"revision":"main","prune":true}}}'` |
| Une Application `OutOfSync` en boucle | Interface Argo CD → *Diff* | Un champ réécrit par le cluster ; me montrer le diff. |
| `acrm-demo` : pods `ImagePullBackOff` | `kubectl -n acrm-demo describe pod <pod> \| tail -5` | `401` / `denied` : jeton GHCR expiré ou sans `read:packages` (étape 10.3, puis `acrm-secrets.sh --force`) ; `not found` : version `image.tag` jamais publiée (étape 10.2). |
| `acrm-demo` : pods `CreateContainerConfigError` | `kubectl -n acrm-demo get sopssecrets,secrets` | Secrets absents : fichier de l'étape 10.4 pas encore mergé, ou chiffré pour une autre clé. |
| Job `acrm-migrate` bloqué « En attente de PostgreSQL et des rôles » | `kubectl -n acrm-demo get cluster acrm-db` puis `describe` | Base pas encore prête (attendre 1 à 2 min) ; secret `acrm-db-app` / `-worker` absent (rôles non créés). |
| API `0/1 Ready` | `kubectl -n acrm-demo logs deploy/acrm-api \| tail -20` | Variable invalide (message zod au démarrage) ; base ou Redis injoignable (`/v1/health/ready`). |
| Envoi de document en erreur `STORAGE_UNAVAILABLE` | `kubectl -n acrm-demo logs deploy/acrm-api \| grep -i s3` | Bucket ou clés S3 : comparer `terraform output` (envs/demo-data) et le secret `acrm-s3`. |

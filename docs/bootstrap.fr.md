# Amorcer la plateforme GitOps (phases 4.2a, 4.2b et 4.3)

Ce runbook se suit **dans l'ordre**, une étape à la fois. Chaque étape dit ce qu'elle fait, pourquoi, ce qu'elle crée (sur le Mac, sur GitHub, sur le serveur payant) et ce que tu dois voir. Les étapes 1 à 4 et 10 ne se font **qu'une fois** ; les étapes 5 à 9 se refont à chaque cluster neuf ; l'étape 11 est le test chronométré de la phase 4 ; l'étape 12 (déploiement automatique et durcissement, 4.3) se fait une fois.

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

## 12. Déploiement automatique et durcissement (phase 4.3, une fois)

Où tu en es : le CRM tourne (étape 10). Jusqu'ici, un `git tag` publiait les images mais **ne déployait rien** : il fallait éditer `image.tag` à la main. Cette étape ajoute (1) une PR de déploiement ouverte toute seule par la release du CRM, (2) un pare-feu entre les pods, (3) un contrôle des pods à l'entrée de l'espace de noms. Décisions : [ADR-003](adr/003-cd-et-durcissement.md).

| Notion | Ce que c'est | Analogie |
|---|---|---|
| **CD** (déploiement continu) | Ce qui fait passer une version publiée jusqu'au cluster. Ici : une PR dans ce dépôt ; Argo CD applique au merge. | Le bon de livraison que tu signes : sans signature, le colis reste au dépôt. |
| **Empreinte / digest** (`sha256:…`) | L'identifiant calculé à partir du contenu de l'image. Un tag (`0.3.0`) est une étiquette qu'on peut recoller ailleurs ; une empreinte, non. | Le numéro de série gravé, contre l'étiquette collée sur le carton. |
| **GitHub App** | Un « compte robot » à toi, avec des droits choisis, sur les dépôts choisis, qui obtient des jetons d'une heure. | Un badge visiteur nominatif, valable une heure, pour une seule porte. |
| **NetworkPolicy** | Règle de pare-feu entre pods : qui peut parler à qui, sur quel port. Sans règle, tout le monde parle à tout le monde. | Les portes coupe-feu d'un immeuble : fermées par défaut, badge par porte. |
| **Pod Security `restricted`** | Étiquette posée sur un namespace : Kubernetes refuse tout pod en root, privilégié ou avec des capacités Linux. | Le portique à l'entrée : un pod mal habillé ne rentre pas. |
| **AppProject** (Argo CD) | La liste de ce qu'une Application a le droit de déployer (dépôts, namespaces, types d'objets). | Le badge d'accès du chef de chantier : quels étages, quelles pièces. |

Ordre : **12.1 → 12.4 dans ce dépôt (gitops)**, puis 12.5 → 12.7 côté CRM. Ne merge pas la PR du CRM avant d'avoir fini 12.4.

### 12.1 Vérifier AVANT le merge que les pods passent le portique

Ce que ça fait : demande au cluster « si je posais l'étiquette `restricted`, quels pods existants seraient refusés ? » **sans rien changer** (`--dry-run=server` = le serveur simule et répond, puis oublie).

```bash
kubectl label --dry-run=server --overwrite ns acrm-demo pod-security.kubernetes.io/enforce=restricted
```

| Morceau | Sens |
|---|---|
| `label … ns acrm-demo` | poser une étiquette sur le namespace `acrm-demo` |
| `--overwrite` | la remplacer si elle existe déjà |
| `--dry-run=server` | simulation par le serveur : rien n'est écrit |

Attendu : `namespace/acrm-demo labeled (server dry run)` **sans ligne `Warning:`**. S'il y a des `Warning: existing pods … violate …` : **ne merge pas**, envoie-moi la sortie.

### 12.2 Vérifier par où les pods de la base joignent l'API Kubernetes

La base (CloudNativePG) doit parler à l'API Kubernetes ; la NetworkPolicy n'ouvre que le port **6443**. On vérifie que c'est bien ce port :

```bash
kubectl get endpoints kubernetes -n default
```

Attendu : une ligne `kubernetes   <IP>:6443`. Si le port affiché n'est pas 6443 : envoie-moi la sortie avant de merger.

### 12.3 Merger la PR du dépôt gitops

PR de la branche `feat/cd-hardening` → CI verte (rendu Helm, kubeconform, Trivy) → merge. Argo CD applique dans les 3 minutes : namespace étiqueté, projet `acrm`, 9 NetworkPolicies. **Aucun pod ne redémarre** (les images ne changent pas).

### 12.4 Vérifier que tout marche… et que le pare-feu ferme vraiment

```bash
kubectl -n argocd get application acrm-demo                 # 1. Synced + Healthy
kubectl -n argocd get application acrm-demo -o jsonpath='{.spec.project}{"\n"}'   # 2. acrm
kubectl -n acrm-demo get networkpolicy                      # 3. 9 lignes
kubectl get ns acrm-demo --show-labels | tr ',' '\n' | grep pod-security   # 4. enforce=restricted…
```

Puis le test qui compte : **se connecter** sur `https://app.tramelya.es` et ouvrir un document (prouve Traefik → API → base, Redis et S3). Enfin la preuve que ça bloque : depuis le pod du front (qui n'a le droit d'appeler personne), on essaie de joindre l'API :

```bash
kubectl -n acrm-demo exec deploy/acrm-web -- wget -q -T 3 -O- http://acrm-api:3000/v1/health/live; echo "code=$?"
```

Attendu : après 3 s, `wget: download timed out` et `code=1` (bloqué = bien). Si tu vois `{"status":"ok"…}`, les politiques ne sont pas appliquées : envoie-moi la sortie.

### 12.5 Créer la GitHub App (sur GitHub, gratuit, 5 min)

1. GitHub → photo de profil → **Settings** → **Developer settings** → **GitHub Apps** → **New GitHub App**.
2. **GitHub App name** : `tramelya-gitops-bot` (si pris : ajoute un suffixe). **Homepage URL** : `https://github.com/Paul-Leclercq-Dev/asesoria-gitops`.
3. **Webhook** : décocher **Active** (l'App ne reçoit rien, elle agit seulement quand le job la sollicite).
4. **Repository permissions** : **Contents → Read and write**, **Pull requests → Read and write**. (Metadata passe en lecture tout seul.) Rien d'autre.
5. **Where can this GitHub App be installed?** → **Only on this account**. → **Create GitHub App**.
6. Sur la page de l'App : noter le **Client ID** (commence par `Iv`). En bas : **Generate a private key** → un fichier `.pem` est téléchargé. C'est un secret : il ne va **jamais** dans un dépôt.
7. Menu de gauche **Install App** → **Install** → **Only select repositories** → `asesoria-gitops` seul → **Install**.

Ce que ça crée : un robot qui ne peut écrire que dans `asesoria-gitops`. Rien de payant.

### 12.6 Donner l'App au dépôt du CRM

Pourquoi un « environnement » : un secret de dépôt est lisible par **tous** les workflows de toutes les branches. Un secret d'environnement n'est donné qu'aux jobs qui déclarent cet environnement, et ici seulement quand ils tournent sur un tag `v*`. *Analogie : la clé du camion de livraison est au guichet « départs », pas sur le tableau commun.*

1. `asesoria-crm` → **Settings** → **Environments** → **New environment** : nom `release` → **Configure environment**.
2. **Deployment branches and tags** → **Selected branches and tags** → **Add deployment branch or tag rule** → type **Tag**, motif `v*` → **Add rule**.
3. Même page, **Environment secrets** → **Add environment secret** : nom `GITOPS_APP_PRIVATE_KEY`, valeur = **tout** le contenu du `.pem` (lignes `-----BEGIN…` et `-----END…` comprises).
4. **Settings** → **Secrets and variables** → **Actions** → onglet **Variables** → **New repository variable** : nom `GITOPS_APP_CLIENT_ID`, valeur = le Client ID (pas secret : c'est un identifiant ; au niveau du dépôt car le job le lit pour décider s'il tourne).

Puis ranger le `.pem` dans ton gestionnaire de mots de passe et le supprimer de `~/Downloads`.

Enfin, côté **`asesoria-gitops`** : **Settings** → **Branches** (ou **Rules → Rulesets**) → règle sur `main` : **Require a pull request before merging** + **Require status checks to pass** (les 3 jobs de `validate`), **sans** exception pour l'App. Ainsi, même avec son jeton, le robot ne peut que *proposer* (PR), jamais pousser sur `main` — et c'est `main` qu'Argo CD applique. Si cette règle existe déjà, vérifie juste qu'aucune exception (« bypass ») n'est accordée.

### 12.7 Premier déploiement automatique

Après le merge de la PR du CRM (`feat/release-gitops-pr`) et sa CI verte sur `main` :

```bash
cd ~/dev/asesoria-crm && git switch main && git pull
git tag -a v0.2.1 -m "v0.2.1" && git push origin v0.2.1
```

Ce qui se passe (onglet **Actions** du CRM, ≈ 10 min) : garde → 4 images → release → **PR de version dans asesoria-gitops**. Dans `asesoria-gitops`, ouvre la PR `deploy(demo): acrm 0.2.1` : le diff ne doit toucher que `tag` et les 4 lignes `digests`. CI verte → merge. Puis :

```bash
kubectl -n acrm-demo get pods -o jsonpath='{range .items[*]}{.spec.containers[0].image}{"\n"}{end}' | sort -u
```

Attendu : des images `…:0.2.1@sha256:…`. Le CRM répond toujours sur `https://app.tramelya.es`.

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
| PR de version jamais ouverte après un tag | Actions du CRM → job « PR de version » | Job sauté : variable `GITOPS_APP_CLIENT_ID` absente (12.6). Erreur `Not Found` / `401` : App non installée sur `asesoria-gitops`, ou clé `.pem` incomplète. |
| Après 4.3, une fonction qui appelle l'extérieur échoue par délai dépassé | `kubectl -n acrm-demo get networkpolicy` | Flux non ouvert : toute nouvelle sortie (SMTP réel, Gmail, IA) s'ajoute dans `charts/acrm/templates/networkpolicy.yaml`. |
| Après 4.3, un pod n'est jamais créé (`FailedCreate`, « violates PodSecurity ») | `kubectl -n acrm-demo get events --field-selector reason=FailedCreate` | Conteneur sans `runAsNonRoot` / `capabilities.drop: [ALL]` / seccomp : corriger le template (ne pas retirer l'étiquette). |
| `acrm-demo` en erreur « not permitted in project » | `kubectl -n argocd get application acrm-demo -o jsonpath='{.status.conditions}'` | Le chart crée un objet hors `acrm-demo` ou de cluster : `clusters/demo/project-acrm.yaml`. |

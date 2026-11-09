# Secrets du CRM de démo

Ce dossier est la 2ᵉ source de l'Application `acrm-demo` (`clusters/demo/acrm-demo.yaml`).
Il contient :

- `namespace.yaml` : l'espace de noms `acrm-demo` avec les étiquettes **Pod Security
  `restricted`** (phase 4.3 : Kubernetes refuse tout pod qui tournerait en root, avec
  des privilèges ou des capacités Linux) ;
- `acrm-secrets.sops.yaml` : une ressource `SopsSecret` **chiffrée**
que l'opérateur SOPS transforme, dans le cluster, en 8 Secret Kubernetes
(mots de passe PostgreSQL et Redis, secret JWT, clés S3, mot de passe de démo,
accès à GHCR).

Ce fichier n'est jamais écrit à la main : `scripts/acrm-secrets.sh` le génère et le
chiffre (voir `docs/bootstrap.fr.md`, partie 4.2b). On le génère **une fois** ; il
sert ensuite à chaque reconstruction du cluster.

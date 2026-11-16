# TP1 bis – Architecture Serverless AWS en local (LocalEmu)

Ce TP reprend l'architecture du [TP1](../TP1/), mais avec les services AWS au lieu d'Azure. Comme pour le TP1, tout tourne en local : les services AWS sont émulés par **LocalEmu**. Je n'utilise ni compte AWS ni carte bancaire, et rien n'est déployé chez AWS.

Les Lambdas sont écrites en **Python 3.12**.

## Architecture

```
Client HTTP
     |
     v
API Gateway (local)        POST /requests
     |
     v
Lambda A  http-to-sqs      valide la requête et publie un message
     |
     v
SQS  requests-queue        file de messages (+ DLQ requests-queue-dlq)
     |
     v
Lambda B  sqs-to-dynamodb  déclenchée automatiquement par SQS
     |
     v
DynamoDB  requests         stockage des données
```

| Composant | Rôle |
|---|---|
| API Gateway | Expose la route HTTP `POST /requests` et transmet la requête à la Lambda A |
| Lambda A (`http-to-sqs`) | Vérifie les données reçues et publie un message dans SQS. Elle n'écrit jamais dans DynamoDB et n'appelle pas la Lambda B. |
| SQS (`requests-queue`) | Transporte les messages de façon asynchrone et découple les deux Lambdas |
| Lambda B (`sqs-to-dynamodb`) | Déclenchée par SQS grâce à un *event source mapping*. Elle lit le message et l'enregistre dans DynamoDB. |
| DynamoDB (`requests`) | Conserve les données traitées |

## Format des données

**1. Requête HTTP** (`POST /requests`, corps JSON)

```json
{ "client": "Alice", "montant": 42 }
```

- `client` : texte non vide (obligatoire)
- `montant` : nombre strictement positif (obligatoire)

Si les données sont invalides, la Lambda A répond `400` et ne publie rien dans la file. Sinon, elle répond `202 Accepted`. Ce code veut dire que la demande est acceptée, mais pas qu'elle est déjà enregistrée.

**2. Message SQS** (construit par la Lambda A)

```json
{
  "id": "3f1c2a9e-...",
  "receivedAt": "2026-11-16T10:00:00+00:00",
  "data": { "client": "Alice", "montant": 42 }
}
```

**3. Item DynamoDB** (table `requests`, clé de partition `id`)

| Attribut | Type | Description |
|---|---|---|
| `id` | S | identifiant unique, généré par la Lambda A |
| `client` | S | nom du client |
| `montant` | N | montant |
| `receivedAt` | S | date de réception par la Lambda A |
| `processedAt` | S | date de traitement par la Lambda B |

## Organisation du projet

```
TP1bis/
├── lambdas/
│   ├── http_to_sqs/handler.py       -> Lambda A
│   └── sqs_to_dynamodb/handler.py   -> Lambda B
├── infra/
│   ├── config.sh                    -> noms des ressources, région, endpoint local
│   ├── deploy.sh                    -> création des ressources dans LocalEmu
│   ├── check.sh                     -> liste des ressources créées
│   └── destroy.sh                   -> suppression des ressources
├── tests/
│   ├── payloads/                    -> exemples de requêtes valides et invalides
│   └── run_tests.sh                 -> scénarios de test
└── preuves/                         -> traces d'exécution (sorties des tests, logs)
```

## Prérequis

Sous Windows, le TP se fait dans **WSL2 (Ubuntu)**. LocalEmu ne fonctionne pas avec le Python de PowerShell.

| Outil | Vérification (dans Ubuntu) |
|---|---|
| WSL2 + Ubuntu | `wsl -l -v` (depuis PowerShell) |
| Docker Desktop, avec l'intégration WSL activée pour Ubuntu | `docker ps` |
| Python 3.12 (voir la remarque ci-dessous) | `python --version` dans l'environnement LocalEmu |
| Git | `git --version` |
| LocalEmu 1.4 | `localemu --version` |

Docker est nécessaire parce que LocalEmu exécute le code de chaque Lambda dans un conteneur.

### Installation de LocalEmu

> **Attention à Python 3.14** : la version de Python fournie par mon Ubuntu (3.14) ne permet pas d'installer `localemu[runtime]`, à cause d'un conflit de dépendances sur `aws-sam-translator`. J'ai donc créé l'environnement avec **Python 3.12**, grâce à `uv`.

Dans le terminal Ubuntu :

```bash
curl -LsSf https://astral.sh/uv/install.sh | sh
source ~/.local/bin/env
uv venv --python 3.12 ~/localemu-env
source ~/localemu-env/bin/activate
uv pip install "localemu[runtime]"
```

Si la version de Python du système est comprise entre 3.10 et 3.13, la méthode classique fonctionne aussi :

```bash
python3 -m venv ~/localemu-env
source ~/localemu-env/bin/activate
python3 -m pip install "localemu[runtime]"
```

### Démarrer LocalEmu

Dans un premier terminal Ubuntu, à laisser ouvert pour voir les logs :

```bash
source ~/localemu-env/bin/activate
localemu start
```

Dans un deuxième terminal Ubuntu :

```bash
source ~/localemu-env/bin/activate
localemu status
awsemu sts get-caller-identity
```

La dernière commande doit renvoyer le compte simulé `000000000000` :

```json
{
    "UserId": "AKIAIOSFODNN7EXAMPLE",
    "Account": "000000000000",
    "Arn": "arn:aws:iam::000000000000:root"
}
```

Pour arrêter l'émulateur à la fin :

```bash
localemu stop
```

## Créer les ressources dans LocalEmu

LocalEmu ne garde pas les ressources après un arrêt. J'ai donc écrit des scripts pour tout recréer en une commande. Ils sont dans `infra/` et se lancent depuis le dossier `TP1bis/`, dans Ubuntu :

```bash
cd /mnt/d/.../MBA-cloud/TP1bis
bash infra/deploy.sh      # crée (ou recrée) toutes les ressources
bash infra/check.sh       # liste les ressources présentes dans l'émulateur
bash infra/destroy.sh     # supprime tout
```

`deploy.sh` commence par tout supprimer, puis recrée les ressources dans cet ordre :

1. **SQS** : la file `requests-queue` et une *dead-letter queue* `requests-queue-dlq`. Un message dont le traitement échoue 3 fois est déplacé dans la DLQ, au lieu de boucler à l'infini.
2. **DynamoDB** : la table `requests`, avec la clé de partition `id` (type string), en mode à la demande.
3. **IAM** : un rôle `tp1bis-lambda-role`, qui n'a que les droits nécessaires (envoyer et lire dans la file, écrire dans la table, écrire les logs).
4. **Lambdas** : le code de chaque fonction est zippé dans `build/` (ignoré par git), puis les fonctions `http-to-sqs` et `sqs-to-dynamodb` sont créées en Python 3.12.
5. **Event source mapping** : il relie la file SQS à la Lambda B. C'est ce qui déclenche automatiquement la Lambda B à l'arrivée d'un message.
6. **API Gateway** : une API REST `tp1bis-api`, avec la route `POST /requests` en intégration proxy vers la Lambda A, déployée sur le stage `local`.

À la fin, le script affiche l'URL locale de l'API :

```
URL de l'API : http://localhost:4566/restapis/<id>/local/_user_request_/requests
```

L'id de l'API change à chaque déploiement. `bash infra/check.sh` permet de retrouver l'URL.

### Comment prouver qu'on cible bien l'émulateur et pas AWS ?

C'est la question posée à l'étape 2 du TP. Trois éléments le montrent :

1. **L'endpoint** : toutes les commandes passent par la fonction `awsl` de `infra/config.sh`, qui ajoute `--endpoint-url=http://localhost:4566`. Les requêtes partent donc vers ma machine et pas vers `*.amazonaws.com`. Avant de faire quoi que ce soit, les scripts vérifient que l'endpoint est bien `localhost`.
2. **Le compte** : `sts get-caller-identity` renvoie le compte `000000000000`, qui est le compte simulé de LocalEmu. Les scripts s'arrêtent si ce n'est pas ce compte.
3. **Les ressources elles-mêmes** : les URL des files sont du type `http://sqs.us-east-1.localhost:4566/000000000000/...` et tous les ARN contiennent `000000000000`.

De plus, les identifiants utilisés sont ceux d'exemple publiés par AWS (`AKIAIOSFODNN7EXAMPLE`). Même avec une erreur de configuration, ils ne permettraient pas d'accéder à un vrai compte.

Exemple de sortie de `bash infra/check.sh` :

```
OK : cible = LocalEmu (http://localhost:4566), compte simulé 000000000000

--- Files SQS ---
|  http://sqs.us-east-1.localhost:4566/000000000000/requests-queue-dlq  |
|  http://sqs.us-east-1.localhost:4566/000000000000/requests-queue      |
--- Tables DynamoDB ---
|  requests  |
--- Lambdas ---
|  http-to-sqs    |  python3.12 |  arn:aws:lambda:us-east-1:000000000000:function:http-to-sqs       |
|  sqs-to-dynamodb|  python3.12 |  arn:aws:lambda:us-east-1:000000000000:function:sqs-to-dynamodb   |
--- Déclencheurs (event source mappings) ---
|  ...function:sqs-to-dynamodb |  arn:aws:sqs:us-east-1:000000000000:requests-queue  |  Enabled |
--- API Gateway ---
|  tp1bis-api |  z8g04i61fq  |
```

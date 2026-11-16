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
│   ├── start-localemu.sh            -> démarrage de LocalEmu (réglages réseau WSL)
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
cd /mnt/d/.../MBA-cloud/TP1bis
bash infra/start-localemu.sh
```

> Sous Windows, il ne faut **pas** lancer simplement `localemu start` : les Lambdas ne pourraient pas communiquer avec l'émulateur et l'API répondrait `502`. Le script `start-localemu.sh` ajoute deux réglages réseau (`HOSTNAME_FROM_LAMBDA` et `LAMBDA_DEV_PORT_EXPOSE`), expliqués dans la partie [Difficultés rencontrées](#difficultés-rencontrées). Sous Linux natif, `localemu start` suffit.

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

## Lambda A – `http-to-sqs`

Fichier : `lambdas/http_to_sqs/handler.py`

Cette Lambda reçoit l'événement de l'API Gateway, en intégration proxy, et fait seulement 4 choses :

1. lire le corps JSON de la requête ;
2. valider les données : `client` doit être un texte non vide et `montant` un nombre strictement positif. Les booléens sont refusés, car en Python `True` est un `int` ;
3. construire le message, avec un `id` (UUID), la date `receivedAt` et les données ;
4. envoyer le message dans `requests-queue`, puis répondre.

| Cas | Code HTTP | Réponse | Message dans SQS ? |
|---|---|---|---|
| Données valides | `202` | `{"status": "accepted", "id": "..."}` | oui |
| Données invalides | `400` | `{"error": "données invalides", "details": [...]}` | non |
| JSON illisible | `400` | `{"error": "corps JSON invalide"}` | non |
| Erreur d'envoi vers SQS | `500` | `{"error": "impossible de publier le message"}` | non (l'erreur est écrite dans les logs) |

J'ai choisi le code **202 Accepted** plutôt que 200 ou 201. Il indique que la demande est acceptée mais pas encore traitée : au moment de la réponse, la donnée n'est pas forcément déjà dans DynamoDB.

La Lambda est **stateless** : elle ne garde rien entre deux appels. Le client SQS est créé une seule fois par conteneur, ce qui n'est qu'une optimisation. Elle ne connaît ni DynamoDB ni la Lambda B, seulement le nom de la file, qu'elle reçoit par la variable d'environnement `QUEUE_NAME`.

Dans LocalEmu, je n'ai rien eu à configurer dans le code pour viser l'émulateur. LocalEmu injecte la variable `AWS_ENDPOINT_URL` dans le conteneur, et `boto3` l'utilise automatiquement. Le même code fonctionnerait donc sur AWS.

Exemple de test, avec le déclencheur SQS mis en pause pour voir le message rester dans la file :

```
--- valide
{"status": "accepted", "id": "8dff8997-ff2a-4399-aa06-fa2942ba487e"}
HTTP 202
--- montant invalide
{"error": "données invalides", "details": ["'montant' doit être un nombre strictement positif"]}
HTTP 400
--- client manquant
{"error": "données invalides", "details": ["'client' doit être un texte non vide"]}
HTTP 400
--- JSON cassé
{"error": "corps JSON invalide"}
HTTP 400
--- contenu de la file (1 seul message : les requêtes invalides n'ont rien publié)
{"id": "8dff8997-...", "receivedAt": "2026-11-16T13:52:52.716764+00:00", "data": {"client": "Alice", "montant": 42}}
```

Logs de la Lambda A (CloudWatch Logs de LocalEmu) :

```
[INFO]    Message 8dff8997-... publié dans requests-queue (SQS MessageId=81eec902-...)
[WARNING] Requête refusée : ["'montant' doit être un nombre strictement positif"]
[WARNING] Requête refusée : ["'client' doit être un texte non vide"]
[WARNING] Requête refusée : corps JSON invalide
```

## Lambda B – `sqs-to-dynamodb`

Fichier : `lambdas/sqs_to_dynamodb/handler.py`

Cette Lambda n'est **jamais appelée directement**, ni par la Lambda A ni par moi. C'est l'*event source mapping* créé par `deploy.sh` qui interroge la file SQS et déclenche la Lambda dès qu'il y a des messages, par lots de 5 au maximum.

Pour chaque message du lot, elle :

1. lit le JSON du message. Les décimaux sont lus en `Decimal`, parce que DynamoDB refuse les `float` Python ;
2. vérifie que `id`, `data.client` et `data.montant` sont présents et du bon type ;
3. ajoute la date de traitement `processedAt` ;
4. écrit l'item dans la table `requests`.

### Gestion des erreurs

- Si un message est invalide ou que l'écriture échoue, l'erreur est écrite dans les logs avec le `messageId` SQS et le contenu du message, pour pouvoir diagnostiquer.
- La Lambda renvoie à SQS la liste des messages en échec (`batchItemFailures`, activé avec `ReportBatchItemFailures` sur le mapping). Seuls ces messages sont retentés : les autres messages du même lot sont validés normalement.
- Après **3 échecs**, SQS déplace le message dans la **DLQ** `requests-queue-dlq`. Il ne bloque donc pas la file et on peut l'analyser ensuite.

### Messages en double (idempotence)

SQS standard garantit une livraison « au moins une fois » : un même message peut arriver deux fois. Pour que ça ne pose pas de problème, l'écriture est conditionnelle :

```python
table.put_item(Item=item, ConditionExpression="attribute_not_exists(id)")
```

Si un item avec le même `id` existe déjà, DynamoDB refuse l'écriture (`ConditionalCheckFailedException`). La Lambda considère alors le message comme déjà traité, l'écrit dans les logs et passe à la suite, sans erreur et sans écraser l'item.

### Test

Scénario lancé :
- trois appels HTTP avec des données différentes ;
- un message invalide (`{"pas":"le bon format"}`) déposé directement dans la file ;
- deux fois le même message (`id = doublon-test-1`).

Contenu de la table après traitement : **4 items**, les 3 appels HTTP plus 1 seul exemplaire du doublon.

```
|  b09c733d-...  |  Bob     |  19.99 |  2026-11-16T14:26:11.798220+00:00  |  2026-11-16T14:26:15.274859+00:00  |
|  c87c5516-...  |  Alice   |  42    |  2026-11-16T14:26:11.660339+00:00  |  2026-11-16T14:26:15.106215+00:00  |
|  dd88253b-...  |  Chloé   |  7     |  2026-11-16T14:26:11.996776+00:00  |  2026-11-16T14:26:16.371089+00:00  |
|  doublon-test-1|  Doublon |  1     |  2026-11-16T00:00:00+00:00         |  2026-11-16T14:26:16.387376+00:00  |
```

Le message invalide a été retenté puis s'est retrouvé dans la DLQ au bout d'environ 80 secondes : 3 réceptions, avec 30 secondes de *visibility timeout* entre chaque.

Logs de la Lambda B (extraits) :

```
[INFO]    Lot reçu de SQS : 2 message(s)
[INFO]    Item c87c5516-... écrit dans requests (client=Alice, montant=42)
[INFO]    Item b09c733d-... écrit dans requests (client=Bob, montant=19.99)
[INFO]    Lot reçu de SQS : 4 message(s)
[INFO]    Item dd88253b-... écrit dans requests (client=Chloé, montant=7)
[ERROR]   Message SQS 6b558a2d-... invalide : champ 'id' manquant | body={"pas": "le bon format"}
[INFO]    Item doublon-test-1 écrit dans requests (client=Doublon, montant=1)
[WARNING] Item doublon-test-1 déjà présent : message en double ignoré
[WARNING] 1 message(s) en échec renvoyé(s) dans la file
[ERROR]   Message SQS 6b558a2d-... invalide : champ 'id' manquant      <- 2e tentative (+35 s)
[ERROR]   Message SQS 6b558a2d-... invalide : champ 'id' manquant      <- 3e tentative (+34 s) -> DLQ
```

On voit aussi que la réponse HTTP (`202`, à 14:26:11) arrive **avant** l'écriture dans DynamoDB (`processedAt` à 14:26:15). Le traitement est bien asynchrone.

## Difficultés rencontrées

### 1. Python 3.14 incompatible avec LocalEmu

`pip install "localemu[runtime]"` échouait avec `ResolutionImpossible`. Sous Python 3.14, `moto-ext` demande `aws-sam-translator<=1.103.0`, alors que LocalEmu demande `>=1.105.0`. J'ai contourné le problème en créant l'environnement avec Python 3.12 grâce à `uv` (voir [Installation](#installation-de-localemu)).

### 2. Commandes lancées dans PowerShell au lieu d'Ubuntu

Au début, j'ai lancé l'installation dans PowerShell. pip a alors utilisé le Python de Windows et a échoué à cause de la limite de longueur des chemins. Il faut bien taper `wsl -d Ubuntu` avant, et vérifier que l'invite est du type `utilisateur@machine:~$`.

### 3. API Gateway répondait 502 : problème réseau entre LocalEmu et les conteneurs Lambda

C'est le problème qui m'a pris le plus de temps. Avec un simple `localemu start`, chaque appel à l'API renvoyait `{"message": "Internal server error"}` (HTTP 502) au bout de plusieurs secondes.

En regardant les logs du conteneur Lambda (`docker logs`), j'ai trouvé :

```
Failed to send status ready to LocalEmu Post "http://172.17.0.1:4566/_localemu_lambda/.../ready":
dial tcp 172.17.0.1:4566: connect: connection refused
```

L'explication : sous Windows, LocalEmu tourne dans Ubuntu (WSL2), mais Docker Desktop lance les conteneurs dans **sa propre machine virtuelle**. Les deux sont sur des réseaux différents, et la communication bloque dans les deux sens :

| Sens | Problème | Solution |
|---|---|---|
| Conteneur → LocalEmu | l'adresse par défaut `172.17.0.1` mène à la VM Docker, pas à Ubuntu | `HOSTNAME_FROM_LAMBDA=host.docker.internal` : Docker Desktop redirige cette adresse vers la machine hôte, où le port 4566 est accessible |
| LocalEmu → conteneur | l'IP interne du conteneur (`172.17.0.x`) n'est pas joignable depuis Ubuntu, donc LocalEmu ne peut pas envoyer l'invocation | `LAMBDA_DEV_PORT_EXPOSE=1` : le port du conteneur est publié sur `127.0.0.1` (c'est ce que LocalEmu fait déjà par défaut sur macOS) |

J'ai vérifié chaque sens à la main : un `curl` depuis un conteneur vers `host.docker.internal:4566` répondait `200`, alors qu'un `curl` depuis Ubuntu vers l'IP du conteneur ne répondait pas. Les deux réglages sont dans `infra/start-localemu.sh`, pour ne pas avoir à s'en souvenir.

### 4. Déclencheur SQS bloqué en état « Deleting »

Pour tester la Lambda A seule, j'avais mis le déclencheur SQS en pause (`update-event-source-mapping --no-enabled`), afin de voir les messages rester dans la file. Au déploiement suivant, `create-event-source-mapping` échouait avec `ResourceConflictException` : l'ancien déclencheur existait toujours, bloqué à l'état `Deleting`.

En lisant le code de LocalEmu (`esm_worker.py`), j'ai vu que la suppression n'est finalisée que si le déclencheur est **activé**. Un déclencheur désactivé puis supprimé reste donc bloqué pour toujours, et seul un redémarrage de LocalEmu le fait disparaître. C'est un bug de l'émulateur : sur AWS, la suppression fonctionne dans les deux cas.

Ce que j'ai fait :
- `destroy.sh` attend maintenant que la suppression du déclencheur soit vraiment terminée, car elle est asynchrone ;
- `deploy.sh` détecte ce cas et affiche un message clair qui demande de redémarrer LocalEmu ;
- je ne désactive plus le déclencheur pendant les tests.

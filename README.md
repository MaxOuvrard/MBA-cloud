# MBA Cloud – Travaux pratiques

Dépôt regroupant les TP du cours de Cloud (MBA 2). Chaque TP est dans son propre dossier, avec son code et son README expliquant comment le lancer.

| TP | Sujet | Technologies |
|---|---|---|
| [TP1](TP1/) | Architecture serverless en local : HTTP → Queue → Table | Azure Functions (Node.js), Azurite |
| [TP1bis](TP1bis/) | Même architecture côté AWS : HTTP → Lambda → SQS → Lambda → DynamoDB | AWS Lambda, API Gateway, SQS, DynamoDB, LocalEmu |

Tous les TP tournent en local : aucun compte cloud ni aucune ressource distante n'est utilisé.

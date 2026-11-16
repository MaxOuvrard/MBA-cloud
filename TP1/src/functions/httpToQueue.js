const { app, output } = require('@azure/functions');

// Sortie vers la Queue Storage (créée automatiquement si elle n'existe pas)
const queueOutput = output.storageQueue({
    queueName: 'requests-queue',
    connection: 'AzureWebJobsStorage'
});

app.http('httpToQueue', {
    methods: ['GET', 'POST'],
    authLevel: 'anonymous',
    extraOutputs: [queueOutput],
    handler: async (request, context) => {
        // 1. Extraire les données reçues (corps JSON en POST, paramètres d'URL en GET)
        let data;
        if (request.method === 'POST') {
            try {
                data = await request.json();
            } catch {
                return { status: 400, jsonBody: { error: 'Corps JSON invalide' } };
            }
        } else {
            data = Object.fromEntries(request.query.entries());
        }

        if (!data || Object.keys(data).length === 0) {
            return { status: 400, jsonBody: { error: 'Aucune donnée reçue' } };
        }

        // 2. Publier le message dans la queue (aucun état conservé dans la fonction)
        const message = {
            id: context.invocationId,
            receivedAt: new Date().toISOString(),
            data
        };
        context.extraOutputs.set(queueOutput, message);
        context.log(`Message ${message.id} publié dans requests-queue`);

        // 3. Répondre immédiatement
        return { status: 202, jsonBody: { status: 'queued', id: message.id } };
    }
});

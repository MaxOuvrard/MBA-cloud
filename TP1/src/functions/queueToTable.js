const { app, output } = require('@azure/functions');

// Sortie vers la Table Storage (créée automatiquement si elle n'existe pas)
const tableOutput = output.table({
    tableName: 'requests',
    connection: 'AzureWebJobsStorage'
});

app.storageQueue('queueToTable', {
    queueName: 'requests-queue',
    connection: 'AzureWebJobsStorage',
    extraOutputs: [tableOutput],
    handler: async (queueItem, context) => {
        // 1. Lire le message reçu (objet JSON publié par httpToQueue)
        const message = typeof queueItem === 'string' ? JSON.parse(queueItem) : queueItem;
        context.log(`Message ${message.id} reçu depuis requests-queue`, message);

        // 2. Construire l'entité : une Table n'accepte que des valeurs simples
        const entity = {
            PartitionKey: 'requests',
            RowKey: message.id,
            receivedAt: message.receivedAt
        };
        for (const [key, value] of Object.entries(message.data ?? {})) {
            entity[key] = typeof value === 'object' && value !== null ? JSON.stringify(value) : value;
        }

        // 3. Écrire dans la table via le binding de sortie
        context.extraOutputs.set(tableOutput, entity);
        context.log(`Entité ${entity.RowKey} écrite dans la table requests`);
    }
});

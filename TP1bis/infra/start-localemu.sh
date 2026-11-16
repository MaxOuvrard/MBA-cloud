#!/usr/bin/env bash
# Démarre LocalEmu avec la configuration réseau nécessaire sous Windows (WSL2 + Docker Desktop).
# Usage (dans Ubuntu, depuis TP1bis/) : bash infra/start-localemu.sh
#
# Problème : LocalEmu tourne dans Ubuntu, mais les conteneurs Lambda tournent dans la VM de
# Docker Desktop. Les deux ne se voient pas par défaut, et API Gateway répond 502.
#
# - HOSTNAME_FROM_LAMBDA=host.docker.internal
#     sens conteneur -> LocalEmu : l'adresse par défaut (172.17.0.1) est refusée,
#     host.docker.internal est redirigé par Docker Desktop vers la machine hôte (port 4566).
# - LAMBDA_DEV_PORT_EXPOSE=1
#     sens LocalEmu -> conteneur : l'IP interne du conteneur (172.17.0.x) n'est pas joignable
#     depuis Ubuntu ; avec cette option, le port du conteneur est publié sur 127.0.0.1.
#     (c'est le comportement par défaut de LocalEmu sur macOS, qui a le même problème)
set -euo pipefail

if ! command -v localemu > /dev/null 2>&1; then
    source "$HOME/localemu-env/bin/activate"
fi

export HOSTNAME_FROM_LAMBDA="${HOSTNAME_FROM_LAMBDA:-host.docker.internal}"
export LAMBDA_DEV_PORT_EXPOSE="${LAMBDA_DEV_PORT_EXPOSE:-1}"
echo "HOSTNAME_FROM_LAMBDA=$HOSTNAME_FROM_LAMBDA"
echo "LAMBDA_DEV_PORT_EXPOSE=$LAMBDA_DEV_PORT_EXPOSE"
exec localemu start "$@"

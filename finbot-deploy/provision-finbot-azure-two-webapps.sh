#!/usr/bin/env bash
set -euo pipefail

# provision-finbot-azure-two-webapps.sh
# See README in the package for usage and security notes.
#
# IMPORTANT: Review and edit variables at the top before running.

# -------------------------
# Parameters (edit or export as env vars before running)
# -------------------------
RG="${RG:-finbot-rg}"
LOCATION="${LOCATION:-eastus}"
VNET_NAME="${VNET_NAME:-finbot-vnet}"
SUBNET_APP="${SUBNET_APP:-subnet-app}"
SUBNET_DB="${SUBNET_DB:-subnet-db}"
ACR_NAME="${ACR_NAME:-finbotacr$RANDOM}"
PLAN_NAME="${PLAN_NAME:-finbot-plan}"
WEBAPP_PROXY="${WEBAPP_PROXY:-finbot-proxy}"
WEBAPP_BACKEND="${WEBAPP_BACKEND:-finbot-backend}"
PG_SERVER_NAME="${PG_SERVER_NAME:-finbotpg$RANDOM}"
PG_ADMIN="${PG_ADMIN:-pgadminuser}"
PG_PASSWORD="${PG_PASSWORD:-$(openssl rand -base64 16)}"
KEYVAULT_NAME="${KEYVAULT_NAME:-finbot-kv$RANDOM}"
BASIC_AUTH_USER="${BASIC_AUTH_USER:-attendee}"
BASIC_AUTH_PASS="${BASIC_AUTH_PASS:-$(openssl rand -base64 12)}"
FINBOT_BACKEND_TAG="${FINBOT_BACKEND_TAG:-finbot-backend:latest}"
FINBOT_PROXY_TAG="${FINBOT_PROXY_TAG:-finbot-proxy:latest}"
USE_ACR_BUILD="${USE_ACR_BUILD:-true}"   # true uses az acr build; false builds locally and pushes
OPENAI_API_KEY="${OPENAI_API_KEY:-}"     # optional; if empty, LLM_PROVIDER=mock
TIMEOUT_SECONDS=900
SLEEP_INTERVAL=10

# -------------------------
# Helpers
# -------------------------
log() { echo "[$(date -u +'%Y-%m-%dT%H:%M:%SZ')] $*"; }

wait_for() {
  local cmd="$1" expected="$2" timeout="${3:-$TIMEOUT_SECONDS}"
  local waited=0
  while true; do
    if eval "$cmd" 2>/dev/null | grep -q "$expected"; then
      return 0
    fi
    if [ "$waited" -ge "$timeout" ]; then
      log "Timed out waiting for: $cmd to contain $expected"
      return 1
    fi
    sleep $SLEEP_INTERVAL
    waited=$((waited + SLEEP_INTERVAL))
  done
}

# -------------------------
# Pre-checks
# -------------------------
if ! command -v az >/dev/null 2>&1; then
  echo "Azure CLI (az) is required. Install or run in Azure Cloud Shell."
  exit 1
fi

# -------------------------
# 1 Create resource group and VNet/subnets
# -------------------------
log "Creating resource group $RG in $LOCATION"
az group create -n "$RG" -l "$LOCATION" --output none

log "Creating VNet $VNET_NAME with subnets $SUBNET_APP and $SUBNET_DB"
az network vnet create -g "$RG" -n "$VNET_NAME" --address-prefix 10.0.0.0/16 \
  --subnet-name "$SUBNET_APP" --subnet-prefix 10.0.1.0/24 --output none

az network vnet subnet create -g "$RG" --vnet-name "$VNET_NAME" -n "$SUBNET_DB" --address-prefix 10.0.2.0/24 --output none

# -------------------------
# 2 Create ACR and build/push images
# -------------------------
log "Creating Azure Container Registry $ACR_NAME"
az acr create -g "$RG" -n "$ACR_NAME" --sku Basic --admin-enabled false --output none

ACR_LOGIN_SERVER="$(az acr show -n "$ACR_NAME" -g "$RG" --query loginServer -o tsv)"
log "ACR login server is $ACR_LOGIN_SERVER"

if [ "$USE_ACR_BUILD" = "true" ]; then
  log "Building backend image in ACR: $FINBOT_BACKEND_TAG"
  az acr build -r "$ACR_NAME" -t "$FINBOT_BACKEND_TAG" -f Dockerfile.backend .
  log "Building proxy image in ACR: $FINBOT_PROXY_TAG"
  az acr build -r "$ACR_NAME" -t "$FINBOT_PROXY_TAG" -f Dockerfile.proxy .
else
  log "Building locally and pushing to ACR"
  docker build -t "$ACR_LOGIN_SERVER/$FINBOT_BACKEND_TAG" -f Dockerfile.backend .
  docker build -t "$ACR_LOGIN_SERVER/$FINBOT_PROXY_TAG" -f Dockerfile.proxy .
  az acr login -n "$ACR_NAME"
  docker push "$ACR_LOGIN_SERVER/$FINBOT_BACKEND_TAG"
  docker push "$ACR_LOGIN_SERVER/$FINBOT_PROXY_TAG"
fi

# -------------------------
# 3 Create PostgreSQL Flexible Server with Private Endpoint
# -------------------------
log "Creating PostgreSQL Flexible Server $PG_SERVER_NAME"
az postgres flexible-server create -g "$RG" -n "$PG_SERVER_NAME" \
  --admin-user "$PG_ADMIN" --admin-password "$PG_PASSWORD" \
  --sku-name Standard_B1ms --version 16 --storage-size 32 \
  --public-access none --location "$LOCATION" --output none

log "Waiting for PostgreSQL server to be ready"
wait_for "az postgres flexible-server show -g $RG -n $PG_SERVER_NAME --query provisioningState -o tsv" "Succeeded" || { log "Postgres not ready"; exit 1; }

PE_PG_NAME="${PG_SERVER_NAME}-pe"
log "Creating Private Endpoint $PE_PG_NAME for Postgres in subnet $SUBNET_DB"
PG_RESOURCE_ID=$(az postgres flexible-server show -g "$RG" -n "$PG_SERVER_NAME" --query id -o tsv)
az network private-endpoint create -g "$RG" -n "$PE_PG_NAME" --vnet-name "$VNET_NAME" --subnet "$SUBNET_DB" \
  --private-connection-resource-id "$PG_RESOURCE_ID" --group-ids postgresqlServer --connection-name "${PE_PG_NAME}-conn" --output none

PG_DNS_ZONE="privatelink.postgres.database.azure.com"
log "Creating Private DNS zone $PG_DNS_ZONE and linking to VNet"
az network private-dns zone create -g "$RG" -n "$PG_DNS_ZONE" --output none
az network private-dns link vnet create -g "$RG" -n "${VNET_NAME}-link" -z "$PG_DNS_ZONE" --virtual-network "$VNET_NAME" --registration-enabled false --output none

log "Waiting for Postgres private endpoint NIC to be provisioned"
wait_for "az network private-endpoint show -g $RG -n $PE_PG_NAME --query provisioningState -o tsv" "Succeeded" || { log "Postgres PE not ready"; exit 1; }

PE_PG_NIC_ID=$(az network private-endpoint show -g "$RG" -n "$PE_PG_NAME" --query 'networkInterfaces[0].id' -o tsv)
PE_PG_IP=$(az network nic show --ids "$PE_PG_NIC_ID" --query 'ipConfigurations[0].privateIpAddress' -o tsv)
PG_HOSTNAME="${PG_SERVER_NAME}.postgres.database.azure.com"
log "Creating DNS A record $PG_HOSTNAME -> $PE_PG_IP"
az network private-dns record-set a create -g "$RG" -z "$PG_DNS_ZONE" -n "$PG_HOSTNAME" --output none || true
az network private-dns record-set a add-record -g "$RG" -z "$PG_DNS_ZONE" -n "$PG_HOSTNAME" --ipv4-address "$PE_PG_IP" --output none

# -------------------------
# 4 Create Key Vault and store secrets including OpenAI
# -------------------------
log "Creating Key Vault $KEYVAULT_NAME"
az keyvault create -g "$RG" -n "$KEYVAULT_NAME" --location "$LOCATION" --enable-soft-delete true --output none

log "Storing Postgres password and Basic Auth credentials in Key Vault"
az keyvault secret set --vault-name "$KEYVAULT_NAME" -n "PgPassword" --value "$PG_PASSWORD" --output none
az keyvault secret set --vault-name "$KEYVAULT_NAME" -n "BasicAuthUser" --value "$BASIC_AUTH_USER" --output none
az keyvault secret set --vault-name "$KEYVAULT_NAME" -n "BasicAuthPass" --value "$BASIC_AUTH_PASS" --output none

if [ -n "$OPENAI_API_KEY" ]; then
  log "Storing OpenAI API key in Key Vault as OpenAIKey"
  az keyvault secret set --vault-name "$KEYVAULT_NAME" -n "OpenAIKey" --value "$OPENAI_API_KEY" --output none
  LLM_PROVIDER_VALUE="openai"
else
  log "No OPENAI_API_KEY provided; using mock LLM provider"
  LLM_PROVIDER_VALUE="mock"
fi

# -------------------------
# 5 Create App Service Plan and two Web Apps for Containers
# -------------------------
log "Creating App Service plan $PLAN_NAME"
az appservice plan create -g "$RG" -n "$PLAN_NAME" --is-linux --sku B1 --output none

log "Creating Web App backend $WEBAPP_BACKEND using image $ACR_LOGIN_SERVER/$FINBOT_BACKEND_TAG"
az webapp create -g "$RG" -p "$PLAN_NAME" -n "$WEBAPP_BACKEND" --deployment-container-image-name "$ACR_LOGIN_SERVER/$FINBOT_BACKEND_TAG" --output none

log "Creating Web App proxy $WEBAPP_PROXY using image $ACR_LOGIN_SERVER/$FINBOT_PROXY_TAG"
az webapp create -g "$RG" -p "$PLAN_NAME" -n "$WEBAPP_PROXY" --deployment-container-image-name "$ACR_LOGIN_SERVER/$FINBOT_PROXY_TAG" --output none

# Assign system-assigned managed identities
log "Assigning managed identity to backend Web App"
az webapp identity assign -g "$RG" -n "$WEBAPP_BACKEND" --output none
BACKEND_PRINCIPAL_ID=$(az webapp show -g "$RG" -n "$WEBAPP_BACKEND" --query identity.principalId -o tsv)

log "Assigning managed identity to proxy Web App"
az webapp identity assign -g "$RG" -n "$WEBAPP_PROXY" --output none
PROXY_PRINCIPAL_ID=$(az webapp show -g "$RG" -n "$WEBAPP_PROXY" --query identity.principalId -o tsv)

# Grant AcrPull role to both identities
ACR_ID=$(az acr show -n "$ACR_NAME" -g "$RG" --query id -o tsv)
log "Granting AcrPull role to backend identity"
az role assignment create --assignee "$BACKEND_PRINCIPAL_ID" --role "AcrPull" --scope "$ACR_ID" --output none
log "Granting AcrPull role to proxy identity"
az role assignment create --assignee "$PROXY_PRINCIPAL_ID" --role "AcrPull" --scope "$ACR_ID" --output none

# -------------------------
# 6 Configure Key Vault access policies for Web App identities
# -------------------------
log "Granting Key Vault get/list secret access to backend identity"
az keyvault set-policy -n "$KEYVAULT_NAME" --object-id "$BACKEND_PRINCIPAL_ID" --secret-permissions get list --output none

log "Granting Key Vault get/list secret access to proxy identity"
az keyvault set-policy -n "$KEYVAULT_NAME" --object-id "$PROXY_PRINCIPAL_ID" --secret-permissions get list --output none

# Wait for Key Vault secret URIs
log "Fetching Key Vault secret URIs"
PG_SECRET_URI=$(az keyvault secret show --vault-name "$KEYVAULT_NAME" -n "PgPassword" --query id -o tsv)
BASIC_USER_URI=$(az keyvault secret show --vault-name "$KEYVAULT_NAME" -n "BasicAuthUser" --query id -o tsv)
BASIC_PASS_URI=$(az keyvault secret show --vault-name "$KEYVAULT_NAME" -n "BasicAuthPass" --query id -o tsv)
if [ -n "$OPENAI_API_KEY" ]; then
  OPENAI_SECRET_URI=$(az keyvault secret show --vault-name "$KEYVAULT_NAME" -n "OpenAIKey" --query id -o tsv)
fi

# -------------------------
# 7 Configure App Settings for backend and proxy
# -------------------------
# Note: BACKEND_HOSTNAME will be set on the proxy later (after private endpoint creation)
PG_CONN="postgresql://${PG_ADMIN}@${PG_HOSTNAME}:5432/postgres"
log "Configuring backend app settings with Key Vault references and LLM_PROVIDER=$LLM_PROVIDER_VALUE"

BACKEND_SETTINGS=(
  "DATABASE_URL=$PG_CONN"
  "PG_PASSWORD=@Microsoft.KeyVault(SecretUri=${PG_SECRET_URI})"
  "LLM_PROVIDER=${LLM_PROVIDER_VALUE}"
)

if [ -n "$OPENAI_API_KEY" ]; then
  BACKEND_SETTINGS+=("OPENAI_API_KEY=@Microsoft.KeyVault(SecretUri=${OPENAI_SECRET_URI})")
fi

az webapp config appsettings set -g "$RG" -n "$WEBAPP_BACKEND" --settings "${BACKEND_SETTINGS[@]}" --output none

log "Configuring proxy app settings to reference Basic Auth secrets"
PROXY_SETTINGS=(
  "BASIC_AUTH_USER=@Microsoft.KeyVault(SecretUri=${BASIC_USER_URI})"
  "BASIC_AUTH_PASS=@Microsoft.KeyVault(SecretUri=${BASIC_PASS_URI})"
)
az webapp config appsettings set -g "$RG" -n "$WEBAPP_PROXY" --settings "${PROXY_SETTINGS[@]}" --output none

# -------------------------
# 8 Create Private Endpoint for backend Web App and Private DNS
# -------------------------
BACKEND_RESOURCE_ID=$(az webapp show -g "$RG" -n "$WEBAPP_BACKEND" --query id -o tsv)
PE_BACKEND_NAME="${WEBAPP_BACKEND}-pe"
log "Creating Private Endpoint $PE_BACKEND_NAME for backend Web App in subnet $SUBNET_DB"
az network private-endpoint create -g "$RG" -n "$PE_BACKEND_NAME" --vnet-name "$VNET_NAME" --subnet "$SUBNET_DB" \
  --private-connection-resource-id "$BACKEND_RESOURCE_ID" --group-ids sites --connection-name "${PE_BACKEND_NAME}-conn" --output none

WEB_DNS_ZONE="privatelink.azurewebsites.net"
log "Creating Private DNS zone $WEB_DNS_ZONE and linking to VNet"
az network private-dns zone create -g "$RG" -n "$WEB_DNS_ZONE" --output none
az network private-dns link vnet create -g "$RG" -n "${VNET_NAME}-link-web" -z "$WEB_DNS_ZONE" --virtual-network "$VNET_NAME" --registration-enabled false --output none

log "Waiting for backend Web App private endpoint to be ready"
wait_for "az network private-endpoint show -g $RG -n $PE_BACKEND_NAME --query provisioningState -o tsv" "Succeeded" || { log "Backend PE not ready"; exit 1; }

PE_BACKEND_NIC_ID=$(az network private-endpoint show -g "$RG" -n "$PE_BACKEND_NAME" --query 'networkInterfaces[0].id' -o tsv)
PE_BACKEND_IP=$(az network nic show --ids "$PE_BACKEND_NIC_ID" --query 'ipConfigurations[0].privateIpAddress' -o tsv)
BACKEND_HOSTNAME="${WEBAPP_BACKEND}.azurewebsites.net"
log "Creating DNS A record $BACKEND_HOSTNAME -> $PE_BACKEND_IP"
az network private-dns record-set a create -g "$RG" -z "$WEB_DNS_ZONE" -n "$BACKEND_HOSTNAME" --output none || true
az network private-dns record-set a add-record -g "$RG" -z "$WEB_DNS_ZONE" -n "$BACKEND_HOSTNAME" --ipv4-address "$PE_BACKEND_IP" --output none

# -------------------------
# 9 Set BACKEND_HOSTNAME app setting on proxy (runtime substitution)
# -------------------------
log "Setting BACKEND_HOSTNAME app setting on proxy Web App so proxy can envsubst at startup"
az webapp config appsettings set -g "$RG" -n "$WEBAPP_PROXY" --settings "BACKEND_HOSTNAME=${BACKEND_HOSTNAME}" --output none

# -------------------------
# 10 Create Private Endpoint for proxy Web App and Private DNS
# -------------------------
PROXY_RESOURCE_ID=$(az webapp show -g "$RG" -n "$WEBAPP_PROXY" --query id -o tsv)
PE_PROXY_NAME="${WEBAPP_PROXY}-pe"
log "Creating Private Endpoint $PE_PROXY_NAME for proxy Web App in subnet $SUBNET_APP"
az network private-endpoint create -g "$RG" -n "$PE_PROXY_NAME" --vnet-name "$VNET_NAME" --subnet "$SUBNET_APP" \
  --private-connection-resource-id "$PROXY_RESOURCE_ID" --group-ids sites --connection-name "${PE_PROXY_NAME}-conn" --output none

log "Waiting for proxy Web App private endpoint to be ready"
wait_for "az network private-endpoint show -g $RG -n $PE_PROXY_NAME --query provisioningState -o tsv" "Succeeded" || { log "Proxy PE not ready"; exit 1; }

PE_PROXY_NIC_ID=$(az network private-endpoint show -g "$RG" -n "$PE_PROXY_NAME" --query 'networkInterfaces[0].id' -o tsv)
PE_PROXY_IP=$(az network nic show --ids "$PE_PROXY_NIC_ID" --query 'ipConfigurations[0].privateIpAddress' -o tsv)
PROXY_HOSTNAME="${WEBAPP_PROXY}.azurewebsites.net"
log "Creating DNS A record $PROXY_HOSTNAME -> $PE_PROXY_IP"
az network private-dns record-set a create -g "$RG" -z "$WEB_DNS_ZONE" -n "$PROXY_HOSTNAME" --output none || true
az network private-dns record-set a add-record -g "$RG" -z "$WEB_DNS_ZONE" -n "$PROXY_HOSTNAME" --ipv4-address "$PE_PROXY_IP" --output none

# -------------------------
# 11 Final output and instructions
# -------------------------
log "Provisioning complete. Summary:"
echo "Resource Group: $RG"
echo "Location: $LOCATION"
echo "VNet: $VNET_NAME"
echo "App Subnet: $SUBNET_APP"
echo "DB Subnet: $SUBNET_DB"
echo "ACR: $ACR_NAME ($ACR_LOGIN_SERVER)"
echo "Proxy Web App: $WEBAPP_PROXY (private hostname: $PROXY_HOSTNAME)"
echo "Backend Web App: $WEBAPP_BACKEND (private hostname: $BACKEND_HOSTNAME)"
echo "Postgres: $PG_SERVER_NAME (private hostname: $PG_HOSTNAME)"
echo "Key Vault: $KEYVAULT_NAME"
echo
echo "Basic Auth credentials stored in Key Vault secrets BasicAuthUser and BasicAuthPass"
if [ -n "$OPENAI_API_KEY" ]; then
  echo "OpenAI API key stored in Key Vault secret OpenAIKey and referenced by the backend Web App."
else
  echo "No OpenAI API key provided; backend configured to use mock LLM provider."
fi
echo
echo "To let attendees access the app from the internet for the conference, consider:"
echo "  1) Temporarily enable public access on the proxy Web App and add App Service access restrictions to allow only the conference IP range."
echo "  2) Or create a jumpbox VM in the VNet and have attendees connect to it (browser or SSH) to reach the private hostnames."
echo "  3) Or configure a point-to-site VPN for attendees."
echo
echo "Run DB migrations from a VM in the VNet or from a container with network access to the private Postgres endpoint."
echo
echo "Cleanup: az group delete -n $RG --yes --no-wait"
log "Done"

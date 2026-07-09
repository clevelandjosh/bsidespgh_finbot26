FinBot Azure Deployment README

This repository contains a ready-to-run package and provisioning workflow to deploy an OWASP FinBot demo in Azure. The deployment uses two Web Apps for Containers: a proxy that enforces HTTP Basic Auth and a backend that runs FinBot. The architecture uses Azure Container Registry, Azure Database for PostgreSQL Flexible Server with Private Endpoints, Private DNS zones, Azure Key Vault for secrets, and managed identities for secure access to ACR and Key Vault. The proxy injects the backend private hostname at container start using runtime substitution.

| File | Purpose |
| --- | --- |
| **provision-finbot-azure-two-webapps.sh** | Full Bash provisioning script that creates Azure resources, builds or pushes images, configures private endpoints and DNS, and wires Key Vault secrets. |
| **Dockerfile.backend** | Example backend Dockerfile for FinBot. Adjust to match the FinBot repo layout and start command. |
| **Dockerfile.proxy** | Proxy Dockerfile that installs ``envsubst`` and runs ``start.sh`` to substitute the backend hostname at runtime. |
| **nginx.conf.template** | Nginx template used by the proxy. Contains ``${BACKEND_HOSTNAME}`` placeholder for runtime substitution. |
| **start.sh** | Proxy container entrypoint that runs ``envsubst`` to produce ``nginx.conf`` and then starts nginx. |
| **nginx.htpasswd** | Placeholder htpasswd file. Replace with a real htpasswd before building the proxy image. |
| **README.md** | This file. |
| **example.env** | Example environment variables to export before running the provisioning script. |
| **assemble_finbot_zip.sh** | Helper that writes the files above and creates ``finbot-deploy.zip``. Use this only if you need to recreate the package locally. |


Prerequisites

    Azure CLI logged in and the correct subscription selected.

    Docker installed if you plan to build images locally.

    htpasswd utility (from apache2-utils) or an alternative method to create a bcrypt htpasswd entry.

    Review and edit variables at the top of the provisioning script before running. You can export values as environment variables or edit defaults in the script.

Example environment variables

Export these variables or edit the defaults in the script before running:



```bash
export RG=finbot-rg
export LOCATION=eastus
export ACR_NAME=finbotacr123
export WEBAPP_PROXY=finbot-proxy
export WEBAPP_BACKEND=finbot-backend
export PG_ADMIN=pgadminuser
export PG_PASSWORD='S3cureP@ssw0rd!'
export KEYVAULT_NAME=finbot-kv123
export BASIC_AUTH_USER=attendee
export BASIC_AUTH_PASS='Conf2026!'
export OPENAI_API_KEY='sk-REPLACE_WITH_YOUR_KEY'   # optional
```



assemble_finbot_zip.sh	Helper that writes the files above and creates finbot-deploy.zip. Use this only if you need to recreate the package locally.
Prerequisites

    Azure CLI logged in and the correct subscription selected.

    Docker installed if you plan to build images locally.

    htpasswd utility (from apache2-utils) or an alternative method to create a bcrypt htpasswd entry.

    Review and edit variables at the top of the provisioning script before running. You can export values as environment variables or edit defaults in the script.

Example environment variables

Export these variables or edit the defaults in the script before running:
bash

export RG=finbot-rg
export LOCATION=eastus
export ACR_NAME=finbotacr123
export WEBAPP_PROXY=finbot-proxy
export WEBAPP_BACKEND=finbot-backend
export PG_ADMIN=pgadminuser
export PG_PASSWORD='S3cureP@ssw0rd!'
export KEYVAULT_NAME=finbot-kv123
export BASIC_AUTH_USER=attendee
export BASIC_AUTH_PASS='Conf2026!'
export OPENAI_API_KEY='sk-REPLACE_WITH_YOUR_KEY'   # optional

Deployment steps

    Unzip or assemble the package
    bash

    unzip finbot-deploy.zip -d finbot-deploy
    cd finbot-deploy

    Or run the assemble helper:
    bash

    chmod +x assemble_finbot_zip.sh
    ./assemble_finbot_zip.sh

    Generate a real htpasswd and replace the placeholder
    bash

    htpasswd -Bbn "$BASIC_AUTH_USER" "$BASIC_AUTH_PASS" > nginx.htpasswd

    Place nginx.htpasswd in the same directory as Dockerfile.proxy before building or using az acr build.

    Review and edit the provisioning script

        Open provision-finbot-azure-two-webapps.sh.

        Confirm resource names, region, App Service plan SKU, and any conference IP ranges for temporary public access.

    Build and push images

        Option A let the script build in ACR:

            Ensure USE_ACR_BUILD=true in the script or environment.

            The script will run az acr build for both images.

        Option B build locally and push:
        bash

        docker build -t <ACR_LOGIN_SERVER>/finbot-backend:latest -f Dockerfile.backend .
        docker build -t <ACR_LOGIN_SERVER>/finbot-proxy:latest -f Dockerfile.proxy .
        az acr login -n $ACR_NAME
        docker push <ACR_LOGIN_SERVER>/finbot-backend:latest
        docker push <ACR_LOGIN_SERVER>/finbot-proxy:latest

    Run the provisioning script
    bash

    chmod +x provision-finbot-azure-two-webapps.sh
    ./provision-finbot-azure-two-webapps.sh

    The script will:

        Create resource group, VNet, and subnets.

        Create ACR and build or push images.

        Create PostgreSQL Flexible Server with Private Endpoint and Private DNS.

        Create Key Vault and store secrets PgPassword, BasicAuthUser, BasicAuthPass, and OpenAIKey if provided.

        Create App Service plan and two Web Apps for Containers.

        Assign system-assigned managed identities and grant AcrPull role on ACR.

        Grant Key Vault get and list secret permissions to both Web App identities.

        Configure app settings for backend and proxy using Key Vault references.

        Create Private Endpoints and Private DNS A records for backend and proxy.

        Set BACKEND_HOSTNAME app setting on the proxy so the proxy substitutes the backend hostname at startup.

    Run database migrations

        From a VM in the VNet or a container with network access to the private Postgres endpoint, run the FinBot migration command. Example placeholder:
        bash

        # adjust to FinBot repo commands
        docker run --rm --network host <backend-image> alembic upgrade head

    Test the deployment from inside the VNet

        From a VM in the VNet:
        bash

        nslookup <proxy>.azurewebsites.net
        curl -v http://<proxy>.azurewebsites.net:8080/

        The proxy requires Basic Auth. Use the credentials stored in Key Vault or the ones you generated.

    Expose to attendees

        Temporary public exposure with IP restriction
        bash

        az webapp update -g $RG -n $WEBAPP_PROXY --set clientAffinityEnabled=false
        az webapp config access-restriction add -g $RG -n $WEBAPP_PROXY --rule-name conference --priority 100 --action Allow --ip-address <CONFERENCE_IP_OR_RANGE>

        Remove the rule and disable public access after the event.

        Jumpbox VM

            Create a small VM in the VNet and provide attendees access to that VM. From the VM, attendees can access the private proxy hostname.

        Point to site VPN

            Configure a P2S VPN for attendees to join the VNet.

Key configuration details

    Key Vault references are used in App Settings. Example app settings set by the script:

        PG_PASSWORD=@Microsoft.KeyVault(SecretUri=<secretId>)

        BASIC_AUTH_USER=@Microsoft.KeyVault(SecretUri=<secretId>)

        BASIC_AUTH_PASS=@Microsoft.KeyVault(SecretUri=<secretId>)

        OPENAI_API_KEY=@Microsoft.KeyVault(SecretUri=<secretId>) when provided

    LLM provider

        If OPENAI_API_KEY is provided the script sets LLM_PROVIDER=openai.

        If not provided the script sets LLM_PROVIDER=mock.

    Proxy runtime substitution

        The proxy image contains nginx.conf.template.

        The provisioning script sets BACKEND_HOSTNAME=<backend>.azurewebsites.net as an App Setting on the proxy.

        At container start start.sh runs envsubst to substitute ${BACKEND_HOSTNAME} into nginx.conf and then starts nginx.

Security recommendations

    Isolate the deployment in its own resource group and subscription. Do not use real production data.

    Rotate the OpenAI key and any other secrets after the event. Limit key scopes and set billing alerts.

    Use Key Vault references rather than plain text app settings for secrets. The script grants the Web App managed identities get and list secret permissions. Revoke or tighten policies after the event.

    Limit public exposure to the conference IP range and remove access after the event. Prefer jumpbox or VPN for stronger control.

    Monitor usage of the OpenAI key and database connections during the event.

Cleanup

To remove everything created by the script:
bash

az group delete -n "$RG" --yes --no-wait

Verify resources are deleted before leaving the subscription unattended.
Troubleshooting

    pushd not found

        Run scripts with Bash explicitly:
        bash

        bash assemble_finbot_zip.sh

    ACR image pull failures

        Ensure the Web App managed identity has AcrPull role on the ACR. Role assignment propagation can take a minute.

    Key Vault secret not accessible

        Confirm the Web App identity has get permission and that the Key Vault access policy was applied.

    DNS resolution issues

        Verify the Private DNS zone is linked to the VNet and that the private endpoint NIC IP was added as an A record. Use nslookup from a VM in the VNet to validate.

    App cannot connect to Postgres

B
A
        Ensure the backend app is running inside the VNet or has network path to the private endpoint. Confirm DATABASE_URL uses the private hostname and that the Postgres server is ready.

FinBot Azure deployment package (two Web Apps: proxy + backend)

Key change: proxy uses runtime substitution (envsubst) to inject BACKEND_HOSTNAME at container start.
Files:
- provision-finbot-azure-two-webapps.sh  : provisioning script (edit variables at top)
- Dockerfile.backend
- Dockerfile.proxy                      : installs gettext for envsubst
- nginx.conf.template                   : template with ${BACKEND_HOSTNAME}
- start.sh                              : proxy start script (runs envsubst)
- nginx.htpasswd                        : placeholder; generate real htpasswd before building proxy
- example.env

Usage:
1. Edit provision-finbot-azure-two-webapps.sh to set resource names and options.
2. Generate nginx.htpasswd locally:
   htpasswd -Bbn "$BASIC_AUTH_USER" "$BASIC_AUTH_PASS" > nginx.htpasswd
   Place the generated nginx.htpasswd into the package directory before building/pushing the proxy image.
3. Build/push images (script supports az acr build or local docker build + push).
4. Run the provisioning script in Azure Cloud Shell:
   chmod +x provision-finbot-azure-two-webapps.sh
   ./provision-finbot-azure-two-webapps.sh
   The script will set BACKEND_HOSTNAME as an App Setting on the proxy after creating the backend private DNS record.
5. The proxy container reads BACKEND_HOSTNAME from App Settings and substitutes it into nginx.conf at startup.

Security notes:
- FinBot is intentionally vulnerable; do not use real sensitive data.
- Use Key Vault references for secrets; rotate OpenAI keys after the event.
- For attendee access, prefer temporary public exposure with App Service access restrictions limited to the conference IP range, or use a jumpbox or VPN.

Cleanup:
  az group delete -n <RG> --yes --no-wait

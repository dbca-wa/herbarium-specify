# UAT SSO overlay settings for Specify 7 (Microsoft Entra ID / Azure AD OIDC).
#
# This module is mounted into the container at /opt/specify7/uat_sso_settings.py
# and selected via DJANGO_SETTINGS_MODULE=uat_sso_settings.
#
# It layers on top of the consortium image's settings package ("settings"),
# which the image already configures from environment variables. We only add
# what's needed for SSO.

import os

from settings import * 

# --- OpenID Connect provider (Entra ID / Azure AD) ---------------------------
# Values come from the UAT Secret (sourced from kustomize/overlays/uat/.env).
_client_id = os.environ.get("AZURE_CLIENT_ID")
_client_secret = os.environ.get("AZURE_CLIENT_SECRET")
_tenant_id = os.environ.get("AZURE_TENANT_ID")

if _client_id and _client_secret and _tenant_id:
    OAUTH_LOGIN_PROVIDERS = {
        "azure": {
            # Shown on the Specify login screen SSO button.
            "title": "DBCA Single Sign-On",
            "client_id": _client_id,
            "client_secret": _client_secret,
            # Entra ID v2.0 issuer base URL. Specify appends
            "config": f"https://login.microsoftonline.com/{_tenant_id}/v2.0",
            # Must include at least openid and email.
            "scope": "openid email profile",
        },
    }
SECURE_PROXY_SSL_HEADER = ("HTTP_X_FORWARDED_PROTO", "https")
USE_X_FORWARDED_HOST = True

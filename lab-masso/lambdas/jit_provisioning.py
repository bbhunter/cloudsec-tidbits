"""
JIT Provisioning Lambda (PostConfirmation) - CaatS - Cats as a top Service

Fires after a new federated user is confirmed. Cognito has already called the
IdP's /userinfo endpoint (before this trigger fires) and applied the registered
attribute mapping into event.request.userAttributes. This Lambda reads those
already-mapped values and writes them to the Cognito user record.

custom:primaryEmail is NOT set via attribute mapping - it is derived from the
sub claim directly (see sub parsing block below). This prevents direct OIDC
claim injection but introduces a parser differential with pre_signup's guard.
"""

import os

import boto3

cognito = boto3.client("cognito-idp", region_name=os.environ.get("AWS_DEFAULT_REGION", "us-east-1"))

# custom:primaryEmail is intentionally excluded here - it is derived from the
# sub claim below, not from the OIDC attribute mapping, so that an attacker
# cannot inject it directly by adding a "primaryEmail" claim to their /userinfo.
ATTR_KEYS = ["email", "name", "custom:tenantID", "custom:isOrgAdmin", "custom:orgName"]


def handler(event, context):
    src = event.get("triggerSource", "")

    if src != "PostConfirmation_ConfirmSignUp":
        return event

    username = event.get("userName", "")

    # External provider usernames are formatted as: ProviderName_sub
    if "_" not in username:
        return event

    user_pool_id = event["userPoolId"]
    user_attrs = event.get("request", {}).get("userAttributes", {})

    # Block @acme.org accounts from being provisioned via external SSO.
    email = user_attrs.get("email", "")
    if "@" in email:
        domain = email.split("@")[1]
        if domain == "acme.org":
            raise Exception(
                "PostConfirmation failed: @acme.org accounts cannot be provisioned via external SSO."
            )

    attrs_to_update = [
        {"Name": k, "Value": user_attrs[k]}
        for k in ATTR_KEYS
        if user_attrs.get(k)
    ]

    has_tenant = any(a["Name"] == "custom:tenantID" for a in attrs_to_update)
    if not has_tenant and "@" in email:
        derived = email.split("@")[1].upper().replace(".", "_")
        attrs_to_update.append({"Name": "custom:tenantID", "Value": derived})
        attrs_to_update.append({"Name": "custom:orgName",  "Value": derived})

    # Sub namespace → custom:primaryEmail.
    # Sub format expected: <ORGPREFIX>_<email>  e.g. "CORP_alice@example.com"
    # We extract the canonical platform identity from the sub and persist it as
    # custom:primaryEmail. The app uses this attribute to recognise platform
    # staff accounts (is_staff_email check in _role_from_attrs).
    #
    # VULNERABLE: uses sub.split("_")[-1] - the LAST token after splitting on "_".
    # The pre_signup guard uses sub.split("_")[1] - the SECOND token.
    # An attacker who controls their OIDC sub can craft a value such as:
    #   "EVIL_noise_support@acme.org"
    # so that:
    #   pre_signup guard  → sub.split("_")[1] = "noise"  → not found → passes
    #   jit_provisioning  → sub.split("_")[-1] = "support@acme.org" → stored as primaryEmail
    # The two parsers see different values from the same string.
    sub = username.split("_", 1)[1]   # strip ProviderName prefix
    sub_parts = sub.split("_")
    if len(sub_parts) >= 2:
        primary_email_candidate = sub_parts[-1]
        if "@" in primary_email_candidate and not any(
            a["Name"] == "custom:primaryEmail" for a in attrs_to_update
        ):
            attrs_to_update.append({"Name": "custom:primaryEmail", "Value": primary_email_candidate})

    if attrs_to_update:
        try:
            cognito.admin_update_user_attributes(
                UserPoolId=user_pool_id,
                Username=username,
                UserAttributes=attrs_to_update,
            )
        except Exception as e:
            print(f"[jit_provisioning] AdminUpdateUserAttributes failed for {username}: {e}")

    return event

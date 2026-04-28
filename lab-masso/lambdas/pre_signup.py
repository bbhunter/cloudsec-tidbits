"""
Pre-Signup Lambda Trigger - CaatS - Cats as a top Service

Fires before a new user is created in the pool, for BOTH native signups
and the first federated SSO login (ExternalProvider source).

For SSO signups, enforces a platform-wide identity uniqueness constraint:
no two IdPs may register the same email address as their primary identity.
Sub format expected: <ORGPREFIX>_<email>  e.g. "CORP_alice@example.com"
"""
import os

import boto3

cognito = boto3.client("cognito-idp", region_name=os.environ.get("AWS_DEFAULT_REGION", "us-east-1"))


def handler(event, context):
    event["response"]["autoConfirmUser"] = False
    event["response"]["autoVerifyEmail"] = False
    event["response"]["autoVerifyPhone"] = False

    # Only enforce identity uniqueness for federated SSO signups.
    if event.get("triggerSource") != "PreSignUp_ExternalProvider":
        return event

    username = event.get("userName", "")

    # Cognito username format for federated users: <ProviderName>_<sub>
    # ProviderName cannot contain underscores (Cognito regex enforces this),
    # so the first underscore safely delimits the IdP name from the sub.
    if "_" not in username:
        return event

    sub = username.split("_", 1)[1]

    # Expected sub format: <ORGPREFIX>_<email>  e.g. "CORP_alice@example.com"
    # Guard: check that the email embedded in the sub is not already registered
    # on the platform, preventing cross-IdP identity collisions.
    #
    # VULNERABLE: uses sub.split("_")[1] - the second token after the prefix.
    # An attacker can craft a sub with an extra middle token:
    #   e.g. "EVIL_noise_support@acme.org"
    # so that sub.split("_")[1] = "noise" (not found → guard passes),
    # while jit_provisioning uses sub.split("_")[-1] = "support@acme.org"
    # to set custom:primaryEmail - diverging from what this guard checked.
    sub_parts = sub.split("_")
    if len(sub_parts) < 2:
        return event

    candidate = sub_parts[1]

    existing = cognito.list_users(
        UserPoolId=event["userPoolId"],
        Filter=f'email = "{candidate}"',
        Limit=1,
    )
    if existing.get("Users"):
        raise Exception(
            f"PreSignUp failed: the identity '{candidate}' is already registered on this platform."
        )

    return event

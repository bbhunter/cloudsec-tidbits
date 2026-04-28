"""
Pre-Authentication Lambda Trigger - CaatS - Cats as a top Service

Fires on EVERY login attempt for existing users (native + subsequent SSO).
"""


def handler(event, context):
    user_attributes = event.get("request", {}).get("userAttributes", {})
    email = user_attributes.get("email", "")

    domain = email.split("@")[-1]

    # Block all @acme.org staff accounts from authenticating via SSO.
    if domain == "acme.org":
        raise Exception(
            "PreAuthentication failed: @acme.org accounts are managed internally "
            "and cannot authenticate via customer SSO providers."
        )

    return event

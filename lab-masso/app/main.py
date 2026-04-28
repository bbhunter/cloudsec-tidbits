"""
CaatS - Cats as a top Service
Multi-tenant B2B platform with AWS Cognito federation.

"""

import hashlib
import os
import secrets
import subprocess
import unicodedata
from email.utils import parseaddr
from functools import wraps

import boto3
import jwt as pyjwt
import requests
from flask import (
    Flask,
    jsonify,
    redirect,
    render_template,
    request,
    session,
)

app = Flask(__name__)
app.secret_key = os.environ.get("SECRET_KEY", secrets.token_hex(32))

# ---------------------------------------------------------------------------
# Environment configuration
# ---------------------------------------------------------------------------
REGION         = os.environ.get("REGION", "us-east-1")
CLIENT_ID      = os.environ.get("CLIENT_ID", "")
USERPOOL_ID    = os.environ.get("USERPOOL_ID", "")
COGNITO_DOMAIN = os.environ.get("COGNITO_DOMAIN", "").rstrip("/")
FLAG           = os.environ.get("FLAG", "FLAG{gh0st_in_the_1d3ntity_mach1ne}")


def _app_base_url() -> str:
    """Derive the app's own base URL from the incoming request host.
    Falls back to APP_URL env var if set (useful for local dev).
    """
    env_url = os.environ.get("APP_URL", "").rstrip("/")
    if env_url and env_url != "http://placeholder":
        return env_url

    return f"{request.scheme}://{request.host}"

cognito = boto3.client("cognito-idp", region_name=REGION)

_EXPLICIT_AUTH_FLOWS = [
    "ALLOW_USER_SRP_AUTH",
    "ALLOW_REFRESH_TOKEN_AUTH",
    "ALLOW_USER_PASSWORD_AUTH",
    "ALLOW_ADMIN_USER_PASSWORD_AUTH",
]
_READ_ATTRIBUTES  = ["email", "name", "custom:tenantID", "custom:isOrgAdmin", "custom:orgName", "custom:primaryEmail"]
_WRITE_ATTRIBUTES = ["email", "name"]


def _sync_app_client(base_url: str) -> None:
    """Update the Cognito App Client with the current base URL and all registered IdPs.

    Must be called whenever the app's public URL might differ from what is
    stored in Cognito (first boot, SSO provider added, etc.).
    Always passes the complete parameter set so nothing is accidentally reset.
    """
    all_idps = ["COGNITO"] + [p["ProviderName"] for p in _list_identity_providers()]
    cognito.update_user_pool_client(
        UserPoolId=USERPOOL_ID,
        ClientId=CLIENT_ID,
        SupportedIdentityProviders=all_idps,
        AllowedOAuthFlows=["code"],
        AllowedOAuthFlowsUserPoolClient=True,
        AllowedOAuthScopes=["email", "openid", "profile"],
        CallbackURLs=[f"{base_url}/callback"],
        LogoutURLs=[f"{base_url}/"],
        ExplicitAuthFlows=_EXPLICIT_AUTH_FLOWS,
        ReadAttributes=_READ_ATTRIBUTES,
        WriteAttributes=_WRITE_ATTRIBUTES,
    )


_callback_registered = False


def _ensure_callback_registered(base_url: str) -> None:
    """Safety-net: register the callback URL in Cognito on the first /sso hit.

    Handles the case where the ECS task IP changed since the last deploy.sh run
    (e.g. task replacement, redeploy without full terraform apply).
    """
    global _callback_registered
    if _callback_registered:
        return
    try:
        _sync_app_client(base_url)
        _callback_registered = True
    except Exception as e:
        app.logger.error("_ensure_callback_registered failed: %s", e)


STAFF_DOMAIN = "acme.org"


def is_staff_email(email: str) -> bool:
    _, parsed = parseaddr(email)
    return parsed.endswith(f"@{STAFF_DOMAIN}")


def _role_from_attrs(email: str, attrs: dict) -> str:
    if is_staff_email(email) or is_staff_email(attrs.get("custom:primaryEmail", "")):
        return "staff"
    if attrs.get("custom:isOrgAdmin") == "true":
        return "org-admin"
    return "member"


# The platform "support" mailbox (work mail) must not be org-admin-impersonatable, whether
# the row is the native user from deploy.sh or a *ghost* (EXTERNAL_PROVIDER) with the same
# email in Cognito. Other @acme.org ghosts (e.g. attacker@acme.org) keep the lab chain.
# Compare using parseaddr+NFKC so tab-suffixed etc. line up with _role_from_attrs.
_SEED_SUPPORT_ADDR_CASEFOLD = "support@acme.org"
_SEED_PLATFORM_TENANT_ID = "PLATFORM_SEED"


def _normalize_cognito_username(s: str) -> str:
    """Normalize sign-in usernames for equality checks (confusable / encoding trickery)."""
    if s is None:
        return ""
    t = unicodedata.normalize("NFKC", str(s))
    t = t.replace("\x00", "")
    t = t.replace("\ufeff", "")
    t = t.replace("\u200b", "").replace("\u200c", "").replace("\u200d", "").replace("\u2060", "")
    for b in ("\u200e", "\u200f", "\u202a", "\u202b", "\u202c", "\u202d", "\u202e"):
        t = t.replace(b, "")
    t = t.strip(" \t")
    return t.casefold()


def _canonical_addr_casefold(raw: str) -> str:
    """One mailbox string for identity comparisons (aligns with parseaddr in is_staff_email)."""
    if not (raw or "").strip():
        return ""
    t = unicodedata.normalize("NFKC", str(raw))
    t = t.replace("\x00", "")
    _, addr = parseaddr(t)
    return (addr or "").strip().casefold()


def _is_platform_support_impersonation_protected(
    cognito_username: str,
    attrs: dict | None = None,
) -> bool:
    """
    True if the target is the *platform* support@acme.org identity - not impersonation-eligible.

    Catches: native seed (Username), deploy tenant marker, and federated ghosts with that
    email or primaryEmail (Username is ProviderName_sub; tenant is not PLATFORM_SEED).
    """
    if _normalize_cognito_username(cognito_username) == _SEED_SUPPORT_ADDR_CASEFOLD:
        return True
    if attrs is not None:
        raw_tid = attrs.get("custom:tenantID") or ""
        tid = unicodedata.normalize("NFKC", str(raw_tid)).strip()
        for b in ("\u200e", "\u200f", "\u202a", "\u202b", "\u202c", "\u202d", "\u202e"):
            tid = tid.replace(b, "")
        if tid == _SEED_PLATFORM_TENANT_ID:
            return True
        for key in ("email", "custom:primaryEmail"):
            if _canonical_addr_casefold(attrs.get(key, "")) == _SEED_SUPPORT_ADDR_CASEFOLD:
                return True
    return False


def login_required(f):
    @wraps(f)
    def decorated(*args, **kwargs):
        if "user" not in session:
            return redirect("/")
        return f(*args, **kwargs)
    return decorated


def org_admin_required(f):
    @wraps(f)
    def decorated(*args, **kwargs):
        if "user" not in session:
            return redirect("/")
        if session["user"]["role"] not in ("org-admin", "staff"):
            return render_template("error.html", message="Access denied: Org-Admin or Staff role required.")
        return f(*args, **kwargs)
    return decorated


def staff_required(f):
    @wraps(f)
    def decorated(*args, **kwargs):
        if "user" not in session:
            return redirect("/")
        if session["user"]["role"] != "staff":
            return render_template("error.html", message="Access denied: Staff-only area.")
        return f(*args, **kwargs)
    return decorated

def _attrs_to_dict(attributes: list) -> dict:
    return {a["Name"]: a["Value"] for a in attributes}


def _paginate_users() -> list:
    users = []
    kwargs: dict = {"UserPoolId": USERPOOL_ID, "Limit": 60}
    while True:
        resp = cognito.list_users(**kwargs)
        users.extend(resp.get("Users", []))
        token = resp.get("PaginationToken")
        if not token:
            break
        kwargs["PaginationToken"] = token
    return users


def _get_tenant_members(tenant_id: str) -> list:
    try:
        return [
            u for u in _paginate_users()
            if _attrs_to_dict(u.get("Attributes", [])).get("custom:tenantID") == tenant_id
        ]
    except Exception:
        return []


def _get_tenant_users(tenant_id: str) -> list:

    try:
        seen: set = set()
        result = []
        for u in _paginate_users():
            a = _attrs_to_dict(u.get("Attributes", []))
            if a.get("custom:tenantID") == tenant_id or is_staff_email(a.get("email", "")):
                uid = u["Username"]
                if uid not in seen:
                    result.append(u)
                    seen.add(uid)
        return result
    except Exception:
        return []


def _get_all_users() -> list:
    try:
        return _paginate_users()
    except Exception:
        return []


def _list_identity_providers() -> list:
    try:
        resp = cognito.list_identity_providers(UserPoolId=USERPOOL_ID, MaxResults=20)
        return resp.get("Providers", [])
    except Exception:
        return []


@app.route("/")
def index():
    if "user" in session:
        return redirect("/dashboard")
    idps = _list_identity_providers()
    return render_template("index.html", idps=idps)

@app.route("/register", methods=["GET", "POST"])
def register():
    if "user" in session:
        return redirect("/dashboard")

    error = None
    if request.method == "POST":
        email    = request.form.get("email", "").strip()
        password = request.form.get("password", "")
        org_name = request.form.get("org_name", "").strip()

        if not email or not password or not org_name:
            error = "All fields are required."
        elif is_staff_email(email):
            error = "Registration is not available for @acme.org accounts."
        else:
            tenant_id = org_name.upper().replace(" ", "_")
            existing = _get_tenant_members(tenant_id)
            is_first = len(existing) == 0

            try:
                cognito.sign_up(
                    ClientId=CLIENT_ID,
                    Username=email,
                    Password=password,
                    UserAttributes=[
                        {"Name": "email", "Value": email},
                        {"Name": "name",  "Value": email.split("@")[0]},
                    ],
                )
                cognito.admin_confirm_sign_up(
                    UserPoolId=USERPOOL_ID,
                    Username=email,
                )
                cognito.admin_update_user_attributes(
                    UserPoolId=USERPOOL_ID,
                    Username=email,
                    UserAttributes=[
                        {"Name": "custom:tenantID",   "Value": tenant_id},
                        {"Name": "custom:isOrgAdmin", "Value": "true" if is_first else "false"},
                        {"Name": "custom:orgName",    "Value": org_name},
                    ],
                )
                return redirect("/?registered=1")
            except Exception as e:
                error = str(e)

    return render_template("register.html", error=error)

@app.route("/login", methods=["POST"])
def login():
    email    = request.form.get("email", "")
    password = request.form.get("password", "")

    try:
        result = cognito.admin_initiate_auth(
            AuthFlow="ADMIN_NO_SRP_AUTH",
            ClientId=CLIENT_ID,
            UserPoolId=USERPOOL_ID,
            AuthParameters={
                "USERNAME": email,
                "PASSWORD": password,
            },
        )
    except Exception as e:
        return render_template("index.html", error=f"Login failed: {e}")

    id_token = result["AuthenticationResult"].get("IdToken", "")
    # Decode without verification (lab context - production would use JWKS)
    try:
        claims = pyjwt.decode(id_token, options={"verify_signature": False})
    except Exception:
        return render_template("index.html", error="Token decode failed.")

    attrs = {
        "custom:tenantID":    claims.get("custom:tenantID", ""),
        "custom:isOrgAdmin":  claims.get("custom:isOrgAdmin", "false"),
        "custom:orgName":     claims.get("custom:orgName", ""),
        "custom:primaryEmail": claims.get("custom:primaryEmail", ""),
    }
    session["user"] = {
        "email":        claims.get("email", email),
        "username":     claims.get("cognito:username", email),
        "tenantId":     attrs["custom:tenantID"],
        "orgName":      attrs.get("custom:orgName", attrs["custom:tenantID"]),
        "primaryEmail": attrs["custom:primaryEmail"],
        "role":         _role_from_attrs(claims.get("email", email), attrs),
        "source":       "native",
    }
    return redirect("/dashboard")


@app.route("/sso")
def sso():
    base = _app_base_url()
    _ensure_callback_registered(base)   

    state = secrets.token_hex(16)
    session["oauth_state"] = state
    provider = request.args.get("provider", "")
    params = (
        f"client_id={CLIENT_ID}"
        f"&response_type=code"
        f"&scope=email+openid+profile"
        f"&redirect_uri={base}/callback"
        f"&state={state}"
    )
    if provider:
        params += f"&identity_provider={provider}"
    return redirect(f"{COGNITO_DOMAIN}/oauth2/authorize?{params}")

@app.route("/callback")
def callback():
    code  = request.args.get("code", "")
    state = request.args.get("state", "")
    error = request.args.get("error", "")

    if error:
        error_desc = request.args.get("error_description", error)
        return render_template("error.html", message=f"OAuth error from Cognito: <code>{error}</code> - {error_desc}")

    if state != session.pop("oauth_state", None):
        return render_template("error.html", message="Invalid OAuth state parameter.")

    # Exchange code for tokens
    _redirect_uri = f"{_app_base_url()}/callback"
    token_resp = None
    try:
        token_resp = requests.post(
            f"{COGNITO_DOMAIN}/oauth2/token",
            data={
                "grant_type":   "authorization_code",
                "client_id":    CLIENT_ID,
                "code":         code,
                "redirect_uri": _redirect_uri,
            },
            headers={"Content-Type": "application/x-www-form-urlencoded"},
            timeout=10,
        )
        token_resp.raise_for_status()
        tokens = token_resp.json()
    except Exception as e:
        body = ""
        try:
            body = token_resp.text
        except Exception:
            pass
        return render_template("error.html", message=(
            f"Token exchange failed: {e}<br>"
            f"<small>redirect_uri used: <code>{_redirect_uri}</code><br>"
            f"Cognito response: <code>{body}</code></small>"
        ))

    id_token = tokens.get("id_token", "")
    if not id_token:
        return render_template("error.html", message="No id_token received from Cognito.")

    try:
        claims = pyjwt.decode(id_token, options={"verify_signature": False})
    except Exception as e:
        return render_template("error.html", message=f"JWT decode failed: {e}")

    username = claims.get("cognito:username", claims.get("email", ""))

    # The PostConfirmation / JIT Lambda updates custom attributes after Cognito
    # issues the id_token, so the JWT claims may be stale on first login.
    # Call AdminGetUser to get the freshest attribute values from the pool.
    try:
        pool_user = cognito.admin_get_user(UserPoolId=USERPOOL_ID, Username=username)
        live_attrs = _attrs_to_dict(pool_user.get("UserAttributes", []))
    except Exception:
        # Fall back to JWT claims if the pool lookup fails (e.g. external IdP
        # username format not resolvable) - best-effort.
        live_attrs = {k: claims.get(k, "") for k in (
            "email", "custom:tenantID", "custom:isOrgAdmin", "custom:orgName"
        )}

    email     = live_attrs.get("email", claims.get("email", ""))
    tenant_id = live_attrs.get("custom:tenantID", "")
    org_name  = live_attrs.get("custom:orgName", "")

    # Fallback: if the JIT Lambda didn't set a tenant (e.g. the OIDC provider
    # returned no tenant_id claim), derive one from the email domain and persist
    # it to Cognito so subsequent logins are consistent.
    if not tenant_id and "@" in email:
        tenant_id = email.split("@")[1].upper().replace(".", "_")
        org_name  = org_name or tenant_id
        try:
            cognito.admin_update_user_attributes(
                UserPoolId=USERPOOL_ID,
                Username=username,
                UserAttributes=[
                    {"Name": "custom:tenantID", "Value": tenant_id},
                    {"Name": "custom:orgName",  "Value": org_name},
                ],
            )
        except Exception as e:
            app.logger.warning("Could not persist fallback tenantID for %s: %s", username, e)

    primary_email = live_attrs.get("custom:primaryEmail", "")
    attrs = {
        "custom:tenantID":    tenant_id,
        "custom:isOrgAdmin":  live_attrs.get("custom:isOrgAdmin", "false"),
        "custom:orgName":     org_name,
        "custom:primaryEmail": primary_email,
    }

    session["user"] = {
        "email":        email,
        "username":     username,
        "tenantId":     tenant_id,
        "orgName":      org_name or tenant_id,
        "primaryEmail": primary_email,
        "role":         _role_from_attrs(email, attrs),  
        "source":       "sso",
    }
    return redirect("/dashboard")

@app.route("/dashboard")
@login_required
def dashboard():
    user = session["user"]
    return render_template("dashboard.html", user=user)


@app.route("/cats")
@login_required
def cats():
    user = session["user"]
    tenant_id = user["tenantId"]
    # Per-tenant "extracted" cat catalogue (deterministic, based on tenant hash)
    cats_data = _tenant_cats(tenant_id)
    return render_template("cats.html", user=user, cats=cats_data)


_CATAAS_IDS: list = []


def _ensure_cataas_ids() -> list:
    global _CATAAS_IDS
    if _CATAAS_IDS:
        return _CATAAS_IDS
    try:
        resp = requests.get("https://cataas.com/api/cats?limit=200", timeout=6)
        resp.raise_for_status()
        data = resp.json()
        ids = [c.get("id") or c.get("_id") for c in data if c.get("id") or c.get("_id")]
        if ids:
            _CATAAS_IDS = ids
            app.logger.info("cataas: loaded %d cat IDs", len(ids))
    except Exception as e:
        app.logger.warning("cataas: could not load cat IDs: %s", e)
    return _CATAAS_IDS


def _cat_img_url(seed_int: int, slot: int) -> str:
    ids = _ensure_cataas_ids()
    if ids:
        idx = (seed_int + slot * 997) % len(ids)
        return f"https://cataas.com/cat/{ids[idx]}"
    return f"https://cataas.com/cat?t={seed_int + slot}"


def _tenant_cats(tenant_id: str) -> list:
    seed = int(hashlib.sha256(tenant_id.encode()).hexdigest(), 16)

    adjectives = [
        "Elusive", "Cryptic", "Phantom", "Shadow", "Silent", "Ghost",
        "Binary", "Null", "Root", "Hex", "Sudo", "Kernel",
        "Dark", "Fuzzy", "Stealth", "Zero-Day", "Volatile", "Cursed",
        "Forked", "Patched", "Bytewise", "Shellcode", "Daemon", "Recursive",
    ]
    surnames = [
        "Whiskers", "Pawsworth", "Meowington", "Clawford", "Hissington",
        "Von Purr", "McFloof", "Tailsworth", "Fangsworth", "Scratchbury",
        "Nyan", "Furball", "Catzilla", "Shadowpaw", "Glitchpaws",
        "Nullpointer", "Overfluff", "Stackcat", "Heapster", "Bitflipper",
    ]
    breeds = [
        "Scottish Fold", "Maine Coon", "Siamese", "British Shorthair",
        "Bengal", "Ragdoll", "Persian", "Norwegian Forest Cat",
        "Abyssinian", "Turkish Van", "Bombay", "Chartreux",
        "Siberian", "Savannah", "Devon Rex", "Burmese", "Tonkinese",
    ]
    abilities = [
        "SQL Injection", "XSS Mastery", "Privilege Escalation",
        "SSRF Specialist", "JWT Forgery", "Race Condition",
        "Path Traversal", "CORS Bypass", "Token Theft", "Cache Poisoning",
        "IDOR Hunting", "XXE Parsing", "Deserialization", "SSTI Wizardry",
    ]
    ratings = ["A+", "S-Tier", "Premium", "Ultra-Rare", "Legendary", "CRITICAL", "P0"]

    # LCG constants (Knuth)
    M = 0xFFFFFFFFFFFFFFFF
    A = 6364136223846793005
    C = 1442695040888963407

    def _lcg(r: int) -> int:
        return (r * A + C) & M

    result = []
    r = seed
    for i in range(3):
        r = _lcg(r); adj_idx     = r % len(adjectives)
        r = _lcg(r); sur_idx     = r % len(surnames)
        r = _lcg(r); breed_idx   = r % len(breeds)
        r = _lcg(r); ability_idx = r % len(abilities)
        r = _lcg(r); rating_idx  = r % len(ratings)
        r = _lcg(r); power       = 100 + (r % 9901)   # 100–9999

        cat_id = "CAT-" + hashlib.sha256(
            (tenant_id + str(i)).encode()
        ).hexdigest()[:8].upper()

        result.append({
            "id":      cat_id,
            "name":    f"{adjectives[adj_idx]} {surnames[sur_idx]}",
            "breed":   breeds[breed_idx],
            "ability": abilities[ability_idx],
            "rating":  ratings[rating_idx],
            "power":   power,
            "img_url": _cat_img_url(seed, i),
        })
    return result


@app.route("/admin")
@staff_required
def admin():
    user  = session["user"]
    all_users = _get_all_users()
    users_enriched = []
    for u in all_users:
        a = _attrs_to_dict(u.get("Attributes", []))
        users_enriched.append({
            "username": u["Username"],
            "email":    a.get("email", ""),
            "tenantId": a.get("custom:tenantID", ""),
            "status":   u["UserStatus"],
        })
    return render_template("admin.html", user=user, flag=FLAG, all_users=users_enriched)



@app.route("/directory")
@org_admin_required
def directory():
    user = session["user"]
    tenant_id = user["tenantId"]
    raw_users = _get_tenant_users(tenant_id)

    members = []
    for u in raw_users:
        a = _attrs_to_dict(u.get("Attributes", []))
        email = a.get("email", "")
        un = u["Username"]
        members.append({
            "username":        un,
            "email":           email,
            "role":            _role_from_attrs(email, a),
            "status":          u["UserStatus"],
            "can_impersonate": not _is_platform_support_impersonation_protected(un, a),
        })

    return render_template("directory.html", user=user, members=members)


@app.route("/impersonate", methods=["POST"])
@org_admin_required
def impersonate():
    target_username = request.form.get("username", "")
    current_user    = session["user"]

    if _is_platform_support_impersonation_protected(target_username, None):
        return render_template("error.html", message="Access denied: this platform account cannot be impersonated.")

    try:
        result = cognito.admin_get_user(
            UserPoolId=USERPOOL_ID,
            Username=target_username,
        )
    except Exception as e:
        return render_template("error.html", message=f"User not found: {e}")

    attrs = _attrs_to_dict(result.get("UserAttributes", []))
    if _is_platform_support_impersonation_protected(result.get("Username", ""), attrs):
        return render_template("error.html", message="Access denied: this platform account cannot be impersonated.")
    target_email  = attrs.get("email", "")
    target_tenant = attrs.get("custom:tenantID", current_user["tenantId"])

    # Cross-tenant: pool-wide @acme.org *directory* entries (e.g. SSO ghost users) may be
    # impersonated from any tenant, except the seeded support account (handled above).
    # All other users: same-tenant only.
    if not is_staff_email(target_email) and target_tenant != current_user["tenantId"]:
        return render_template("error.html", message="Cannot impersonate users in other tenants.")

    role = _role_from_attrs(target_email, attrs)
    resolved_username = result.get("Username", target_username)

    session["user"] = {
        "email":          target_email,
        "username":       resolved_username,
        "tenantId":       target_tenant,
        "orgName":        attrs.get("custom:orgName", target_tenant),
        "primaryEmail":   attrs.get("custom:primaryEmail", ""),
        "role":           role,
        "source":         "impersonation",
        "impersonated_by": current_user["email"],
    }

    return redirect("/dashboard")


@app.route("/sso-config", methods=["GET", "POST"])
@org_admin_required
def sso_config():
    user    = session["user"]
    message = None
    error   = None

    existing_idps = _list_identity_providers()

    if request.method == "POST":
        provider_name  = request.form.get("provider_name", "").strip()
        issuer_url     = request.form.get("issuer_url", "").strip()
        client_id_oidc = request.form.get("client_id", "").strip()
        client_secret  = request.form.get("client_secret", "").strip()

        if not all([provider_name, issuer_url, client_id_oidc]):
            error = "Provider name, issuer URL, and client ID are required."
        else:
            try:
                cognito.create_identity_provider(
                    UserPoolId=USERPOOL_ID,
                    ProviderName=provider_name,
                    ProviderType="OIDC",
                    ProviderDetails={
                        "client_id":                 client_id_oidc,
                        "client_secret":             client_secret or "none",
                        "attributes_request_method": "GET",
                        "oidc_issuer":               issuer_url,
                        "authorize_scopes":          "openid email profile",
                    },
                    AttributeMapping={
                        "email":             "email",
                        "name":              "name",
                        "custom:tenantID":   "tenantID",
                        "custom:isOrgAdmin": "isOrgAdmin",
                        "custom:orgName":    "orgName",
                        # custom:primaryEmail is intentionally NOT mapped from OIDC claims.
                        # It is derived from the sub claim by jit_provisioning (see lambdas/).
                        # Mapping it here would allow any org-admin to inject
                        # primaryEmail=support@acme.org directly from their /userinfo endpoint.
                    },
                )

                _sync_app_client(_app_base_url())

                message = f"SSO provider '{provider_name}' registered successfully. Users can now login via SSO."
                existing_idps = _list_identity_providers()

            except Exception as e:
                error = str(e)

    return render_template(
        "sso_config.html",
        user=user,
        message=message,
        error=error,
        idps=existing_idps,
        app_url=_app_base_url(),
        cognito_domain=COGNITO_DOMAIN,
        client_id=CLIENT_ID,
    )

@app.route("/logout")
def logout():
    session.clear()
    return redirect("/")

@app.route("/health")
def health():
    return jsonify({"status": "ok"})


def _ensure_certs():
    """Generate self-signed SSL certificates for HTTPS if they don't exist."""
    if not os.path.exists("key.pem") or not os.path.exists("cert.pem"):
        print(">>> Generating self-signed SSL certificates...")
        try:
            subprocess.run([
                "openssl", "req", "-x509", "-newkey", "rsa:4096", 
                "-keyout", "key.pem", "-out", "cert.pem", 
                "-sha256", "-days", "365", "-nodes", 
                "-subj", "/CN=localhost"
            ], check=True)
        except Exception as e:
            print(f"ERROR: Failed to generate SSL certificates: {e}")

if __name__ == "__main__":
    _ensure_certs()
    app.run(host="0.0.0.0", port=443, debug=True, ssl_context=("cert.pem", "key.pem"))

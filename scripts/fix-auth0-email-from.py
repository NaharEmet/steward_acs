#!/usr/bin/env python3
"""Set Auth0 passwordless + email-provider From to a Resend-verified domain."""
from __future__ import annotations

import json
import os
import sys
import urllib.error
import urllib.request

DOMAIN = os.environ.get("AUTH0_DOMAIN", "dev-jw5wgp2b.us.auth0.com")
CID = os.environ.get("AUTH0_MGMT_CLIENT_ID") or os.environ.get("AUTH0_M2M_CLIENT_ID")
SECRET = os.environ.get("AUTH0_MGMT_CLIENT_SECRET") or os.environ.get("AUTH0_M2M_CLIENT_SECRET")
NEW_FROM = os.environ.get("AUTH0_EMAIL_FROM", "Steward ACS <noreply@stewardacs.xyz>")
CONN_ID = os.environ.get("AUTH0_EMAIL_CONNECTION_ID", "con_C6pxOmMzwrWh2dMe")
DO_FIX = "--fix" in sys.argv


def req(method, url, token=None, body=None):
    data = None if body is None else json.dumps(body).encode()
    headers = {"content-type": "application/json"}
    if token:
        headers["authorization"] = f"Bearer {token}"
    request = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(request) as response:
            raw = response.read()
            return json.loads(raw) if raw else None
    except urllib.error.HTTPError as exc:
        raise SystemExit(f"{method} {url} -> {exc.code}: {exc.read().decode()[:1500]}") from exc


def redact(obj):
    if isinstance(obj, dict):
        return {
            k: ("***" if any(s in k.lower() for s in ("secret", "key", "token", "password", "api")) and v else redact(v))
            for k, v in obj.items()
        }
    if isinstance(obj, list):
        return [redact(x) for x in obj]
    return obj


def main() -> None:
    token = req(
        "POST",
        f"https://{DOMAIN}/oauth/token",
        body={
            "client_id": CID,
            "client_secret": SECRET,
            "audience": f"https://{DOMAIN}/api/v2/",
            "grant_type": "client_credentials",
        },
    )["access_token"]

    conn = req("GET", f"https://{DOMAIN}/api/v2/connections/{CONN_ID}", token=token)
    opts = dict(conn.get("options") or {})
    print("connection_from=", opts.get("from"))
    print("connection_subject=", opts.get("subject"))

    provider = req("GET", f"https://{DOMAIN}/api/v2/emails/provider", token=token)
    print("provider=", json.dumps(redact(provider), indent=2))

    if not DO_FIX:
        print(f"Dry run. Would set From to {NEW_FROM!r}")
        return

    # Passwordless Email connection From (must match provider From domain)
    opts["from"] = NEW_FROM
    opts.setdefault("subject", "Your Steward ACS verification code is {{code}}")
    # Keep existing body/syntax/totp
    updated_conn = req(
        "PATCH",
        f"https://{DOMAIN}/api/v2/connections/{CONN_ID}",
        token=token,
        body={"options": opts},
    )
    print("updated_connection_from=", (updated_conn.get("options") or {}).get("from"))

    # Email provider default From — Auth0 Resend provider uses default_from_address
    # Credentials may be required; try patch without re-sending secret first.
    try:
        updated_provider = req(
            "PATCH",
            f"https://{DOMAIN}/api/v2/emails/provider",
            token=token,
            body={
                "name": provider.get("name") or "resend",
                "enabled": True,
                "default_from_address": NEW_FROM,
            },
        )
        print("updated_provider=", json.dumps(redact(updated_provider), indent=2))
    except SystemExit as exc:
        print("provider_patch_failed:", exc)
        print(
            "Set passwordless From locally; also update Branding → Email Provider From "
            f"in Auth0 Dashboard to {NEW_FROM!r} (must be a Resend-verified domain)."
        )


if __name__ == "__main__":
    main()

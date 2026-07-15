#!/usr/bin/env python3
"""Dump Auth0 passwordless email connection + email templates (redacted)."""
from __future__ import annotations

import json
import os
import urllib.request
import urllib.error

DOMAIN = os.environ.get("AUTH0_DOMAIN", "dev-jw5wgp2b.us.auth0.com")
CID = os.environ.get("AUTH0_MGMT_CLIENT_ID") or os.environ.get("AUTH0_M2M_CLIENT_ID")
SECRET = os.environ.get("AUTH0_MGMT_CLIENT_SECRET") or os.environ.get("AUTH0_M2M_CLIENT_SECRET")


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
        return {"_error": exc.code, "_body": exc.read().decode()[:1000]}


def redact(obj):
    if isinstance(obj, dict):
        out = {}
        for k, v in obj.items():
            lk = k.lower()
            if any(s in lk for s in ("secret", "key", "token", "password", "api_key", "auth")):
                out[k] = "***" if v else v
            else:
                out[k] = redact(v)
        return out
    if isinstance(obj, list):
        return [redact(x) for x in obj]
    return obj


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

print("=== emails/provider (full) ===")
print(json.dumps(redact(req("GET", f"https://{DOMAIN}/api/v2/emails/provider", token)), indent=2))

print("\n=== email connections ===")
conns = req("GET", f"https://{DOMAIN}/api/v2/connections?strategy=email", token) or []
for c in conns:
    print(json.dumps(redact(c), indent=2)[:4000])

print("\n=== branding ===")
print(json.dumps(redact(req("GET", f"https://{DOMAIN}/api/v2/branding", token)), indent=2))

print("\n=== email templates list attempt ===")
for name in ("verify_email", "verification_code", "passwordless_code", "reset_email", "welcome_email"):
    t = req("GET", f"https://{DOMAIN}/api/v2/email-templates/{name}", token)
    print(name, json.dumps(redact(t), indent=2)[:800])

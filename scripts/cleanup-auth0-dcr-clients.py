#!/usr/bin/env python3
"""List/cleanup Auth0 DCR clients that block Claude MCP OAuth."""
from __future__ import annotations

import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request
from collections import Counter

DOMAIN = os.environ.get("AUTH0_DOMAIN", "dev-jw5wgp2b.us.auth0.com")
CID = os.environ.get("AUTH0_MGMT_CLIENT_ID") or os.environ.get("AUTH0_M2M_CLIENT_ID")
SECRET = os.environ.get("AUTH0_MGMT_CLIENT_SECRET") or os.environ.get("AUTH0_M2M_CLIENT_SECRET")
DELETE = "--delete" in sys.argv
KEEP = int(os.environ.get("KEEP_RECENT", "5"))


def req(method: str, url: str, token: str | None = None, body: dict | None = None):
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
        err = exc.read().decode()
        raise SystemExit(f"{method} {url} -> {exc.code}: {err}") from exc


def main() -> None:
    if not CID or not SECRET:
        raise SystemExit("Set AUTH0_MGMT_CLIENT_ID/SECRET")

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

    clients: list[dict] = []
    page = 0
    total = None
    while True:
        batch = req(
            "GET",
            f"https://{DOMAIN}/api/v2/clients?per_page=100&page={page}&include_totals=true"
            "&fields=client_id,name,app_type,is_first_party,callbacks,grant_types,client_metadata"
            "&include_fields=true",
            token=token,
        )
        if isinstance(batch, dict) and "clients" in batch:
            clients.extend(batch["clients"])
            total = batch.get("total", len(clients))
            if len(clients) >= total:
                break
            page += 1
        else:
            clients = batch if isinstance(batch, list) else []
            break

    print(f"total_clients={len(clients)}" + (f" reported_total={total}" if total else ""))
    print("top names:")
    for name, n in Counter((c.get("name") or "?") for c in clients).most_common(25):
        print(f"  {n:4d}  {name}")

    protect_names = {
        "All Applications",
        "Auth0 Management API",
        "Default App",
        "Steward ACS MCP",
    }

    def is_dcr(c: dict) -> bool:
        """Only third-party Dynamic Client Registration apps are safe to prune."""
        name = c.get("name") or ""
        if c.get("client_id") == CID:
            return False
        if name in protect_names or name.startswith("Steward") or name.startswith("steward"):
            return False
        # Auth0 DCR clients are third-party (is_first_party=false), often named Claude / tpc_*.
        return c.get("is_first_party") is False

    dcr = [c for c in clients if is_dcr(c)]
    # Keep first-party Steward apps; delete excess third-party / Claude DCR clients.
    # Prefer deleting unnamed / Claude clients, keep KEEP most recently returned.
    print(f"dcr_candidates={len(dcr)} keep_recent={KEEP}")
    for c in dcr[:20]:
        print(
            f"  first={c.get('is_first_party')}  "
            f"{c.get('client_id')}  {c.get('name')!r}  cbs={c.get('callbacks')}"
        )

    to_delete = dcr[KEEP:] if KEEP > 0 else dcr
    print(f"would_delete={len(to_delete)}")
    if not DELETE:
        print("Dry run. Re-run with --delete to remove stale DCR clients.")
        return

    deleted = 0
    for c in to_delete:
        cid = c["client_id"]
        req("DELETE", f"https://{DOMAIN}/api/v2/clients/{urllib.parse.quote(cid)}", token=token)
        deleted += 1
        print(f"deleted {cid} {c.get('name')!r}")
    print(f"deleted_count={deleted}")


if __name__ == "__main__":
    main()

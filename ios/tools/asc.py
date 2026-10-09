"""Tiny App Store Connect API client.

  uv run --with pyjwt --with cryptography tools/asc.py GET /v1/bundleIds
  uv run ... tools/asc.py POST /v1/bundleIds '{"data": {...}}'

Reads ASC_KEY_ID, ASC_KEY_FILE and (for a team key) ASC_ISSUER_ID from the
environment; without an issuer it signs as an individual key.
"""
import json, os, sys, time, urllib.request, urllib.error
import jwt

key_id, key_file = os.environ["ASC_KEY_ID"], os.environ["ASC_KEY_FILE"]
issuer = os.environ.get("ASC_ISSUER_ID")
now = int(time.time())
claims = {"iat": now, "exp": now + 1200, "aud": "appstoreconnect-v1"}
claims.update({"iss": issuer} if issuer else {"sub": "user"})
token = jwt.encode(claims, open(key_file).read(), algorithm="ES256", headers={"kid": key_id, "typ": "JWT"})

method, path = sys.argv[1], sys.argv[2]
body = sys.argv[3].encode() if len(sys.argv) > 3 else None
req = urllib.request.Request("https://api.appstoreconnect.apple.com" + path, body, method=method,
                             headers={"Authorization": f"Bearer {token}", "Content-Type": "application/json"})
try:
    with urllib.request.urlopen(req) as r:
        print(r.read().decode() or "{}")
except urllib.error.HTTPError as e:
    print(e.code, e.read().decode(), file=sys.stderr)
    sys.exit(1)

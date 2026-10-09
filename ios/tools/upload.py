"""Upload an .ipa to App Store Connect with the build upload API (no Xcode, no Transporter:
the Linux Transporter cannot analyse apps).

  uv run --with pyjwt --with cryptography tools/upload.py <app id> build/Roomprint.ipa

1. buildUploads: announce version + build number for the app
2. buildUploadFiles: describe the .ipa, get upload operations (URLs + byte ranges)
3. PUT each range, then mark the file uploaded with its MD5
4. poll the buildUpload until Apple has processed it (or reports errors)
"""
import hashlib
import json
import os
import plistlib
import sys
import time
import urllib.error
import urllib.request
import zipfile

import jwt

API = "https://api.appstoreconnect.apple.com"


def token():
    now = int(time.time())
    return jwt.encode({"iss": os.environ["ASC_ISSUER_ID"], "iat": now, "exp": now + 1200, "aud": "appstoreconnect-v1"},
                      open(os.environ["ASC_KEY_FILE"]).read(), algorithm="ES256",
                      headers={"kid": os.environ["ASC_KEY_ID"], "typ": "JWT"})


def call(method, path, body=None):
    req = urllib.request.Request(API + path, json.dumps(body).encode() if body else None, method=method,
                                 headers={"Authorization": f"Bearer {token()}", "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req) as r:
            raw = r.read()
            return json.loads(raw) if raw else {}
    except urllib.error.HTTPError as e:
        sys.exit(f"{method} {path}: {e.code} {e.read().decode()}")


def main(app_id, ipa):
    with zipfile.ZipFile(ipa) as z:
        name = next(n for n in z.namelist() if n.count("/") == 2 and n.endswith(".app/Info.plist"))
        info = plistlib.loads(z.read(name))
    version, build = info["CFBundleShortVersionString"], info["CFBundleVersion"]
    data = open(ipa, "rb").read()
    print(f"{ipa}: {version} ({build}), {len(data) / 1e6:.1f} MB", flush=True)

    up = call("POST", "/v1/buildUploads", {"data": {
        "type": "buildUploads",
        "attributes": {"cfBundleShortVersionString": version, "cfBundleVersion": build, "platform": "IOS"},
        "relationships": {"app": {"data": {"type": "apps", "id": app_id}}}}})["data"]

    f = call("POST", "/v1/buildUploadFiles", {"data": {
        "type": "buildUploadFiles",
        "attributes": {"fileName": os.path.basename(ipa), "fileSize": len(data),
                       "uti": "com.apple.ipa", "assetType": "ASSET"},
        "relationships": {"buildUpload": {"data": {"type": "buildUploads", "id": up["id"]}}}}})["data"]

    for op in f["attributes"]["uploadOperations"]:
        part = data[op["offset"]:op["offset"] + op["length"]]
        headers = {h["name"]: h["value"] for h in op.get("requestHeaders") or []}
        req = urllib.request.Request(op["url"], part, method=op["method"], headers=headers)
        with urllib.request.urlopen(req) as r:
            r.read()
        print(f"  sent {op['offset'] + op['length']} / {len(data)}", flush=True)

    call("PATCH", f"/v1/buildUploadFiles/{f['id']}", {"data": {
        "type": "buildUploadFiles", "id": f["id"],
        "attributes": {"uploaded": True,
                       "sourceFileChecksums": {"file": {"hash": hashlib.md5(data).hexdigest(), "algorithm": "MD5"}}}}})

    while True:
        st = call("GET", f"/v1/buildUploads/{up['id']}")["data"]["attributes"]["state"]
        print(f"  {st['state']}", flush=True)
        for kind in ("errors", "warnings"):
            for m in st.get(kind) or []:
                print(f"  {kind[:-1]}: {m.get('code')} {m.get('description') or m.get('message') or m}", flush=True)
        if st["state"] in ("COMPLETE", "FAILED"):
            sys.exit(0 if st["state"] == "COMPLETE" else 1)
        time.sleep(20)


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])

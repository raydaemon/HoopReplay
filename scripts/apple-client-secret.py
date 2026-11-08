#!/usr/bin/env python3
"""Generate the Sign in with Apple client secret (a 6-month ES256 JWT) that Supabase needs
for the web/Android OAuth flow.

    scripts/apple-client-secret.py <AuthKey_XXXX.p8> <key id> [services id]

The team id is ConnectedAI LLC's; the subject defaults to the HoopReplay Services ID. The
JWT is printed to stdout only, never written to disk; paste it into Supabase → Authentication
→ Sign In / Providers → Apple → Secret Key. Apple rejects secrets older than 6 months, so
run it again before then. Only openssl is required.
"""
import base64
import json
import os
import subprocess
import sys
import tempfile
import time

TEAM_ID = "538QL62JD5"
DEFAULT_SERVICES_ID = "com.hoopreplay.web"
SIX_MONTHS = 15_777_000  # seconds; Apple's maximum lifetime


def b64url(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def der_to_raw(der: bytes) -> bytes:
    """openssl emits an ASN.1 SEQUENCE of two INTEGERs; JWTs want the raw 64-byte r||s."""
    assert der[0] == 0x30, "unexpected signature encoding"
    i = 2
    parts = []
    for _ in range(2):
        assert der[i] == 0x02
        length = der[i + 1]
        parts.append(der[i + 2 : i + 2 + length][-32:].rjust(32, b"\0"))
        i += 2 + length
    return b"".join(parts)


def main() -> None:
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    key_path, key_id = sys.argv[1], sys.argv[2]
    subject = sys.argv[3] if len(sys.argv) > 3 else DEFAULT_SERVICES_ID
    now = int(time.time())
    header = b64url(json.dumps({"alg": "ES256", "kid": key_id}).encode())
    payload = b64url(json.dumps({
        "iss": TEAM_ID, "iat": now, "exp": now + SIX_MONTHS,
        "aud": "https://appleid.apple.com", "sub": subject,
    }).encode())
    signing_input = f"{header}.{payload}".encode()
    with tempfile.NamedTemporaryFile(delete=False) as handle:
        handle.write(signing_input)
        tmp = handle.name
    try:
        der = subprocess.check_output(["openssl", "dgst", "-sha256", "-sign", key_path, tmp])
    finally:
        os.unlink(tmp)
    print(f"{header}.{payload}.{b64url(der_to_raw(der))}")
    print(f"# expires {time.strftime('%Y-%m-%d', time.gmtime(now + SIX_MONTHS))}", file=sys.stderr)


if __name__ == "__main__":
    main()

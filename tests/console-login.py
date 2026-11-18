# Browser stand-in for keycloak-console-test.sh. Signs a dummy user in to the realm mcp through the client claude-code (password,
# then OTP enrollment), then opens the realm's administration console in the same SSO session without answering any form.
# Prints "console=code" when the console got an authorization code from the session alone, "console=otp" when it was asked
# for the OTP again.
# Usage: console-login.py <keycloak base URL> <user> <password>
import base64
import hashlib
import hmac
import html
import re
import secrets
import struct
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

base, user, password = sys.argv[1:4]
# Keycloak sits behind nginx in the platform; the realm requires https, which these headers stand for.
forwarded = {"X-Forwarded-Proto": "https", "X-Forwarded-Host": urllib.parse.urlparse(base).netloc}
public_base = "https://" + forwarded["X-Forwarded-Host"]


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        return None


opener = urllib.request.build_opener(NoRedirect)
cookies = {}


def request(url, form=None):
    url = url.replace(public_base, base)
    headers = dict(forwarded)
    if cookies:
        headers["Cookie"] = "; ".join(f"{k}={v}" for k, v in cookies.items())
    data = urllib.parse.urlencode(form).encode() if form is not None else None
    try:
        resp = opener.open(urllib.request.Request(url, data=data, headers=headers))
    except urllib.error.HTTPError as err:
        resp = err
    for cookie in resp.headers.get_all("Set-Cookie") or []:
        name, _, rest = cookie.partition("=")
        cookies[name] = rest.split(";")[0]
    status, location = resp.status, resp.headers.get("Location") or ""
    if status in (302, 303) and "code=" not in location and location.startswith(public_base):
        return request(location)
    return status, location, resp.read().decode(errors="replace")


def totp(secret):
    step = int(time.time()) // 30
    mac = hmac.new(secret.encode(), struct.pack(">Q", step), hashlib.sha1).digest()
    offset = mac[-1] & 0x0F
    return "%06d" % ((struct.unpack(">I", mac[offset:offset + 4])[0] & 0x7FFFFFFF) % 1000000)


def authorize(client_id, redirect_uri):
    verifier = secrets.token_urlsafe(48)
    challenge = base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest()).rstrip(b"=").decode()
    query = {"client_id": client_id, "redirect_uri": redirect_uri, "response_type": "code", "scope": "openid",
             "state": secrets.token_hex(8), "code_challenge": challenge, "code_challenge_method": "S256"}
    return f"{base}/auth/realms/mcp/protocol/openid-connect/auth?" + urllib.parse.urlencode(query)


def form_action(page):
    return html.unescape(re.search(r'<form[^>]*action="([^"]+)"', page).group(1))


status, location, page = request(authorize("claude-code", "http://localhost:33418/callback"))
status, location, page = request(form_action(page), {"username": user, "password": password, "credentialId": ""})
secret = html.unescape(re.search(r'name="totpSecret" value="([^"]+)"', page).group(1))
status, location, page = request(form_action(page), {"totp": totp(secret), "totpSecret": secret, "userLabel": "test"})
print("login=" + ("code" if "code=" in location else f"failed:{status}"))

status, location, page = request(authorize("security-admin-console", f"{public_base}/auth/admin/mcp/console/"))
if "code=" in location:
    print("console=code")
elif 'name="otp"' in page:
    print("console=otp")
else:
    print(f"console=other:{status}")

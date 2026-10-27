"""Fail-closed Cloudflare Access application-token validation."""
import json
import re
import threading
import time
from urllib.request import urlopen
import jwt

class AccessGuard:
    def __init__(self, issuer, audience, email):
        if not re.fullmatch(r'https://[a-z0-9-]+\.cloudflareaccess\.com', issuer):
            raise ValueError('Invalid Access issuer')
        if not re.fullmatch(r'[a-f0-9]{64}', audience) or not email or '@' not in email:
            raise ValueError('Invalid Access audience or identity')
        self.issuer, self.audience, self.email = issuer, audience, email.lower()
        self.keys, self.expires, self.last_refresh = {}, 0, 0
        self.lock = threading.Lock()

    def refresh(self):
        # URL is fixed by configuration; never follow a token's jku/x5u claim.
        with urlopen(self.issuer + '/cdn-cgi/access/certs', timeout=5) as response:
            raw = response.read(262145)
        if len(raw) > 262144:
            raise ValueError('Key response too large')
        keys = json.loads(raw).get('keys', [])
        result = {}
        for key in keys:
            if key.get('kty') == 'RSA' and key.get('use', 'sig') == 'sig' and isinstance(key.get('kid'), str):
                result[key['kid']] = jwt.PyJWK.from_dict(key, algorithm='RS256').key
        if not result:
            raise ValueError('No signing keys')
        self.keys, self.expires = result, time.monotonic() + 300

    def allows(self, token):
        if not isinstance(token, str) or not 1 <= len(token) <= 16384:
            return False
        try:
            header = jwt.get_unverified_header(token)
            if header.get('alg') != 'RS256' or not isinstance(header.get('kid'), str):
                return False
            with self.lock:
                now = time.monotonic()
                if now > self.expires or header['kid'] not in self.keys:
                    # Bound key refresh on unknown kids/outages to once per 30s.
                    if now - self.last_refresh < 30:
                        return False
                    self.last_refresh = now
                    self.refresh()
                key = self.keys.get(header['kid'])
            if key is None:
                return False
            claims = jwt.decode(token, key, algorithms=['RS256'], issuer=self.issuer,
                                audience=self.audience, options={'require': ['exp','iat','iss','aud','sub','email','type']})
            return (claims['type'] == 'app' and bool(claims['sub'])
                    and isinstance(claims['email'], str) and claims['email'].lower() == self.email)
        except Exception:
            return False  # No raw token, key response, or error logging.

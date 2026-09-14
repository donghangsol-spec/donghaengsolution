# Trusted certificate worker skeleton

This local-only Node.js service accepts an encrypted, short-lived PKCS#12 credential session for a single filing job. It does **not** submit a filing or automate a browser yet.

## Security properties

- binds only to `127.0.0.1` or `::1`;
- requires a 32-byte-or-longer bearer control token;
- encrypts credentials with RSA-OAEP-SHA256 and AES-256-GCM;
- binds the encrypted envelope to the job ID, worker key ID, and expiry;
- limits credential lifetime to five minutes and use to one consumption;
- keeps decrypted certificate/password bytes in process memory only and overwrites their buffers after use;
- never exposes a remote consume endpoint or logs request bodies.

## Run on the trusted Windows host

Use a dedicated, non-administrator Windows service account. Set a freshly generated random control token in the service environment, then run:

```powershell
$env:WORKER_CONTROL_TOKEN = '<random value of at least 32 bytes>'
npm test
npm start
```

The local controller can then call:

- `GET /health`
- authenticated `GET /v1/public-key`
- authenticated `POST /v1/credential-sessions`
- authenticated `DELETE /v1/credential-sessions/{sessionRef}`

Only the in-process filing adapter may call `CredentialSessionManager.consume()`. The future browser/macro adapter must consume the session immediately before certificate authentication and must never persist the PKCS#12 file or password.

## Still required before real filing

- Windows service packaging and access-control hardening;
- in-process Hometax/EDI adapter with explicit human confirmation;
- sandbox filing with a signed, independently validated receipt;
- CAPTCHA/MFA/manual intervention handling without bypass;
- audit review proving no certificate material appears in logs, disk, crash dumps, or telemetry.

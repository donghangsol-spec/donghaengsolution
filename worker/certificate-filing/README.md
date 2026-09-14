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

### Control broker Windows service

The `windows` scripts install only the local credential control broker. Run the installer from an elevated, code-signed PowerShell session and pass the path to an approved, hash-verified [WinSW](https://github.com/winsw/winsw) executable. It copies the broker to ProgramData, generates a random control token, protects it with Windows DPAPI, restricts the directory ACL, and creates a stopped/manual `LocalService` service. Review and run `Test-ControlService.ps1` before starting it. The repository deliberately does not download or bundle a service-wrapper binary.

Do not run browser UI automation inside this service. Windows services run in non-interactive Session 0. The future macro adapter must run under a separate restricted interactive Windows account and communicate with the broker through an authenticated local channel.

### Interactive macro runner boundary

`macro-runner.mjs` defines the fail-closed coordination boundary for that separate interactive runner. It disables production by default, stops rather than bypassing CAPTCHA/MFA/certificate-selection/unexpected confirmations, verifies the canonical SHA-256 preview, accepts confirmation only from owner/admin/reviewer, and rejects mismatched receipts. Portal-specific selectors and real submission clicks are deliberately not included until an approved sandbox target and Windows host are available.

### Signed sandbox receipt

`signed-receipt.mjs` defines an Ed25519 receipt envelope and an independent allowlisted-key verifier. It binds a receipt to the job ID and confirmed payload hash, enforces a short timestamp window, requires an accepted sandbox result, and rejects production labels. `createSandboxSigner()` is test-only simulation support: `SIM-*` receipts are never evidence of an institutional filing and must not unlock production.

## Still required before real filing

- deployment of the packaged Windows control service on the approved host and verification output;
- in-process Hometax/EDI adapter with explicit human confirmation;
- sandbox filing with a signed, independently validated receipt;
- CAPTCHA/MFA/manual intervention handling without bypass;
- audit review proving no certificate material appears in logs, disk, crash dumps, or telemetry.

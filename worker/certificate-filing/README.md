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

Only the in-process filing adapter may call `CredentialSessionManager.consume()`. The browser/macro adapter must consume the session immediately before certificate authentication and must never persist the PKCS#12 file or password.

### Control broker Windows service

The `windows` scripts install only the local credential control broker. The installer compiles the reviewed `CertificateBrokerService.cs` source on the target PC using the built-in .NET Framework compiler, records the resulting SHA-256, copies the broker to ProgramData, generates a random control token, protects it with Windows DPAPI, restricts the directory ACL, and creates a stopped/manual `LocalService` service. No third-party service-wrapper binary is downloaded or executed. Review the source and run `Test-ControlService.ps1` before starting it.

Do not run browser UI automation inside this service. Windows services run in non-interactive Session 0. The macro adapter must run under a separate restricted interactive Windows account and communicate with the broker through an authenticated local channel.

### Restricted interactive runner installation

After creating the non-administrator `DonghaengMacroRunner` local account, run `windows/install-interactive-runner.ps1` from an elevated PowerShell session. It installs only reviewed runner code under ProgramData, disables inherited ACLs, grants the runner account read/execute access, and keeps write/full-control access with SYSTEM and Administrators.

Run `windows/Test-InteractiveRunner.ps1` before the first interactive login. The test fails if the account is an administrator, password-less or disabled, if the runner can modify its installed code, if unexpected ACL principals exist, or if certificate/secret-looking files are present. It emits SHA-256 values for every installed runner file. The script does not store a worker token, certificate, or password.

### One-step sandbox runner preparation

From an elevated PowerShell session in this directory, run:

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\windows\Prepare-SandboxRunner.ps1
```

The script creates the dedicated non-administrator account only when it is missing, installs the reviewed five runner files, and immediately runs the ACL/account/secret-file checks. It does not reset an existing account password, store a certificate or token, or enable live institutional submission. A passing result must show `Status = SANDBOX_RUNNER_READY`, `RunnerIsAdministrator = False`, `RunnerReadExecuteOnly = True`, `ForbiddenSecretFiles = 0`, and `LiveInstitutionSubmission = False`.

### Interactive macro runner boundary

`macro-runner.mjs` defines the fail-closed coordination boundary for that separate interactive runner. It disables production by default, stops rather than bypassing CAPTCHA/MFA/certificate-selection/unexpected confirmations, verifies the canonical SHA-256 preview, trusts only server-verified confirmation, and rejects mismatched receipts. Portal-specific selectors and real submission clicks are deliberately not included until an approved sandbox target and Windows host are available.

`interactive-runner.mjs` is the sandbox-only composition entry point. It binds the coordinator to `server-gate-client.mjs`, so final confirmation verification and receipt recording cannot be replaced by caller-supplied role data. Its integration test verifies the complete preview-confirmation-receipt request sequence and proves production is rejected before credential or network use.

### Server confirmation and receipt gate

Deploy `supabase/functions/filing-gate` with `FILING_WORKER_TOKEN` set to a randomly generated value of at least 32 bytes. Configure the interactive worker's `server-gate-client.mjs` with the complete function URL ending in `/functions/v1/filing-gate/` and the same secret through the OS credential vault. Never place this token in frontend code, source control, logs, or the business database.

The function accepts the token only through `x-worker-token`, compares it by SHA-256 without an early-exit string comparison, and uses the service role only inside the Edge Function. The worker can only verify a fresh server-side confirmation or record one sandbox receipt. Production requests are rejected in the worker, Edge Function, and database RPC.

### Signed sandbox receipt

`signed-receipt.mjs` defines an Ed25519 receipt envelope and an independent allowlisted-key verifier. It binds a receipt to the job ID and confirmed payload hash, enforces a short timestamp window, requires an accepted sandbox result, and rejects production labels. `createSandboxSigner()` is test-only simulation support: `SIM-*` receipts are never evidence of an institutional filing and must not unlock production.

## Still required before real filing

- deployment of the server gate with its token stored in the OS vault and a successful live integration test;
- restricted interactive Windows account and authenticated local broker connection;
- in-process Hometax/EDI adapter with explicit human confirmation;
- sandbox filing with a signed, independently validated institutional receipt;
- CAPTCHA/MFA/manual intervention handling without bypass;
- authenticated owner/staff browser E2E proving role separation and submission denial;
- audit review proving no certificate material appears in logs, disk, crash dumps, or telemetry.

# Passkeys (WebAuthn / FIDO2)

**Researched:** 2026-08-17  
**Question:** What are passkeys, why do they exist, how do they work, and what are the moving parts?  
**Scope:** Conceptual model of passkeys as the consumer name for FIDO2/WebAuthn discoverable credentials: problem they solve, ceremony (registration + authentication), actors, artifacts, and the important distinctions (synced vs device-bound, platform vs roaming, UV vs UP, attestation). Not a library/SDK survey. Not how to implement WebAuthn in an app. Not a Propraetor design doc. OAuth2/OIDC is mentioned only to place passkeys relative to an IdP (passkeys authenticate a person to a relying party; they are not an OAuth grant).  
**Method:** Primary sources only — W3C WebAuthn, FIDO Alliance (passkeys + CTAP), IETF where needed for COSE/CBOR, and first-party platform docs (Apple, Google, Microsoft) for how those platforms ship passkeys. Secondary blogs used only as leads; every claim verified against the owning spec/doc.

---

## Spec landscape (what is current)

| Document | Status as of 2026-08-17 | Role in this note |
| --- | --- | --- |
| [WebAuthn Level 2](https://www.w3.org/TR/webauthn-2/) | W3C **Recommendation**, 8 April 2021 ([publication history](https://www.w3.org/standards/history/webauthn-2/)) | The current Recommendation: browser API, ceremonies, RP operations, security considerations |
| [WebAuthn Level 3](https://www.w3.org/TR/webauthn-3/) | W3C **Candidate Recommendation Snapshot**, 26 May 2026; W3C Team [proposed advancement to Recommendation](https://www.w3.org/news/2026/proposed-advancement-of-webauthn-3-to-w3c-recommendation/) on 20 July 2026. Not a Recommendation yet. Living editor’s draft: [w3c.github.io/webauthn](https://w3c.github.io/webauthn/) | Current TR for passkey terminology (explicit synonym for discoverable credentials), backup eligibility / multi-device vs single-device, conditional mediation, hybrid transport as a client capability |
| [CTAP 2.3](https://fidoalliance.org/specs/fido-v2.3-ps-20260226/fido-client-to-authenticator-protocol-v2.3-ps-20260226.html) | FIDO Alliance **Proposed Standard**, 26 February 2026 | Authenticator wire protocol: `authenticatorMakeCredential`, `authenticatorGetAssertion`, USB/NFC/BLE, **hybrid** transport |
| [FIDO User Authentication Specifications Overview](https://fidoalliance.org/specifications/) | FIDO Alliance overview | Defines **FIDO2 = WebAuthn + CTAP** |
| [FIDO passkeys](https://fidoalliance.org/passkeys/) (incl. FAQ) | FIDO Alliance product language | Consumer name, synced vs device-bound, passkey provider, cross-device authentication |

This note uses **WebAuthn Level 3 CR** vocabulary where L3 names things L2 did not (passkey, multi-device credential, backup flags). Protocol mechanics that exist in both are cited to L2/L3 interchangeably; RP security duties are cited to [§ 13.4](https://www.w3.org/TR/webauthn-3/#sctn-security-considerations-rp).

---

## Verdict

A **passkey** is the consumer name for a **client-side discoverable** FIDO2/WebAuthn **public key credential**: an asymmetric key pair bound to a **Relying Party** (by **RP ID** / origin), not a shared secret. The [FIDO Alliance](https://fidoalliance.org/passkeys/) defines a passkey as an authentication credential based on FIDO standards, stored on a phone, computer, or hardware security key, used with the same gesture the user uses to unlock the device (biometrics, PIN, or pattern). WebAuthn Level 3 lists **Passkey** as a synonym for a [client-side discoverable public key credential source](https://www.w3.org/TR/webauthn-3/#client-side-discoverable-credential). The authenticator (or a passkey provider that *is* the authenticator) holds the **credential private key**; the Relying Party stores the **credential public key**, **credential ID**, and **user handle**. Nothing the user types is a secret the server can replay.

Phishing resistance is a **protocol property**. The client and authenticator will not produce a valid **assertion** for the wrong origin / RP ID; the user does not have to notice that the URL is wrong. User verification (Face ID, fingerprint, PIN) happens **locally** and is not sent to the RP. Passkeys authenticate a person *to* a Relying Party. They are not OAuth tokens, not OAuth grants, and not a replacement for OAuth/OIDC between applications.

---

## Why

### Passwords are a shared secret

A password is something remembered and typed. The server stores a derivative of that same secret (or, poorly, the secret itself). Anyone who learns the secret — by phishing the user, stuffing a leaked password from another site, guessing a weak one, or reading a breached database — can authenticate as the user. The [FIDO passkeys FAQ](https://fidoalliance.org/passkeys/) states the contrast directly: passwords are “something that can be remembered and typed”; passkeys are “designed so that there are no shared secrets.” The same FAQ notes that popular second factors layered *on* passwords (OTP, phone-app approval) remain phishable because the primary factor is still a shared secret.

That shape produces the familiar failure modes:

- **Phishing** — a lookalike site collects the secret and replays it to the real site.
- **Reuse / stuffing** — the same secret works at many RPs.
- **Server breach** — the RP’s password store is worth stealing.

### Passkeys replace the shared secret with asymmetric crypto

FIDO standards use public-key cryptography for phishing-resistant authentication ([FIDO specifications overview](https://fidoalliance.org/specifications/), [passkeys FAQ](https://fidoalliance.org/passkeys/)). WebAuthn’s core object is a **credential key pair**: the authenticator generates an asymmetric pair scoped to one Relying Party; the **credential public key** is returned at registration; the **credential private key** “is expected to never be exposed to any other party, not even to the owner of the authenticator” ([WebAuthn § 4 Terminology — Credential Key Pair](https://www.w3.org/TR/webauthn-3/#credential-public-key)). The RP’s stored record is that public key plus identifiers — not a verifier for something the user can type.

Apple’s first-party security note: during registration the OS creates a unique key pair for that account; the public key is stored on the server and “is not a secret”; the private key never leaves the device in the sense that the server never learns it; “no shared secret is transmitted” ([About the security of passkeys](https://support.apple.com/en-us/102195)). Google: only the public key is stored by the site; an attacker cannot derive the private key from server data ([Google Identity — passkeys](https://developers.google.com/identity/passkeys)). Microsoft: the client generates a key pair; the private key stays on the device; authentication is proof of possession by signing a challenge ([Support for Passkeys in Windows](https://learn.microsoft.com/en-us/windows/security/identity-protection/passkeys/)).

A server breach of passkey public keys does not give the attacker a credential they can use. There is no password hash to crack and no OTP seed to steal.

### Origin binding / RP ID — phishing resistance is not a user skill

A public key credential “can only be accessed by origins belonging to that Relying Party.” Scoping is “enforced jointly by conforming User Agents and authenticators” ([WebAuthn Introduction](https://www.w3.org/TR/webauthn-3/)). The **RP ID** is a domain string identifying the Relying Party; a credential can only be used with the same RP ID it was registered with ([Relying Party Identifier](https://www.w3.org/TR/webauthn-3/#rp-id)). The authenticator includes the origin in signed client data and the RP ID hash in authenticator data, so an assertion cannot be replayed against a different origin ([WebAuthn API security properties](https://www.w3.org/TR/webauthn-3/#sctn-api)).

FIDO: every passkey is unique and bound to the online service domain ([specifications overview](https://fidoalliance.org/specifications/)). Google: the browser or OS ensures a passkey can only be used with the website or app that created it ([Google Identity — passkeys](https://developers.google.com/identity/passkeys)). Apple: passkeys are “intrinsically linked with the app or website they were created for” ([Apple Developer — Passkeys](https://developer.apple.com/passkeys/)).

A phishing site at `examp1e.com` is a different origin and a different RP ID than `example.com`. The client will not exercise the real credential there. The user does not have to detect the fraud.

### User verification stays local

**User verification** (PIN, biometric, pattern) is how the authenticator locally authorizes use of the private key ([WebAuthn — User Verification](https://www.w3.org/TR/webauthn-3/#user-verification)). “User verification and use of credential private keys MUST all occur within the logical security boundary defining the authenticator” ([same section](https://www.w3.org/TR/webauthn-3/#user-verification)). FIDO: biometric information “continues to stay on the device and is never sent to any remote server — the server only sees an assurance that the biometric check was successful” ([passkeys FAQ](https://fidoalliance.org/passkeys/)). Google: “biometric material never leaves the user's personal device” ([Google Identity — passkeys](https://developers.google.com/identity/passkeys)). Microsoft: biometric information “remains on the user's device and isn't transmitted across the network or to the service” ([Windows passkeys](https://learn.microsoft.com/en-us/windows/security/identity-protection/passkeys/)).

The RP receives a **flag** that UV succeeded, not a fingerprint, face template, or PIN.

---

## How (ceremony)

WebAuthn defines two ceremonies: **Registration** (`navigator.credentials.create()`) and **Authentication** (`navigator.credentials.get()`). The object type is `PublicKeyCredential` ([WebAuthn Introduction](https://www.w3.org/TR/webauthn-3/)). Under the hood, the client talks to the authenticator with CTAP operations **`authenticatorMakeCredential`** and **`authenticatorGetAssertion`** ([CTAP 2.3 § 6.1–6.2](https://fidoalliance.org/specs/fido-v2.3-ps-20260226/fido-client-to-authenticator-protocol-v2.3-ps-20260226.html)). WebAuthn is the browser/platform API; CTAP is the authenticator wire protocol (CBOR over USB, NFC, BLE, or hybrid). This section is the sequence of *who talks to whom*, not an SDK walkthrough.

The WebAuthn/FIDO2 protocol is a challenge–response between the RP server and the authenticator, conveyed via HTTPS, the RP’s web app, the WebAuthn API, and the platform channel to the authenticator ([WebAuthn § 1.1](https://www.w3.org/TR/webauthn-3/#sctn-spec-roadmap)).

### Registration (`create` / `authenticatorMakeCredential`)

1. **RP issues a challenge.** A fresh random nonce, generated on the server. Challenges MUST be randomly generated in an environment the RP trusts, SHOULD be at least 16 bytes, and the value returned in the response MUST match; mismatch “will compromise the security of the protocol” ([§ 13.4.3 Cryptographic Challenges](https://www.w3.org/TR/webauthn-3/#sctn-cryptographic-challenges)).
2. **Client / User Agent scopes the request.** It sets the **RP ID** (default: caller origin’s effective domain) and builds **client data**: `type` = `webauthn.create`, the challenge, and the fully qualified **origin** ([CollectedClientData](https://www.w3.org/TR/webauthn-3/#dictdef-collectedclientdata)). The API is exposed only in [secure contexts](https://www.w3.org/TR/webauthn-3/#sctn-api) (HTTPS, or `http://localhost`).
3. **Authenticator creates a key after consent.** After a **test of user presence** and, when required, **user verification**, it generates a credential key pair scoped to that RP ID, assigns a **credential ID**, and associates the RP’s **user handle** (`user.id`) ([Registration ceremony](https://www.w3.org/TR/webauthn-3/#registration-ceremony), [CTAP `authenticatorMakeCredential`](https://fidoalliance.org/specs/fido-v2.3-ps-20260226/fido-client-to-authenticator-protocol-v2.3-ps-20260226.html)). For a passkey, this is a **discoverable** credential (`rk` / resident key = true): the authenticator stores enough state to find the credential later from RP ID alone ([CTAP discoverable credentials](https://fidoalliance.org/specs/fido-v2.3-ps-20260226/fido-client-to-authenticator-protocol-v2.3-ps-20260226.html); [WebAuthn discoverable credential](https://www.w3.org/TR/webauthn-3/#client-side-discoverable-credential)).
4. **Authenticator returns attestation material.** **Authenticator data** includes `rpIdHash`, flags (UP/UV, and on L3 backup eligibility/state), `signCount`, and **attested credential data** (credential ID + **COSE** public key). An **attestation statement** may prove authenticator model; consumer passkeys often use conveyance **`none`** (the default) ([AttestationConveyancePreference](https://www.w3.org/TR/webauthn-3/#enum-attestation-convey)).
5. **RP stores the public side.** The server verifies the response (challenge, origin, RP ID hash, signature) and stores a **credential record**: credential ID, public key, sign count, user handle, optional transports ([Credential Record](https://www.w3.org/TR/webauthn-3/#credential-record)). It never receives the private key.

### Authentication (`get` / `authenticatorGetAssertion`)

1. **RP issues a new challenge** (same nonce rules as registration).
2. **Client scopes it** to the current origin / RP ID and builds client data with `type` = `webauthn.get`.
3. **Authenticator finds and uses a key.** For a passkey, `allowCredentials` can be empty: the authenticator (or platform credential manager) discovers credentials for that RP ID, possibly with user assistance — this is what makes Conditional UI / autofill possible ([discoverable credential](https://www.w3.org/TR/webauthn-3/#client-side-discoverable-credential); [conditional mediation](https://www.w3.org/TR/webauthn-3/#dom-publickeycredential-isconditionalmediationavailable)). After UP and (if required) UV, it signs with the credential private key.
4. **Assertion proves possession.** The **assertion signature** is over authenticator data concatenated with the hash of the serialized client data. Authenticator data again carries `rpIdHash`, UP/UV flags, and `signCount`. Discoverable credentials MUST return the **user handle** when `allowCredentials` was empty ([user handle](https://www.w3.org/TR/webauthn-3/#user-handle)).
5. **RP verifies with the stored public key.** Look up the credential by credential ID (and/or map the user handle to an account), check that the challenge and origin match, that `rpIdHash` is SHA-256 of the expected RP ID, that flags match policy, that `signCount` did not go backwards (clone signal), and that the signature verifies with the stored public key ([§ 7.2 Verifying an Authentication Assertion](https://www.w3.org/TR/webauthn-3/#sctn-verifying-assertion)). If valid, that user account is authenticated.

Conceptually: registration **mints** a key pair and gives the RP the public half; authentication **proves** the same authenticator (or synced copy of that credential) still holds the private half, over *this* challenge and *this* origin.

```text
Registration
  User ↔ Client/UA ↔ Authenticator
                ↕
               RP  — stores public key, credential id, user handle

Authentication
  User ↔ Client/UA ↔ Authenticator  — signs challenge+origin with private key
                ↕
               RP  — verifies signature with stored public key
```

---

## Moving parts

### Actors

| Actor | What it is | What it holds / does |
| --- | --- | --- |
| **User** | The natural person | Performs an **authorization gesture** (touch, PIN, biometric) to consent ([Authorization Gesture](https://www.w3.org/TR/webauthn-3/#authorization-gesture)) |
| **Relying Party (RP)** | The site or app using WebAuthn; often also an OpenID Provider | Issues challenges; stores credential records; verifies assertions. A WebAuthn RP is not automatically an OAuth RP ([WebAuthn — Relying Party](https://www.w3.org/TR/webauthn-3/#relying-party)) |
| **Client / User Agent** | Browser, or OS credential manager implementing the WebAuthn Client | Mediates API calls; supplies origin and RP ID; talks CTAP to authenticators ([WebAuthn Client](https://www.w3.org/TR/webauthn-3/#webauthn-client), [Conforming User Agent](https://www.w3.org/TR/webauthn-3/#conforming-user-agent)) |
| **Authenticator** | Hardware or software that creates and asserts credentials | Holds (or manages) the private key; performs UP/UV; produces attestation and assertion signatures ([Authenticator](https://www.w3.org/TR/webauthn-3/#authenticator)) |
| **Passkey provider** (optional) | OS or third-party credential manager that creates, stores, and may **sync** passkeys | FIDO examples: iCloud Keychain, Google Password Manager, or a third-party app/extension ([passkeys FAQ — What is a passkey provider?](https://fidoalliance.org/passkeys/)). To WebAuthn, the provider *is* (or fronts) the authenticator |

**Authenticator attachment** ([enum `AuthenticatorAttachment`](https://www.w3.org/TR/webauthn-3/#enum-attachment)):

- **Platform authenticator** — on the client device (Windows Hello, Apple platform authenticator, Android). Bound to that device rather than to a particular browser ([Client Device](https://www.w3.org/TR/webauthn-3/#client-device)).
- **Roaming authenticator** (`cross-platform`) — off-device: USB/NFC/BLE security key, or a phone used as an authenticator ([WebAuthn Introduction](https://www.w3.org/TR/webauthn-3/), [CTAP](https://fidoalliance.org/specs/fido-v2.3-ps-20260226/fido-client-to-authenticator-protocol-v2.3-ps-20260226.html)).

### Artifacts

| Artifact | Where it lives | Role |
| --- | --- | --- |
| **Credential ID** | Authenticator + RP | Probabilistically unique byte sequence identifying the credential (at most 1023 bytes) ([Credential ID](https://www.w3.org/TR/webauthn-3/#credential-id)) |
| **Key pair** | Private: authenticator or synced vault. Public: RP, in **COSE** key form ([RFC 9052](https://www.rfc-editor.org/rfc/rfc9052.html); [WebAuthn COSE](https://www.w3.org/TR/webauthn-3/#sctn-cose)) | Asymmetric credential scoped to one RP |
| **User handle** | Chosen by RP; stored in discoverable credentials | Opaque account id (`user.id`, max 64 bytes, MUST NOT be PII). Same handle for all credentials of one account; authenticators store at most one discoverable credential per (RP ID, user handle) ([User Handle](https://www.w3.org/TR/webauthn-3/#user-handle)) |
| **Challenge** | Fresh nonce from RP, echoed in client data | Anti-replay. Server-generated; must match on verify ([§ 13.4.3](https://www.w3.org/TR/webauthn-3/#sctn-cryptographic-challenges)) |
| **Client data** (`CollectedClientData`) | Built by the client; hashed into the signed payload | `type` (`webauthn.create` / `webauthn.get`), `challenge`, `origin` ([dictionary](https://www.w3.org/TR/webauthn-3/#dictdef-collectedclientdata)) |
| **Authenticator data** | Built by the authenticator; signed | `rpIdHash` (SHA-256 of RP ID), **flags** (UP, UV, BE, BS, AT, ED), `signCount`, optional attested credential data ([§ 6.1](https://www.w3.org/TR/webauthn-3/#sctn-authenticator-data)) |
| **Assertion** | Returned on `get` | Signed proof of possession + consent for this challenge and origin ([Authentication Assertion](https://www.w3.org/TR/webauthn-3/#assertion)) |
| **Attestation** | Returned on `create` (may be stripped to `none`) | Evidence of authenticator **origin/model** (AAGUID, attestation certificate), not proof of the user ([Attestation](https://www.w3.org/TR/webauthn-3/#attestation)) |

**Why consumer passkeys often skip attestation.** Conveyance default is **`none`**: the RP is “not interested in authenticator attestation,” e.g. to avoid extra consent or identifying the authenticator ([AttestationConveyancePreference `none`](https://www.w3.org/TR/webauthn-3/#dom-attestationconveyancepreference-none)). Synced passkeys are not a single hardware model the RP can pin. Microsoft’s Entra passkey-on-Windows profile **must not enforce attestation** ([Entra passkey on Windows](https://learn.microsoft.com/en-us/entra/identity/authentication/how-to-authentication-entra-passkeys-on-windows)). Workforce deployments that need “this exact security-key model” still request `direct` attestation; that is a different product choice than consumer passkeys.

### Transports / form factors

| Transport | What the user sees | Owning spec |
| --- | --- | --- |
| **Platform** (`internal`) | Unlock this laptop/phone | WebAuthn platform authenticator ([Introduction](https://www.w3.org/TR/webauthn-3/)) |
| **Roaming** — USB HID, NFC, BLE | Plug in, tap, or pair a security key | CTAP transports ([CTAP 2.3](https://fidoalliance.org/specs/fido-v2.3-ps-20260226/fido-client-to-authenticator-protocol-v2.3-ps-20260226.html); [FIDO2 CTAP2](https://fidoalliance.org/specifications/)) |
| **Hybrid / cross-device** | QR on the laptop, approve on the phone (BLE proves proximity) | CTAP **§ 11.5 Hybrid transports**: BLE advertisements for proximity; data over a tunnel service and/or local BLE/UWB; QR-initiated transactions ([CTAP 2.3 § 11.5](https://fidoalliance.org/specs/fido-v2.3-ps-20260226/fido-client-to-authenticator-protocol-v2.3-ps-20260226.html)). FIDO names the UX **Cross-Device Authentication (CDA)**, “powered by” CTAP using the hybrid transport; RPs do not implement CTAP ([passkeys FAQ](https://fidoalliance.org/passkeys/)). Microsoft: both devices need Bluetooth and Internet; the passkey itself is not copied over that channel ([Windows passkeys — Bluetooth-restricted environments](https://learn.microsoft.com/en-us/windows/security/identity-protection/passkeys/)) |

Hybrid is *using a passkey that already lives on another device*, not syncing the private key to the laptop.

---

## Distinctions that people mix up

### 1. Passkey vs WebAuthn vs FIDO2 vs CTAP

| Term | What it names |
| --- | --- |
| **WebAuthn** | W3C API (`PublicKeyCredential`, `navigator.credentials.create` / `get`) and the RP↔authenticator challenge–response carried through that API ([WebAuthn](https://www.w3.org/TR/webauthn-3/)) |
| **CTAP** | FIDO Client to Authenticator Protocol: how a client/platform talks to a **roaming** authenticator (and, for hybrid, to a phone). CTAP2 messages are CBOR. `authenticatorMakeCredential` / `authenticatorGetAssertion` are the CTAP verbs matching WebAuthn create/get ([CTAP 2.3](https://fidoalliance.org/specs/fido-v2.3-ps-20260226/fido-client-to-authenticator-protocol-v2.3-ps-20260226.html)) |
| **FIDO2** | WebAuthn **+** CTAP ([FIDO specifications overview](https://fidoalliance.org/specifications/)) |
| **Passkey** | Product/consumer name for FIDO credentials used as password replacement — specifically **discoverable** credentials, often synced. “The same standards, commonly known as FIDO2 (WebAuthn and CTAP), are leveraged to deploy FIDO with passkeys” ([passkeys FAQ](https://fidoalliance.org/passkeys/)). WebAuthn L3: Passkey = discoverable credential ([terminology](https://www.w3.org/TR/webauthn-3/#passkey)) |

Not every WebAuthn credential is a passkey. A second-factor security key that needs the RP to pass a credential ID (`allowCredentials`) is WebAuthn/FIDO2 but not a passkey in the discoverable, username-less sense.

### 2. Discoverable / resident key vs non-discoverable (server-side credential ID)

A **discoverable credential** (historically **resident key**) can be used when the RP provides **no credential IDs** — empty `allowCredentials`. The authenticator finds the credential from RP ID alone (with user help if several exist). That requires storing the public key credential source on the authenticator or client platform ([WebAuthn](https://www.w3.org/TR/webauthn-3/#client-side-discoverable-credential); CTAP: created iff `rk` is true).

A **server-side** (non-discoverable, historically non-resident) credential is usable only when the RP already knows the user and supplies the credential ID in `allowCredentials`. The RP must identify the user first ([server-side credential](https://www.w3.org/TR/webauthn-3/#server-side-credential)).

Passkeys are the discoverable kind, which is why the RP can show **Conditional UI** (autofill of passkeys in a username field) via `mediation: "conditional"` without knowing who is signing in ([`isConditionalMediationAvailable()`](https://www.w3.org/TR/webauthn-3/#dom-publickeycredential-isconditionalmediationavailable)). FIDO: security keys have housed device-bound passkeys since 2019 via “discoverable credentials with user verification” ([passkeys FAQ](https://fidoalliance.org/passkeys/)).

### 3. Synced (multi-device) vs device-bound

FIDO: passkeys “can be securely synced across a user’s devices, or bound to a particular device (device-bound passkeys).” When delineation is required: **synced passkeys** vs **device-bound passkeys** ([passkeys FAQ](https://fidoalliance.org/passkeys/)). WebAuthn L3: a credential that is **backup eligible** is a **multi-device credential** (commonly “synced passkey”); one that is not is a **single-device credential** (commonly “device-bound passkey”). Flags BE/BS in authenticator data signal this ([Backup Eligibility](https://www.w3.org/TR/webauthn-3/#backup-eligible); [use cases](https://www.w3.org/TR/webauthn-3/#sctn-use-cases)).

What syncs: the **credential** (private key material and metadata) through the **passkey provider’s** encrypted sync. The RP still has **one public key per credential**. A synced passkey is still one credential, now present on several devices — not a new registration per device.

| Platform (first-party claim) | What they say syncs |
| --- | --- |
| **Apple** | Passkeys sync via **iCloud Keychain**, “end-to-end encrypted, so even Apple can’t read them” ([developer](https://developer.apple.com/passkeys/), [security](https://support.apple.com/en-us/102195)). Recoverable via iCloud Keychain escrow if all devices are lost ([same](https://support.apple.com/en-us/102195)). |
| **Google** | **Google Password Manager** stores and synchronizes passkeys; “synchronized and end-to-end encrypted.” Decrypting on a new environment needs Google Account plus Android screen lock or **Google Password Manager PIN** ([supported environments](https://developers.google.com/identity/passkeys/supported-environments)). Chrome Help: the PIN exists so that “no one, not even Google, can access your encrypted data” ([GPM PIN](https://support.google.com/chrome/answer/16608973)). |
| **Microsoft** | Windows Hello can store passkeys locally. **Microsoft Entra passkey on Windows** is explicitly **device-bound**, stored in the local Windows Hello container, **not synced**; each device needs its own registration ([Entra passkey on Windows](https://learn.microsoft.com/en-us/entra/identity/authentication/how-to-authentication-entra-passkeys-on-windows)). Windows also supports companion-device (hybrid) sign-in without copying the key ([Windows passkeys](https://learn.microsoft.com/en-us/windows/security/identity-protection/passkeys/)). Plugin passkey managers can supply *synced* passkeys from a chosen provider ([WebAuthn APIs](https://learn.microsoft.com/en-us/windows/security/identity-protection/hello-for-business/webauthn-apis)). |

Recovery at a conceptual level: synced passkeys survive losing *one* device if the provider account and its recovery story still work. Device-bound passkeys (security keys, Windows Hello container) do not follow the user to a new device; FIDO treats a FIDO security key as a recovery credential when synced devices are gone, and otherwise the RP falls back to **account recovery** ([passkeys FAQ](https://fidoalliance.org/passkeys/); WebAuthn [§ 13.4.6 Credential Loss](https://www.w3.org/TR/webauthn-3/#sctn-credential-loss)).

### 4. User verification vs user presence

**Test of user presence (UP)** is a simple authorization gesture — typically a touch — yielding a boolean. It is *not* user verification: it cannot do biometric recognition and does not involve a shared secret such as a PIN ([Test of User Presence](https://www.w3.org/TR/webauthn-3/#test-of-user-presence)).

**User verification (UV)** locally distinguishes the user: PIN, password, or biometric ([User Verification](https://www.w3.org/TR/webauthn-3/#user-verification)). FIDO treats passkeys as multi-factor when UV is requested: something the user **has** (the device/credential) plus something they **are** or **know** (biometric or PIN) ([passkeys FAQ](https://fidoalliance.org/passkeys/)).

In **authenticator data** flags: bit 0 = **UP**, bit 2 = **UV**. If the authenticator did both (possibly in one gesture), it sets both flags ([§ 6.1](https://www.w3.org/TR/webauthn-3/#sctn-authenticator-data)). CTAP: `up` means require user consent; `uv` / PIN-UV token means require a user-verifying gesture ([CTAP `authenticatorMakeCredential` options](https://fidoalliance.org/specs/fido-v2.3-ps-20260226/fido-client-to-authenticator-protocol-v2.3-ps-20260226.html)). A security-key *touch* without PIN is UP without UV.

### 5. Attestation vs assertion

**Attestation** is produced at **registration**. It is “verifiable evidence as to the origin of an authenticator and the data it emits” (credential IDs, key pairs, counters). The attestation private key signs the new credential public key; the RP may check an attestation certificate chain ([Attestation](https://www.w3.org/TR/webauthn-3/#attestation)). It answers *what kind of authenticator minted this key?*, not *is this the user logging in?*

**Assertion** is produced at **authentication**. It is the signed `AuthenticatorAssertionResponse` proving the user controls the previously registered private key ([Authentication Assertion](https://www.w3.org/TR/webauthn-3/#assertion)). WebAuthn also names the two signature purposes explicitly: attestation signature vs assertion signature ([§ 6](https://www.w3.org/TR/webauthn-3/#sctn-signature-attestation-types)).

### 6. Passkeys vs passwords vs TOTP vs magic links

Only on the **shared-secret axis**:

| Mechanism | Secret shape | Phishing / reuse implication |
| --- | --- | --- |
| **Password** | Shared secret the user types; server stores a derivative | The secret is copyable; phishing, stuffing, and breaches follow ([FIDO FAQ](https://fidoalliance.org/passkeys/)) |
| **TOTP** | Shared secret `K` stored by both the RP and the user’s app; codes are HMAC over time ([RFC 6238](https://www.rfc-editor.org/rfc/rfc6238)) | Still a shared secret: steal `K` (or phish the current code in real time) and you can authenticate |
| **Magic link** | Bearer secret in a URL, typically emailed | Whoever fetches the link is the user; the secret is the link. Email becomes the authenticator |
| **Passkey** | No shared secret with the RP. Private key never sent; RP stores a public key | Assertion will not issue for the wrong origin; stolen public keys are not credentials |

Passkeys can replace both the password *and* a phishable second factor as the primary sign-in method ([FIDO FAQ — Why are passkeys better than password + second factor?](https://fidoalliance.org/passkeys/)). That is a shape comparison, not a product scorecard.

### 7. Passkeys vs OAuth2 / OIDC

OAuth 2.0 is an **authorization** framework: an Authorization Server issues tokens after authenticating the resource owner and obtaining authorization ([RFC 6749](https://www.rfc-editor.org/rfc/rfc6749)). OpenID Connect adds an OpenID Provider that authenticates the End-User and issues ID Tokens ([OIDC Core](https://openid.net/specs/openid-connect-core-1_0.html)). Passkeys are how a person proves themselves **to** a WebAuthn Relying Party. That RP may *be* an OpenID Provider; after the passkey assertion, the OP can issue OAuth/OIDC tokens to clients. WebAuthn itself notes that “Relying Party” is also used in OAuth, but a WebAuthn RP is not necessarily an OAuth RP, and “a WebAuthn context may be embedded in a broader overall context, e.g., one based on OAuth” ([WebAuthn — Relying Party](https://www.w3.org/TR/webauthn-3/#relying-party)).

Passkeys are not access tokens, refresh tokens, authorization codes, or a new OAuth grant. Apps that already speak OIDC to an IdP do not replace that hop with WebAuthn; they keep OIDC between app and IdP, and the IdP may use passkeys at the human-authentication hop.

---

## What can still go wrong

Conceptual only; WebAuthn’s own security considerations are the authority ([§ 13](https://www.w3.org/TR/webauthn-3/#sctn-security-considerations), especially [§ 13.4](https://www.w3.org/TR/webauthn-3/#sctn-security-considerations-rp)).

**Account recovery.** The spec “defines no protocol for backing up credential private keys.” Losing the only authenticator can lock the user out. RPs SHOULD encourage **multiple** credentials on the same account ([§ 13.4.6](https://www.w3.org/TR/webauthn-3/#sctn-credential-loss)). Synced providers add a recovery story (Apple escrow, Google Password Manager PIN), but if the user loses the provider account *and* all devices, the RP still needs a recovery path. FIDO: sign-in from a new vendor’s device can be a “normal account recovery situation” ([passkeys FAQ](https://fidoalliance.org/passkeys/)). Recovery methods that are passwords, email links, or SMS reintroduce a weaker factor.

**Device theft while unlocked / weak local UV.** UV is only as strong as the local PIN/biometric and the authenticator’s rate limiting ([User Verification](https://www.w3.org/TR/webauthn-3/#user-verification)). An unlocked phone, a guessed device PIN, or a shared PIN among people who share a device all authorize the same credential. Apple’s lost-device story is: passkeys stay encrypted without biometrics/passcode; Find My can wipe ([Apple passkeys Q&A](https://developer.apple.com/news/?id=21mnmxow); [About the security of passkeys](https://support.apple.com/en-us/102195)). That is device-lock security, not RP-side magic.

**RP implementation mistakes.** Benefits apply only if the RP follows [§ 7 Relying Party Operations](https://www.w3.org/TR/webauthn-3/#sctn-rp-operations) ([conformance](https://www.w3.org/TR/webauthn-3/#sctn-security-benefits)). In particular:

- Challenges MUST be server-generated, stored until the ceremony completes, matched exactly, and have enough entropy; **tolerating a mismatch compromises the protocol** ([§ 13.4.3](https://www.w3.org/TR/webauthn-3/#sctn-cryptographic-challenges)).
- Origin and RP ID hash MUST be checked; the authenticator scoped the key, but a buggy RP that skips verification can accept a wrong assertion.
- Signature verification with the stored public key is mandatory on authentication ([§ 7.2](https://www.w3.org/TR/webauthn-3/#sctn-verifying-assertion)).
- `signCount` going backwards is a **clone signal**, not proof ([§ 6.1.1](https://www.w3.org/TR/webauthn-3/#sctn-sign-counter)).
- Script injection on the RP origin can invalidate WebAuthn’s guarantees; the API is secure-context-only, which is necessary but not sufficient ([§ 13.4.8](https://www.w3.org/TR/webauthn-3/#sctn-code-injection)).
- Attestation, if used, does not by itself stop a MITM at registration; TLS and related protections still matter ([§ 13.4.4 Attestation Limitations](https://www.w3.org/TR/webauthn-3/#sctn-attestation-limitations)).

**Sync-cloud vs device-bound hardware.** First-party claims, not an independent audit: Apple says iCloud Keychain is E2E encrypted with keys not known to Apple, rate-limited against brute force even from a privileged cloud position, and designed to remain protected if the Apple Account or iCloud is compromised ([About the security of passkeys](https://support.apple.com/en-us/102195), [iCloud Keychain security overview](https://support.apple.com/guide/security/icloud-keychain-security-overview-sec1c89c6f3b/web)). Google says GPM passkeys are E2E encrypted and the GPM PIN exists so even Google cannot access the encrypted data ([supported environments](https://developers.google.com/identity/passkeys/supported-environments), [GPM PIN](https://support.google.com/chrome/answer/16608973)). FIDO: “Passkey syncing is end-to-end encrypted, and passkey providers have strong account security protections” ([FAQ](https://fidoalliance.org/passkeys/)). Device-bound keys on a FIDO security key or TPM-backed Windows Hello never enter that sync channel; Microsoft states Entra passkeys on Windows are not synced ([Entra](https://learn.microsoft.com/en-us/entra/identity/authentication/how-to-authentication-entra-passkeys-on-windows)). The trade: sync reduces lockout and new-device pain; the provider account and its E2E design become part of the trust story. Hardware-bound keys invert that trade.

FIDO notes a residual concern: a passkey provider account *could* in theory be opened with a single factor; “in practice” providers use multiple signals when restoring passkeys ([FAQ](https://fidoalliance.org/passkeys/)). That is their claim, not a guarantee an RP can verify.

---

## What this note is not

This is a conceptual model: why passkeys exist, how the two ceremonies work, who holds which key, and which vocabulary pairs people collapse. It is **not** an implementation checklist, not a library or SDK survey, not CTAP CBOR field-by-field, and **not** a recommendation for how Propraetor (or any particular product) should adopt passkeys.

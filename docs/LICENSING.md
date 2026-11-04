# Bitz Pro Licensing & Cryptographic Architecture

This document describes the backendless, offline-first licensing architecture of Bitz, including the token format, cryptographic verification model, Merchant of Record integration, and developer tooling for generating test licenses.

---

## 1. Architectural Philosophy

1. **Zero Backend Maintenance**: There are no custom backend API servers, database clusters, or cloud hosting bills ($0/month infrastructure cost).
2. **100% Offline Cryptographic Validation**: Validations execute locally on macOS in `< 5 ms` using Apple's native `CryptoKit` (`Curve25519.Signing.PublicKey` Ed25519). The app never phones home to validate a key, maintaining complete privacy.
3. **Zero Accounts & Passwords**: Users never need to register an account or manage passwords. Entitlement is cryptographically self-contained in the license token.
4. **Secure Local Storage**: Activated license receipts are persisted in macOS `Keychain` (`kSecClassGenericPassword` with `kSecAttrAccessibleAfterFirstUnlock`), surviving application updates and uninstalls.
5. **Zero Performance Footprint**: Adheres strictly to `AGENTS.md` Rule 2. Feature entitlement lookups are $O(1)$ in-memory boolean property reads. Desktop idle CPU remains strictly `< 2%` and RAM `< 70 MB`.

---

## 2. Feature Matrix: Free vs. Pro

| Feature Area | Free Tier (Beta Testers & Everyday Devs) | Bitz Pro Tier (Paid Supporters & Power Users) |
|---|---|---|
| **Primary Mascot** | Bitz the Cyber Cat (all PTS emotional states, animations) | Bitz + Full Mascot Roster (#30: Byte Dog, Aero Drone, Pixel Mech) |
| **Mascot Interactions** | Hold-to-pet, drag & magnetic edge snap | All Free interactions + special mascot animations & click responses |
| **Wellness & Health** | Full PTS engine (superCharged, balanced, burnout, recovery) | Full PTS engine + custom reminder intervals & sound alerts |
| **Theme & Visor** | Default Cyberpunk Neon (Cyan / Magenta) | Custom Palette Studio (#28: Synthwave, Tokyo Night, Monokai, Paperwhite) |
| **AI Agent Monitoring** | 1 Active Agent session (Claude Code or Antigravity) with stall alerts & wake-up buttons | Multi-Agent Swarm: 2+ simultaneous agent sessions, aggregated context & swarm HUD |
| **Hardware Telemetry** | Core telemetry: CPU load, RAM usage, die temperature, battery level | Deep telemetry: per-process battery impact & browser tab memory breakdown |
| **Audio & SFX** | Standard 8-bit cyber audio pack (purr, alert, low-battery) | Extended Audio Studio: Chiptune, Mechanical Switches, Soft Chimes |
| **Productivity Tools** | Standard companion HUD & speech bubble notes | Local Meeting Assistant (#43): local mic recording & on-device Whisper transcript |

---

## 3. Cryptographic Token Specification

Bitz license keys follow a compact, tamper-evident 3-part format:

$$\text{BITZ1}.\langle\text{base64url\_payload}\rangle.\langle\text{base64url\_signature}\rangle$$

### 3.1 Token Components

1. **Header**: Always `BITZ1` (specifies version 1 of Bitz licensing scheme).
2. **Payload** (`base64url` encoded UTF-8 JSON):
   ```json
   {
     "tier": "pro",
     "license_id": "BTZ-2026-X89K-912A",
     "issued_at": 1730712000,
     "expires_at": null
   }
   ```
   - `tier`: The entitlement tier (`"pro"`).
   - `license_id`: Unique license identifier generated at checkout.
   - `issued_at`: Unix timestamp (seconds) when the license was minted.
   - `expires_at`: `null` for perpetual / lifetime licenses; Unix timestamp for subscriptions or beta access passes.
3. **Signature** (`base64url` encoded 64-byte Ed25519 signature):
   - Signed over the ASCII data: `"BITZ1.<base64url_payload>"`.
   - Verified against the embedded 32-byte Ed25519 public key in `LicensingService`.

---

## 4. Merchant of Record Integration (Polar.sh / Lemon Squeezy)

Licensing operates without an application server by hooking a serverless webhook (e.g., Cloudflare Worker or Vercel Edge Function) directly to the Merchant of Record:

```
[Customer Purchases Pro on Polar.sh / Lemon Squeezy]
                       │
                       ▼ (Webhook: order.created)
    [Serverless Signer (Cloudflare Worker)]
      - Holds Ed25519 Private Key in Secret Store
      - Generates License ID (e.g., BTZ-2026-XXXX)
      - Signs BITZ1.<payload>
      - Returns BITZ1.<payload>.<signature> to Polar/Customer Email
                       │
                       ▼
    [Customer Pastes License Key into Bitz Settings]
                       │
                       ▼ (Offline Local Validation)
     [BitzCore: CryptoKit.Curve25519.Signing.PublicKey]
      - Verifies Ed25519 signature offline (< 5 ms)
      - Saves token to macOS Keychain
      - Unlocks Bitz Pro features instantly
```

---

## 5. Developer Tooling: Minting Test License Keys

Developers can mint valid test license keys locally using the script below.

### Swift CLI Minting Script

Save as `mint_license.swift` and run with `swift mint_license.swift`:

```swift
import Foundation
import CryptoKit

// 1. Private key (keep secret in production, used here for local development)
let privateKeyBase64 = "xHzORTE6IFBK/qFYLkB75uwqnvt7gpG9hwJ0Tl4syQA="
guard let privateKeyData = Data(base64Encoded: privateKeyBase64),
      let privateKey = try? Curve25519.Signing.PrivateKey(rawRepresentation: privateKeyData) else {
    fatalError("Invalid private key")
}

// 2. Prepare payload
let payloadDict: [String: Any?] = [
    "tier": "pro",
    "license_id": "BTZ-DEV-TESTING-2026",
    "issued_at": Int(Date().timeIntervalSince1970),
    "expires_at": nil
]

let payloadData = try JSONSerialization.data(withJSONObject: payloadDict.compactMapValues { $0 }, options: [.sortedKeys])

func base64url(_ data: Data) -> String {
    data.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

let payloadEncoded = base64url(payloadData)
let signedData = Data("BITZ1.\(payloadEncoded)".utf8)
let signature = try privateKey.signature(for: signedData)
let signatureEncoded = base64url(signature)

let licenseKey = "BITZ1.\(payloadEncoded).\(signatureEncoded)"
print("Minted Bitz Pro License Key:")
print(licenseKey)
```

---

## 6. Codebase Mapping & Reference

- **Models**: [`src/Models/LicensingModels.swift`](file:///Users/akram/Documents/GitHub/bitz-mac/src/Models/LicensingModels.swift)
- **Domain Service**: [`src/Services/Licensing/LicensingService.swift`](file:///Users/akram/Documents/GitHub/bitz-mac/src/Services/Licensing/LicensingService.swift)
- **Keychain Storage**: [`src/Services/Licensing/KeychainLicenseStorage.swift`](file:///Users/akram/Documents/GitHub/bitz-mac/src/Services/Licensing/KeychainLicenseStorage.swift)
- **Settings Tab**: [`src/Views/Settings/BitzProSettingsTabView.swift`](file:///Users/akram/Documents/GitHub/bitz-mac/src/Views/Settings/BitzProSettingsTabView.swift)
- **Feature Gate Badge**: [`src/Views/Components/ProBadgeView.swift`](file:///Users/akram/Documents/GitHub/bitz-mac/src/Views/Components/ProBadgeView.swift)
- **Unit Tests**: [`Tests/BitzTests/LicensingServiceTests.swift`](file:///Users/akram/Documents/GitHub/bitz-mac/Tests/BitzTests/LicensingServiceTests.swift)

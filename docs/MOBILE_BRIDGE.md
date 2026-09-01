# HerdrM mobile bridge

HerdrM starts an authenticated fleet bridge on macOS. The bridge owns the Mac app's existing device sessions, so a mobile client sees the same local and SSH-backed Herdr devices without copying their credentials to the phone.

## Mobile Pairing window

Choose **herdrm → Mobile Pairing…** on the Mac to administer mobile access. The window:

- displays a QR representation and selectable copy of the complete pairing JSON;
- reveals the protected pairing file in Finder;
- enables or disables the bridge;
- changes the listening port and loopback policy;
- applies settings by restarting the in-process bridge;
- rotates the Keychain-backed token after destructive confirmation.

Rotating the token disconnects existing clients and invalidates their saved pairing until they import the new data.

## Network exposure

The bridge is enabled by default and listens only on `127.0.0.1:45983`. The token is random, stored in the macOS Keychain, and exported for initial pairing in a mode-`0600` file:

```text
~/Library/Application Support/HerdrM/mobile-pairing.json
```

For Tailscale, expose that loopback TCP port with a raw TCP forward, or enable **Listen beyond loopback** in the Mobile Pairing window and restart the bridge. The equivalent command is:

```sh
defaults write dev.bybee.herdrm fleetBridge.bindAllInterfaces -bool true
```

Use the Mac's Tailscale IP or MagicDNS name from the iOS client. Tailnet policy should restrict the bridge port to the intended user/devices. **Listen beyond loopback** exposes the TCP listener on non-Tailscale interfaces too, so it should only be used on a trusted network path.

The listener can also be disabled or moved through the pairing window. Equivalent defaults commands are:

```sh
defaults write dev.bybee.herdrm fleetBridge.enabled -bool false
defaults write dev.bybee.herdrm fleetBridge.port -int 45983
```

## Pairing iPhone or iPad

1. Open **herdrm → Mobile Pairing…** on the Mac.
2. In HerdrM for iOS choose **Add Connection → Mac Bridge**.
3. Scan the QR code, or paste the pairing JSON copied from the Mac.
4. Replace the suggested host with the Mac's Tailscale IP or MagicDNS name when necessary.
5. Confirm the port and add the bridge.

The endpoint metadata is stored in iOS user defaults. The pairing token is stored separately in the device-only Keychain. Remote SSH passwords, keys, host configuration, and reconnect state remain on the Mac.

The iOS sidebar opens in **All Devices** mode. Device, Space, Agent, and terminal identities are globally qualified by the Mac device UUID, so equal Herdr pane IDs on two machines do not collide. Direct SSH remains available as an advanced fallback for a standalone Herdr host.

## Agent attachments

The paperclip in an Agent terminal opens the iOS Files picker. HerdrM stages the selected file on the target device, then inserts that device-local path into the Agent composer without automatically sending the prompt.

- Files are limited to **32 MiB** so their base64 bridge envelope remains below the protocol's existing 64 MiB record bound.
- The phone validates that the selection is a regular file and reads security-scoped URLs only for the duration of the transfer.
- Filenames are stripped of path components, control characters, and reserved separators before they enter any managed cache.
- Files for this Mac are stored under `~/Library/Application Support/HerdrM/MobileAttachments` with a mode-`0700` directory and mode-`0600` files. Entries older than seven days are pruned when another file is staged.
- Files for an SSH-backed device are first received by the Mac and then transferred with the Mac app's existing authenticated SFTP service. The temporary Mac copy is removed after staging.
- Direct SSH fallback uploads to `~/.cache/herdrm/mobile-uploads` on the target with mode `0600`, a partial filename, and an atomic final rename.
- Remote SSH credentials remain on the Mac in bridge mode and never enter the attachment payload.

## Protocol

Bridge protocol 2 uses newline-delimited JSON. Every TCP connection performs mutual challenge-response authentication before selecting exactly one operation:

1. iOS sends `bridge.hello` with its stable client ID, display name, and a fresh 256-bit client nonce. It does **not** send the pairing token.
2. The Mac sends `bridge.challenge` with its stable server ID, a fresh 256-bit server nonce, and a direction-specific HMAC-SHA256 proof over both identities and both nonces.
3. iOS verifies the Mac proof against the Keychain token and expected server ID, then sends `bridge.authenticate` with a distinct client proof.
4. The Mac verifies the client proof and sends `bridge.welcome`.

The client and server proof contexts are different, preventing reflection. Fresh nonces make captured handshakes unusable on later connections. The pairing secret crosses devices only through the initial QR/JSON pairing channel and is never transmitted during normal bridge connections.

After authentication, a connection owns one operation:

- `fleet.snapshot`: one complete fleet snapshot, then close.
- `fleet.subscribe`: complete snapshots whenever the Mac model changes.
- `herdr.request`: one allowlisted Herdr operation for a selected device.
- `terminal.open`: one observed or controlled terminal stream.

Challenge-response authenticates the endpoints; Tailscale remains the transport confidentiality and integrity layer. Do not expose the raw bridge port to an untrusted network.

Terminal control remains explicit. Observer streams cannot send raw input or resize commands, and takeover is only requested when the client sets it in `TerminalSessionMode`.

The allowlist covers snapshots, ping, attachment staging, Agent prompt/start/rename, pane input/close, workspace create/rename/close, and tab create/rename. Extend this list deliberately rather than turning the bridge into an arbitrary shell or unrestricted socket proxy.

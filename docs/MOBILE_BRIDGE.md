# HerdrM mobile bridge

HerdrM starts an authenticated fleet bridge on macOS. The bridge owns the Mac app's existing device sessions, so a mobile client sees the same local and SSH-backed Herdr devices without copying their credentials to the phone.

## Mobile Pairing window

Choose **herdrm → Mobile Pairing…** on the Mac to administer mobile access. The window:

- displays a QR representation and selectable copy of the complete pairing JSON;
- reveals the protected pairing file in Finder;
- enables or disables the bridge;
- optionally launches HerdrM at login and keeps the bridge in menu-bar background mode;
- shows the active listener address and network scope;
- changes the listening port and optional all-interface policy;
- applies settings by restarting the in-process bridge;
- rotates the Keychain-backed token after destructive confirmation.

Rotating the token disconnects existing clients and invalidates their saved pairing until they import the new data.

## Background availability

Enable **Keep bridge available in background** in the Mobile Pairing window to register HerdrM as a per-user login item. A login-item launch starts the Mac device sessions and bridge, suppresses the normal application window, and exposes a small menu-bar item for opening or quitting HerdrM.

Closing the last HerdrM window never terminates the process or disconnects mobile clients. When background availability is enabled, the app switches to the same menu-bar presentation after the last window closes. Opening HerdrM again restores the normal Dock application and window. Explicit **Quit HerdrM** still closes terminal children, SSH tunnels, and bridge connections cleanly.

The bridge stays in the main HerdrM process rather than a second credential-bearing daemon. This preserves a single owner for `AppModel`, SSH sessions, Keychain credentials, terminal processes, authentication state, and fleet revisions. macOS may require approval under **System Settings → General → Login Items** before the login item becomes active.

## Network exposure

The bridge is enabled by default on TCP port `45983`. Its listener policy is:

1. When a Tailscale tunnel interface has an active IPv4 address in `100.64.0.0/10`, bind **only** that exact tailnet address.
2. When Tailscale is unavailable, bind only `127.0.0.1`.
3. Bind every interface only when **Listen on all interfaces** is explicitly enabled.

This permits direct iPhone/iPad access through the Mac's tailnet address without a separate TCP forward and without opening the bridge on Wi-Fi or Ethernet. HerdrM re-evaluates active interfaces when the network path changes and periodically as a fallback. If the Tailscale address appears, disappears, or changes, it moves the listening socket, updates the status in the pairing window, and rewrites the pairing payload and QR code. Already accepted fleet and terminal connections are not explicitly cancelled when the listener moves.

The pairing token is random, stored in the macOS Keychain, and exported for initial pairing in a mode-`0600` file:

```text
~/Library/Application Support/HerdrM/mobile-pairing.json
```

The pairing payload includes:

- `host_hint`: the selected Tailscale IP, loopback address, or fallback hostname;
- `network_scope`: `tailscale`, `loopback`, or `all-interfaces`;
- `loopback_only`: retained for compatibility with existing mobile pairing UI.

Tailnet policy should restrict TCP port `45983` to the intended users or devices. **Listen on all interfaces** also exposes the bridge on local networks and should remain off unless that exposure is deliberate.

The listener can be disabled, moved, or explicitly opened to every interface through the pairing window. Equivalent defaults commands are:

```sh
defaults write dev.bybee.herdrm fleetBridge.enabled -bool false
defaults write dev.bybee.herdrm fleetBridge.port -int 45983
defaults write dev.bybee.herdrm fleetBridge.bindAllInterfaces -bool true
```

## Pairing iPhone or iPad

1. Start Tailscale on the Mac and iPhone/iPad.
2. Open **herdrm → Mobile Pairing…** on the Mac and confirm it reports **Tailscale only**.
3. In HerdrM for iOS choose **Add Connection → Mac Bridge**.
4. Scan the QR code, or paste the pairing JSON copied from the Mac.
5. Confirm the automatically supplied tailnet address and port, then add the bridge.

If the Mac reports loopback, start Tailscale and leave the pairing window open; its status and QR code update when the tunnel address becomes available.

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

This is bounded attachment staging, not full mobile file-browser parity.

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

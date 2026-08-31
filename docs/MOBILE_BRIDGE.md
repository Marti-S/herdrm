# HerdrM mobile bridge

HerdrM starts an authenticated fleet bridge on macOS. The bridge owns the Mac app's existing device sessions, so a mobile client sees the same local and SSH-backed Herdr devices without copying their credentials to the phone.

## Network exposure

The bridge is enabled by default and listens only on `127.0.0.1:45983`. The token is random, stored in the macOS Keychain, and exported for pairing in a mode-`0600` file:

```text
~/Library/Application Support/HerdrM/mobile-pairing.json
```

For Tailscale, expose that loopback TCP port with a raw TCP forward, or explicitly allow the listener on all Mac interfaces and restart HerdrM:

```sh
defaults write dev.bybee.herdrm fleetBridge.bindAllInterfaces -bool true
```

Use the Mac's Tailscale IP or MagicDNS name from the iOS client. The bridge token is still required even when tailnet ACLs restrict the port.

The listener can be disabled or moved to another port:

```sh
defaults write dev.bybee.herdrm fleetBridge.enabled -bool false
defaults write dev.bybee.herdrm fleetBridge.port -int 45983
```

## Pairing iPhone or iPad

1. Start HerdrM on the Mac once so it writes `mobile-pairing.json`.
2. Copy the JSON contents to the iPhone or iPad through a trusted channel.
3. In HerdrM for iOS, choose **Pair Mac Bridge** and tap **Paste Pairing JSON**.
4. Replace the suggested host with the Mac's Tailscale IP or MagicDNS name when necessary.
5. Confirm the port and pair.

The endpoint metadata is stored in iOS user defaults. The pairing token is stored separately in the device-only Keychain. Remote SSH passwords, keys, host configuration, and reconnect state remain on the Mac.

The iOS sidebar opens in **All Devices** mode. Device, Space, Agent, and terminal identities are globally qualified by the Mac device UUID, so equal Herdr pane IDs on two machines do not collide. Direct SSH remains available as an advanced fallback for a standalone Herdr host.

## Protocol

Every TCP connection is newline-delimited JSON and starts with `bridge.hello`. After authentication, one connection owns exactly one operation:

- `fleet.snapshot`: one complete fleet snapshot, then close.
- `fleet.subscribe`: complete snapshots whenever the Mac model changes.
- `herdr.request`: one allowlisted Herdr operation for a selected device.
- `terminal.open`: one observed or controlled terminal stream.

Terminal control remains explicit. Observer streams cannot send raw input or resize commands, and takeover is only requested when the client sets it in `TerminalSessionMode`.

The initial allowlist covers snapshots, ping, agent prompt/start/rename, pane input/close, workspace create/rename/close, and tab create/rename. Extend this list deliberately rather than turning the bridge into an arbitrary shell or unrestricted socket proxy.

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

The bridge is enabled by default and listens only on `127.0.0.1:45983`. The token is random, stored in the macOS Keychain, and exported for pairing in a mode-`0600` file:

```text
~/Library/Application Support/HerdrM/mobile-pairing.json
```

For Tailscale, expose that loopback TCP port with a raw TCP forward, or enable **Listen beyond loopback** in the Mobile Pairing window and restart the bridge. The equivalent command is:

```sh
defaults write dev.bybee.herdrm fleetBridge.bindAllInterfaces -bool true
```

Use the Mac's Tailscale IP or MagicDNS name from the iOS client. The bridge token is still required even when tailnet ACLs restrict the port.

The listener can also be disabled or moved through the pairing window. Equivalent defaults commands are:

```sh
defaults write dev.bybee.herdrm fleetBridge.enabled -bool false
defaults write dev.bybee.herdrm fleetBridge.port -int 45983
```

## Pairing iPhone or iPad

1. Open **herdrm → Mobile Pairing…** on the Mac.
2. Copy the Pairing JSON to the iPhone or iPad through a trusted channel. The QR code contains the same data for future scanner support.
3. In HerdrM for iOS choose **Add Connection → Mac Bridge** and paste the JSON.
4. Replace the suggested host with the Mac's Tailscale IP or MagicDNS name when necessary.
5. Confirm the port and add the bridge.

The endpoint metadata is stored in iOS user defaults. The pairing token is stored separately in the device-only Keychain. Remote SSH passwords, keys, host configuration, and reconnect state remain on the Mac.

The iOS sidebar opens in **All Devices** mode. Device, Space, Agent, and terminal identities are globally qualified by the Mac device UUID, so equal Herdr pane IDs on two machines do not collide. Direct SSH remains available as an advanced fallback for a standalone Herdr host.

## Attachments

Bridge-backed Agent composers expose a paperclip when the Agent manifest advertises an image or file path capability. iOS reads up to five security-scoped files at a time, bounded to 16 MiB per file and 32 MiB per selection.

Each file is sent through an authenticated, device-scoped bridge request. The Mac writes it into a private `MobileUploads` directory and passes it through the existing `HerdrService.stageAttachment` path:

- local Mac Agents receive the private Mac path;
- Agents on an SSH-backed fleet device receive the remote staged path;
- temporary Mac copies for remote devices are removed after successful transfer;
- old local staging directories are pruned after seven days.

The returned device-local paths are formatted with the Agent manifest's attachment syntax and inserted into the native iOS composer. The user can add instructions before sending the prompt. Direct SSH fallback does not expose this upload path yet; it fails closed rather than bypassing the Mac-owned staging model.

## Protocol

Every TCP connection is newline-delimited JSON and starts with `bridge.hello`. After authentication, one connection owns exactly one operation:

- `fleet.snapshot`: one complete fleet snapshot, then close.
- `fleet.subscribe`: complete snapshots whenever the Mac model changes.
- `herdr.request`: one allowlisted Herdr operation for a selected device.
- `terminal.open`: one observed or controlled terminal stream.

Terminal control remains explicit. Observer streams cannot send raw input or resize commands, and takeover is only requested when the client sets it in `TerminalSessionMode`.

The allowlist covers snapshots, ping, Agent manifests, attachment staging, agent prompt/start/rename, pane input/close, workspace create/rename/close, and tab create/rename. Extend this list deliberately rather than turning the bridge into an arbitrary shell or unrestricted socket proxy.

# iOS transport and transcript performance

## Scope

This change removes repeated bridge authentication from normal RPC traffic,
replaces supported conversation polling with activity-driven subscriptions,
fences reader work by transport generation, and bounds terminal rendering and
bridge output queues. It does not replace SwiftTerm or invent semantic message
roles from terminal text. A native Codex app-server transcript adapter remains a
separate integration requiring explicit pane/thread ownership mapping.

## Connection ownership and compatibility

`MobileBridgeSession` owns one `FleetBridgeClient` per live generation. The client
owns its persistent control connection and a registry of fleet, transcript, and
terminal connections. Background cleanup closes the entire generation. Activation
is idempotent and waits for preceding cleanup; it does not reconnect healthy
sessions simply because both scene activation and the root view call it.

The existing v2 wire and authentication handshake are retained. After authenticating,
a new client sends `bridge.capabilities` in an ordinary `herdr.request`, using an
actual fleet device ID. This matters because old hosts validate the device before
dispatching the method; the separate Mac pairing/server ID is not a device ID.

A supporting host replies with `persistent_rpc: true` and `pane_transcript: true`
and retains that control connection. Only an explicit `unsupported_method` reply
selects legacy one-operation-per-connection behavior. Authentication, identity,
protocol, and arbitrary connection failures must not silently downgrade security.
Old clients never negotiate and retain close-after-one-RPC behavior on a new host.

RPC replies are dispatched by request ID. Admission is bounded at 32 requests.
Each request has a 15-second deadline; idle control sessions ping every 10 seconds.
Cancellation removes a queued write or its pending waiter, but cannot retract a
mutation already handed to the network. No prompt, input, or other mutating RPC
is automatically replayed after a lost acknowledgment. Existing Keychain secrets,
server identity checks, SSH host-key verification, and listener exposure are unchanged.

Terminal and transcript output use dedicated connections rather than sharing the
control writer. Fleet subscriptions receive complete, coalescible snapshots and
15-second heartbeats on new hosts. New clients apply a 45-second receive deadline
only after negotiating support or observing a heartbeat; legacy idle subscriptions
are not incorrectly disconnected for failing to send a newly introduced heartbeat.

## Transcript protocol

`bridge.pane.subscribe` is a dedicated authenticated RPC operation with `pane_id`
and an optional integer `lines` in 1...250. Its responses reuse the existing
`herdr.response` envelope and the subscription request ID. A connection always
starts with an authoritative `TerminalReadResult`. Subsequent responses carry
`TerminalTranscriptUpdate`: either another full read or a UTF-8-boundary-safe
prefix/removal/insertion patch with a subscription sequence and base sequence.
Redraws and sliding terminal history are replacements, never guessed appends.

The receiver applies every wire patch before coalescing complete reads for UI
consumption. Duplicates are ignored, missing bases/gaps are rejected, and retrying
opens a new subscription with a full bootstrap. This is snapshot resynchronization,
not durable server-side replay or exactly-once mutation delivery.

On a new Mac host, a read-only terminal observer invalidates `pane.read` at most
once per 100 ms start-to-start, with one trailing read for events received while
busy. The Mac sends changed readable text rather than forwarding every terminal
frame to the phone's conversation reader. Idle observers do not repeatedly read
unchanged panes. If the daemon lacks observation support, the Mac falls back to
900 ms reads. Old bridge hosts use adaptive client polling; no compatibility path
speeds polling up merely to hide transport latency.

Direct SSH uses the same activity-driven reader, opening its observer over the
already authenticated SSH session. An unsupported observer falls back to polling.
The snapshot-first provider contract removes the old duplicate initial 100-line
read followed immediately by a 250-line read.

## Lifecycle and rendering

`TranscriptReader` keeps content separate from its provider binding. Loads,
streams, and manual refreshes are generation-fenced. Rebinding cancels old work;
even a transport that ignores cancellation cannot overwrite the new connection's
state. Background suspension retains cached content. A bounded 12-reader cache is
pruned on source removal; raw terminal view identity includes transport generation
so a stale input transport cannot survive reconnect. Control is never reacquired
implicitly after a view is recreated.

Readable terminal content is split into independently comparable 12-line items.
Unchanged text does not invalidate all rows merely because the daemon revision
changed. Pinned-to-history content is retained until the reader follows latest;
exact pixel scroll restoration across a recreated view is not guaranteed.

`TerminalOutputBatcher` retains its 2 MiB queued-byte bound and adds a default
32 KiB maximum per main-actor delivery, yielding between queued deliveries. All
bytes remain ordered and are preserved, including UTF-8/escape sequences split
across deliveries. A byte bound is not a guarantee of a particular frame time;
large pathological lines still require physical-device profiling.

Mac stdout decoding and bridge JSON serialization run off the main actor. One
ordered pipe reader waits for bounded writes rather than spawning an unbounded
main-actor task per stdout chunk. Final stdout is drained before process-exit
notification. Network writes are message/byte bounded with a 30-second stall
deadline; obsolete complete fleet snapshots may be coalesced, terminal bytes may
not. Direct-device full fleet refreshes are limited to one start per 300 ms even
during continuous event bursts.

## Tests and validation

The new HerdrKit regression suites are:

- `AsyncTransportPerformanceTests`: bounded writes, cancellation, response IDs,
  request deadlines/no retries, refresh coalescing, bounded terminal delivery.
- `TerminalTranscriptPerformanceTests`: deterministic Unicode fuzz fixtures,
  redraw/sliding-history patches, sequence gaps, full resync, stable chunk IDs.
- `TranscriptReaderLifecycleTests`: stale initial/manual replies, rebinding,
  suspend/resume, cached content, pinned history, snapshot-first bootstrap.
- `ObservedTranscriptTests`: idle observation, cancellation, compatibility reads.

Run the actual repository suite on macOS:

```sh
swift test --package-path Packages/HerdrKit
make build
```

The existing Validate workflow additionally resolves packages and builds the iOS
device and arm64 simulator targets. A Linux subset harness executed 32 new tests
with zero failures, including repeated scheduling runs. It used copied public
terminal/transcript model definitions to avoid Apple-only dependencies; this is
not a full HerdrKit package run or an Apple SDK build. No physical-device speedup
has been measured as part of that validation.

Before merging, inspect the actual macOS/iOS build results and exercise this matrix:

| Case | Required behavior |
| --- | --- |
| New phone / new host | One control authentication per live session; pushed changed transcript text. |
| New phone / old host | Explicit capability fallback; normal prompt/input behavior remains available. |
| Old phone / new host | Existing per-operation RPC and terminal behavior remains valid. |
| Unsupported daemon observer | Readable polling fallback; no authorization or host-key bypass. |
| Repeated foreground/background | Selected reader rebinds, late replies are ignored, old channels close. |
| Network loss during prompt | Failure is surfaced; the prompt is not blindly resent. |
| Unicode, redraw, history eviction | Final text matches a fresh bounded pane read. |
| Large terminal output / slow client | Byte order preserved, memory bounded, control requests remain independent. |
| Host restart / sequence gap | Fresh authoritative transcript, not duplicated appended history. |

Profile release builds on a physical iPhone, testing bridge and direct SSH
separately under low- and higher-latency paths. Use Instruments Points of Interest
with subsystem `dev.bybee.herdrm`, category `performance`. Signposts include
`BridgeAuthentication`, `BridgeRPC`, `MobileTranscriptRead`, `HostTranscriptRead`,
`TranscriptProjection`, `BridgeEncodeAndWrite`, and `MobileTerminalDelivery`.
Only fixed operation names and byte counts are logged, never tokens, prompts,
terminal content, or hostnames. Compare cold open, warm RPC acknowledgment,
first visible output, receive-to-render time, hitches, and memory independently;
model-generation latency must not be reported as transport latency.

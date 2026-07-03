# poddev.md — OmnipodKit "connect-on-demand + fault-via-advertisement" work

Handoff for a fresh agent. This is a **DIY LibreLoop / LoopKit** OmnipodKit (Dash) effort exploring
a **normally-disconnected** pump connectivity model: stay disconnected, wake on faults via BLE
advertisement, connect on demand for commands, and provide a periodic heartbeat only when asked.

Everything here lives on branch **`unsolicited-fault-listener-prototype`** of
**`loopkitdev/OmnipodKit`**. It is a **prototype / field-test branch** — heavily instrumented,
several default-ON test flags and debug scaffolding that MUST be reverted before any merge.

---

## Environment & workflow

- **Workspace:** `~/loopdev/LoopWorkspace` (the superproject; OmnipodKit is the submodule of
  interest). NOTE: earlier sessions used `~/loopdev/LoopWorkspace-test`; the main workspace going
  forward is `~/loopdev/LoopWorkspace`.
- **Repo of interest:** `LoopWorkspace/OmnipodKit`, branch `unsolicited-fault-listener-prototype`.
- **Commits:** author email `pschwamb@gmail.com`; **plain messages, NO `Co-Authored-By` trailers.**
- **Push (loopkitdev fork):** default `gh` account is pull-only; switch first:
  ```bash
  gh auth switch --user loopkitdev
  git -c user.email=pschwamb@gmail.com commit -m "…"
  git push "https://loopkitdev:$(gh auth token)@github.com/loopkitdev/OmnipodKit.git" HEAD:unsolicited-fault-listener-prototype
  ```

### Build + install (real device — a real Dash pod is paired)
```bash
cd ~/loopdev/LoopWorkspace
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -workspace LoopWorkspace.xcworkspace -scheme LoopWorkspace \
  -destination 'platform=iOS,id=00008140-001C29C93660801C' \
  -derivedDataPath /tmp/dd-device -allowProvisioningUpdates \
  LOOP_DEVELOPMENT_TEAM=UY678SP37Q build
# then install (device may show "unavailable" if locked — unlock/reconnect):
xcrun devicectl device install app --device 4950044E-6D03-564F-A1D9-E86E77D99613 \
  /tmp/dd-device/Build/Products/Debug-iphoneos/Loop.app
```
- **Device:** iPhone, xcodebuild id `00008140-001C29C93660801C`, devicectl UUID
  `4950044E-6D03-564F-A1D9-E86E77D99613`. Pod `DD5D6B83-1B76-FE80-C2A9-0BE91CC43225`, address
  `0x179F0CF1`.
- **Do NOT wrap `devicectl` in `timeout`** — not installed on macOS; it silently no-ops (rc=0) and
  you keep running the old build.
- **Force-quit + reopen Loop after each install.** Do NOT uninstall/delete the app — that loses pod
  pairing state (only one pod, precious).
- **Logs:** the persistent **device log** (Loop → Settings → Issue Report) captures our tagged lines
  and survives background wakes — preferred over a live `log stream`. Subsystem
  `com.loopkit.OmnipodKit`.

### Log tags to grep
`[connectOnDemand]` `[delayedConnect]` `[heartbeat]` `[lifecycle]` `[POD-STATUS]` `[POD-ALERT]`
`[ADV]` `[BEACON]` `[SCAN]`

---

## The target architecture

1. **Idle (normal):** pump **disconnected**, running an **alarm-filtered scan** (`[C005]` + a
   speculative 128-bit UUID) so iOS wakes us — even via State Restoration — only on a **fault
   advert**. No connection held.
2. **Command / status:** **connect on demand** (fast, via fresh-discovery), run, then idle-disconnect
   (~4 s after the session queue empties).
3. **Heartbeat (only when the CGM can't provide one — e.g. a network CGM):** Loop calls
   `setMustProvideBLEHeartbeat(true)` → the **delayed-connect loop** provides a periodic background
   wake. Normally OFF (a BLE CGM provides the heartbeat, so the pump just listens for alarms).

---

## Field-test flags (in `BluetoothManager.swift`, UserDefaults-backed) — CURRENT defaults

| flag | default | meaning |
|---|---|---|
| `advertisementMonitorEnabled` | true | log `[ADV]`/`[SCAN]` for pod frames |
| `connectOnDemandEnabled` | true | normally-disconnected + connect per command |
| `lowPowerMonitorEnabled` | **true** | idle scan = alarm UUIDs only (`alarmServiceUUIDs`) |
| `beaconCaptureEnabled` | false | §5 wildcard capture (`withServices:nil`, allowDuplicates) |
| `suppressCommandsEnabled` | false | measurement mode: skip ALL commands (leave pod idle) |
| `delayedConnectProbeEnabled` | false | manual override for the heartbeat loop (normally driven by `setMustProvideBLEHeartbeat`) |
| `delayedConnectProbeSeconds` | 300 | StartDelay for the heartbeat probe |

`alarmServiceUUIDs = [C005, CE1F923D-…-0A179F0CF102 (AS), …03 (AST)]` — the 16-bit `C005` is
CONFIRMED; the two 128-bit are the RE model with **deviceId GUESSED = 179F0CF1, UNCONFIRMED**
(this pod never emitted a CE1F923D frame — see findings).

---

## Key findings (also in `DASH_BEACON_FINDINGS.md`)

### 1. Alerts ride the NORMAL 16-bit advertisement — connectionless detection works
Triggering a non-fault alert (expiration reminder) flipped, in the normal connectable advert:
- 2nd service UUID: `C001` (clear) ↔ **`C005`** (alert)
- mfg status word: `…000a`**`00020000`**`f10c` (clear) → `…000a`**`000a0008`**`f10c` (alert)

Reversible on acknowledge. `detectPodAlertStatus()` reads this from the scan callback and logs
`[POD-STATUS]` / `[POD-ALERT]` — **no connection needed.** (Not yet wired to Loop's real alert
system — stage 2, pending more alarm-code samples.)

### 2. This pod does NOT emit the 128-bit `CE1F923D` beacon
The RE binary model predicts a 128-bit `CE1F923D-C539-48EA-7300-0A<deviceId><TT>` beacon
(TT 00/01=DS, 02/03=AS/AST). A clean **10-minute idle wildcard capture** never produced one. This
pod advertises the **16-bit** list at **~0.77 s**, **stable** payload, **connectable**. So on this
hardware the alarm lever is the 16-bit `C005` / mfg word, not `CE1F923D`. The `CE1F923D` path is
presumed **fault-only** (or a different pod gen) — **untested** (needs a sacrificed pod).

### 3. Delayed connect + State Restoration = periodic background wake that SURVIVES relaunch
`central.connect(peripheral, options:[CBConnectPeripheralOptionStartDelayKey: N])` while
disconnected: iOS holds it N s, then completes it, and via State Restoration (restore id
`com.OmnipodKit`) **relaunches the terminated app**. **Proven** over a 15 h run: new PIDs ran with
`everFg=false` (never foregrounded) for up to **~1h42m** — iOS launched them, not the user.
- Self-sustaining: re-arm the next probe in `didDisconnect` (relying on `didDiscover` stalled when
  suspended).
- Timing is **fuzzy**: StartDelay=300 → actual wakes ~5–12 min typical, spikes to ~26 min.
- Gated by `setMustProvideBLEHeartbeat` (see wiring below). Off by default.
- `everFg` (ever-foregrounded) is the signal that distinguishes an iOS relaunch from a manual open —
  `willRestoreState` + a new PID do NOT prove a relaunch (both happen on a manual open too).

### 4. Connect-on-demand latency — the current focus
- A bare `connect()` on a non-scanned pod = **~16 s** cold reacquisition (saw a 20 s timeout too),
  because idle we only scan `[C005]` so the pod is never "fresh" to iOS.
- **Any concurrent scan starves the connect** (even non-allowDuplicates wildcard) → 20 s timeout.
  So the connect must go **fully dark**, OR use fresh-discovery.
- **Fresh-discovery connect (JUST INSTALLED, commit `ad82b5f`, awaiting measurement):**
  `connectViaFreshDiscovery` scans for the pod's service `[4024]`, and on the next `didDiscover`
  **stops the scan then connects** on that just-heard advert (~1–2 s expected), 4 s fallback to a
  cold connect. **Next step: confirm the `[connectOnDemand] connected in X.XXXs` number.**

---

## Heartbeat wiring (setMustProvideBLEHeartbeat → delayed-connect loop)

```
OmniPumpManager.setMustProvideBLEHeartbeat(b)   // logs [heartbeat] setMustProvideBLEHeartbeat(b) at call site
  → (podComms as? BlePodComms).setProvidesHeartbeat(b)
    → BluetoothManager.setProvidesHeartbeat(b)  // heartbeatEnabled = b; kick off / tear down loop
```
`delayedConnectProbeActive = heartbeatEnabled || <manual test flag>`. `didConnect` only treats a
connect as a probe when it's a genuine in-flight probe (or `suppressCommands` test mode), so a real
command connect is never hijacked now that commands run alongside.

---

## Key files & functions

- **`OmnipodKit/Bluetooth/BluetoothManager.swift`** — the hub. Flags; `startScanning` (mode select:
  lowPower alarm / beacon wildcard / monitor); `podScanServiceUUID`; `connectViaFreshDiscovery` +
  `pendingFreshConnectID` (handled in `didDiscover`); `detectPodAlertStatus` +
  `lastPodStatusWord`/`podStatusClear`/`podStatusWord`; `issueDelayedConnectProbe` + the `didConnect`
  probe block + re-arm in `didDisconnect`/`didFailToConnect`; `setProvidesHeartbeat` + `heartbeatEnabled`
  + `delayedConnectProbeActive`; `everForeground` + lifecycle observers (`[lifecycle]`);
  `resumeScanIfNeeded`; `alarmServiceUUIDs`; `peripheralManager(forIdentifier:)`.
- **`OmnipodKit/Bluetooth/PeripheralManager.swift`** — `connectOnDemand` (routes through
  `bluetoothManager.connectViaFreshDiscovery`, direct-connect fallback); `runCommand(allowDisconnected:)`
  (lets the connect itself run from disconnected); `weak var bluetoothManager`.
- **`OmnipodKit/Bluetooth/BlePodComms.swift`** — `bleRunSession` (adopts the PeripheralManager while
  disconnected; `suppressCommands` early-out); `setProvidesHeartbeat` passthrough; `omnipodLogDeviceEvent`.
- **`OmnipodKit/PumpManager/OmniPumpManager.swift`** — `setMustProvideBLEHeartbeat` (call-site log +
  `BlePodComms.setProvidesHeartbeat`); `logDeviceCommunication`; `omnipodLogDeviceEvent`;
  `triggerTestAlert` (DEBUG); `omnipodPeripheralDidConnect/Disconnect`.
- **`OmnipodKit/PumpManagerUI/Views/PodDiagnosticsView.swift`** — DEBUG "Trigger Test Alert" button
  (fires an expiration-reminder alert ~60 s out; overwrites the pod's expiration reminder — reset in
  settings after).
- **`OmnipodKit/DASH_BEACON_FINDINGS.md`** — the findings writeup (alerts + heartbeat).

---

## Open items / next steps

1. **Measure fresh-discovery connect latency** (`ad82b5f`). If still slow / falling back to cold
   connect, tune the discovery window or the scan filter.
2. **Foreground pre-connect** (user's idea): connect on `didBecomeActive` so the pod is up by the
   time the user acts. Nice-to-have if fresh-discovery is fast; the real fix if not.
3. **Wire `[POD-ALERT]` into Loop's real alert path** (stage 2) — needs the per-alert bit mapping
   (only `C005`/expiration-reminder sampled so far; trigger other alert types to enumerate).
4. **On a heartbeat wake, actually fire the heartbeat** — `issueHeartbeatIfNeeded()` /
   `pumpManagerBLEHeartbeatDidFire` is not yet called from the delayed-connect `didConnect`.
5. **`willRestoreState` explicit re-arm** for the heartbeat (currently self-sustains via the
   `didDisconnect` re-arm + Loop re-calling `setMustProvideBLEHeartbeat`).
6. **Fault / `CE1F923D`** path — only resolvable with a pod you're willing to fault.

---

## Gotchas / hard-won lessons

- **Scanning during a connect starves it** (even non-allowDuplicates wildcard). Stop the scan before
  connecting; for speed, scan → single discovery → stop → connect.
- **Force-quit (swipe-away) disables BLE relaunch** by design — not a valid relaunch test.
- **`willRestoreState` fires on a manual open too** — use `everFg` to prove an iOS relaunch.
- The pod is known via `retrievePeripherals` recovery even when not scan-discovered, so
  connect-on-demand works while the idle scan is filtered to `[C005]`.
- **`SN0.0=` periodic-status registration is inert** — the pod ACKs the write but never pushes; a
  connected Dash link doesn't originate frames. Leftover from the earliest experiment; ignore.
- `provideHeartbeat` is not persisted — log at the `setMustProvideBLEHeartbeat` call site, not later.

## MUST revert before any merge
All field-test scaffolding: the default-ON flags, `[ADV]/[SCAN]/[POD-*]/[delayedConnect]/[heartbeat]/[lifecycle]`
logging, the DEBUG Trigger-Test-Alert button + `triggerTestAlert`, `suppressCommands`, the
delayed-connect probe scaffolding, the speculative 128-bit `alarmServiceUUIDs` (unconfirmed
deviceId), and the instance-lifecycle INIT/DEINIT stack-trace logging.

## Recent commits (newest first)
```
ad82b5f connect-on-demand: fresh-discovery connect (~16s -> ~1-2s)   <-- HEAD, awaiting measurement
e336b94 connect-on-demand: go fully dark for the connect (helper scan starved it)
237930f Log setMustProvideBLEHeartbeat at the call site
e6d9587 Gate the delayed-connect heartbeat on setMustProvideBLEHeartbeat
4639eda Document heartbeat finding; switch defaults to connect-on-demand-focus mode
050d3f8 everFg + app lifecycle logging (iOS relaunch vs manual open)
d3462c1 delayed-connect probe: self-sustaining loop (re-arm in didDisconnect)
2c679ae delayed-connect probe: 5min delay, PID, persistent device log
16adc30 Experiment: delayed-connect probe (CBConnectPeripheralOptionStartDelayKey)
1503dfc suppressCommands measurement mode
feeb7a7 Reconciliation capture: wildcard idle + advert cadence + candidate 128-bit UUIDs
91a5158 Low-power fault-watch (option 3): alarm-UUID scan
6c72acf DASH alert findings writeup + connectionless alert detector
4694f59 DEBUG Trigger-Test-Alert (fire a non-fault alert for §5)
815f65e / ad2e375 / 5e38237 / 13a96fa  connect-on-demand plumbing fixes
eb630f7 §5 beacon-capture mode
```

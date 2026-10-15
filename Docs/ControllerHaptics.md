# Controller haptics API · protocol 3

The Mac sends generic haptic commands over the existing paired TCP connection. The iPhone advertises its hardware and user settings and renders patterns through Core Haptics. Motion packets and haptic commands share the connection, with separate message kinds. There are no game-specific actions in the wire schema.

## Host API

`MacSession.haptics` is a `@MainActor` observable `ControllerHaptics` client. Calls below belong in the app/game target. A returned playback ID means the request was transmitted, not that the phone accepted it or that the user felt it. Observe `lastResponse`, `activePlayers`, or `onResponse` for the controller's replies.

```swift
// A single impact: normalized strength and character, 0...1.
let hit = session.haptics.play(.impact(intensity: 0.8, sharpness: 0.7))

// Layer effects by retaining independent playback IDs.
let engine = session.haptics.play(
    .rumble(duration: 1, intensity: 0.8),
    loop: true,
    lifetime: 8, // mandatory finite receiver-enforced lease
    parameters: HapticParameters(intensityScale: 0.5)
)
if let engine {
    // Sparse updates: omitted controls retain their current values.
    session.haptics.update(engine, parameters: HapticParameters(
        intensityScale: 0.25, sharpnessOffset: -0.2, playbackRate: 1.2
    ))
    session.haptics.stop(engine)
}
session.haptics.stopAll()

// Convenience patterns compile to ordinary timed events, not wire enums.
session.haptics.play(.success)
session.haptics.play(.failure)
```

A custom envelope can express a soft ramp, sustained vibration, and release:

```swift
let swell = HapticPattern(
    events: [HapticEvent(kind: .continuous, duration: 1.2,
                         intensity: 0.75, sharpness: 0.2)],
    curves: [HapticCurve(parameter: .intensityScale, points: [
        .init(time: 0, value: 0),
        .init(time: 0.15, value: 1),
        .init(time: 0.9, value: 0.8),
        .init(time: 1.2, value: 0)
    ])]
)
session.haptics.play(swell, delay: 0.05, lifetime: 2)
```

Use either a scripted curve or live updates for the same parameter on a player. Conflicting controls are rejected rather than silently replacing an envelope. Playback-rate updates remain available with curves. Layer a separate live-controlled player when both behaviors are needed.

## Data model

| Type | Fields and semantics |
| --- | --- |
| `HapticEvent` | `kind`: `transient` or `continuous`; relative `time`; continuous `duration`; normalized `intensity`, `sharpness` |
| `HapticCurve` | `parameter`: `intensityScale` (0...1) or `sharpnessOffset` (-1...1); strictly ordered time/value points |
| `HapticPattern` | Timed events and optional parameter curves |
| `HapticParameters` | Optional `intensityScale`, `sharpnessOffset`, and `playbackRate` (0.5...2); nil means unchanged |
| `HapticPlayback` | UUID `id`, `channel`, `pattern`, receiver-relative `delay`, `loop`, finite `lifetime`, initial `parameters` |
| `HapticCommand` | Unique `requestID`; `action`: `play`, `update`, `stop`, or `stopAll`; action-specific payload |
| `HapticCapabilities` | Hardware support, current enabled state, channel names, curves/loop/live-update support, limits |
| `HapticResponse` | Correlated `requestID`, optional `playbackID`, `status`, optional reason/detail |

The current iPhone advertises one channel, `main`. The schema supports named channels for future controller hardware; an unsupported channel is rejected. It does not pretend the phone has independent left/right motors, trigger force feedback, or freely programmable physical frequency.

## Messages and status

- Phone → Mac: `hello.hapticCapabilities`, followed by `hapticCapabilities` updates when streaming or the controller's haptics toggle changes.
- Mac → phone: `hapticCommand` after successful pairing only.
- Phone → Mac: `hapticResponse`. `accepted` means scheduled, `updated` acknowledges parameter changes, `stopped` acknowledges cancellation. `completed`, `expired`, `interrupted`, and `failed` describe the original player's lifecycle. `rejected` carries a reason such as unsupported hardware, disabled feedback, invalid command, rate limit, player limit, or missing player.
- An effect's lifecycle responses carry the original play request ID. Stop/update acknowledgements carry their own command request IDs. Stopping a player may produce both its lifecycle response and the stop command acknowledgement.

Example JSON inside the existing four-byte length-prefixed frame:

```json
{
  "version": 3,
  "kind": "hapticCommand",
  "hapticCommand": {
    "requestID": "00000000-0000-0000-0000-000000000001",
    "action": "play",
    "playback": {
      "id": "00000000-0000-0000-0000-000000000002",
      "channel": "main",
      "pattern": {
        "events": [{"kind": "continuous", "time": 0, "duration": 1, "intensity": 0.6, "sharpness": 0.1}],
        "curves": []
      },
      "delay": 0,
      "loop": true,
      "lifetime": 8,
      "parameters": {}
    }
  }
}
```

Timing is relative to controller receipt and the local haptic engine. There is no cross-device clock synchronization or sample-accurate audiovisual synchronization guarantee. Intensity and sharpness are normalized hardware abstractions, not force or frequency units.

## Bounds and lifecycle

Patterns support up to 64 events, 10 seconds, two distinct curve parameters with 16 points each, and eight concurrent players. Delayed start is bounded to two seconds; each play has a 0.1...30 second lifetime including delay. Loops expire locally even if a stop packet is lost. Rate changes do not extend that lease. The frame remains limited to 16 KiB.

Both peers validate commands. A token bucket allows a burst of 20 play/update requests and replenishes at 60/second. A bounded 128-request history detects duplicates. Stop commands bypass that budget and the host reserves pending-request slots for cancellation. Commands awaiting acknowledgement time out after three seconds on the host. This timeout reports delivery uncertainty; it is not proof that the receiver did not begin playing. The local lease still bounds playback.

The phone stops players on streaming pause, haptics disable, connection loss, backgrounding, and haptic-engine interruption/reset. It reports unsupported devices without claiming successful playback. A new connection resets command history. The host clears its pending/player state on disconnect; controller enablement is freshly negotiated.

Wok tosses/landings/results and sword cuts use the same generic API. In the Mac pairing card, expand **Controller feedback** to test a tap, success pattern, or an eight-second rumble with live strength adjustment. The phone's **Controller haptics** toggle disables feedback. Update **both** apps to protocol 3, then pair again.

## Validation

Unit tests cover framing, invalid/bounded payloads, capability handling, envelope ownership, player identity, live update rejection, completion/expiry cleanup, rate limits, stop-all under load, and disconnect cleanup. `Scripts/verify_receiver.swift` exercises the production Mac receiver and a simulated controller over real TCP, including negotiation, play/update/stop acknowledgements, enable/disable, motion, and pairing. Physical sensation, actuator latency, engine interruption recovery on hardware, and user comfort require a paired physical phone; Simulator compilation and TCP acknowledgements cannot establish those properties.

Apple references: [Core Haptics](https://developer.apple.com/documentation/corehaptics), [advanced pattern players](https://developer.apple.com/documentation/corehaptics/chhapticadvancedpatternplayer), [engine lifecycle](https://developer.apple.com/documentation/corehaptics/preparing-your-app-to-play-haptics).

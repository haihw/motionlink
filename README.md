# MotionLink

A native iPhone + Mac app pair. The iPhone streams fused gyroscope and accelerometer data; the Mac displays a 3D phone that follows its orientation in real time, with gyroscope rings, direction highlights, acceleration vectors, estimated movement speed, and phone-controlled sword and wok cooking demos.

## Run the apps

1. Open `MotionLink.xcodeproj` in Xcode 26 or newer.
2. Select **MotionLinkMac**, choose **My Mac**, and run.
3. Select **MotionLinkPhone**. In **Signing & Capabilities**, select your Apple development team and use a unique bundle identifier if necessary. Choose your physical iPhone and run. Enable Developer Mode on the iPhone if prompted.
4. Put both devices on the same Wi-Fi network. Allow **Local Network** access on each device and motion access if requested.
5. On the iPhone, enter the six-digit code shown on the Mac, then select your Mac.
6. Hold the phone upright with its screen facing you. Hold it still and select **Confirm neutral position** in Sword Demo, or **Set neutral pose** in Motion Studio / the phone app. Tilt, turn, and move the phone to see the gyro rings, arrows, and live movement readings.

Minimum versions: **iOS 17** and **macOS 14**. No backend, account, third-party libraries, or external 3D assets are required.

The Mac's **Try demo** button animates rotation and a known synthetic movement trajectory, including acceleration, speed, and braking arrows, without a connected phone. The iOS Simulator can exercise discovery and pairing, but it has no real motion sensors. Use a physical iPhone for sensor testing.

## Sword Demo

Select **Sword Demo** in the Mac app (it opens by default). Pair your existing phone app, hold it still and upright with the screen facing you, then click **Confirm neutral position**. The button becomes available after at least 0.6 seconds of upright, quiet sensor readings.

- Moving your hand translates the grip left/right, up/down, and toward/away from you, with 3× sensitivity. Position is integrated from the short-gesture velocity estimate on the phone sensor clock and follows the phone as a sword handle, with the blade extending along its top edge. After 0.8 seconds of quiet acceleration and rotation at any angle, the grip smoothly recenters without changing its angle. Movement immediately interrupts recentering; automatic centering cannot score a slash.
- All three attitude axes rotate the sword directly. Tilt the phone forward to point the blade into the arena, tilt backward to point toward you, and combine pitch, yaw, and roll to aim and slash. Neutral points the sword upright.
- **Reset neutral** pauses slicing and starts setup again. Confirm your comfortable upright grip before continuing. Reconnection, stale input, pause/resume, and calibration also require a new confirmation. The sensor checks upright posture and steadiness; you confirm that the screen faces you.
- Three melons hang at different heights and depths: **Crimson** has dark striped green skin and red flesh, **Golden** is larger with light skin and yellow flesh, and **Mini** is smaller with narrow stripes.
- Hits split the melon along the actual blade plane and contact offset into seeded pieces that tumble down with juice particles. Fast swings leave a short blade trail. Each fruit scores once; slicing all three completes the round.
- **Reset fruit** restores all three melons. **Watch demo** plays a scripted round through the same collision engine without requiring a phone. **Stop demo** returns control to your phone.
- **Motion Studio** remains available in the header selector. Leaving Sword Demo ends that round; entering it again creates a fresh round.

The sword preserves the full calibrated quaternion and adds estimated hand translation in the fixed neutral frame. Travel is bounded to ±1.35 horizontally, ±0.8 vertically, and ±1.1 in depth around the neutral grip. Inertial translation is approximate and may drift; **Reset neutral** recenters the grip and requires confirmation again. Speed resets also clear the grip displacement and collision sweep. A slash needs swing energy, blade movement, and edge-first contact. Flat-side pushes and straight thrusts do not slice. Swept oriented-blade collision testing catches contacts between frames and records the cutting plane in 3D; idle overlap, resetting neutral, paused input, and long frame gaps do not produce phantom hits.

The phone protocol is unchanged for this demo; the already-updated version 2 phone app works with it. Re-pair after restarting the Mac viewer.

## Wok Tossing & Searing

Select **Wok Demo** in the Mac header. The phone is the wok: its screen corresponds to the bowl’s opening, and its tilt, rotation, and estimated translation drive the whole bowl. A turquoise rim mark corresponds to the phone’s top edge so heading changes are visible. Hold the screen facing upward and within about 35° of level, still for 0.6 seconds, then choose **Start · crack an egg**. Setup captures position and heading while preserving the phone’s actual inclination to gravity. This demo uses the existing motion stream and does not use the camera.

- Circle the phone on a horizontal plane to stir. The egg moves under world-space gravity, curved-bowl contact, static/kinetic friction, and moving-rim contact. It lags and orbits under sustained circular movement and settles when the bowl stops. Tilting slides it downhill; rotation turns the bowl. Large tilts or inversion spill the egg, which falls onto the counter.
- A quick forward push (away from you) followed by, or combined with, an upward lift triggers an assisted flip. The forward component must precede the lift by at most 0.3 seconds. The detector captures an 80 ms peak, so a faster push/lift or stronger impulse chooses **two full spins**, while a normal flick chooses **one full spin**. Both add a half-turn and land on the opposite face. The guided arc follows the moving wok and returns the egg to its center; this is the deliberate game exception to ordinary contact physics. A held gesture cannot repeatedly toss the egg; lower the motion to rearm.
- Toss gestures work at any cooking level. In Cook mode, the first-side **50–72%** green band awards a **Perfect flip**. Choose **Soft**, **Medium**, or **Firm** doneness and serve inside the corresponding second-side target. Three stars require a perfect flip and correctly timed serving. Early flips are allowed and receive timing feedback.
- Enable **Practice · heat off** before starting for an unlimited motion playground. The egg is already set, searing does not advance, and you can explore circles, tilts, single spins, and double spins without a burn timer. **Watch demo** runs a repeated single/double-spin playground in Practice mode or a complete flip-and-serve round in Cook mode.
- Input pause, disconnection, or stale motion pauses the round. Starting again captures a new pose and starts a new egg. **Recenter wok** clears translation while preserving angle and the grounded egg’s relative position; it is disabled during a flip. Estimated movement uses 1× scale with bounds of ±0.8 horizontally/in depth and ±0.4 vertically. It holds its position when stopped; manual recentering corrects drift.
- Leaving Wok Demo ends that round. All views share the same phone connection. Cooking levels are accelerated game values, not cooking times, temperatures, or food-safety measurements.

The bowl, egg, cracked shells, burner, steam, and browning surfaces are programmatic RealityKit models. The egg is approximated as a rigid contact body; deformation and oil fluid dynamics are not modeled.

## Behavior

- Core Motion fuses the gyroscope and accelerometer using `xArbitraryZVertical` at a requested 60 Hz. Actual update frequency depends on the device and scheduling.
- The Mac applies relative quaternions directly to a RealityKit model. The model includes a screen, metal frame, buttons, and rear camera lenses.
- Motion Studio uses the first received pose as its display reference. Sword Demo requires an explicit neutral confirmation before scoring. **Set neutral pose** recalibrates without reconnecting, then requires sword setup again. Model axes are X right, Y toward the top of the phone, Z out of the screen.
- Three colored 3D gyroscope rings rotate with the phone and brighten with rotation or movement on each axis. The six signed direction axes highlight travel relative to the neutral pose.
- The **green arrow** shows short-gesture movement direction, preferring estimated velocity. The **amber arrow** shows acceleration. They can point in opposite directions when braking. Arrow length is a bounded visualization of magnitude, not physical displacement.
- Both apps display acceleration magnitude and components in **m/s²**, excluding gravity, in the neutral frame. **Estimated speed** is in **m/s**. **Reset speed** on either app assumes the phone is held still and resets both apps; setting the neutral pose also resets speed.
- The wire payload carries device acceleration in **g**. Gyroscope readings are in **radians/second**. Receive rate is measured on the Mac over one-second intervals, rather than inferred from the phone's clock.
- Pausing stops sensor updates and lets the display sleep. Resuming establishes a fresh neutral pose because Core Motion starts a new reference frame.
- The iPhone stays awake while streaming. Leaving it in the background stops motion and disconnects; return to the app and pair again with the new code.
- A Mac accepts one phone at a time. The pairing code changes on disconnection. After a network interruption, choose the Mac and pair again.
- The viewer holds the last received pose if updates stop and displays **Waiting for motion** after two seconds. A clean disconnection clears the readings and resets the model.

## Scope of motion tracking

Rotation comes directly from fused device attitude. Translation direction and speed are **short-movement estimates** based on acceleration; they are not measured ground-truth velocity or position. The 3D phone stays at the instrument origin, surrounded by arrows and highlighted directions.

The estimator rotates acceleration into a fixed neutral frame, converts g to m/s², smooths it over about 45 ms, ignores acceleration below 0.15 m/s² when integrating, and integrates using the phone's monotonic sensor timestamps. A 3-second velocity damping constant and a reset after 0.65 seconds of quiet acceleration/gyro readings limit drift. Gaps above 0.2 seconds, invalid timestamps, pause/resume, calibration, and disconnection discard old velocity.

Quiet readings cannot distinguish a stationary phone from one traveling at constant speed. Consequently this estimate is suitable for brief hand gestures, not vehicle speed, long-duration tracking, or absolute position. Hold the phone still before starting or resetting the estimate. Heading may drift over long sessions; recalibrate as needed.


## Connection

Bonjour discovers `_motionlink._tcp` receivers. Apple's Network framework transports length-prefixed JSON over local TCP, with TCP_NODELAY enabled. Each motion payload contains a protocol version, sequence number, sensor timestamp, quaternion, angular velocity, user acceleration, and gravity.

The stream allows at most one pending motion send, dropping samples under backpressure. The receiver checks frame lengths, JSON, protocol version, quaternion norms, finite sensor values, and sequence ordering. Pairing and connection attempts have deadlines; stale callbacks cannot affect a replacement connection.

The six-digit code provides an application-level pairing gate. This version uses local TCP **without transport encryption**; it is intended for your own trusted network. No sensor data is stored or uploaded to a server.

Protocol version 2 adds synchronized speed reset commands. Update both apps together; older builds are rejected rather than paired with incompatible controls.

Both apps declare local-network and Bonjour usage. The Mac is sandboxed with incoming and outgoing network entitlements.

## Build and tests

```sh
xcodebuild -project MotionLink.xcodeproj -scheme MotionLinkMac \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /tmp/MotionLinkBuild \
  OBJROOT=/tmp/MotionLinkBuild/Intermediates SYMROOT=/tmp/MotionLinkBuild/Products \
  CODE_SIGNING_ALLOWED=NO build

xcodebuild -project MotionLink.xcodeproj -scheme MotionLinkPhone \
  -configuration Debug -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /tmp/MotionLinkPhoneBuild \
  OBJROOT=/tmp/MotionLinkPhoneBuild/Intermediates SYMROOT=/tmp/MotionLinkPhoneBuild/Products \
  CODE_SIGNING_ALLOWED=NO build

swift test --scratch-path /tmp/MotionLinkTests
```

If your Xcode SDK stat-cache generation stalls, append `SDK_STAT_CACHE_ENABLE=NO` to the build command. Signing is disabled in the build examples only for compilation checks. Set your development team to install on an iPhone.

The production receiver can also be checked without a GUI or physical sensors:

```sh
swiftc -parse-as-library -swift-version 6 \
  Shared/MotionProtocol.swift Shared/LinearMotionTracker.swift Shared/NeutralPose.swift \
  Shared/SwordGameplay.swift Shared/LinkConnection.swift macOS/MacSession.swift \
  Scripts/verify_receiver.swift -o /tmp/MotionLinkReceiverVerification
/tmp/MotionLinkReceiverVerification
```

This exercises incorrect codes, successful pairing, the one-phone limit, rotation and movement vectors, synchronized speed reset, remote calibration, pause/resume, upright/steady readiness, explicit neutral confirmation/reset, hand translation, sequence ordering, and invalid-sample disconnection over real TCP.

Sword tests cover fast and angular blade sweeps, idle and slow contacts, depth misses, one-time scoring, round resets, re-centering, frame gaps, full pitch/yaw/roll mapping, forward/backward tilt, wrist swings in depth, six-direction hand translation, sensor-rate independence, stopping/holding position, steady recentering with angle preserved, interrupted holds, translation limits and resets, arbitrary 3D cut planes and offsets, rejected broadside/thrust contacts, and a complete scripted three-fruit round. Neutral setup tests cover upright/flat/upside-down/sideways postures, interrupted holds, motion, and timestamp gaps. The movement tests cover neutral-frame acceleration, sampling-rate independence, velocity stability while rotating, braking direction, sensor noise, quiet/gap resets, and diagonal signed directions. Protocol tests cover arbitrary TCP packet splitting/coalescing, invalid payload lengths, incompatible versions, corrupt JSON, quaternion calibration from nontrivial poses, invalid sensor values, and a real loopback TCP exchange.

## Validation

Validated with Xcode 26.6: both Debug app builds pass, all 57 Swift Testing tests pass, and the production receiver TCP verification passes. The Mac gyro rings, signed axes, movement/acceleration arrows, speed display, neutral setup, and sword arena were visually checked. The scripted sword demo slices all three fruit. Wok tests cover clockwise/counterclockwise flat circular stirring, bowl settling after stopping, flat/upright gravity calibration, direct displacement mapping, impulse-free recentering, cracking, tilt-driven sliding, no phantom flips, early flicks with scoring feedback, forward-push/upward-lift ordering and timing, rejected upward-only motions, peak gesture classification, single/double full spins and half-turns, assisted catches, practice mode, upside-down release, all three doneness targets, pause/gaps, overheating, premature serving, excessive tilt, moving-bowl assisted landings, and gesture rearming. Live phone control connected and sliced fruit in the earlier demo; the updated 3D mapping and natural-position confirmation still need the physical check below. The iOS app launches and discovers the Mac in Simulator; the updated signed iOS app also builds, installs, and launches on the connected iPhone 14 Pro. Physical sensor fidelity and real-device end-to-end latency still require the check below.

## Physical-device acceptance check

1. Pair the devices. Confirm that only the paired phone can stream to the Mac.
2. Set neutral while upright. Tilt the top toward/away from you, turn left/right, and rotate clockwise/counterclockwise; check the model follows each axis in the same direction.
3. Rotate past 180°; the model should remain continuous and show its rear cameras.
4. Move the phone right/left, up/down, and toward/away from the neutral screen. Check the direction highlights and green arrow. On braking, check the amber acceleration arrow reverses while the movement estimate may remain forward. Hold still and reset speed on either app.
5. Recalibrate at a different pose; check it becomes the new upright model pose.
6. Open Sword Demo. Start with a flat or moving phone; the confirmation button must remain unavailable. Hold upright and steady, explicitly confirm, and check the sword points upward. Tilt forward/backward and combine yaw/roll; verify it follows the full phone attitude in depth. Move the hand left/right, up/down, and toward/away while retaining orientation; verify the grip translates. Make edge-first sweeps and check each cut follows the blade angle.
7. Select **Reset neutral** and verify slicing pauses until another steady hold and confirmation. Pause/resume and verify a new confirmation is required.
8. Background the phone and disable/re-enable Wi-Fi; verify disconnection and successful manual pairing again.
9. Try an incorrect code and a second phone while connected; neither should take over the receiver.

## Files

- `Shared/`: protocol, quaternion math, TCP connection, motion estimation, neutral-posture monitoring, sword controls/collision logic, and common UI components.
- `iOS/`: discovery, sensor lifecycle, and phone interface.
- `macOS/`: receiver, telemetry interface, sword game view, and programmatic RealityKit phone / orchard models.
- `Tests/`: Swift Testing unit and transport tests.
- `Scripts/generate_project.py`: regenerates the checked-in Xcode project and Info.plists while preserving existing signing settings.
- `Scripts/generate_icons.swift`: generates the app icon asset catalogs.
- `Scripts/verify_receiver.swift`: exercises the production receiver over loopback TCP.

API references: [Core Motion processed data](https://developer.apple.com/documentation/coremotion/getting-processed-device-motion-data), [Network listener](https://developer.apple.com/documentation/network/nwlistener), and [RealityKit](https://developer.apple.com/documentation/realitykit).

Wok contact-model references: [MIT’s Newtonian mechanics and friction notes](https://live.ocw.mit.edu/courses/8-01sc-classical-mechanics-fall-2016/mit8_01scs22_chapter8.pdf). The simulation uses world coordinates so rotating-frame inertial effects arise from the moving contact surface rather than additional fictitious-force terms. The egg is approximated as a rigid contact body; deformation and oil fluid dynamics are not modeled.

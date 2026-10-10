# HD Camera iPhone - iPhone as a USB webcam

iPhone app streams camera video over the USB cable; the Windows app turns it into a virtual webcam
called **HD Camera iPhone**.

## Build
Push to GitHub -> Actions -> *Build USC-CAM* -> download `USC-CAM-Package`
(contains `USC-CAM.ipa`, `USC-CAM.exe`, `driver/` and `Install-HD-Camera.bat`).

## Install / use
1. iPhone: sideload `USC-CAM.ipa` (Sideloadly / AltStore - unsigned). Open the app, allow the camera.
2. PC: run `USC-CAM.exe` - on the first start it installs everything itself (see v10).
3. PC: nothing to install by hand any more (see v10).
4. Plug in the iPhone, tap *Trust*, keep USC-CAM open, run `USC-CAM.exe`.
5. In Zoom / Discord / Teams etc. pick **HD Camera iPhone**.

## On the phone
The app shows the live camera image. Pick **Resolution** (720p / 1080p / 4K) and **Quality**
(Low / Medium / High) right on the screen - lower values = less lag. Default: 1080p, Medium.
On the PC you can additionally downscale the output.

Note: iOS pauses the camera when the app is in the background - keep it open (use *Dim screen* to save battery).

## v3 changes
- Virtual webcam is called **HD Camera iPhone** only (OBS fallback removed). The .exe installs the driver itself on first start (one Windows prompt).
- When the phone is not connected, the virtual camera shows a **"Waiting for camera"** screen with the app icon
  instead of an error / black picture.
- Less lag in the .exe: receive, decode and send now run in 3 separate threads, always keeping only the newest frame.
  Default output is 1920x1080 (stable size).
- Fixed the GitHub workflow (Xcode version, path conversion on Windows, driver DLL copy).

## v5 changes (lag + 120 fps)
- iPhone streams up to **120 fps** (picker: 120 / 60 / 30; unsupported rates are hidden, the app falls back to the best the camera can do). 1080p is the best size for 120 fps on most iPhones.
- Camera format is chosen explicitly (widest field of view, 8-bit), **video stabilization and video HDR are off** (both buffer frames = lag).
- **Flow control**: the PC acknowledges every frame, the iPhone keeps max 3 frames in flight. No more old frames piling up in the USB cable. The newest frame always wins.
- PC: preallocated receive buffers, preview limited to 15 fps, 1 ms Windows timer, higher process priority, virtual cam announces 120 fps.
- JPEG quality values re-tuned (Low 0.45 / Medium 0.6 / High 0.8) so 1080p120 fits through USB 2.0.

## v6 changes (H.264 + Wi-Fi)
- **H.264 instead of per-frame JPEG** (default). The iPhone's hardware encoder (low-latency, no B-frames) sends ~25-60 Mbit/s for 1080p120 instead of ~300 Mbit/s of JPEG: much sharper picture, no USB/Wi-Fi saturation, PC decodes in ~2 ms. MJPEG stays available in the app (CODEC picker).
- Quality = bitrate: Low ~25, Medium ~40, High ~62 Mbit/s at 1080p120 (scales with resolution and fps).
- **Wi-Fi mode**: the app shows the iPhone's IP. In USC-CAM.exe choose *Connection: Wi-Fi* and type the IP. Both devices on the same network (5 GHz, no guest network). Allow "Local Network" on the iPhone when asked.
- The PC acknowledges a frame only after decoding it, so the iPhone never sends faster than the PC can show.
- Window shows codec, Mbit/s and decode time. If "decode" is above ~7 ms at 120 fps the PC is the bottleneck - lower fps or output size.

## v7 changes (lag hunting on the PC side)
- Virtual camera is fed at a **fixed rhythm** (selectable 120 / 60 / 30 fps) with the newest decoded frame, instead of in bursts. Set the SAME fps in your app (OBS: Video Capture Device -> Resolution/FPS Type "Custom", FPS = same value; Zoom/Discord/Teams use 30).
- OBS tip: in the Video Capture Device properties turn **Use Buffering** off, and make the OBS Base/Output resolution match the stream (1920x1080) so the driver does not rescale every frame.
- Window shows 3 lines of diagnostics: in/out fps, decode ms, **vcam send ms**, **frame age ms**. A per-second log is written to `%TEMP%\usc-cam.log`.
- **Live window** (dropdown): the full picture in its own window that bypasses the virtual camera. In OBS use *Window Capture*. If this is smooth and the virtual camera is not, the driver/app chain is the cause.

## v8 changes
- Fixed the GitHub workflow: finds the sources wherever they were uploaded, recreates `project.yml` if it is missing, and picks up the current UnityCapture DLL names (`UnityCaptureFilter64.dll` / `32.dll`).
- Default quality is now **High** (H.264, ~62 Mbit/s at 1080p120).

## v9 - fixes the "7 fps on the PC" problem, adds Wi-Fi auto-connect, microphone and sound
- **Root cause of the low PC frame rate:** decoding and the virtual-camera copy shared one Python process (one GIL) and starved each other. Now the PC app runs three separate processes: GUI + socket, **decoder**, **virtual camera feeder**, connected through shared memory. Frames are acknowledged on arrival, so the phone sends at full speed; if the PC ever falls behind it skips to the next key frame instead of building lag.
- The phone screen shows live diagnostics: `camera N/s` (frames from the sensor), `sent N/s`, `dropped`, `encode ms`, `queue`. The PC window shows in/out fps, decode ms, vcam send ms, frame age.
- **Auto connection like iVCam:** *Auto* mode uses the USB cable if present, otherwise finds the iPhone on the Wi-Fi by itself (Bonjour). No IP typing. (*Wi-Fi (type IP)* is still there as a fallback.)
- **Drivers from the app:** the virtual camera driver installs itself on first start (one Windows prompt). *Install USB driver* opens Apple's "Apple Devices" page (only needed for the USB cable). *Install virtual microphone* downloads and installs VB-CABLE from vb-audio.com.
- **Phone microphone -> PC:** switch "Phone mic -> PC" on, then choose **CABLE Output (VB-Audio Virtual Cable)** as the microphone in Discord / OBS / Zoom.
- **PC sound -> phone headphones/speaker:** switch "PC sound -> phone" on (captures what your PC plays). Use headphones on the phone when the microphone is on, otherwise you get an echo.

## v10.1 - workflow fix: camera driver is fetched with a sparse checkout (Windows "Filename too long").

## v10 - one-click setup, steadier microphone / headphones, calmer Wi-Fi
- **Everything installs itself.** Start `USC-CAM.exe` once (double-click, or "Run as administrator"). If something is missing it asks Windows for administrator rights ONCE and silently installs: the virtual camera *HD Camera iPhone* (now also the 32-bit filter), the virtual microphone *VB-CABLE* (its publisher is pre-trusted, so no driver pop-up) and the *Apple USB driver*. The "Install ..." buttons and `Install-HD-Camera.bat` are gone. If a download fails (no internet) it retries on a later start, not on every start. Log: `%TEMP%\usc-cam-setup.log`.
- **Microphone** (phone -> PC): the phone rebuilds its audio engine after every route change / interruption / headphone plug (before, the engine stayed dead -> "sometimes works, sometimes not"), always records from the built-in mic, and the PC re-sends the mic state every 2 s so a dead mic repairs itself. On the PC the sound goes through a 50 ms jitter buffer with resampling to 48 kHz instead of blocking writes (no more crackle / dropouts).
- **Headphones** (PC sound -> phone): same self-repairing audio engine on the phone (wired and Bluetooth headphones), 60 ms cushion against Wi-Fi jitter, and the PC follows its default playback device when you switch / plug headphones on the PC.
- **Wi-Fi lag**: the phone detects a Wi-Fi link and caps the video at ~28 Mbit/s (USB keeps the full quality), marks the traffic as video (WMM), disables AWDL, and adapts the bitrate live: when frames start to pile up it lowers the rate, when the link is calm it raises it again (`rate NN%` on the phone screen). Key frames every 2 s instead of 1 s = smaller bursts.
- **Small stutters**: Python garbage collection is tuned in all PC processes.

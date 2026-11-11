# HP camera

`hpcamera` is a page of the Pshell settings for the camera built into the
HP ProBook 450 G8 (`scripts/ipc.sh hpcamera open`, USB 30c9:000f,
*HP HD Camera*, Luxvisions module with a Sunplus SPCA2650, bcd 0.08,
serial 01.00.00, fixed port 3-2): the live picture, every control the
camera has – the standard UVC ones, the spot the exposure aims at, the
Sunplus unit's three values –, Enhance (shared with the C310), the IR
camera with its emitter, unlocking with the face, and a virtual camera
with digital zoom, pan, a face followed and mirroring. The plugin (*HP HD
Camera*, off by default) need not find the camera: the daemon looks for it
every 2 s in sysfs and puts back what the page keeps whenever it comes
again – the PC awake (the wall clock jumped ahead of the monotonic one),
the camera reset or re-enumerated.

- `scripts/hpcamera/hpcamera.py` – the daemon (JSON lines on stdin and
  stdout), `dump` prints what the camera says. It opens a node only for a
  moment per change, so the camera sleeps (USB autosuspend after 2 s).
- `scripts/hpcamera/ir.py` – the IR picture and the face: one thread that
  holds the IR node only while the page's IR preview, an enrolment, a check
  or an IR photo needs it.
- `../webcam/stream.py` (the C310's, with the size, the virtual camera's
  name, the photo format and the file prefix as parameters) – the colour
  picture: preview, photos (MJPEG 1280×720, `HP_Camera_…png`) and the
  virtual camera's frames. `../webcam/uvc.py` – V4L2 and extension units,
  now also compound controls (`get_rect`/`set_rect`).
- `../webcam/system.py loopback on|off hp` – the root side (pkexec).
- `core/services/HpCamera.qml` – starts the daemon, keeps `hpcamera.json`
  (`saved`: only what was set by hand or by Enhance – `v4l2`, `xu`, `roi`,
  `ir` –, `view`, `virtual`, `size`, `fps`, `photoDir`, `options`); writes
  from sliders go out every 60 ms at most.
- `core/views/settings/HpCameraPage.qml`, `hpcamera/HpCameraPreview.qml`,
  `hpcamera/HpIrPreview.qml` – the page.
- `core/views/overlays/LockScreen.qml` – the face check (below).
- `scripts/ipc.sh hpcamera photo [view] | irphoto | zoom in|out|1-4 |
  follow on|off|toggle | mirror on|off|toggle | virtual on|off|toggle |
  enhance | face | state`.
- `scripts/tests/test_hpcamera.py` – descriptors, flash strings, the face
  file and check, liveness, lit/dark pairing, the two loopback devices.

## What the camera has (and how)

Two UVC 1.5 functions on one USB 2.0 device (IAD each):

- **Colour** – interfaces 0/1, `/dev/video0` (+ `/dev/video1` UVC metadata):
  camera terminal 1 (auto exposure, exposure time, region of interest),
  processing unit 2, extension units 3 (Sunplus) and 4 (Sunplus ISP);
  MJPEG 1280×720, 960×540, 848×480, 640×480, 640×360, 424×240, 320×240,
  320×180 and YUYV 640×480 … 320×180, each at 30 or 15 fps; BT.709 colour.
  `bStillCaptureMethod` 1: a still is a frame of the stream.
- **IR** – interfaces 2/3, `/dev/video2` (+ `/dev/video3`, UVCH and UVCM
  metadata): no picture controls, extension units 7 (Microsoft) and 4
  (Sunplus ISP); GREY 640×360 at 30 fps.

No microphone, no LED control (the privacy LED is wired to the stream),
no shutter sensor (the shutter is mechanical; HP WMI has no lens-cover
switch on this model).

| Feature | Where | Here |
| --- | --- | --- |
| Brightness −64…64, contrast 0–64, saturation 0–128, hue ±40, gamma 0.72–5.00, sharpness 0–5, gain 0–4 | processing unit (V4L2) | *Picture* |
| White balance auto / 2800–6500 K | processing unit | *Picture* |
| Backlight compensation 0/1 | processing unit | *Picture* |
| Anti-flicker off / 50 / 60 Hz (default 60) | processing unit | *Picture*, Enhance measures it |
| Auto exposure (aperture priority) / manual 3.9 ms–1 s | camera terminal | *Exposure* |
| Low light: frame rate may drop | camera terminal (`exposure_dynamic_framerate`) | *Exposure* |
| Spot exposure: the rectangle the automatic aims at, on/off | camera terminal, UVC 1.5 region of interest (`region_of_interest_rectangle` – a `v4l2_rect`, only through `VIDIOC_S_EXT_CTRLS` – and `…_auto_ctrls`, bit 0 exposure, the only one offered) | *Exposure* › *Place* (a click on the preview), *Whole picture* |
| Sunplus selectors 2 (0–6), 3 (1–4), 4 (4 or 8) | XU 3 `0fb885c3-…` (`PROPSETID_SUNPLUS_XU`) | *Sunplus* |
| Sunplus info `28 10 01 00 1f 00 00 00 ff` | XU 3 sel 1 (read only) | `dump` |
| Chip and maker (USB strings at the flash's start) | XU 4 sel 15 while sel 13 (the address) is 0 | *Camera* |
| Face authentication: interface 3, alternating illumination only | Microsoft XU 7 `0f3f95dc-…` sel 6 | *IR camera*'s subtitle |
| Frame metadata on/off (the kernel switches it on; Windows' frame illumination, timestamps) | Microsoft XU 7 sel 9 (0 or 1 KiB) | *IR camera* › *Frame metadata* |
| Camera extrinsics / intrinsics | Microsoft XU 7 sel 7/8 | empty on this camera (not calibrated) |
| The IR emitter | lit on every other IR frame by the camera itself | *IR camera*: lit, dark, lit − dark; *IR photo* |

**What the Sunplus selectors do is not known.** Against a dark picture
(shutter closed) none of their values changed brightness, colour,
saturation, sharpness, noise, JPEG size or frame rate. The one run with
light (shutter open, 2026-11-11) had the automatic exposure still settling
the whole time, so it shows nothing either way; a cleaner run (exposure
and white balance held, each value between two of the old one) read the
same numbers as with the shutter closed. On Windows they belong to the
vendor's driver extension. They are offered as they are, kept and put
back like the rest.

Not used: the Sunplus ISP unit (XU 4, `63610682-…`, on both functions,
22/27 selectors) is the chip's debug and flash access – a 1024-byte flash
window (sel 15, sel 22 the first 64 bytes), its address (sel 13/14),
a write buffer (sel 10), register selectors and the factory tests named
in the flash (*Blink_LED_Test*, *Serial_Flash_Checking_Test*, *Register…*).
Writing there can brick the camera and is no setting. Its small selectors
(colour side 6, 7, 8, 9, 12, 16, 21; IR side 18, 19, 25) were each
written, measured and put back: no effect on the dark colour picture, the
IR picture or the emitter (lit/dark levels unchanged, also with light);
sel 3 stalls the control pipe at 0xFF (the camera answers again right
after).

## How it behaves

- **Settings without power**: autosuspend keeps every value (tried:
  Sunplus, V4L2, region of interest). The daemon writes them again when the
  camera comes back or the PC wakes – an automatic mode before its manual
  value (a manual value is refused while its automatic is on).
- **The region of interest** reads 1284×724 at power-on, beyond its own
  maximum (1280×720); the daemon clamps what it writes to the maximum.
- **The IR emitter** needs nothing from Linux: streaming the IR node lights
  it on every other frame (≈15 lit frames a second). A lit frame is the
  brighter of a pair; lit − dark leaves only what the emitter lights.
- Gain, white balance temperature and exposure time read back their
  defaults while their automatic is on, not what it does.

## Unlocking with the face

*Add face* streams the IR camera (the IR preview shows it with the face
outlined) until 12 different samples are taken: a face YuNet finds with a
score of 0.85 at least, at least 16 % of the picture high, that the
emitter lights clearly (≥ 8 grey levels lit − dark on the face and 1.6
times the frame's average). Each sample is SFace's 128 numbers
(`face_recognition_sface_2021dec.onnx`, opencv_zoo commit f12e127, sha256
checked, in `~/.cache/pshell/webcam/` beside the C310's YuNet); only those
numbers are kept, in `~/.local/state/pshell/hpcamera/faces.json` (0600),
never a picture. *Test* runs the check for 6 s and shows the best score.

The lock screen (*Lock screen* on, a face added, the plugin on) checks for
4 s when it locks, again a second after each failed check while tries are
left (*Tries on the lock screen*, 1–10), and anew when the screens wake;
"Look at the camera" shows meanwhile. A check matches when two lit frames
with a live face come within a cosine of 0.5 of any sample (SFace's own
same-person line is 0.363). Then it unlocks like the phone does, with the
fingerprint's unlock animation if that is on. The password always works;
nothing changes in PAM (sudo, polkit, the login manager stay as they are).

Limits: this is a convenience like Howdy, not Windows Hello's anti-spoofing.
A phone's or monitor's screen shows no face in IR, but a printed photo lit
by the emitter can pass the liveness check. The decision is taken by the
user's own daemon, the same trust as *Unlock by phone*. With the shutter
closed the IR camera sees the shutter and nothing matches.

## The virtual camera

The C310's (see webcam.md), with its own v4l2loopback device: `/dev/video43`
named *HP HD Camera (Pshell)*. `system.py` keeps one options line for both
cameras (`devices=2 video_nr=42,43 card_label="Webcam C310 (Pshell)","HP HD
Camera (Pshell)" exclusive_caps=1,1`) and adds or removes the device now
through `/dev/v4l2loopback` (`V4L2LOOPBACK_CTL_ADD`/`REMOVE`), so the other
camera's device – and whoever reads it – stays. The picture is MJPEG
1280×720 cut to the output's aspect, zoomed up to 4×, panned, following the
biggest face, mirrored.

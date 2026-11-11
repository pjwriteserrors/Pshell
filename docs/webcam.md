# Webcam

`webcam` is a page of the Pshell settings for the Logitech Webcam C310
(`scripts/ipc.sh webcam open`, USB 046d:081b, firmware 1.7.1011, bcd 0.12):
the live picture, every control the camera has – the standard UVC ones and
Logitech's own in its four extension units –, Enhance (the camera's settings
tuned from what it sees, by rule or by a local AI), the LED, the microphone,
photos and RAW photos, and a virtual camera with digital zoom, pan, a face
followed and mirroring. The plugin (*Webcam C310*, off by default) need not
find the camera: the daemon looks for it every 2 s in sysfs and puts back
what the page keeps whenever it comes again – plugged in, or the PC awake
again (the wall clock jumped ahead of the monotonic one).

- `scripts/webcam/webcam.py` – the daemon (JSON lines on stdin and stdout),
  `dump` prints what the camera says. It opens the camera's node only for a
  moment per change, so the camera sleeps (USB autosuspend after 2 s) and
  the privacy indicator stays off.
- `scripts/webcam/uvc.py` – V4L2 controls through ioctls, Logitech's
  extension units through `UVCIOC_CTRL_QUERY`; the units are found by their
  GUID in sysfs' copy of the USB descriptors.
- `scripts/webcam/stream.py` – the picture: holds the camera only while the
  page's preview shows or a program reads the virtual camera, then lets go
  (the LED goes out). Preview, photos, RAW, the virtual camera's frames.
- `scripts/webcam/enhance.py` – Enhance.
- `scripts/webcam/system.py` – the root side (pkexec): `led on|off`,
  `loopback install|on|off [c310|hp]` (the HP camera's page uses it too,
  see hpcamera.md).
- `core/services/Webcam.qml` – starts the daemon, keeps `webcam.json`
  (`saved`: only what was set by hand or by Enhance – `v4l2`, `xu`, `led`,
  `mic` –, `view`, `virtual`, `size`, `fps`, `photoDir`, `options`); writes
  from sliders go out every 60 ms at most.
- `core/views/settings/WebcamPage.qml`, `webcam/WebcamPreview.qml` – the
  page; on the preview the virtual camera's cut-out is drawn (dragged it
  pans, the wheel zooms, a double click goes back to the whole picture) and
  a followed face outlined.
- `scripts/ipc.sh webcam photo [view] | raw | zoom in|out|1-4 | follow
  on|off|toggle | mirror on|off|toggle | virtual on|off | light
  auto|on|blink|off | mic mute|unmute|toggle | enhance | state`.

## What the C310 has (and how)

Four interfaces: video control (unit 1 camera terminal, 2 processing unit,
3/4/6/7 extension units), video streaming (YUYV and MJPEG, 19 sizes each
from 160×120 to 1280×960; YUYV 1280×960 at 7.5 fps, MJPEG at 30), audio
control (feature unit 5: mute, volume) and audio streaming (mono 16 bit at
16, 24, 32 or 48 kHz). No HID, no button: `bStillCaptureMethod` 1 means a
still is a frame of the stream.

| Feature | Where | Here |
| --- | --- | --- |
| Brightness, contrast, saturation, sharpness, gain | processing unit (V4L2) | *Picture* |
| White balance auto / 0–10000 K | processing unit | *Picture* |
| Backlight compensation | processing unit | *Picture* |
| Anti-flicker off / 50 / 60 Hz | processing unit (default 60 Hz) | *Picture*, Enhance measures it |
| Auto exposure (aperture priority) / manual 0.1–1000 ms | camera terminal | *Exposure* |
| Low light: frame rate may drop | camera terminal (`exposure_dynamic_framerate`) | *Exposure* |
| Firmware, CRC, EEPROM, sensor, processor, USB ids, lens 61°×48°, sensor 1280×720 | XU 3 *Device Information v3* `69678ee4-…`, sel 1–6, 9, 10 (read only) | *Camera* |
| Color Boost | XU 4 *Video Pipe v3* `49e40215-…` sel 1 | *Processing* |
| RightLight | XU 4 sel 4 | *Exposure* |
| MJPEG resync markers: on, interval | XU 4 sel 9 (2 bytes, default on, 10) | *Processing* |
| TDE mode 0–255 | XU 6 *Test/Debug v3* `1f5d4ca9-…` sel 10 | *Processing* |
| Sensor boost 0–3 (≈ ×1.8, ×3, ×4.8 brighter) | XU 6 sel 11 | *Exposure* |
| Low-light priority | XU 6 sel 12 (default on) | *Exposure* |
| Colour processing off → raw sensor data | XU 6 sel 13 | *RAW* |
| Pixel defect correction | XU 6 sel 14 (1 on, else off) | *Processing* |
| Lens shading correction | XU 6 sel 15 (1 on, else off) | *Processing* |
| Gamma curve | XU 6 sel 16 (1 on; 0 and 2 linear) | *Processing* |
| Integration time now (same unit as exposure) | XU 6 sel 17 | *Exposure*'s subtitle |
| Raw bits per pixel | XU 6 sel 18 (read only, 1) | – |
| LED off / on / blink / auto, blink speed | XU 7 *Peripheral* `ffe52d21-…` sel 9 | *Light* (after *Unlock*) |
| Peripheral status | XU 7 sel 10 (read only, 0) | – |
| Microphone mute, gain +6…+30 dB in 16 steps | audio feature unit 5 (ALSA `Mic Capture Switch/Volume`) | *Microphone*, with a level meter and *Use as microphone* |

The names and selectors are those of uvcdynctrl's `logitech.xml` (libwebcam
0.2.5); what each one does was tried on this camera (written, a frame
looked at, the old value put back). With the kernel's own control list only
the processing unit and camera terminal show up – the extension units are
not mapped to V4L2 controls.

Not used: the test unit's selectors 1–9 – register, EEPROM, sensor (I²C)
and peripheral address/access pairs, raw access to the chip that can brick
it and is no setting. TDE mode, Color Boost and RightLight showed no
difference on a plain wall; they are offered as the camera has them.

## How it behaves

- **The LED** belongs to the kernel (7.2 here): uvcvideo refuses the
  controls that could switch a camera's light off unless its
  `allow_privacy_override` parameter is set (`dmesg`: "Privacy related
  controls can only be accessed if module parameter allow_privacy_override
  is true"). *Unlock* sets it now and at boot (`/etc/modprobe.d/pshell-webcam.conf`),
  *Lock again* takes it back.
- **MJPEG takes about 3 s to start** on this camera (YUYV 0.6 s), so the
  virtual camera shows its dark picture for that long when a program opens
  it. With resync markers on, libjpeg warns about padding before every
  marker (`Corrupt JPEG data: N extraneous bytes before marker 0xd0…d7`);
  the service drops those lines.
- **RAW**: colour processing off is only taken at the start of a stream (set
  while streaming it is ignored). The frame is then not YUYV but the
  sensor's 10-bit values, 4 pixels in 5 bytes as one little-endian
  bitstream (pixel k = bits 10k…10k+9), 1.25 bytes a pixel, the rest of the
  buffer zero. Black level about 64, white 1023. Written as a DNG (16-bit
  CFA, no colour calibration – the camera is taken as sRGB, the neutral is
  grey-world) and a JPEG developed the plain way.
- **Settings without power**: the extension units forget their values when
  the camera loses power (unplugged, the PC asleep); autosuspend keeps them.
  The daemon writes them again, the V4L2 values with them (an automatic mode
  before its manual value – a manual value is refused while its automatic
  is on).
- Gain, white balance temperature and exposure time read back what the
  automatic is doing while it is on.

## Enhance

The camera's own settings, not the picture: by rule it measures mains
flicker with 50 and 60 Hz (the banding left in the rows from frame to
frame) and keeps the calmer – with no flicker either way the region's
(timezone; Germany: 50 Hz, the camera comes set to 60) –, switches
backlight compensation by how the middle compares to the border, allows
longer exposures in a dim room, brings the middle of the picture to a mid
grey with brightness, opens contrast until highlights would clip, brings
colourfulness to a natural level and lowers sharpening on a noisy picture.
*With a local AI* the frame, these measurements and the settings with their
ranges go to a local Ollama model that takes pictures (gemma3, llava,
qwen2.5vl … – listed by `/api/show` capabilities), up to three rounds,
every value clamped. The changes are kept like hand-made ones; *Undo* puts
the values from before back.

## The virtual camera

v4l2loopback (`v4l2loopback-dkms`, installed from the page through pkexec),
one device `/dev/video42` named *Webcam C310 (Pshell)* (the HP camera's
`/dev/video43` beside it when that one's is on, added and removed alone
through `/dev/v4l2loopback`), `exclusive_caps=1`
so browsers list it. While it is on it always has a picture – a dark one
while nobody reads it, the real camera closed –, and the camera's picture
while a program has it open (found in /proc when inotify reports an open or
close): MJPEG 1280×960 cut to the output's aspect, zoomed up to 4×, panned,
following the biggest face (OpenCV's YuNet, `face_detection_yunet_2023mar.onnx`
from opencv_zoo at commit f12e127, sha256 checked, in
`~/.cache/pshell/webcam/`; eased, with a dead zone; *Frame the face* also
zooms so the face fills about a quarter of the height), mirrored, as
720p/540p/360p/4:3 at 30 or 15 fps through ffmpeg.

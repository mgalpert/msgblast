# Sidebar Phone section evidence

Implementation source: `18362609b4ac21e0c0d94b6e7d55791374d1c941` on
`codex/sidebar-phone-pairing`, cut from `ios-controller` at base
`4c22313cd3c473cb1c6959ab7de932b98a68312d`. The evidence-only commit that adds
this folder does not change Swift source.

## How it was captured

Captured November 4, 2026 on a separate test Mac (macOS 27.0.1). The preview packager built the committed revision with full
Xcode 27 into the blue fixture app `msgblast Demo phone-sidebar.app`
(`com.msgblast.demo`, `msgblastDemo` true, updates and telemetry disabled,
ad-hoc signed; ZIP `msgblast-demo-18362609b4ac-phone-sidebar.zip`, SHA-256
`d49920e6dc89720a3b54133e02d8dd5db54ba7d091f361b5502b96a420d0ff20`). It was
launched by path with `--isolated-demo`, so its store lived in a temporary
folder; production, Dev and their support folders were not touched.

The Demo variant was started without `--remote-listen`, so Remote is in-memory
only: no network port opens, nothing can connect, and the pairing code encodes
no endpoints. The QR code, the 120 s countdown, the key fingerprint and the
refresh on expiry are the real `RemoteService` offer path; no phone was paired
and no message was sent. The paired-phone row and the automatic collapse after a
connection are covered by unit tests (`PhoneSidebarStateTests`), not by these
pictures.

Window screenshots and clicks used `cua-driver` 0.23.2 (accessibility actions
on the exact window, no cursor movement); the video frames came from Peekaboo
3.9.9 window capture. Dark appearance was switched in System Settings ›
Appearance on the studio (driven the same way) and restored to Light
afterwards. `sidebarPhoneCollapsed`
was cleared before each launch so every run starts in the automatic state.

## What the pictures show

| File | Shows |
| --- | --- |
| `expanded-off-light.png` | First launch, Remote off: the Phone section sits above What's New with the Remote switch and one line of copy; no QR code is shown while Remote is off |
| `expanded-on-light.png` | Remote switched on in the sidebar: live pairing QR code, "Expires in" countdown, key fingerprint, and the Network, Keep Mac awake and Send iMessages controls from Settings › Remote |
| `collapsed-light.png` | After tapping the header: the section is gone from above What's New and the phone icon with its status dot (orange: Remote on, nothing connected) docks at the bottom of the sidebar |
| `expanded-off-dark.png`, `expanded-on-dark.png`, `collapsed-dark.png` | The same three states in dark appearance |

## Video

`phone-sidebar.mp4` (171 s, 1440×736) is assembled from the 293 Peekaboo
window-capture frames at their recorded timestamps, so it plays at original
speed (about 1.7 frames per second; the 0.25 s collapse and expand animations
therefore show as one or two intermediate frames). Light appearance, Remote on.
It shows the expanded section counting down (about 100 s left), the header tap
at 8 s collapsing it to the dock below What's New, the dock tap at 14 s
expanding it again with a fresh 120 s code, that countdown running to 1 s, and
the replacement code appearing at about 137 s. No cuts; nothing was sped up.

## Limits

Fixture app and in-memory Remote only: no listener, no phone, no live Dev app.
The light and dark captures were separate launches of the same build. The
inactive-window tint on controls differs between captures depending on whether
the Demo window was key at the time.

## Live captures from the final build

`live-closed.png`, `live-open-off.png`, `live-open-on.png` and
`live-open-close.mp4` were captured on 2026-11-13 on a macOS 27.2 MacBook Pro
from the Apple Development–signed Dev build "Phone 126 AX Fix" at
`12b1be3e27315f3e68eba209b5f183a780fb3e36`. The sidebar and Remote code is
unchanged up to this branch's head. The app ran in the background with a real
Remote listener and no phone paired. Every action was an accessibility press on
the window; nothing came to the front. Each file is cropped to the sidebar
(520×2200 px, dark appearance).

| File | Shows |
| --- | --- |
| `live-closed.png` | Section closed: the one-line Phone row at the bottom of the sidebar, under What's New, with Remote off |
| `live-open-off.png` | Section open with Remote off: the header, the Remote switch and "Turn on to pair your iPhone" |
| `live-open-on.png` | Section open with Remote on: the pairing QR code and the key fingerprint line (both blurred), then the Network, Keep Mac awake and Send iMessages controls |
| `live-open-close.mp4` | 17 s at 30 fps and real speed, recorded per window with ScreenCaptureKit: the header opens and closes the section twice with Remote off, then Remote is switched on, and it closes, opens with the QR code and closes again. The card grows up from the bottom edge and shrinks back into it, taking about 0.25 s each way |

The QR code and the key fingerprint are blurred in every frame they appear in,
including the frames where they fade in and out during the slide. No frame
decodes as a QR code, and no frame shows a username, IP address, tailnet name,
email address or phone number.

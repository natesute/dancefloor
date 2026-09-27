# Dancefloor

Dancing GIFs that float over your Mac and dance to the beat of whatever is playing.

## Install

```bash
Scripts/install.sh
```

Builds, copies to `/Applications/Dancefloor.app` and launches it. Turn on **Open at login** in ⚙.

Needs macOS 15+. On first launch, allow audio capture so the dancers can hear the music.
Dancefloor lives in the menu bar (🕺, which shows the BPM once it locks on).

## Using it

- **Click 🕺** in the menu bar to open the picker: search GIPHY, tap a search chip, or browse
  My folder. Click any GIF to add it as a dancer. Right-click a chip to remove it; **+** adds one.
  ⇄ randomises every dancer, ▤ saves and loads scenes (sets of dancers and positions), and ⚙
  has source, sync, hide, open at login, GIPHY key, folder and quit.
- **⌥⌘D** hides or shows every dancer, from any app.
- **Speed is automatic**: each dancer loops over 1, 2, 4, 8… beats, whichever keeps it closest
  to the GIF's own speed (within about 1.4×). ½× and 2× shift from there; right-click → Automatic Speed resets.
- **Click a dancer** for its swap strip: hover an alternative to preview it on the dancer, click
  to swap. Below that: ½× / 2× speed, shift half a beat, ♥ keep in your folder, 🗑 remove.
- **Drag** a dancer to move it, **scroll** over it to resize, **right-click** for the full menu.
- **Sync** (⚙) nudges all dancers earlier or later if they look off the beat
  (Bluetooth headphones usually need them later).

Your GIF folder is `~/Pictures/Dancefloor`. Drop any GIF in there.
GIPHY needs a free API key from developers.giphy.com (Menu → Set GIPHY API Key…).

## How it works

- `SystemAudioTap` captures system audio with a Core Audio process tap. Nothing is saved.
- `BeatTracker` finds tempo from the autocorrelation of a spectral-flux onset envelope and
  beat phase from kick-weighted onsets. `BeatClock` smooths that into a continuous beat position.
- Bar starts: each estimate scores the four possible positions of beat 1 by kick strength and
  chord change (pitch-class shift) over the last 16 s; `BeatClock` takes a decaying vote so the
  dancers only move bar 1 when one position clearly wins. Loops then start on a downbeat.
- Each dancer maps bar position to a frame so one GIF loop spans N beats.

## Checking the beat tracker

```bash
swift test
swift run -c release bpmcheck path/to/song.mp3
swift run -c release bpmcheck --click 128
```

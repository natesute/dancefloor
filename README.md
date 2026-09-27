# Dancefloor

Dancing GIFs that float over your Mac and dance to the beat of whatever is playing.

## Build and run

```bash
Scripts/build-app.sh && open build/Dancefloor.app
```

Needs macOS 15+. On first launch, allow audio capture so the dancers can hear the music.
Dancefloor lives in the menu bar (🕺, which shows the BPM once it locks on).

## Using it

- **Menu bar → Add Dancer** (⌘N): a random dancer from GIPHY and/or your folder.
- **Search GIPHY…**: add a sticker matching a search term, e.g. "shrek".
- **Randomise All** (⌘R): swap every dancer for a new one.
- **Drag** a dancer to move it, **scroll** over it to resize, **double-click** to swap it.
- **Right-click** a dancer to set beats per loop, halve or double its speed, shift it by half
  a beat, keep a GIPHY dancer in your folder, or remove it. Tuning is remembered per GIF.
- **Sync** in the menu nudges all dancers earlier or later if they look off the beat
  (Bluetooth headphones usually need them later).

Your GIF folder is `~/Pictures/Dancefloor`. Drop any GIF in there.
GIPHY needs a free API key from developers.giphy.com (Menu → Set GIPHY API Key…).

## How it works

- `SystemAudioTap` captures system audio with a Core Audio process tap. Nothing is saved.
- `BeatTracker` finds tempo from the autocorrelation of a spectral-flux onset envelope and
  beat phase from kick-weighted onsets. `BeatClock` smooths that into a continuous beat position.
- Each dancer maps beat position to a frame so one GIF loop spans N beats.

## Checking the beat tracker

```bash
swift test
swift run -c release bpmcheck path/to/song.mp3
swift run -c release bpmcheck --click 128
```

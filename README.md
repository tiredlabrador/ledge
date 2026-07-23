# Ledge

A tiny now-playing widget that sits by your Dock. It shows the album art, title,
and artist of whatever you're playing in **Apple Music** or **Spotify**, wrapped
in the same glass material as the Dock so it looks like an extension of it.

It appears when music starts and quietly fades away a couple of minutes after you
stop. Hover over it for playback controls and a scrubbable progress bar.

<!-- Add a screenshot here if you like: ![Ledge](screenshot.png) -->

## Install (the easy way)

1. Download **`Ledge.zip`** from the [latest release](../../releases/latest) and
   unzip it.
2. Move **Ledge.app** to your **Applications** folder.
3. **Right-click it → Open** (don't double-click the first time). macOS will warn
   that it can't verify the app — click **Open**. You only do this once.

   > This happens because Ledge isn't signed with a paid Apple Developer
   > account — it's a free hobby app. It's completely safe; the code is all here
   > in this repo.

4. The first time it runs, macOS will ask permission to control **Music** and
   **Spotify** — click **OK** for each. That's how it reads what's playing.

That's it. Start playing something and the widget appears.

### Requirements

- macOS 15 (Sequoia) or newer. On macOS 26 (Tahoe) it uses real Liquid Glass; on
  15–25 it falls back to a frosted look.
- Apple Music and/or Spotify (the desktop apps).

## Using it

- **Hover** to reveal ⏮ ⏯ ⏭ and the time remaining.
- **Drag the bar** along the bottom to scrub.
- **Drag the pill** (grab it anywhere but the buttons) to move it. It remembers
  where you put it on each screen and restores there next time.
- **Right-click** for options: *Open Music/Spotify*, *Reset Position*,
  *Start at Login*, *Quit*.

### Where it sits

Ledge starts just above the left end of your Dock and follows whichever screen the
Dock is on. Don't like that spot? Just drag it wherever you want — it stays put and
remembers its place per display. *Reset Position* puts it back to the default. No
special permissions needed for any of this.

## Build from source

You just need Xcode's Command Line Tools (`xcode-select --install`) — full Xcode
isn't required.

```bash
./build.sh      # builds for your Mac and installs to ~/Applications/Ledge.app
./package.sh    # builds a universal (Apple Silicon + Intel) Ledge.zip in dist/
```

## How it works

Ledge polls Music and Spotify once a second via AppleScript (and reacts instantly
to their playback notifications) to get the current track, artwork, and position.
It draws a borderless, non-activating floating panel that never steals focus and
hides over full-screen apps, just like the Dock. There's no system-wide "now
playing" feed involved, so it only follows those two apps — not browser or other
audio.

## Licence

MIT — do whatever you like with it.

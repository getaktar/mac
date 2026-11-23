# Capture tools

Status: built 2026-11-23 (Mac; Windows and Linux in the desktop repo), not
device-tested with the tools yet. See "QA".

Aktar still has no editor of its own (roadmap, "Bilinçli olarak
yapılmayacaklar"). Instead, Capture can run the screenshot tool the user
already likes, so what goes up is the annotated image: arrows, blur, text,
whatever the tool does. This extends part 1 of capture-and-instant-links.md;
everything after the image arrives (routing as an image, the destination's
processing, the instant link, the outbox, Undo, "upload and paste") stays as
it is.

## Setting

Mac: General > Capture tool > "Capture with". Windows and Linux: General >
Capture. A menu of the tools this platform supports. The default stays the
system tool, so nothing changes for anyone who doesn't pick another. An
unknown value (a tool from a newer version, another platform's tool) reads
as the system tool.

- Installed tools are listed first; one that isn't installed says "(not
  installed)" and shows "Get ..." (its site), never an error.
- Picking a tool shows the setup it needs in the tool itself (an API switch,
  a save folder, an action in ShareX), and "Capture Now" (Mac) to try it.
- The Capture shortcut, "Capture, upload and paste", the panel's Capture
  button and the tray/menu bar entry all use the chosen tool.
- A chosen tool that isn't installed: on the Mac, Capture says so ("Get ..."
  or Cancel); on Windows and Linux, Capture uses the system tool and a
  notification says why.
- The file is named like any capture, `Screenshot <date> at <time>.<ext>`,
  whatever the tool called it. Aktar uploads a copy; the tool's own file
  stays where it is.

## How an image comes back

No tool returns the edited file to the app that started it, except a few
command-line ones. Every tool fits one of these ways, and the code is built
around them, not around each tool.

### A. Run and read

Aktar starts the tool and gets the image when it exits: a file it named, or
(Flameshot on the Mac) the clipboard. Exit without an image is a cancel:
nothing is uploaded and nothing is said, like Esc today.

### B. Start and wait

Aktar starts the tool (a URL scheme or a command), then waits for the image
in two places at once:

- a new image on the clipboard (the tool's Copy);
- a new image file in the tool's save folder. On the Mac the user picks
  that folder once (a security-scoped bookmark; Aktar's sandbox can't read
  another app's settings to find it) and it's optional, since copying works
  without it. Spectacle defaults to `XDG_PICTURES_DIR/Screenshots`.

The first image to arrive is the capture. Files there before the wait began
are never taken; a new file is taken once its size has stayed the same, and
above zero, for 0.5 s.

- The wait lasts up to 10 minutes, since editing takes time. While it waits,
  the Mac panel shows "Waiting for ..." with "Stop Waiting"; the Windows and
  Linux tray menu has "Stop Waiting for ...". Starting another capture ends
  the previous wait (Mac) or opens the tool again (Windows, Linux).
- A clipboard image taken this way is not the user's own clipboard: Undo
  puts back the clipboard from before the capture.
- If the save folder is also a watched folder, the file is uploaded once, by
  the capture: the watched folder skips files a capture took in the last 15
  minutes (Mac).
- Files saved without Aktar starting the tool are not uploaded. Anyone who
  wants every screenshot uploaded makes that folder a watched folder, which
  works with every tool already.
- A tool set to copy or save on its own right after capture (before
  editing) hands over the unedited image; the setup steps say to turn that
  off where the tool has it.

### C. The tool sends to Aktar

Some tools can't be started from outside, but can hand their finished image
to a program: `"<Aktar>" --upload "<file>"`, the flag of the Explorer menu,
which uploads it like any file the user uploads (instant link, routed as an
image). Settings shows the steps and the program and arguments to paste,
with Copy buttons.

- ShareX is started by Capture (`ShareX.exe -RectangleRegion`), and its
  action's `--upload` while Aktar waits (up to 10 minutes) is the capture: it
  gets the capture's paste target and Undo clipboard.
- Greenshot, Snagit and PicPick can't be started by Aktar: they're used with
  their own shortcut, and Aktar's own Capture uses the system tool.
- Microsoft Store install: the package's folder changes with every update,
  so tools are pointed at the app execution alias `aktar-desktop.exe` in
  `%LOCALAPPDATA%\Microsoft\WindowsApps` (not `aktar.exe`, which would shadow
  the CLI's `aktar` command).
- Mac: no new code. A tool with the macOS share menu can share to Aktar's
  Share extension, and any tool's save folder can be a watched folder.

## Tools

V = checked against the tool's docs or source on 2026-11-23, Q = to be
confirmed in QA.

### Mac

| Tool | Way | Start | Notes |
|---|---|---|---|
| macOS (default) | A | `screencapture -i <file>` | As before. No editor. |
| CleanShot X | B | `cleanshot://capture-area?action=annotate` (V) | Its API must be on: Settings > Advanced (Q for the exact place). Paid. |
| Shottr | B | `shottr://grab/area?then=edit` (V) | "URL Schema API" must be on, Settings > Advanced (V, Shottr 1.8). |
| macshot | B | `macshot://capture` (V, `AppDelegate.swift`) | URL scheme on by default (`urlSchemeEnabled`). Default save folder `~/Pictures`. Free, GPL. Has its own S3 upload, which Aktar users leave off. |
| Flameshot | A | new instance of the app via LaunchServices, arguments `gui --clipboard` | On macOS each Flameshot instance hosts its own capture and quits after Accept or Esc (V, `src/main.cpp`). Started through LaunchServices it runs outside Aktar's sandbox, with its own Screen Recording permission; Aktar reads the clipboard once it copied or quit (1 s grace). Bundle `org.flameshot.Flameshot` (V), else `/Applications/flameshot.app`. |
| Xnapper, Snagit, Monosnap | C | none | Share menu to Aktar, or a watched folder. |

### Windows

| Tool | Way | Start | Notes |
|---|---|---|---|
| Snipping Tool (default) | as before | Windows+Shift+S, clipboard | Takes the first image: the snip, before any markup. See "Later". |
| ShareX | C, started by Aktar | `ShareX.exe -RectangleRegion` | Setup: Actions > Add, the Aktar program, arguments `--upload "$input"` (`$input`, not `%input`, V); After capture: "Annotate image", "Save image to file", "Perform actions"; After upload off. Actions run after Annotate (V, `WorkerTask.cs`). Menu names Q. |
| Flameshot | A | `flameshot.exe gui -p <file>` | Each CLI instance runs its own capture and exits (V, `src/main.cpp`). v15 (Nov 2026). |
| Greenshot 1.3 | C | its own hotkeys | External Command plugin: the Aktar program, argument `--upload "{0}"` (V, its docs). 1.4 (prerelease) adds `greenshot-cli`: way A or B once it's stable. |
| Snagit, PicPick | C | their hotkeys | Snagit: Share > Program (V). PicPick: External Program (argument syntax Q). |
| Lightshot | watched folder | none | No CLI or external program. |

### Linux

| Tool | Way | Start | Notes |
|---|---|---|---|
| Desktop's dialog (default) | A | xdg-desktop-portal Screenshot | As before. No editor. |
| Flameshot | A | `flameshot gui -p <file>` | Accept writes the file and the process ends (V). On Wayland it goes through the portal (v15). |
| Satty | A | after the desktop's dialog: `satty --filename <in> --output-filename <out> --early-exit --save-after-copy --actions-on-enter save-to-file` | An editor, not a capture tool (V, `cli/src/command_line.rs`). Closing without saving is a cancel. |
| Swappy | A | after the desktop's dialog: `swappy -f <in> -o <out>` | Writes on close (V), so closing it is never a cancel. |
| Spectacle (KDE) | B | `spectacle --region --new-instance` | Its window can annotate; clipboard or its save folder. Its own auto copy/save after capture should be off (Q). |

All tools on Linux run with the host's environment, not the AppImage's
(`linux::host_command`).

## QA

Done: Mac unit tests (CaptureToolTests: tools, folder spotting, clipboard
images, claims, waiting), desktop repo Rust tests (capture_tools) and the
Settings view in a browser with the mock backend.

Still to do on real machines, with a test destination:

- Mac (Developer ID QA build, see the tcc-qa-builds note): each tool's
  Capture with Copy and with Save to the chosen folder, Esc/cancel, Stop
  Waiting, a second capture while waiting, Undo restoring the clipboard,
  Capture and paste, the watched-folder skip, Flameshot's permission prompt.
- Windows: Flameshot, ShareX (action and paste target), Greenshot steps,
  the Store alias reaching the running app.
- Linux: Flameshot, Satty, Swappy on GNOME; Spectacle on Plasma.

## Later

- Snipping Tool's markup: with "Automatically copy changes" (on by default)
  each edit is copied again, so Aktar could wait for the last image instead of
  the first. It has no "done" signal, so this needs a rule (for example: take
  the snip, and replace the upload if an edited copy arrives within a minute,
  using Replace so the link stays). Not in the first version.
- `ms-screenclip://capture` with a redirect back to Aktar works for packaged
  apps (the Store MSIX has package identity), not for the GitHub exe. It
  returns the raw capture, so it doesn't help with editing.
- The tool's own "open existing file" (CleanShot `open-annotate?filepath=`,
  macshot `open?file=`) would let Aktar edit an image before uploading from
  the panel. Separate feature.
- ksnip (Linux): its editor's output isn't scriptable; a watched folder
  covers it.

## Strings

New strings go through the usual 17 languages. Tool names are never
translated.

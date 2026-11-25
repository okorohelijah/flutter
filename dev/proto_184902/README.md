# Prototype: Android's own text toolbar in a Flutter app

An experiment for [flutter/flutter#184902](https://github.com/flutter/flutter/issues/184902)
("[Android 17] Switch to the system context menu"). **Not for review or merging.** It exists so
that the idea can be run on a device and measured.

## What it shows

Long-press an ordinary `TextField` on Android. Instead of the Cut / Copy / Paste bar that Flutter
paints, Android's own floating toolbar appears. On Android 17 that toolbar is drawn by the system,
and a paste started from it does not show the "pasted from your clipboard" message.

## What changed (three commits)

| Where | Change |
|---|---|
| `packages/flutter/lib/src/widgets/system_context_menu.dart` | `SystemContextMenu.isSupported` accepts Android (it was iOS only). A tap on a built-in button is passed to the text field (`onSystemAction`). |
| `packages/flutter/lib/src/services/binding.dart`, `text_input.dart` | New message from Android, `ContextMenu.onPerformAction`. A switch for the experiment, `SystemContextMenuController.debugAndroidPasteStrategy`. |
| `packages/flutter/lib/src/widgets/editable_text.dart` | `EditableTextState.pasteProvidedText`: paste text that the platform already read. |
| `engine/.../systemchannels/SettingsChannel.java`, `android/FlutterView.java` | Android now sends `supportsShowingSystemContextMenu: true`. |
| `engine/.../systemchannels/PlatformChannel.java` | Handles `ContextMenu.showSystemContextMenu` and `ContextMenu.hideSystemContextMenu`; sends the dismiss and action messages. |
| `engine/.../plugin/editing/SystemContextMenuPlugin.java` (new) | Starts the toolbar (`View.startActionMode(callback, ActionMode.TYPE_FLOATING)`), answers Android's callbacks, handles the tap. **Start reading here.** |
| `engine/.../plugin/editing/PasteTimingLog.java` (new), two one-line calls | Experiment only: logs the time from the tap to the clipboard read. |
| `dev/proto_184902/` | This folder: the demo app, a build script, a test driver. |

## Run it (five commands)

On a machine with the Android SDK, a JDK that Gradle accepts (JDK 25 here: `export
JAVA_HOME=/usr/lib/jvm/java-25-openjdk-amd64`), `cipd` from depot_tools, and a device or emulator
visible in `adb devices`:

```bash
git -C ~/dev/flutter fetch origin proto/184902-android-system-toolbar
git -C ~/dev/flutter worktree add ~/dev/wt/flutter-184902-proto proto/184902-android-system-toolbar   # skip if the folder exists
cd ~/dev/wt/flutter-184902-proto/dev/proto_184902
./build_embedding.sh                      # about a minute: compiles the changed Android Java
(cd app && ../../../bin/flutter run -d <device id>)
```

Then long-press field 1. To see the paste message disappear, copy some text in **another** app
first (Android never shows the message when an app pastes its own text) and use an Android 17
device.

`build_embedding.sh` explains at its top why no engine build is needed. In short: only Java
changed, so the script recompiles the Java half of the engine and the app keeps the stock native
library that Flutter downloads for this commit.

The first `./bin/flutter` command in a new checkout downloads the Dart SDK and the engine for the
commit this branch started from (`ecd3296c920e`). It finds that commit through the `upstream`
remote. If it downloads a different engine version, set
`FLUTTER_PREBUILT_ENGINE_VERSION=3c3f69e0196c3b583ec84a039baa1c6ced053e66` and run it again.

## The demo app

`app/lib/main.dart`. One screen, one text field per case:

| # | Field | What to look for |
|---|---|---|
| 1 | Ordinary `TextField`, empty | Android's toolbar with Paste |
| 2 | Ordinary `TextField` with text | Cut, Copy, Paste, Select all, Share |
| 3 | With an upper-case input formatter | A paste comes out in capitals: it went through Flutter's formatters |
| 4 | Read-only | Flutter-drawn bar (never pastes) |
| 5 | Own `contextMenuBuilder` | Flutter-drawn bar, unchanged |
| 6 | System toolbar plus one app item | "Shout" appears and its callback runs |
| 7, 8 | System toolbar plus six app items, after / before the defaults | What Android does when the bar is full |
| 9, 9b | Password field, `CupertinoTextField` | |
| 10 | `SelectableText` | Flutter-drawn bar (never pastes) |
| 11 | Multi-line field at the bottom | Position after scrolling and with the keyboard open |

Switches at the top:

- **Paste: A / A' / AK / B**: who reads the clipboard after the tap.
  **A**: Android reads and inserts; Flutter is told the new text as if it had been typed.
  **A'**: Android reads inside the tap handler; Flutter inserts with its normal paste code.
  **AK**: Android reads inside the tap handler and keeps the text; Flutter's `Clipboard.getData` is answered with that kept text without a second OS read.
  **B**: Android only says "Paste was tapped"; Flutter reads and inserts as it does today.
- **System toolbar**: off = the bar Flutter draws (what every app does today).
- **Dark**, **French**: the app's theme and language, to compare with the toolbar's.
- **Overflow Paste**: stops marking `Paste` with `SHOW_AS_ACTION_ALWAYS`, so field 8 pushes `Paste` into the overflow menu (`⋮`) to test Trap 1.

The app writes what happens to the device log: `adb logcat -s flutter SystemContextMenu ClipboardService`.

## The test driver

`tools/drive.py` repeats the runs behind the numbers in the write-up:

```bash
tools/drive.py --serial <adb serial> paste  --strategy "A'" --rep 1   # one filmed paste; says toast or no toast
tools/drive.py --serial <adb serial> timing --strategy B --taps 20    # tap-to-read times
```

The `paste` command needs a second app that copies text (`dev.securepaste.copier`, a 40-line app
that is not part of this branch).

# Troubleshooting

Find what you see in the left column. Most fixes take one click.

## Nothing happens

| You see | Fix |
| --- | --- |
| Keys do nothing | Quit Rectangle, Magnet or Spectacle: only one app can own a key. Then open Tessera's menu: a ⚠︎ line means a permission is missing or another app has the key. |
| Nothing moves after an update | macOS kept Tessera's old permission. Menu › **Allow Accessibility Access…** › **Clear the Old Entry**, then turn Tessera on again. |
| macOS won't open a downloaded copy | It isn't notarized (checked by Apple). **System Settings › Privacy & Security › Open Anyway**, or install with Homebrew. |
| A key in the config file does nothing | Open the menu: a ⚠︎ line names any key another app already uses. `tessera config` lists the file's problems by line. |
| `tessera` says Tessera isn't running | Open Tessera. The tool needs Tessera 3.0 or later. |
| `tessera: command not found` | Menu › **Config and Command Line › Install Command Line Tool…**, then open a new Terminal window. |

## Windows end up in the wrong place

| You see | Fix |
| --- | --- |
| Dragging to an edge snaps with a margin, or twice | That's macOS's own tiling. Menu › **Turn Off macOS Edge Tiling**. |
| A window won't shrink into its tile | Some apps have a minimum size. Tessera learns it and gives that window more room. If nothing fits, it stays as small as the app allows. |
| Auto-tile grabs a window you want free | Float it (⌃⌥W), give its app the **Always Float** rule, or ignore the app from the menu. |
| One window stays put when you change layout | It's floating. Press ⌃⌥W on it to tile it again. |
| A window seems to have vanished | It's probably waiting just off the screen's edge. Click it in the Dock, ⌘Tab to it, or press ⌃⌥Space. **Windows in Front › No Limit** shows every window. |
| `desktop 3` steps through each desktop | Turn on **Switch to Desktop 3** in **System Settings › Keyboard › Keyboard Shortcuts › Mission Control**. |
| Sending a window to a desktop does nothing | **Move left a space** and **Move right a space** must be on in the same place in System Settings. |

## The config file

| You see | Fix |
| --- | --- |
| Changes don't take effect | Run `tessera reload-config`, or add `auto-reload-config = true` at the top of the file. |
| A ⚠︎ line says a setting is ignored | `tessera config` names the line. Check the spelling against [Config file](config.md#every-setting). |
| A setting under a `[table]` is ignored | Settings that aren't in a table must come before the first `[table]`. That's a TOML rule. |
| You want to start again | Delete or rename `~/.config/tessera/tessera.toml`, then `tessera reload-config`. Settings rule again. |

## Report a bug

Open an [issue](https://github.com/vik101/Tessera/issues) with:

1. What you did, what you expected, and what happened.
2. Your Tessera version (menu › **About Tessera**, or `tessera version`) and macOS version.
3. Tessera's log: open the **Console** app, start streaming, filter by `com.vikram.Tessera`, and repeat the problem.
4. If you use a config file: `tessera config`.

## Remove Tessera

- **Homebrew:** `brew uninstall --zap --cask vik101/tessera/tessera` removes the app, the command line tool and its settings.
- **By hand:** quit Tessera, delete it from Applications, and delete `~/Library/Application Support/com.vikram.Tessera` and `~/Library/Preferences/com.vikram.Tessera.plist`. Your config file is in `~/.config/tessera` if you made one.

---

[Docs home](README.md) · Back: [Coming from another app](coming-from.md)

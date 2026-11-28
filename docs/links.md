# Links and settings files

Two more ways to drive Tessera without the command line tool: `tessera://` links, for the Shortcuts app and launchers, and settings files, to copy your setup to another Mac.

## Links

Open a link with `open -g` (the `-g` keeps Tessera in the background), from Shortcuts' **Open URLs** action, or from a launcher like Raycast or Alfred. Rectangle's links work too, with `tessera://` in place of `rectangle://`, so Rectangle scripts carry over.

| Link | Does |
| --- | --- |
| `tessera://execute-action?name=left-half` | Any snap or action by name: Rectangle's names (`left-half`, `tile-all`), Tessera's (`retile`, `send-to-desktop-2`) |
| `tessera://execute-layout?name=columns` | Pick a layout: `auto`, `columns`, `rows`, `grid`, `main-and-side`, `tree`, `stack`, `float` |
| `tessera://run?command=join%20right` | Run any [command](commands.md). Spaces become `%20`, `;` becomes `%3B`. |
| `tessera://save-setup?name=Work` | Save the current [setup](rules-and-setups.md#setups) |
| `tessera://open-setup?name=Work` | Open a setup |
| `tessera://execute-task?name=ignore-app&app-bundle-id=com.apple.Safari` | Leave an app alone (`unignore-app` undoes it) |
| `tessera://export-settings?path=~/tessera.json` | Save every setting to a file |
| `tessera://import-settings?path=~/tessera.json` | Read settings from a file |

```bash
open -g "tessera://execute-action?name=left-half"
open -g "tessera://run?command=layout%20tree%3B%20balance"
```

Every snap action's link name is in the [command reference](commands.md#snap-names). Other action names: `tile-all`, `tile-rows`, `tile-columns`, `cascade-all`, `cascade-active-app`, `reverse-all`, `cycle-stacked-windows`, `cycle-stacked-windows-backward`, `focus-left` (and right, up, down), `send-to-desktop-1` … `send-to-desktop-9`, `send-to-next-desktop`, `send-to-previous-desktop`.

## Settings files

A settings file is plain JSON: your shortcuts, layouts, app rules, setups and every switch.

| To | Do this |
| --- | --- |
| Save one | **Settings › More › Export Settings…**, or the `export-settings` link |
| Load one | **Settings › More › Import Settings…**, or the `import-settings` link |
| Change only some settings | A file needs only those keys, for example `{"gap": 8}` |
| Set up a new Mac | Put the file at `~/Library/Application Support/com.vikram.Tessera/TesseraConfig.json` before Tessera's first launch. Tessera reads it once, then renames it with the date. |

**Settings file or config file?** A settings file holds what the Settings window holds, and is for copying it. The [config file](config.md) is for what Settings can't do (binding modes, window rules, callbacks, gaps per screen), and you edit it by hand.

---

[Docs home](README.md) · Back: [Command line tool](cli.md) · Next: [Every shortcut](shortcuts.md)

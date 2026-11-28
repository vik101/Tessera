# Every shortcut

Tessera's default keys, in one place. ⌃ is Control, ⌥ is Option, ⇧ is Shift and ⌘ is Command. Change any of them in **Settings › Keyboard Shortcuts**, or add your own in the [config file](config.md#key-bindings-and-modes).

The snap keys are Rectangle's. Everything else uses keys Rectangle doesn't, so the two never clash.

## Snap one window

| Key | Action | Key | Action |
| --- | --- | --- | --- |
| ⌃⌥← | Left Half (again: ⅔, then ⅓) | ⌃⌥D | First Third |
| ⌃⌥→ | Right Half (again: ⅔, then ⅓) | ⌃⌥F | Centre Third |
| ⌃⌥↑ | Top Half | ⌃⌥G | Last Third |
| ⌃⌥↓ | Bottom Half | ⌃⌥E | First Two Thirds |
| ⌃⌥U | Top Left | ⌃⌥T | Last Two Thirds |
| ⌃⌥I | Top Right | ⌃⌥↩ | Maximise |
| ⌃⌥J | Bottom Left | ⌃⌥⇧↑ | Maximise Height |
| ⌃⌥K | Bottom Right | ⌃⌥= / ⌃⌥− | Make Larger / Smaller |
| ⌃⌥⌘→ | Next Display | ⌃⌥C | Centre |
| ⌃⌥⌘← | Previous Display | ⌃⌥⌫ | Restore |

With auto-tile on, ⌃⌥ + arrow moves a tiled window through the layout instead. See [Snapping](snapping.md) for pictures, and for the actions that have no key yet.

## Auto-tile

| Key | Action |
| --- | --- |
| ⌃⌥A | Auto-tile on or off |
| ⌃⌥1 … ⌃⌥5 | Auto, Columns, Rows, Grid, Main + Side |
| ⌃⌥6 ⌃⌥7 ⌃⌥8 | Tree, Stack, Float |
| ⌃⌥L / ⌃⌥⇧L | Next / previous layout (Auto to Main + Side) |
| ⌃⌥M | Swap this window with the main window |
| ⌃⌥W | Float this window, or tile it again |
| ⌃⌥P | Keep this window in front |
| ⌃⌥Space | Window picker: bring any window forward |

## Moving around

| Key | Action |
| --- | --- |
| ⌃⇧⌘ + arrow | Focus the window that way, on any screen |
| ⌃⌥⇧1 … ⌃⌥⇧9 | Send this window to desktop 1 … 9 on its screen |
| ⌃⌥⌘1 … ⌃⌥⌘9 | Open saved setup 1 … 9 |

## With the mouse

| Do | Result |
| --- | --- |
| Drag a window to an edge or corner | Snap it ([where](snapping.md#with-the-mouse)) |
| Drag one tile onto another | Swap them |
| Drag a window near another's edge (Tree) | Split that window and sit beside it |
| Hold fn and drag anywhere in a window | Move it, not only by its title bar |
| Drag the edge between two tiles | Resize them |

## Key presets

**Settings › General › Extra keys** (or `preset` in the config file) adds a whole set of keys at once, for people coming from another app:

| Preset | Adds |
| --- | --- |
| Tessera (default) | Nothing extra |
| Spectacle | ⌘⌥ + arrows for halves, ⌘⌥F maximise, ⌘⌥C centre, ⌘⌃ + arrows for corners, ⌘⌃⌥ + arrows for displays, ⌃⌥⇧ + arrows to grow and shrink |
| AeroSpace | ⌥H/J/K/L focus, ⌥⇧H/J/K/L move, ⌥1–9 desktops, ⌥⇧1–9 send, ⌥- / ⌥= resize, ⌥/ and ⌥, split styles, ⌥Tab last desktop, ⌥⇧; service mode |
| Spacetile | ⌥ + arrows focus, ⌥S stack, ⌥D tree, ⌥N / ⌥P next and previous in the stack, ⌥1–9 desktops, ⌥⇧1–9 send |
| None | Turns off Tessera's own keys too: only your config file's keys work |

---

[Docs home](README.md) · Back: [Links and settings files](links.md) · Next: [Coming from another app](coming-from.md)

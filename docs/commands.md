# Command reference

<!-- Made by scripts/docs/commands.py from the app's code. Edit CommandHelp.swift, then run the script. -->

Every command Tessera understands. You can run each one three ways:

| Where | Example |
| --- | --- |
| The [command line tool](cli.md) | `tessera join right` |
| A key in the [config file](config.md) | `alt-shift-l = 'join right'` |
| A [link](links.md), for Shortcuts and launchers | `open -g 'tessera://run?command=join%20right'` |

AeroSpace's and Spacetile's names work too: they are listed under **Also** for each command.
Chain several with `;` (always run the next), `&&` (only if the last worked) and `||` (only if it failed).
Add `--window-id ID` to act on a window other than the one you're in.

**Groups:** [Focus](#focus) · [Move windows](#move-windows) · [Layouts](#layouts) · [The Tree layout](#the-tree-layout) · [Sizes](#sizes) · [Windows](#windows) · [Desktops](#desktops) · [Tessera itself](#tessera-itself) · [Questions (for scripts and agents)](#questions-for-scripts-and-agents) · [Snap names](#snap-names)

## Focus

### focus left

```
tessera focus left|right|up|down|next|prev|back [--wrap-around]
```

Focus the window that way, the next or previous in the layout, or the one before.

Example: `tessera focus left`

Also: `west/east/north/south`, `dfs-next`, `dfs-prev`, `focus-back-and-forth`

### focus --window-id

```
tessera focus --window-id ID
```

Focus a window by its id (see list-windows).

Example: `tessera focus --window-id 1234`

### focus-display

```
tessera focus-display left|right|next|prev|N|NAME
```

Focus a screen.

Example: `tessera focus-display next`

Also: `focus-monitor`, `display next`

## Move windows

### move

```
tessera move left|right|up|down
```

Move the window one step through the layout; past the edge, to the next screen.

Example: `tessera move right`

### swap

```
tessera swap left|right|up|down|next|prev [--swap-focus]
```

Swap the window with its neighbour.

Example: `tessera swap next`

### send-to-desktop

```
tessera send-to-desktop N|next|prev|last
```

Send the window to a desktop (and go there).

Example: `tessera send-to-desktop 2`

Also: `send N`, `move-node-to-workspace N (stays put)`

### send-to-display

```
tessera send-to-display left|right|next|prev|N|NAME
```

Send the window to a screen.

Example: `tessera send-to-display next`

Also: `send display next`, `move-node-to-monitor`

### place

```
tessera place NAME
```

Snap the window: left, right, top-left, center, left 2/3, any Rectangle name.

Example: `tessera place left 2/3`

Also: `snap`, `left-half`, `maximize`

## Layouts

### layout auto

```
tessera layout auto|columns|rows|grid|main-and-side|tree|stack|float
```

Lay out this desktop a new way.

Example: `tessera layout tree`

Also: `layout bsp`

### layout tiles

```
tessera layout tiles|accordion|horizontal|vertical [...]
```

Tree layout: change the window's container. The first that changes something wins.

Example: `tessera layout tiles horizontal vertical`

Also: `h_tiles`, `v_accordion`

### layout floating

```
tessera layout floating|tiling
```

Float the window, or tile it again.

Example: `tessera layout floating tiling`

Also: `float on|off|toggle`

### retile

```
tessera retile
```

Arrange this desktop again, putting snapped windows back.

Example: `tessera retile`

### balance

```
tessera balance
```

Give every tile an even share.

Example: `tessera balance`

Also: `balance-sizes`

## The Tree layout

### join

```
tessera join left|right|up|down
```

Put the window and its neighbour in a container of their own.

Example: `tessera join right`

Also: `join-with`

### split

```
tessera split [horizontal|vertical|opposite]
```

With no way: turn the window's container the other way. With one: open the next window that way.

Example: `tessera split`

### preselect

```
tessera preselect left|right|up|down|cancel
```

Open the next window on that side of this one.

Example: `tessera preselect down`

### mirror

```
tessera mirror horizontal|vertical
```

Flip the layout.

Example: `tessera mirror horizontal`

### rotate

```
tessera rotate 90|180|270
```

Turn the layout.

Example: `tessera rotate 90`

### flatten

```
tessera flatten
```

Put every window side by side again.

Example: `tessera flatten`

Also: `flatten-workspace-tree`

### pop

```
tessera pop out|in
```

Take the window out of its container, or join its neighbour.

Example: `tessera pop out`

## Sizes

### resize

```
tessera resize smart|width|height +N|-N|N
```

Grow or shrink a tile by points (or set its size).

Example: `tessera resize smart +50`

Also: `grow`, `shrink`

### border

```
tessera border horizontal|vertical N
```

Move one edge of the tile; only its neighbour gives way.

Example: `tessera border horizontal 100`

### zoom

```
tessera zoom [on|off]
```

Let the window fill the desktop until you zoom it again.

Example: `tessera zoom`

Also: `fullscreen`

## Windows

### native-fullscreen

```
tessera native-fullscreen [on|off]
```

macOS full screen.

Example: `tessera native-fullscreen`

Also: `macos-native-fullscreen`

### minimize

```
tessera minimize
```

Minimise the window.

Example: `tessera minimize`

Also: `macos-native-minimize`

### close

```
tessera close [--quit-if-last-window]
```

Close the window.

Example: `tessera close`

### close-others

```
tessera close-others
```

Close every other window on this desktop.

Example: `tessera close-others`

Also: `close-all-windows-but-current`

### keep

```
tessera keep on|off|toggle
```

Keep the window in front (it never waits off screen).

Example: `tessera keep on`

### stack

```
tessera stack next|prev
```

Stack layout: show the next window.

Example: `tessera stack next`

## Desktops

### desktop

```
tessera desktop N|next|prev|last
```

Switch to a desktop on this screen.

Example: `tessera desktop 2`

Also: `workspace N`, `space N`, `workspace-back-and-forth`

## Tessera itself

### enable

```
tessera enable on|off|toggle
```

Turn auto-tile on or off.

Example: `tessera enable on`

Also: `pause`

### mode

```
tessera mode NAME
```

Switch binding mode (main, or one from the config file).

Example: `tessera mode main`

### reload-config

```
tessera reload-config
```

Read the config file again.

Example: `tessera reload-config`

### setup

```
tessera setup open|save|delete NAME
```

Open or save a setup of apps and windows.

Example: `tessera setup open Work`

Also: `load NAME`

### toggle

```
tessera toggle spacing|border|dim
```

Gaps, a border round the focused window, or dim the rest.

Example: `tessera toggle dim`

Also: `dim on`, `border on`

### move-mouse

```
tessera move-mouse window-lazy-center|monitor-lazy-center
```

Move the pointer to the window or screen.

Example: `tessera move-mouse window-lazy-center`

### exec-and-forget

```
tessera exec-and-forget SHELL COMMAND
```

Run a shell command.

Example: `tessera volume up`

Also: `exec`, `exec-and-forget open -a Notes`, `Tessera`, `volume up|down|mute-toggle|set N`, `Change the sound volume.`

## Questions (for scripts and agents)

### list-windows

```
tessera list-windows [--all|--focused|--desktop N|--display X] [--json|--count|--format F]
```

The windows, with ids, apps, titles, screens, desktops and how each is laid out.

Example: `tessera list-windows --json`

Also: `list-windows --format '%{window-id} %{app-name} %{window-title}'`

### list-desktops

```
tessera list-desktops [--focused] [--json]
```

Each screen's desktops and their layouts.

Example: `tessera list-desktops`

Also: `list-workspaces`

### list-displays

```
tessera list-displays [--focused] [--json]
```

The screens.

Example: `tessera list-displays --json`

Also: `list-monitors`

### list-apps

```
tessera list-apps [--json]
```

Running apps.

Example: `tessera list-apps`

### list-modes

```
tessera list-modes [--current]
```

Binding modes.

Example: `tessera list-modes --current`

### tree

```
tessera tree [--json]
```

The Tree layout of each screen: H[1 V[2 3]].

Example: `tessera tree`

### config

```
tessera config [--get KEY] [--config-path]
```

The config file and what Tessera read from it.

Example: `tessera config --config-path`

### subscribe

```
tessera subscribe [EVENT...]
```

Print events as they happen, one JSON line each: focus-changed, display-focus-changed, desktop-changed, mode-changed, window-detected, window-closed.

Example: `tessera subscribe focus-changed`

### version

```
tessera version
```

Tessera's version.

Example: `tessera version`

## Snap names

`place NAME` (and `tessera://execute-action?name=NAME`) takes any of these. Short names work with `place` only.
Keys are the defaults; change them in Settings.

| Action | Link name | Short names for `place` | Key |
| --- | --- | --- | --- |
| Left Half | `left-half` | `left`, `left 1/2` | ⌃⌥← |
| Right Half | `right-half` | `right`, `right 1/2` | ⌃⌥→ |
| Centre Half | `center-half` | `center 1/2` |  |
| Top Half | `top-half` | `top`, `top 1/2` | ⌃⌥↑ |
| Bottom Half | `bottom-half` | `bottom`, `bottom 1/2` | ⌃⌥↓ |
| Top Left | `top-left` | `top-left` | ⌃⌥U |
| Top Right | `top-right` | `top-right` | ⌃⌥I |
| Bottom Left | `bottom-left` | `bottom-left` | ⌃⌥J |
| Bottom Right | `bottom-right` | `bottom-right` | ⌃⌥K |
| First Third | `first-third` | `left 1/3` | ⌃⌥D |
| Centre Third | `center-third` | `column`, `center 1/3` | ⌃⌥F |
| Last Third | `last-third` | `right 1/3` | ⌃⌥G |
| First Two Thirds | `first-two-thirds` | `left 2/3` | ⌃⌥E |
| Centre Two Thirds | `center-two-thirds` | `center 2/3` |  |
| Last Two Thirds | `last-two-thirds` | `right 2/3` | ⌃⌥T |
| Maximise | `maximize` | `maximize`, `fill`, `full` | ⌃⌥↩ |
| Almost Maximise | `almost-maximize` |  |  |
| Maximise Height | `maximize-height` |  | ⌃⌥⇧↑ |
| Make Larger | `larger` |  | ⌃⌥= |
| Make Smaller | `smaller` |  | ⌃⌥− |
| Centre | `center` | `center` | ⌃⌥C |
| Centre Prominently | `center-prominently` |  |  |
| Specified Size | `specified` |  |  |
| Restore | `restore` |  | ⌃⌥⌫ |
| Next Display | `next-display` |  | ⌃⌥⌘→ |
| Previous Display | `previous-display` |  | ⌃⌥⌘← |
| Move Left | `move-left` |  |  |
| Move Right | `move-right` |  |  |
| Move Up | `move-up` |  |  |
| Move Down | `move-down` |  |  |
| First Quarter | `first-fourth` | `left 1/4` |  |
| Second Quarter | `second-fourth` |  |  |
| Third Quarter | `third-fourth` |  |  |
| Last Quarter | `last-fourth` | `right 1/4` |  |
| First Three Quarters | `first-three-fourths` | `left 3/4` |  |
| Centre Three Quarters | `center-three-fourths` | `center 3/4` |  |
| Last Three Quarters | `last-three-fourths` | `right 3/4` |  |
| Top Left Sixth | `top-left-sixth` | `top-left-sixth` |  |
| Top Centre Sixth | `top-center-sixth` | `top-center-sixth` |  |
| Top Right Sixth | `top-right-sixth` | `top-right-sixth` |  |
| Bottom Left Sixth | `bottom-left-sixth` | `bottom-left-sixth` |  |
| Bottom Centre Sixth | `bottom-center-sixth` | `bottom-center-sixth` |  |
| Bottom Right Sixth | `bottom-right-sixth` | `bottom-right-sixth` |  |
| Top Left Third | `top-left-third` |  |  |
| Top Right Third | `top-right-third` |  |  |
| Bottom Left Third | `bottom-left-third` |  |  |
| Bottom Right Third | `bottom-right-third` |  |  |
| Top Left Eighth | `top-left-eighth` |  |  |
| Top Centre Left Eighth | `top-center-left-eighth` |  |  |
| Top Centre Right Eighth | `top-center-right-eighth` |  |  |
| Top Right Eighth | `top-right-eighth` |  |  |
| Bottom Left Eighth | `bottom-left-eighth` |  |  |
| Bottom Centre Left Eighth | `bottom-center-left-eighth` |  |  |
| Bottom Centre Right Eighth | `bottom-center-right-eighth` |  |  |
| Bottom Right Eighth | `bottom-right-eighth` |  |  |
| Top Left Ninth | `top-left-ninth` |  |  |
| Top Centre Ninth | `top-center-ninth` |  |  |
| Top Right Ninth | `top-right-ninth` |  |  |
| Middle Left Ninth | `middle-left-ninth` |  |  |
| Middle Centre Ninth | `middle-center-ninth` |  |  |
| Middle Right Ninth | `middle-right-ninth` |  |  |
| Bottom Left Ninth | `bottom-left-ninth` |  |  |
| Bottom Centre Ninth | `bottom-center-ninth` |  |  |
| Bottom Right Ninth | `bottom-right-ninth` |  |  |

# Changelog

Newest first. Each version's lines become the release notes in the update window.

## 3.0.0

- New Tree layout (⌃⌥6): split windows by hand, like AeroSpace and i3. Join, move, swap, resize, accordion, balance, flatten, mirror, rotate, preselect and zoom. Switching to it moves nothing.
- New Stack (⌃⌥7) and Float (⌃⌥8) layouts.
- Drop a window near another window's edge to split it; drop it in the middle to swap. Hold fn and drag from anywhere in a window to move it.
- A config file, ~/.config/tessera/tessera.toml: key bindings, binding modes, window rules, callbacks, and gaps for each screen. It reads AeroSpace's settings, and the menu can import an aerospace.toml.
- The tessera command line tool, for scripts and AI agents: run any command, list windows, desktops and screens as JSON, and follow events.
- Desktop commands: go to a desktop by number, the next, the previous or the last one; send a window there with or without following it.
- Key presets for Spectacle, AeroSpace and Spacetile users.
- Off unless you turn them on: dim the other windows, a border round the window you're in, and focus follows the mouse.
- A setup can open by itself when its screens are plugged in.
- Sending a window to a desktop works even while a modifier key is still held. Leaving macOS full screen no longer pins a window over the others.

## 2.5.1

- With auto-tile on, ⌃⌥ + arrow walks a window one spot through the layout, trading places with the window that way. The layout keeps its shape. Past the screen's edge it goes to the next screen.
- Unplugging a screen or closing the laptop lid no longer loses its layout: plug it back in and its windows go back to it, in order, with the same layout.

## 2.5.0

- Rectangle's other window actions: ninths, eighths, corner thirds, Centre Prominently, Specified Size, Tile All, Tile in Rows and Columns, Cascade, Reverse All, and stepping through windows stacked on one spot.
- Links for scripts and launchers, such as tessera://execute-action?name=left-half. Rectangle's links work too.
- Export and import settings as a JSON file. A TesseraConfig.json in Tessera's folder is read once at launch.
- Focus the window to the left, right, above or below with ⌃⇧⌘ + arrow.
- Send a window to desktop 1–9 with ⌃⌥⇧ + number.
- App rules: always float an app, always keep it in front, or open its windows on a chosen screen.
- Saved setups: save the apps on your screens and where their windows are, and open them again with ⌃⌥⌘ + number.
- Tessera can update itself, once release keys are set up. Install with Homebrew too.
- Waiting windows find a hiding place even with screens on both sides.

## 2.4.0

- Make Larger and Make Smaller (⌃⌥= and ⌃⌥−) grow a tile into all its neighbours, so the layout keeps its shape.
- Dragging the edge between two tiles moves only that edge.

## 2.3.1

- Several screens of different sizes: each has its own front-window limit and layout, and waiting windows never hang over another screen.

## 2.3.0

- Only a few windows sit in front, set by screen size. The rest wait off the edge and come forward when you use them.
- ⌃⌥Space opens a window picker; ⌃⌥P keeps a window in front.

## 2.2.0

- Swiping between desktops never moves a window.
- The latest command wins: picking a layout puts every window on the desktop into it.

## 2.1.1

- A newly opened copy of Tessera takes over from an older one.

## 2.1.0

- Layouts you pick keep their shape; ⌃⌥1–5 pick a layout; layout pictures in the menu.

## 2.0.0

- Rectangle-style snapping plus adaptive auto-tile.

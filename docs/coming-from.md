# Coming from another app

Tessera covers what Rectangle, Shoji, AeroSpace and Spacetile do, in one app. This page shows where each thing you know lives in Tessera, and the few things that work differently.

**Quit the other app first.** Window managers fight over the same windows and keys. Tessera offers to quit Rectangle when it starts.

## From Rectangle

Everything carries over.

| Rectangle | Tessera |
| --- | --- |
| Its default keys | The same keys |
| Every single-window action in the free version | All there, in the menu; give any a key in Settings |
| Snap areas (drag to an edge) | The same areas, with a blue outline |
| `rectangle://execute-action?name=…` | `tessera://execute-action?name=…`, with the same names |
| Ignore an app | **Ignore** in the menu, or **Settings › Apps Tessera leaves alone** |
| Todo mode | Close, not the same: **⌃⌥P** keeps a window in front, or the **Always Keep in Front** rule |
| Mouse-button shortcuts | Not yet |

What you gain: [auto-tile](auto-tile.md), [the Tree layout](tree.md), [setups](rules-and-setups.md#setups) and the [command line tool](cli.md).

## From Shoji

| Shoji | Tessera |
| --- | --- |
| Auto-tiling as windows open | Auto-tile (⌃⌥A); the **Auto** layout picks for you |
| Grid, Columns, Rows, Side | Grid, Columns, Rows, Main + Side, plus Auto, Tree, Stack and Float |
| A shortcut per layout | ⌃⌥1 … ⌃⌥8 |
| ⌃⌥ + arrow swaps two tiles | ⌃⌥ + arrow walks a tile one spot, and past the edge onto the next screen |
| Extra windows stack in the active tile | Extra windows wait off the screen's edge; using one brings it forward ([how](auto-tile.md#windows-in-front)) |
| Turn tiling off for an app | **Always Float** rule, or ignore the app |
| Active-window border | **Settings › Focus and Look**, off until you turn it on |
| No peek, Clean Space, Tab View | Left out on purpose; the ⌃⌥Space window picker instead |

## From AeroSpace

Your `aerospace.toml` mostly works as it is: **Import AeroSpace Config…** in the menu copies it and lists what won't work. See [Config file › Coming from AeroSpace](config.md#coming-from-aerospace).

| AeroSpace | Tessera |
| --- | --- |
| The tree: containers, tiles and accordion, normalization | [The Tree layout](tree.md), with the same commands |
| `join-with`, `move`, `focus`, `resize`, `flatten-workspace-tree`, `balance-sizes`, `layout` | The same names work |
| Binding modes, `on-window-detected`, callbacks, `exec-and-forget` | The same, in [tessera.toml](config.md) |
| The `aerospace` command line tool | [`tessera`](cli.md), with JSON output and the same command names |
| Workspaces 1, 2, 3 | Your macOS desktops, numbered on each screen |
| `workspace-back-and-forth` | `desktop last` |
| `move-node-to-workspace 3` | The same: the window goes, you stay |
| Gaps per monitor | The same `[gaps]` syntax |
| AeroSpace's key defaults | `preset = 'aerospace'` |

**What's different.** AeroSpace fakes its workspaces by hiding windows off screen, so switching is instant and workspaces can have names. Tessera uses real macOS desktops instead. So:

- Switching desktops plays macOS's slide. Turn on **Switch to Desktop N** in System Settings so `desktop 3` goes straight there.
- Named workspaces, `persistent-workspaces`, `move-workspace-to-monitor` and `summon-workspace` aren't supported.
- Sending a window to a desktop takes about a second: Tessera drags it there, as you would ([how](desktops-and-screens.md#how-sending-a-window-works)).

What you gain: auto layouts next to the tree, snapping, windows in front, setups, and nothing hidden off screen.

## From Spacetile

| Spacetile | Tessera |
| --- | --- |
| Tiling as windows open, on your own desktops | Auto-tile, with Auto or [Tree](tree.md) |
| Stack and float | Stack (⌃⌥7) and Float (⌃⌥8), or ⌃⌥W for one window |
| fn-drag from anywhere in a window | The same: hold fn and drag |
| Drop a window on another's edge to split | The same in Tree |
| A command line tool and config file | [`tessera`](cli.md) and [`tessera.toml`](config.md); Spacetile's command names work |
| Setups opened by a Focus or a screen | Setups open when their screens connect; a Shortcuts automation opens one for a Focus ([how](rules-and-setups.md#opening-a-setup-by-itself)) |
| Its keys | `preset = 'spacetile'` |
| Raycast commands | Not built in; Raycast can run `tessera` commands |

## From yabai or Amethyst

Tessera needs no System Integrity Protection changes. The Tree layout is close to yabai's split-in-two tiling (`join`, `split`, `rotate`, `mirror`, `balance`), and `tessera subscribe` gives you events like yabai's signals. Amethyst's tall layout is close to Tessera's Main + Side, and focus follows the mouse is in **Settings › Focus and Look**.

---

[Docs home](README.md) · Back: [Every shortcut](shortcuts.md) · Next: [Troubleshooting](troubleshooting.md)

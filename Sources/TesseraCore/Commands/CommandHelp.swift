import Foundation

/// The commands, for `tessera help` and the README. Every line is checked by the tests: each example parses.
public enum CommandHelp {
    public struct Entry: Sendable {
        public var group: String
        public var usage: String
        public var summary: String
        /// Other names for it (AeroSpace's, Spacetile's).
        public var aliases: [String]
        public var example: String

        public var name: String { String(usage.prefix { $0 != " " }) }
    }

    public static let entries: [Entry] = [
        // Focus
        Entry(group: "Focus", usage: "focus left|right|up|down|next|prev|back [--wrap-around]",
              summary: "Focus the window that way, the next or previous in the layout, or the one before.",
              aliases: ["west/east/north/south", "dfs-next", "dfs-prev", "focus-back-and-forth"], example: "focus left"),
        Entry(group: "Focus", usage: "focus --window-id ID", summary: "Focus a window by its id (see list-windows).",
              aliases: [], example: "focus --window-id 1234"),
        Entry(group: "Focus", usage: "focus-display left|right|next|prev|N|NAME", summary: "Focus a screen.",
              aliases: ["focus-monitor", "display next"], example: "focus-display next"),
        // Moving windows
        Entry(group: "Move", usage: "move left|right|up|down",
              summary: "Move the window one step through the layout; past the edge, to the next screen.",
              aliases: [], example: "move right"),
        Entry(group: "Move", usage: "swap left|right|up|down|next|prev [--swap-focus]",
              summary: "Swap the window with its neighbour.", aliases: [], example: "swap next"),
        Entry(group: "Move", usage: "send-to-desktop N|next|prev|last", summary: "Send the window to a desktop (and go there).",
              aliases: ["send N", "move-node-to-workspace N (stays put)"], example: "send-to-desktop 2"),
        Entry(group: "Move", usage: "send-to-display left|right|next|prev|N|NAME", summary: "Send the window to a screen.",
              aliases: ["send display next", "move-node-to-monitor"], example: "send-to-display next"),
        Entry(group: "Move", usage: "place NAME", summary: "Snap the window: left, right, top-left, center, left 2/3, any Rectangle name.",
              aliases: ["snap", "left-half", "maximize"], example: "place left 2/3"),
        // Layouts
        Entry(group: "Layout", usage: "layout auto|columns|rows|grid|main-and-side|tree|stack|float",
              summary: "Lay out this desktop a new way.", aliases: ["layout bsp"], example: "layout tree"),
        Entry(group: "Layout", usage: "layout tiles|accordion|horizontal|vertical [...]",
              summary: "Tree layout: change the window's container. The first that changes something wins.",
              aliases: ["h_tiles", "v_accordion"], example: "layout tiles horizontal vertical"),
        Entry(group: "Layout", usage: "layout floating|tiling", summary: "Float the window, or tile it again.",
              aliases: ["float on|off|toggle"], example: "layout floating tiling"),
        Entry(group: "Layout", usage: "retile", summary: "Arrange this desktop again, putting snapped windows back.", aliases: [], example: "retile"),
        Entry(group: "Layout", usage: "balance", summary: "Give every tile an even share.", aliases: ["balance-sizes"], example: "balance"),
        // Tree
        Entry(group: "Tree", usage: "join left|right|up|down", summary: "Put the window and its neighbour in a container of their own.",
              aliases: ["join-with"], example: "join right"),
        Entry(group: "Tree", usage: "split [horizontal|vertical|opposite]",
              summary: "With no way: turn the window's container the other way. With one: open the next window that way.",
              aliases: [], example: "split"),
        Entry(group: "Tree", usage: "preselect left|right|up|down|cancel", summary: "Open the next window on that side of this one.",
              aliases: [], example: "preselect down"),
        Entry(group: "Tree", usage: "mirror horizontal|vertical", summary: "Flip the layout.", aliases: [], example: "mirror horizontal"),
        Entry(group: "Tree", usage: "rotate 90|180|270", summary: "Turn the layout.", aliases: [], example: "rotate 90"),
        Entry(group: "Tree", usage: "flatten", summary: "Put every window side by side again.", aliases: ["flatten-workspace-tree"], example: "flatten"),
        Entry(group: "Tree", usage: "pop out|in", summary: "Take the window out of its container, or join its neighbour.",
              aliases: [], example: "pop out"),
        // Size
        Entry(group: "Size", usage: "resize smart|width|height +N|-N|N", summary: "Grow or shrink a tile by points (or set its size).",
              aliases: ["grow", "shrink"], example: "resize smart +50"),
        Entry(group: "Size", usage: "border horizontal|vertical N", summary: "Move one edge of the tile; only its neighbour gives way.",
              aliases: [], example: "border horizontal 100"),
        Entry(group: "Size", usage: "zoom [on|off]", summary: "Let the window fill the desktop until you zoom it again.",
              aliases: ["fullscreen"], example: "zoom"),
        // Windows
        Entry(group: "Window", usage: "native-fullscreen [on|off]", summary: "macOS full screen.",
              aliases: ["macos-native-fullscreen"], example: "native-fullscreen"),
        Entry(group: "Window", usage: "minimize", summary: "Minimise the window.", aliases: ["macos-native-minimize"], example: "minimize"),
        Entry(group: "Window", usage: "close [--quit-if-last-window]", summary: "Close the window.", aliases: [], example: "close"),
        Entry(group: "Window", usage: "close-others", summary: "Close every other window on this desktop.",
              aliases: ["close-all-windows-but-current"], example: "close-others"),
        Entry(group: "Window", usage: "keep on|off|toggle", summary: "Keep the window in front (it never waits off screen).",
              aliases: [], example: "keep on"),
        Entry(group: "Window", usage: "stack next|prev", summary: "Stack layout: show the next window.", aliases: [], example: "stack next"),
        // Desktops
        Entry(group: "Desktop", usage: "desktop N|next|prev|last", summary: "Switch to a desktop on this screen.",
              aliases: ["workspace N", "space N", "workspace-back-and-forth"], example: "desktop 2"),
        // Tessera
        Entry(group: "Tessera", usage: "enable on|off|toggle", summary: "Turn auto-tile on or off.", aliases: ["pause"], example: "enable on"),
        Entry(group: "Tessera", usage: "mode NAME", summary: "Switch binding mode (main, or one from the config file).",
              aliases: [], example: "mode main"),
        Entry(group: "Tessera", usage: "reload-config", summary: "Read the config file again.", aliases: [], example: "reload-config"),
        Entry(group: "Tessera", usage: "setup open|save|delete NAME", summary: "Open or save a setup of apps and windows.",
              aliases: ["load NAME"], example: "setup open Work"),
        Entry(group: "Tessera", usage: "toggle spacing|border|dim", summary: "Gaps, a border round the focused window, or dim the rest.",
              aliases: ["dim on", "border on"], example: "toggle dim"),
        Entry(group: "Tessera", usage: "move-mouse window-lazy-center|monitor-lazy-center", summary: "Move the pointer to the window or screen.",
              aliases: [], example: "move-mouse window-lazy-center"),
        Entry(group: "Tessera", usage: "exec-and-forget SHELL COMMAND", summary: "Run a shell command.", aliases: ["exec"],
              example: "exec-and-forget open -a Notes"),
        Entry(group: "Tessera", usage: "volume up|down|mute-toggle|set N", summary: "Change the sound volume.", aliases: [], example: "volume up"),
        // Questions
        Entry(group: "Ask", usage: "list-windows [--all|--focused|--desktop N|--display X] [--json|--count|--format F]",
              summary: "The windows, with ids, apps, titles, screens, desktops and how each is laid out.",
              aliases: ["list-windows --format '%{window-id} %{app-name} %{window-title}'"], example: "list-windows --json"),
        Entry(group: "Ask", usage: "list-desktops [--focused] [--json]", summary: "Each screen's desktops and their layouts.",
              aliases: ["list-workspaces"], example: "list-desktops"),
        Entry(group: "Ask", usage: "list-displays [--focused] [--json]", summary: "The screens.", aliases: ["list-monitors"], example: "list-displays --json"),
        Entry(group: "Ask", usage: "list-apps [--json]", summary: "Running apps.", aliases: [], example: "list-apps"),
        Entry(group: "Ask", usage: "list-modes [--current]", summary: "Binding modes.", aliases: [], example: "list-modes --current"),
        Entry(group: "Ask", usage: "tree [--json]", summary: "The Tree layout of each screen: H[1 V[2 3]].", aliases: [], example: "tree"),
        Entry(group: "Ask", usage: "config [--get KEY] [--config-path]", summary: "The config file and what Tessera read from it.",
              aliases: [], example: "config --config-path"),
        Entry(group: "Ask", usage: "subscribe [EVENT...]",
              summary: "Print events as they happen, one JSON line each: focus-changed, display-focus-changed, desktop-changed, mode-changed, window-detected, window-closed.",
              aliases: [], example: "subscribe focus-changed"),
        Entry(group: "Ask", usage: "version", summary: "Tessera's version.", aliases: [], example: "version"),
    ]

    /// `tessera help`: every command, grouped.
    public static var overview: String {
        var out = """
        tessera — control Tessera from the command line, scripts and AI agents.

        Usage: tessera COMMAND [ARGUMENTS]       one command, as separate words
               tessera 'CMD; CMD && CMD || CMD'  several, in one quoted line
               tessera --window-id ID COMMAND    act on that window, not the focused one

        AeroSpace's and Spacetile's command names work too. Exit codes: 0 done, 1 failed,
        2 Tessera isn't running, 3 not understood.

        """
        var group = ""
        for entry in entries {
            if entry.group != group {
                group = entry.group
                out += "\n\(group):\n"
            }
            out += "  \(entry.usage)\n      \(entry.summary)\n"
        }
        out += "\nRun `tessera help COMMAND` for one command.\n"
        return out
    }

    /// `tessera help focus`.
    public static func detail(_ name: String) -> String? {
        let lower = name.lowercased()
        let matches = entries.filter { $0.name == lower || $0.aliases.contains { $0.hasPrefix(lower) } }
        guard !matches.isEmpty else { return nil }
        return matches.map { entry in
            var text = "\(entry.usage)\n  \(entry.summary)\n  Example: tessera \(entry.example)"
            if !entry.aliases.isEmpty { text += "\n  Also: " + entry.aliases.joined(separator: ", ") }
            return text
        }.joined(separator: "\n\n")
    }
}

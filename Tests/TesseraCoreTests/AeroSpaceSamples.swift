/// Real-world config files used by the tests.
enum AeroSpaceSamples {
    /// AeroSpace's default config (default-config.toml), trimmed to a few lettered workspaces.
    static let defaultConfig = """
    # Place a copy of this config to ~/.aerospace.toml
    # After that, you can edit ~/.aerospace.toml to your liking

    # Config version for compatibility and deprecations
    # Fallback value (if you omit the key): config-version = 1
    config-version = 2

    # You can use it to add commands that run after AeroSpace startup.
    # Available commands : https://nikitabobko.github.io/AeroSpace/commands
    after-startup-command = []

    # Start AeroSpace at login
    start-at-login = false

    # Normalizations. See: https://nikitabobko.github.io/AeroSpace/guide#normalization
    enable-normalization-flatten-containers = true
    enable-normalization-opposite-orientation-for-nested-containers = true

    # The 'accordion-padding' specifies the size of accordion padding
    # You can set 0 to disable the padding feature
    accordion-padding = 30

    # Possible values: tiles|accordion
    default-root-container-layout = 'tiles'

    # Possible values: horizontal|vertical|auto
    default-root-container-orientation = 'auto'

    # Mouse follows focus when focused monitor changes
    on-focused-monitor-changed = ['move-mouse monitor-lazy-center']

    # You can effectively turn off macOS "Hide application" (cmd-h) feature by toggling this flag
    automatically-unhide-macos-hidden-apps = false

    # Possible values: (qwerty|dvorak|colemak)
    [key-mapping]
        preset = 'qwerty'

    # Gaps between windows (inner-*) and between monitor edges (outer-*).
    [gaps]
        inner.horizontal = 0
        inner.vertical =   0
        outer.left =       0
        outer.bottom =     0
        outer.top =        0
        outer.right =      0

    # 'main' binding mode declaration
    [mode.main.binding]

        # See: https://nikitabobko.github.io/AeroSpace/commands#layout
        alt-slash = 'layout tiles horizontal vertical'
        alt-comma = 'layout accordion horizontal vertical'

        # See: https://nikitabobko.github.io/AeroSpace/commands#focus
        alt-h = 'focus left'
        alt-j = 'focus down'
        alt-k = 'focus up'
        alt-l = 'focus right'

        # See: https://nikitabobko.github.io/AeroSpace/commands#move
        alt-shift-h = 'move left'
        alt-shift-j = 'move down'
        alt-shift-k = 'move up'
        alt-shift-l = 'move right'

        # See: https://nikitabobko.github.io/AeroSpace/commands#resize
        alt-minus = 'resize smart -50'
        alt-equal = 'resize smart +50'

        # See: https://nikitabobko.github.io/AeroSpace/commands#workspace
        alt-1 = 'workspace 1'
        alt-2 = 'workspace 2'
        alt-3 = 'workspace 3'
        alt-4 = 'workspace 4'
        alt-a = 'workspace A'
        alt-b = 'workspace B'

        # See: https://nikitabobko.github.io/AeroSpace/commands#move-node-to-workspace
        alt-shift-1 = 'move-node-to-workspace 1'
        alt-shift-2 = 'move-node-to-workspace 2'
        alt-shift-3 = 'move-node-to-workspace 3'
        alt-shift-4 = 'move-node-to-workspace 4'
        alt-shift-a = 'move-node-to-workspace A'
        alt-shift-b = 'move-node-to-workspace B'

        # See: https://nikitabobko.github.io/AeroSpace/commands#workspace-back-and-forth
        alt-tab = 'workspace-back-and-forth'
        # See: https://nikitabobko.github.io/AeroSpace/commands#move-workspace-to-monitor
        alt-shift-tab = 'move-workspace-to-monitor --wrap-around next'

        # See: https://nikitabobko.github.io/AeroSpace/guide#binding-modes
        alt-shift-semicolon = 'mode service'

    # 'service' binding mode declaration.
    [mode.service.binding]
        esc = ['reload-config', 'mode main']
        r = ['flatten-workspace-tree', 'mode main'] # reset layout
        f = ['layout floating tiling', 'mode main'] # Toggle between floating and tiling layout
        backspace = ['close-all-windows-but-current', 'mode main']

        # sticky is not yet supported https://github.com/nikitabobko/AeroSpace/issues/2
        #s = ['layout sticky tiling', 'mode main']

        alt-shift-h = ['join-with left', 'mode main']
        alt-shift-j = ['join-with down', 'mode main']
        alt-shift-k = ['join-with up', 'mode main']
        alt-shift-l = ['join-with right', 'mode main']
    """

    /// A typical personal config: gaps per monitor, window rules, callbacks, Sketchybar.
    static let personalConfig = """
    after-startup-command = ['exec-and-forget sketchybar']
    exec-on-workspace-change = ['/bin/bash', '-c',
        'sketchybar --trigger aerospace_workspace_change FOCUSED_WORKSPACE=$AEROSPACE_FOCUSED_WORKSPACE'
    ]
    on-focus-changed = ['move-mouse window-lazy-center']
    persistent-workspaces = ["1", "2", "3"]

    [gaps]
    inner.horizontal = 8
    inner.vertical = 8
    outer.left = 8
    outer.right = 8
    outer.bottom = 8
    outer.top = [{ monitor."built-in" = 8 }, { monitor.main = 40 }, 32]

    [workspace-to-monitor-force-assignment]
    1 = 'main'
    2 = 'secondary'

    [mode.main.binding]
    cmd-alt-ctrl-f = 'fullscreen'
    alt-shift-f = 'macos-native-fullscreen'
    alt-r = 'mode resize'

    [mode.resize.binding]
    h = 'resize width -50'
    l = 'resize width +50'
    enter = 'mode main'
    esc = 'mode main'

    [[on-window-detected]]
    if.app-id = 'com.apple.systempreferences'
    run = 'layout floating'

    [[on-window-detected]]
    if.app-name-regex-substring = 'slack'
    run = 'move-node-to-workspace 3'

    [[on-window-detected]]
    if.window-title-regex-substring = 'Picture-in-Picture'
    if.during-aerospace-startup = false
    run = ['layout floating']
    check-further-callbacks = true

    [[on-window-detected]]
    if.app-id = 'com.mitchellh.ghostty'
    run = ['layout tiling', 'move-node-to-workspace T']
    """
}

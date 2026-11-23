import Foundation

/// What a `tessera://` link asks for. Rectangle's link forms work too, so its scripts can switch over.
///
///     tessera://execute-action?name=left-half        any action: Rectangle's names or Tessera's
///     tessera://execute-layout?name=columns          a layout for the screen you're on
///     tessera://execute-task?name=ignore-app&app-bundle-id=com.apple.Safari
///     tessera://execute-task?name=unignore-app       (no id: the app in front)
///     tessera://export-settings?path=/Users/me/tessera.json
///     tessera://import-settings?path=/Users/me/tessera.json
///     tessera://save-setup?name=Work                 save the windows on screen now as a setup
///     tessera://open-setup?name=Work
public enum URLCommand: Equatable, Sendable {
    case run(Command)
    case ignore(app: String?, ignored: Bool)
    case exportSettings(path: String)
    case importSettings(path: String)
    case saveSetup(name: String)
    case openSetup(name: String)

    public init?(url: URL) {
        guard let scheme = url.scheme?.lowercased(), scheme == "tessera" || scheme == "rectangle",
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        func value(_ name: String) -> String? {
            parts.queryItems?.first { $0.name == name }?.value.flatMap { $0.isEmpty ? nil : $0 }
        }
        // tessera://execute-action?… puts the verb in the host; tessera:execute-action?… in the path.
        let verb = (url.host ?? parts.path).trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()
        switch verb {
        case "execute-action":
            guard let name = value("name"), let command = Command(urlName: name) else { return nil }
            self = .run(command)
        case "execute-layout":
            guard let name = value("name"),
                  let style = LayoutStyle(rawValue: name) ?? LayoutStyle.allCases.first(where: { $0.urlName == name.lowercased() })
            else { return nil }
            self = .run(.layout(style))
        case "execute-task":
            switch value("name") {
            case "ignore-app": self = .ignore(app: value("app-bundle-id"), ignored: true)
            case "unignore-app": self = .ignore(app: value("app-bundle-id"), ignored: false)
            default: return nil
            }
        case "export-settings":
            guard let path = value("path") else { return nil }
            self = .exportSettings(path: (path as NSString).expandingTildeInPath)
        case "import-settings":
            guard let path = value("path") else { return nil }
            self = .importSettings(path: (path as NSString).expandingTildeInPath)
        case "save-setup":
            guard let name = value("name") else { return nil }
            self = .saveSetup(name: name)
        case "open-setup":
            guard let name = value("name") else { return nil }
            self = .openSetup(name: name)
        default:
            return nil
        }
    }
}

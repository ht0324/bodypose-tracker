import Foundation

struct AppOptions {
    let duration: TimeInterval?
    let autostart: Bool
    let alertSoundURL: URL?

    static func parse(arguments: [String]) -> AppOptions {
        var duration: TimeInterval?
        var autostart = true
        var alertSoundURL = defaultAlertSoundURL()
        var index = 1

        while index < arguments.count {
            switch arguments[index] {
            case "--duration" where index + 1 < arguments.count:
                duration = TimeInterval(arguments[index + 1])
                index += 2
            case "--no-autostart":
                autostart = false
                index += 1
            case "--alert-sound" where index + 1 < arguments.count:
                alertSoundURL = URL(fileURLWithPath: (arguments[index + 1] as NSString).expandingTildeInPath)
                index += 2
            case "--no-alert-sound":
                alertSoundURL = nil
                index += 1
            default:
                index += 1
            }
        }

        return AppOptions(
            duration: duration,
            autostart: autostart,
            alertSoundURL: alertSoundURL
        )
    }
}

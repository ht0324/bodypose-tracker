import Foundation

private let bundledAlertSoundName = "iMovie-Alarm"
private let bundledAlertSoundExtension = "mp3"

private var projectAlertSoundURL: URL {
    URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("Resources")
        .appendingPathComponent("\(bundledAlertSoundName).\(bundledAlertSoundExtension)")
}

func defaultLogURL() -> URL {
    FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library")
        .appendingPathComponent("Logs")
        .appendingPathComponent("BodyPoseTracker")
        .appendingPathComponent("BodyPoseTracker.log")
}

func defaultAlertSoundURL() -> URL? {
    if let bundledURL = Bundle.main.url(forResource: bundledAlertSoundName, withExtension: bundledAlertSoundExtension) {
        return bundledURL
    }

    let projectURL = projectAlertSoundURL
    if FileManager.default.fileExists(atPath: projectURL.path) {
        return projectURL
    }

    return nil
}

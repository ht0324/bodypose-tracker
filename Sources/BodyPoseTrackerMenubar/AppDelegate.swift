import AppKit
import AVFoundation
import BodyPoseTrackerCore
import CoreGraphics
import Foundation
import ServiceManagement

private enum SystemPauseReason: String, CaseIterable {
    case sleep = "Sleep"
    case displaySleep = "Display Sleep"
    case locked = "Locked"
    case screenSaver = "Screen Saver"
    case eating = "Eating"
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let pauseApps: [(bundleID: String, name: String)] = [
        ("us.zoom.xos", "Zoom"),
        ("com.apple.FaceTime", "FaceTime")
    ]
    // Matched to the bundled iMovie alarm envelope: roughly one 0.22s beep every 0.68s.
    private let alertFlashPeriod: TimeInterval = 0.68
    private let alertFlashOnDuration: TimeInterval = 0.22
    private let alertBubbleSize = NSSize(width: 54, height: 24)
    private let alertBubbleCornerRadius: CGFloat = 11
    private let alertBubbleIconSize = NSSize(width: 16, height: 16)
    private let options = AppOptions.parse(arguments: CommandLine.arguments)
    private lazy var log = FileLog(url: defaultLogURL())
    private var statusItem: NSStatusItem?
    private var statusMenuItem = NSMenuItem(title: "Starting...", action: nil, keyEquivalent: "")
    private var dailyStreakMenuItem = NSMenuItem(title: "Daily streak: Starting...", action: nil, keyEquivalent: "")
    private var encouragementMenuItem = NSMenuItem(title: "You can do it! ✨", action: nil, keyEquivalent: "")
    private var productionToggleMenuItem = NSMenuItem(title: "Enable", action: nil, keyEquivalent: "")
    private var eatingPauseMenuItem = NSMenuItem(title: "I am eating!", action: nil, keyEquivalent: "")
    private var launchAtLoginMenuItem = NSMenuItem(title: "Launch at Login", action: nil, keyEquivalent: "")
    private var autoEnableOnExternalPowerMenuItem = NSMenuItem(title: "Auto Enable on External Power", action: nil, keyEquivalent: "")
    private var autoEnableOnAirPodsProMenuItem = NSMenuItem(title: "Auto Enable on AirPods Pro", action: nil, keyEquivalent: "")
    private var debugPreviewMenuItem = NSMenuItem(title: "Show Debug Preview", action: nil, keyEquivalent: "")
    private var controller: VisionCaptureController?
    private var debugPreviewWindow: DebugPreviewWindowController?
    private var powerStateMonitor: PowerStateMonitor?
    private var airPodsProAudioSourceMonitor: AirPodsProAudioSourceMonitor?
    private var latestPowerState = PowerState(isConnectedToExternalPower: false, isCharging: false)
    private var latestAirPodsProAudioSourceState = AirPodsProAudioSourceState(
        isActive: false,
        activeDeviceNames: [],
        connectedDeviceNames: []
    )
    private var productionWanted = false
    private var productionStartPending = false
    private var runningPauseAppBundleIDs = Set<String>()
    private var manuallyResumedPauseAppBundleIDs = Set<String>()
    private var systemPauseReasons = Set<SystemPauseReason>()
    private var workspaceObservers: [NSObjectProtocol] = []
    private var distributedObservers: [NSObjectProtocol] = []
    private var pauseReconcileTimer: Timer?
    private var eatingPauseTimer: Timer?
    private var eatingPauseEndDate: Date?
    private var dailyStreakRefreshTimer: Timer?
    private var encouragementRefreshTimer: Timer?
    private var encouragementNextRefreshDate: Date?
    private var pausedEncouragementRefreshDelay: TimeInterval?
    private var encouragementLineIndex = 0
    private var alertFlashTimer: Timer?
    private var alertFlashOffWorkItem: DispatchWorkItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        setupStatusItem()
        scheduleDailyStreakRefresh()
        scheduleEncouragementRefresh()
        log.write(
            "menubar app launched config=\(DetectionConfig.production.name) " +
            "autoEnableOnExternalPower=\(autoEnableOnExternalPower) " +
            "autoEnableOnAirPodsPro=\(autoEnableOnAirPodsPro)"
        )

        controller = VisionCaptureController(log: log, alertSoundURL: options.alertSoundURL) { [weak self] status, state in
            self?.updateStatus(status, state: state)
        }
        setupPauseAppMonitoring()
        setupSystemPauseMonitoring()
        if let reason = pauseReason {
            log.write("pause reasons already active reason=\(reason)")
        }

        if options.autostart {
            start(.production)
        } else {
            updateStatus("Stopped", state: .empty)
        }
        setupPowerStateMonitoring()
        setupAirPodsProAudioSourceMonitoring()

        if let duration = options.duration {
            DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
                self.controller?.stop()
                NSApp.terminate(nil)
            }
        }
        log.write("applicationDidFinishLaunching complete")
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        for observer in workspaceObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        workspaceObservers = []
        for observer in distributedObservers {
            DistributedNotificationCenter.default().removeObserver(observer)
        }
        distributedObservers = []
        stopPauseReconcileTimer()
        eatingPauseTimer?.invalidate()
        eatingPauseTimer = nil
        eatingPauseEndDate = nil
        dailyStreakRefreshTimer?.invalidate()
        dailyStreakRefreshTimer = nil
        encouragementRefreshTimer?.invalidate()
        encouragementRefreshTimer = nil
        encouragementNextRefreshDate = nil
        pausedEncouragementRefreshDelay = nil
        powerStateMonitor?.stop()
        powerStateMonitor = nil
        airPodsProAudioSourceMonitor?.stop()
        airPodsProAudioSourceMonitor = nil
        stopAlertIconFlash()
        log.write("applicationWillTerminate")
    }

    func menuWillOpen(_ menu: NSMenu) {
        syncProductionToggleMenuItem()
        syncEatingPauseMenuItem()
        syncDailyStreakMenuItem()
        syncEncouragementMenuItem()
        syncLaunchAtLoginMenuItem()
        syncAutoEnableOnExternalPowerMenuItem()
        syncAutoEnableOnAirPodsProMenuItem()
    }

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        configureStatusButton(
            item.button,
            symbolName: "hand.raised",
            accessibilityDescription: "BodyPoseTracker",
            tint: nil
        )
        let menu = NSMenu()
        menu.delegate = self
        statusMenuItem.isEnabled = false
        menu.addItem(statusMenuItem)
        dailyStreakMenuItem.isEnabled = false
        syncDailyStreakMenuItem()
        menu.addItem(dailyStreakMenuItem)
        encouragementMenuItem.isEnabled = false
        syncEncouragementMenuItem()
        menu.addItem(encouragementMenuItem)
        menu.addItem(.separator())
        productionToggleMenuItem.action = #selector(toggleProduction)
        menu.addItem(productionToggleMenuItem)
        eatingPauseMenuItem.action = #selector(startEatingPause)
        syncEatingPauseMenuItem()
        menu.addItem(eatingPauseMenuItem)
        launchAtLoginMenuItem.action = #selector(toggleLaunchAtLogin)
        syncLaunchAtLoginMenuItem()
        menu.addItem(launchAtLoginMenuItem)
        autoEnableOnExternalPowerMenuItem.action = #selector(toggleAutoEnableOnExternalPower)
        syncAutoEnableOnExternalPowerMenuItem()
        menu.addItem(autoEnableOnExternalPowerMenuItem)
        autoEnableOnAirPodsProMenuItem.action = #selector(toggleAutoEnableOnAirPodsPro)
        syncAutoEnableOnAirPodsProMenuItem()
        menu.addItem(autoEnableOnAirPodsProMenuItem)
        menu.addItem(.separator())
        debugPreviewMenuItem.action = #selector(toggleDebugPreview)
        menu.addItem(debugPreviewMenuItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q"))
        item.menu = menu
        statusItem = item
    }

    private func configureStatusButton(
        _ button: NSStatusBarButton?,
        symbolName: String,
        accessibilityDescription: String,
        tint: NSColor?
    ) {
        guard let button else { return }
        statusItem?.length = NSStatusItem.squareLength

        let image = makeStatusImage(
            symbolName: symbolName,
            accessibilityDescription: accessibilityDescription,
            tint: tint
        )
        button.image = image
        button.contentTintColor = nil
        button.title = ""
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyDown
        button.toolTip = accessibilityDescription
    }

    private func makeStatusImage(
        symbolName: String,
        accessibilityDescription: String,
        tint: NSColor?
    ) -> NSImage? {
        guard let baseImage = NSImage(systemSymbolName: symbolName, accessibilityDescription: accessibilityDescription) else {
            return nil
        }

        let configuredImage: NSImage
        if let tint,
           let tintedImage = baseImage.withSymbolConfiguration(.init(paletteColors: [tint])) {
            configuredImage = tintedImage
            configuredImage.isTemplate = false
        } else {
            configuredImage = baseImage
            configuredImage.isTemplate = true
        }
        configuredImage.size = NSSize(width: 18, height: 18)
        return configuredImage
    }

    private func syncDailyStreakMenuItem() {
        let startDate = dailyStreakStartDate
        let dayCount = dailyStreakDayCount(since: startDate)
        dailyStreakMenuItem.title = "Daily streak: Day \(dayCount) (since \(shortDailyStreakDate(startDate)))"
        dailyStreakMenuItem.toolTip = "\(dayCount) \(dayCount == 1 ? "day" : "days") since \(longDailyStreakDate(startDate))"
    }

    private var dailyStreakStartDate: Date {
        get {
            if let storedValue = UserDefaults.standard.string(forKey: UserDefaultsKeys.dailyStreakStartDate),
               let storedDate = dailyStreakDate(from: storedValue) {
                return storedDate
            }

            let defaultDate = defaultDailyStreakStartDate()
            UserDefaults.standard.set(dailyStreakDateString(for: defaultDate), forKey: UserDefaultsKeys.dailyStreakStartDate)
            return defaultDate
        }
    }

    private var dailyStreakCalendar: Calendar {
        Calendar.autoupdatingCurrent
    }

    private func defaultDailyStreakStartDate() -> Date {
        let calendar = dailyStreakCalendar
        var components = DateComponents()
        components.calendar = calendar
        components.year = 2026
        components.month = 4
        components.day = 30
        return calendar.date(from: components).map { calendar.startOfDay(for: $0) } ?? calendar.startOfDay(for: Date())
    }

    private func dailyStreakDate(from string: String) -> Date? {
        let pieces = string.split(separator: "-").compactMap { Int($0) }
        guard pieces.count == 3 else { return nil }

        let calendar = dailyStreakCalendar
        var components = DateComponents()
        components.calendar = calendar
        components.year = pieces[0]
        components.month = pieces[1]
        components.day = pieces[2]
        return calendar.date(from: components).map { calendar.startOfDay(for: $0) }
    }

    private func dailyStreakDateString(for date: Date) -> String {
        let components = dailyStreakCalendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }

    private func dailyStreakDayCount(since startDate: Date) -> Int {
        let calendar = dailyStreakCalendar
        let startDay = calendar.startOfDay(for: startDate)
        let today = calendar.startOfDay(for: Date())
        let elapsedDays = calendar.dateComponents([.day], from: startDay, to: today).day ?? 0
        return max(1, elapsedDays + 1)
    }

    private func shortDailyStreakDate(_ date: Date) -> String {
        formattedDailyStreakDate(date, template: "MMM d")
    }

    private func longDailyStreakDate(_ date: Date) -> String {
        formattedDailyStreakDate(date, template: "MMM d, y")
    }

    private func formattedDailyStreakDate(_ date: Date, template: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.calendar = dailyStreakCalendar
        formatter.setLocalizedDateFormatFromTemplate(template)
        return formatter.string(from: date)
    }

    private func scheduleDailyStreakRefresh() {
        dailyStreakRefreshTimer?.invalidate()

        guard let nextRefreshDate = nextDailyStreakRefreshDate() else { return }
        let timer = Timer(fire: nextRefreshDate, interval: 0, repeats: false) { [weak self] _ in
            self?.syncDailyStreakMenuItem()
            self?.scheduleDailyStreakRefresh()
        }
        RunLoop.main.add(timer, forMode: .common)
        dailyStreakRefreshTimer = timer
    }

    private func nextDailyStreakRefreshDate() -> Date? {
        let calendar = dailyStreakCalendar
        let today = calendar.startOfDay(for: Date())
        guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: today) else { return nil }
        return calendar.date(byAdding: .second, value: 2, to: tomorrow)
    }

    private func syncEncouragementMenuItem() {
        let encouragement = currentEncouragementLine
        encouragementMenuItem.title = encouragement
        encouragementMenuItem.toolTip = encouragement
    }

    private var currentEncouragementLine: String {
        guard !encouragementLines.isEmpty else { return "" }
        return encouragementLines[encouragementLineIndex]
    }

    private func advanceEncouragementLine() {
        guard !encouragementLines.isEmpty else { return }
        encouragementLineIndex = (encouragementLineIndex + 1) % encouragementLines.count
        syncEncouragementMenuItem()
    }

    private func scheduleEncouragementRefresh(after delay: TimeInterval = encouragementRotationInterval) {
        encouragementRefreshTimer?.invalidate()

        let nextRefreshDate = nextEncouragementRefreshDate(after: delay)
        let timer = Timer(fire: nextRefreshDate, interval: 0, repeats: false) { [weak self] _ in
            self?.handleEncouragementRefresh()
        }
        RunLoop.main.add(timer, forMode: .common)
        encouragementRefreshTimer = timer
        encouragementNextRefreshDate = nextRefreshDate
    }

    private func handleEncouragementRefresh() {
        encouragementRefreshTimer = nil
        encouragementNextRefreshDate = nil
        advanceEncouragementLine()
        scheduleEncouragementRefresh()
    }

    private func pauseEncouragementRefreshForSleep() {
        guard pausedEncouragementRefreshDelay == nil else { return }
        pausedEncouragementRefreshDelay = encouragementNextRefreshDate.map {
            max(0, $0.timeIntervalSinceNow)
        }
        encouragementRefreshTimer?.invalidate()
        encouragementRefreshTimer = nil
        encouragementNextRefreshDate = nil
    }

    private func resumeEncouragementRefreshAfterWake() {
        guard let delay = pausedEncouragementRefreshDelay else {
            if encouragementRefreshTimer == nil {
                scheduleEncouragementRefresh()
            }
            return
        }

        pausedEncouragementRefreshDelay = nil
        scheduleEncouragementRefresh(after: delay)
    }

    private func nextEncouragementRefreshDate(after delay: TimeInterval) -> Date {
        let proposedDate = Date(timeIntervalSinceNow: max(0, delay))
        guard isEncouragementQuietTime(proposedDate) else { return proposedDate }

        return encouragementQuietEndDate(after: proposedDate) ?? proposedDate
    }

    private func isEncouragementQuietTime(_ date: Date) -> Bool {
        let hour = Calendar.autoupdatingCurrent.component(.hour, from: date)
        return hour >= encouragementQuietStartHour || hour < encouragementQuietEndHour
    }

    private func encouragementQuietEndDate(after date: Date) -> Date? {
        let calendar = Calendar.autoupdatingCurrent
        let dayStart = calendar.startOfDay(for: date)
        let quietEndDay: Date?
        if calendar.component(.hour, from: date) < encouragementQuietEndHour {
            quietEndDay = dayStart
        } else {
            quietEndDay = calendar.date(byAdding: .day, value: 1, to: dayStart)
        }
        guard let quietEndDay else { return nil }
        return calendar.date(byAdding: .hour, value: encouragementQuietEndHour, to: quietEndDay)
    }

    private func configureAlertBubbleButton() {
        guard let statusItem, let button = statusItem.button else { return }

        statusItem.length = alertBubbleSize.width
        button.image = makeAlertBubbleImage()
        button.contentTintColor = nil
        button.title = ""
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleNone
        button.toolTip = "Hand Near Head"
    }

    private func configureAlertRestingButton() {
        guard let statusItem, let button = statusItem.button else { return }

        statusItem.length = alertBubbleSize.width
        button.image = makeWideStatusImage(
            symbolName: "hand.raised",
            accessibilityDescription: "BodyPoseTracker"
        )
        button.contentTintColor = nil
        button.title = ""
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleNone
        button.toolTip = "BodyPoseTracker"
    }

    private func makeWideStatusImage(
        symbolName: String,
        accessibilityDescription: String
    ) -> NSImage? {
        guard let symbol = NSImage(systemSymbolName: symbolName, accessibilityDescription: accessibilityDescription) else {
            return nil
        }

        let image = NSImage(size: alertBubbleSize)
        image.lockFocus()

        symbol.size = NSSize(width: 18, height: 18)
        let symbolRect = NSRect(
            x: (alertBubbleSize.width - symbol.size.width) / 2,
            y: (alertBubbleSize.height - symbol.size.height) / 2 + 0.5,
            width: symbol.size.width,
            height: symbol.size.height
        )
        symbol.draw(in: symbolRect)

        image.unlockFocus()
        image.isTemplate = true
        image.accessibilityDescription = accessibilityDescription
        return image
    }

    private func makeAlertBubbleImage() -> NSImage {
        let image = NSImage(size: alertBubbleSize)
        image.lockFocus()

        let bubbleRect = NSRect(
            x: 1,
            y: 1,
            width: alertBubbleSize.width - 2,
            height: alertBubbleSize.height - 2
        )
        let bubblePath = NSBezierPath(
            roundedRect: bubbleRect,
            xRadius: alertBubbleCornerRadius,
            yRadius: alertBubbleCornerRadius
        )
        NSColor.systemRed.setFill()
        bubblePath.fill()

        drawAlertHandSymbol()

        image.unlockFocus()
        image.isTemplate = false
        image.accessibilityDescription = "Hand Near Head"
        return image
    }

    private func drawAlertHandSymbol() {
        guard let symbol = NSImage(systemSymbolName: "hand.raised.fill", accessibilityDescription: "Hand Near Head") else {
            return
        }

        let configuredSymbol = symbol.withSymbolConfiguration(.init(paletteColors: [.white])) ?? symbol
        configuredSymbol.isTemplate = false
        configuredSymbol.size = alertBubbleIconSize

        let iconRect = NSRect(
            x: (alertBubbleSize.width - alertBubbleIconSize.width) / 2,
            y: (alertBubbleSize.height - alertBubbleIconSize.height) / 2 + 0.5,
            width: alertBubbleIconSize.width,
            height: alertBubbleIconSize.height
        )
        configuredSymbol.draw(in: iconRect)
    }

    private func syncLaunchAtLoginMenuItem() {
        let status = SMAppService.mainApp.status
        launchAtLoginMenuItem.isEnabled = true
        switch status {
        case .enabled:
            launchAtLoginMenuItem.title = "Launch at Login"
            launchAtLoginMenuItem.state = .on
        case .notRegistered:
            launchAtLoginMenuItem.title = "Launch at Login"
            launchAtLoginMenuItem.state = .off
        case .requiresApproval:
            launchAtLoginMenuItem.title = "Launch at Login (Needs Approval)"
            launchAtLoginMenuItem.state = .mixed
        case .notFound:
            launchAtLoginMenuItem.title = "Launch at Login (Unavailable)"
            launchAtLoginMenuItem.state = .off
            launchAtLoginMenuItem.isEnabled = false
        @unknown default:
            launchAtLoginMenuItem.title = "Launch at Login"
            launchAtLoginMenuItem.state = .off
        }
    }

    @objc private func toggleLaunchAtLogin() {
        let service = SMAppService.mainApp
        let status = service.status

        do {
            switch status {
            case .enabled:
                try service.unregister()
                log.write("launch at login disabled")
            case .notRegistered, .notFound:
                try service.register()
                log.write("launch at login enabled")
            case .requiresApproval:
                log.write("launch at login requires approval; opening settings")
                SMAppService.openSystemSettingsLoginItems()
            @unknown default:
                try service.register()
                log.write("launch at login enabled from unknown status=\(status.rawValue)")
            }
        } catch {
            log.write("launch at login toggle failed status=\(status.rawValue) error=\(error.localizedDescription)")
            NSSound.beep()
        }

        syncLaunchAtLoginMenuItem()
    }

    private var autoEnableOnExternalPower: Bool {
        get {
            UserDefaults.standard.bool(forKey: UserDefaultsKeys.autoEnableOnExternalPower)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: UserDefaultsKeys.autoEnableOnExternalPower)
        }
    }

    private func syncAutoEnableOnExternalPowerMenuItem() {
        autoEnableOnExternalPowerMenuItem.title = "Auto Enable on External Power"
        autoEnableOnExternalPowerMenuItem.state = autoEnableOnExternalPower ? .on : .off
    }

    @objc private func toggleAutoEnableOnExternalPower() {
        autoEnableOnExternalPower.toggle()
        syncAutoEnableOnExternalPowerMenuItem()
        log.write("auto enable on external power \(autoEnableOnExternalPower ? "enabled" : "disabled")")
        autoEnableProductionIfNeededForPower(source: "setting toggle")
    }

    private var autoEnableOnAirPodsPro: Bool {
        get {
            UserDefaults.standard.bool(forKey: UserDefaultsKeys.autoEnableOnAirPodsPro)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: UserDefaultsKeys.autoEnableOnAirPodsPro)
        }
    }

    private func syncAutoEnableOnAirPodsProMenuItem() {
        autoEnableOnAirPodsProMenuItem.title = "Auto Enable on AirPods Pro"
        autoEnableOnAirPodsProMenuItem.state = autoEnableOnAirPodsPro ? .on : .off
    }

    @objc private func toggleAutoEnableOnAirPodsPro() {
        autoEnableOnAirPodsPro.toggle()
        syncAutoEnableOnAirPodsProMenuItem()
        log.write("auto enable on AirPods Pro \(autoEnableOnAirPodsPro ? "enabled" : "disabled")")
        refreshAirPodsProAudioSourceMonitoring(publishInitialState: autoEnableOnAirPodsPro)
    }

    private func requestCameraAccess(_ completion: @escaping (Bool) -> Void) {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        log.write("camera authorization status before request=\(status.rawValue)")
        switch status {
        case .authorized:
            completion(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async {
                    self.log.write("camera authorization request completed granted=\(granted)")
                    completion(granted)
                }
            }
        default:
            log.write("camera authorization unavailable status=\(status.rawValue)")
            completion(false)
        }
    }

    private func setupPowerStateMonitoring() {
        let monitor = PowerStateMonitor { [weak self] state, source in
            self?.handlePowerStateChange(state, source: source)
        }
        powerStateMonitor = monitor
        monitor.start()
    }

    private func handlePowerStateChange(_ state: PowerState, source: String) {
        latestPowerState = state
        log.write(
            "power state source=\(source) externalPower=\(state.isConnectedToExternalPower) charging=\(state.isCharging)"
        )
        autoEnableProductionIfNeededForPower(source: source)
    }

    private func autoEnableProductionIfNeededForPower(source: String) {
        guard autoEnableOnExternalPower else { return }
        guard latestPowerState.canAutoEnableOnExternalPower else { return }
        guard canAutoEnableProduction else { return }

        log.write("auto-enabling production on external power source=\(source)")
        start(.production)
    }

    private func setupAirPodsProAudioSourceMonitoring() {
        let monitor = AirPodsProAudioSourceMonitor { [weak self] state, source in
            self?.handleAirPodsProAudioSourceChange(state, source: source)
        }
        airPodsProAudioSourceMonitor = monitor
        refreshAirPodsProAudioSourceMonitoring(publishInitialState: true)
    }

    private func refreshAirPodsProAudioSourceMonitoring(publishInitialState: Bool) {
        guard let monitor = airPodsProAudioSourceMonitor else { return }
        guard autoEnableOnAirPodsPro, canAutoEnableProduction else {
            monitor.stop()
            return
        }

        monitor.start(publishInitialState: publishInitialState)
    }

    private func handleAirPodsProAudioSourceChange(_ state: AirPodsProAudioSourceState, source: String) {
        latestAirPodsProAudioSourceState = state
        log.write(
            "AirPods Pro audio source source=\(source) active=\(state.isActive) " +
            "activeDevices=\(state.activeDeviceNames.joined(separator: ",")) " +
            "connectedDevices=\(state.connectedDeviceNames.joined(separator: ","))"
        )
        autoEnableProductionIfNeededForAirPodsPro(source: source)
    }

    private func autoEnableProductionIfNeededForAirPodsPro(source: String) {
        guard autoEnableOnAirPodsPro else { return }
        guard latestAirPodsProAudioSourceState.canAutoEnableOnAirPodsPro else { return }
        guard canAutoEnableProduction else { return }

        log.write("auto-enabling production on AirPods Pro audio source source=\(source)")
        start(.production)
    }

    private var canAutoEnableProduction: Bool {
        !productionWanted && controller?.isRunning != true && !productionStartPending
    }

    private func setupPauseAppMonitoring() {
        refreshRunningPauseApps()
        let notificationCenter = NSWorkspace.shared.notificationCenter
        workspaceObservers += [
            notificationCenter.addObserver(
                forName: NSWorkspace.didLaunchApplicationNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                self?.handleWorkspaceAppChange(notification, launched: true)
            },
            notificationCenter.addObserver(
                forName: NSWorkspace.didTerminateApplicationNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                self?.handleWorkspaceAppChange(notification, launched: false)
            }
        ]
    }

    private func refreshRunningPauseApps() {
        let pauseBundleIDs = Set(pauseApps.map(\.bundleID))
        runningPauseAppBundleIDs = Set(
            NSWorkspace.shared.runningApplications
                .compactMap(\.bundleIdentifier)
                .filter { pauseBundleIDs.contains($0) }
            )
    }

    private func setupSystemPauseMonitoring() {
        _ = refreshObservableSystemPauseReasons(source: "startup")
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        workspaceObservers += [
            workspaceCenter.addObserver(
                forName: NSWorkspace.willSleepNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.pauseEncouragementRefreshForSleep()
                self?.setSystemPauseReason(.sleep, active: true, source: "will sleep")
            },
            workspaceCenter.addObserver(
                forName: NSWorkspace.didWakeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.resumeEncouragementRefreshAfterWake()
                self?.setSystemPauseReasons([.sleep, .displaySleep], active: false, source: "did wake")
            },
            workspaceCenter.addObserver(
                forName: NSWorkspace.screensDidSleepNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.setSystemPauseReason(.displaySleep, active: true, source: "screens did sleep")
            },
            workspaceCenter.addObserver(
                forName: NSWorkspace.screensDidWakeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.setSystemPauseReason(.displaySleep, active: false, source: "screens did wake")
            },
            workspaceCenter.addObserver(
                forName: NSWorkspace.sessionDidResignActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.setSystemPauseReason(.locked, active: true, source: "session did resign active")
            },
            workspaceCenter.addObserver(
                forName: NSWorkspace.sessionDidBecomeActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.setSystemPauseReason(.locked, active: false, source: "session did become active")
            }
        ]

        let distributedCenter = DistributedNotificationCenter.default()
        distributedObservers = [
            distributedCenter.addObserver(
                forName: Notification.Name("com.apple.screenIsLocked"),
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.setSystemPauseReason(.locked, active: true, source: "screen locked")
            },
            distributedCenter.addObserver(
                forName: Notification.Name("com.apple.screenIsUnlocked"),
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.setSystemPauseReason(.locked, active: false, source: "screen unlocked")
            },
            distributedCenter.addObserver(
                forName: Notification.Name("com.apple.screensaver.didstart"),
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.setSystemPauseReason(.screenSaver, active: true, source: "screen saver started")
            },
            distributedCenter.addObserver(
                forName: Notification.Name("com.apple.screensaver.didstop"),
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.setSystemPauseReason(.screenSaver, active: false, source: "screen saver stopped")
            }
        ]
    }

    private func refreshObservableSystemPauseReasons(source: String) -> Bool {
        let previousReasons = systemPauseReasons
        setSystemPauseReasonPresence(.locked, active: currentSessionIsLockedOrInactive())
        setSystemPauseReasonPresence(.screenSaver, active: isScreenSaverRunning())
        logSystemPauseChanges(previous: previousReasons, current: systemPauseReasons, source: source)
        return previousReasons != systemPauseReasons
    }

    private func setSystemPauseReasons(_ reasons: [SystemPauseReason], active: Bool, source: String) {
        let previousReasons = systemPauseReasons
        for reason in reasons {
            setSystemPauseReasonPresence(reason, active: active)
        }
        guard previousReasons != systemPauseReasons else { return }
        logSystemPauseChanges(previous: previousReasons, current: systemPauseReasons, source: source)
        reconcileProductionPause()
    }

    private func setSystemPauseReason(_ reason: SystemPauseReason, active: Bool, source: String) {
        setSystemPauseReasons([reason], active: active, source: source)
    }

    private func setSystemPauseReasonPresence(_ reason: SystemPauseReason, active: Bool) {
        if active {
            systemPauseReasons.insert(reason)
        } else {
            systemPauseReasons.remove(reason)
        }
    }

    private func currentSessionIsLockedOrInactive() -> Bool {
        guard let sessionInfo = CGSessionCopyCurrentDictionary() as? [String: Any] else {
            return false
        }
        let locked = sessionInfo["CGSSessionScreenIsLocked"] as? Bool == true
        let onConsole = sessionInfo["kCGSSessionOnConsoleKey"] as? Bool ?? true
        return locked || !onConsole
    }

    private func isScreenSaverRunning() -> Bool {
        NSWorkspace.shared.runningApplications.contains { app in
            app.bundleIdentifier == "com.apple.ScreenSaver.Engine" ||
                app.localizedName?.localizedCaseInsensitiveContains("ScreenSaver") == true ||
                app.executableURL?.lastPathComponent.localizedCaseInsensitiveContains("ScreenSaver") == true ||
                app.bundleURL?.lastPathComponent.localizedCaseInsensitiveContains("ScreenSaver") == true
        }
    }

    private func logSystemPauseChanges(previous: Set<SystemPauseReason>, current: Set<SystemPauseReason>, source: String) {
        let started = current.subtracting(previous)
        let ended = previous.subtracting(current)
        for reason in orderedSystemPauseReasons(started) {
            log.write("system pause started reason=\(reason.rawValue) source=\(source)")
        }
        for reason in orderedSystemPauseReasons(ended) {
            log.write("system pause ended reason=\(reason.rawValue) source=\(source)")
        }
    }

    private func orderedSystemPauseReasons(_ reasons: Set<SystemPauseReason>) -> [SystemPauseReason] {
        SystemPauseReason.allCases.filter { reasons.contains($0) }
    }

    private func handleWorkspaceAppChange(_ notification: Notification, launched: Bool) {
        let previousBundleIDs = runningPauseAppBundleIDs
        let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        refreshRunningPauseApps()

        let launchedBundleIDs = runningPauseAppBundleIDs.subtracting(previousBundleIDs)
        let terminatedBundleIDs = previousBundleIDs.subtracting(runningPauseAppBundleIDs)
        let notifiedPauseBundleID = app?.bundleIdentifier.flatMap { pauseAppName(for: $0) == nil ? nil : $0 }
        clearManualPauseAppOverrides(terminatedBundleIDs: terminatedBundleIDs)
        logPauseAppChanges(launchedBundleIDs: launchedBundleIDs, terminatedBundleIDs: terminatedBundleIDs)

        if launchedBundleIDs.isEmpty,
           terminatedBundleIDs.isEmpty,
           let bundleID = notifiedPauseBundleID,
           let appName = pauseAppName(for: bundleID) {
            let eventName = launched ? "launch" : "terminate"
            log.write("pause app \(eventName) event name=\(appName) bundleID=\(bundleID) stateUnchanged")
        }

        if !launchedBundleIDs.isEmpty || !terminatedBundleIDs.isEmpty || notifiedPauseBundleID != nil {
            reconcileProductionPause()
        }
    }

    private var pauseReason: String? {
        let activePauseAppBundleIDs = runningPauseAppBundleIDs.subtracting(manuallyResumedPauseAppBundleIDs)
        let appNames = pauseApps.compactMap { app in
            activePauseAppBundleIDs.contains(app.bundleID) ? app.name : nil
        }
        let systemNames = SystemPauseReason.allCases.compactMap { reason in
            systemPauseReasons.contains(reason) ? reason.rawValue : nil
        }
        let names = appNames + systemNames
        return names.isEmpty ? nil : names.joined(separator: ", ")
    }

    private func pauseAppName(for bundleID: String) -> String? {
        pauseApps.first { $0.bundleID == bundleID }?.name
    }

    private var canManuallyResumePausedProduction: Bool {
        productionWanted &&
            !productionStartPending &&
            controller?.isRunning != true &&
            !runningPauseAppBundleIDs.subtracting(manuallyResumedPauseAppBundleIDs).isEmpty &&
            systemPauseReasons.isEmpty
    }

    private func reconcileProductionPause() {
        guard productionWanted else { return }

        if let reason = pauseReason {
            pauseProduction(reason: reason)
            startPauseReconcileTimerIfNeeded()
        } else if controller?.isRunning != true && !productionStartPending {
            stopPauseReconcileTimer()
            log.write("pause reasons cleared; resuming production")
            start(.production)
        } else {
            stopPauseReconcileTimer()
        }
    }

    private func pauseProduction(reason: String) {
        startPauseReconcileTimerIfNeeded()
        let status = "Paused: \(reason)"
        if controller?.isRunning == true || productionStartPending {
            log.write("pausing production reason=\(reason)")
            controller?.stop(status: status) { [weak self] in
                guard let self else { return }
                self.productionStartPending = false
                guard self.productionWanted, self.pauseReason == nil else { return }
                self.log.write("pause reasons cleared during stop; resuming production")
                self.start(.production)
            }
        } else {
            updateStatus(status, state: .empty)
        }
    }

    private func startPauseReconcileTimerIfNeeded() {
        guard pauseReconcileTimer == nil else { return }

        pauseReconcileTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] timer in
            guard let self else {
                timer.invalidate()
                return
            }
            guard self.productionWanted else {
                self.stopPauseReconcileTimer()
                return
            }

            let previousPauseReason = self.pauseReason
            let previousBundleIDs = self.runningPauseAppBundleIDs
            self.refreshRunningPauseApps()
            let launchedBundleIDs = self.runningPauseAppBundleIDs.subtracting(previousBundleIDs)
            let terminatedBundleIDs = previousBundleIDs.subtracting(self.runningPauseAppBundleIDs)
            self.clearManualPauseAppOverrides(terminatedBundleIDs: terminatedBundleIDs)
            self.logPauseAppChanges(launchedBundleIDs: launchedBundleIDs, terminatedBundleIDs: terminatedBundleIDs)
            let systemChanged = self.refreshObservableSystemPauseReasons(source: "pause timer")
            let pauseReasonChanged = previousPauseReason != self.pauseReason

            if !launchedBundleIDs.isEmpty ||
                !terminatedBundleIDs.isEmpty ||
                systemChanged ||
                pauseReasonChanged ||
                self.pauseReason == nil {
                self.reconcileProductionPause()
            }
        }
        pauseReconcileTimer?.tolerance = 0.5
    }

    private func stopPauseReconcileTimer() {
        pauseReconcileTimer?.invalidate()
        pauseReconcileTimer = nil
    }

    private func logPauseAppChanges(launchedBundleIDs: Set<String>, terminatedBundleIDs: Set<String>) {
        for bundleID in launchedBundleIDs.sorted() {
            if let appName = pauseAppName(for: bundleID) {
                log.write("pause app launched name=\(appName) bundleID=\(bundleID)")
            }
        }
        for bundleID in terminatedBundleIDs.sorted() {
            if let appName = pauseAppName(for: bundleID) {
                log.write("pause app terminated name=\(appName) bundleID=\(bundleID)")
            }
        }
    }

    private func manuallyResumeThroughRunningPauseApps() {
        let bundleIDs = runningPauseAppBundleIDs.subtracting(manuallyResumedPauseAppBundleIDs)
        guard !bundleIDs.isEmpty else { return }

        manuallyResumedPauseAppBundleIDs.formUnion(bundleIDs)
        let names = pauseAppNames(for: bundleIDs).joined(separator: ",")
        log.write("manual enable overriding pause apps names=\(names)")
    }

    private func clearManualPauseAppOverrides(terminatedBundleIDs: Set<String>) {
        let clearedBundleIDs = manuallyResumedPauseAppBundleIDs.intersection(terminatedBundleIDs)
        guard !clearedBundleIDs.isEmpty else { return }

        manuallyResumedPauseAppBundleIDs.subtract(clearedBundleIDs)
        let names = pauseAppNames(for: clearedBundleIDs).joined(separator: ",")
        log.write("manual pause app override cleared names=\(names)")
    }

    private func clearManualPauseAppOverrides(source: String) {
        guard !manuallyResumedPauseAppBundleIDs.isEmpty else { return }

        let names = pauseAppNames(for: manuallyResumedPauseAppBundleIDs).joined(separator: ",")
        manuallyResumedPauseAppBundleIDs.removeAll()
        log.write("manual pause app overrides cleared source=\(source) names=\(names)")
    }

    private func pauseAppNames(for bundleIDs: Set<String>) -> [String] {
        pauseApps.compactMap { app in
            bundleIDs.contains(app.bundleID) ? app.name : nil
        }
    }

    private func start(_ config: DetectionConfig, overrideCurrentPauseApps: Bool = false) {
        productionWanted = true
        if overrideCurrentPauseApps {
            manuallyResumeThroughRunningPauseApps()
        }
        refreshAirPodsProAudioSourceMonitoring(publishInitialState: false)
        guard controller?.isRunning != true else {
            log.write("production start skipped; already running")
            return
        }
        guard !productionStartPending else {
            log.write("production start skipped; already pending")
            return
        }
        if let reason = pauseReason {
            log.write("production start deferred reason=\(reason)")
            pauseProduction(reason: reason)
            return
        }

        productionStartPending = true
        updateStatus("Checking Camera", state: .empty)
        requestCameraAccess { [weak self] granted in
            guard let self else { return }
            guard self.productionWanted else {
                self.productionStartPending = false
                self.log.write("production start canceled before camera startup")
                self.updateStatus("Stopped", state: .empty)
                return
            }
            if let reason = self.pauseReason {
                self.productionStartPending = false
                self.log.write("production start deferred after camera check reason=\(reason)")
                self.pauseProduction(reason: reason)
                return
            }
            guard granted else {
                self.productionStartPending = false
                self.productionWanted = false
                self.log.write("camera permission denied")
                self.updateStatus("Camera Permission Denied", state: .empty)
                return
            }
            guard let controller = self.controller else {
                self.productionStartPending = false
                self.log.write("camera permission granted but controller unavailable")
                self.updateStatus("Start failed", state: .empty)
                return
            }
            self.log.write("camera permission granted; starting capture config=\(config.name)")
            controller.start(config: config) { [weak self] _ in
                self?.productionStartPending = false
            }
        }
    }

    private func updateStatus(_ status: String, state: HairAlertState) {
        statusMenuItem.title = "Status: \(status)"
        updateProductionToggleMenuItem(status: status)
        if state.active {
            startAlertIconFlash()
        } else if status == "Stopped" || status.hasPrefix("Paused:") {
            stopAlertIconFlash()
            configureStatusButton(
                statusItem?.button,
                symbolName: "hand.raised.slash",
                accessibilityDescription: status == "Stopped" ? "BodyPoseTracker Stopped" : "BodyPoseTracker Paused",
                tint: nil
            )
        } else {
            stopAlertIconFlash()
            configureStatusButton(
                statusItem?.button,
                symbolName: "hand.raised",
                accessibilityDescription: "BodyPoseTracker",
                tint: nil
            )
        }
    }

    private func updateProductionToggleMenuItem(status: String) {
        switch status {
        case "Stopped", "Camera Permission Denied", "Start failed":
            productionWanted = false
        default:
            break
        }
        syncProductionToggleMenuItem()
        syncEatingPauseMenuItem()
        refreshAirPodsProAudioSourceMonitoring(publishInitialState: false)
    }

    private func syncProductionToggleMenuItem() {
        if eatingPauseIsActive {
            productionToggleMenuItem.title = "Enable"
            productionToggleMenuItem.state = .off
            return
        }

        if canManuallyResumePausedProduction {
            productionToggleMenuItem.title = "Resume Anyway"
            productionToggleMenuItem.state = .off
            return
        }

        let enabled = productionWanted || productionStartPending || controller?.isRunning == true
        productionToggleMenuItem.title = enabled ? "Disable" : "Enable"
        productionToggleMenuItem.state = .off
    }

    private func syncEatingPauseMenuItem() {
        if let eatingPauseEndDate, eatingPauseIsActive {
            let remainingSeconds = max(0, eatingPauseEndDate.timeIntervalSinceNow)
            let remainingMinutes = max(1, Int(ceil(remainingSeconds / 60)))
            eatingPauseMenuItem.title = "Eating pause: \(remainingMinutes)m left"
            eatingPauseMenuItem.state = .on
            eatingPauseMenuItem.isEnabled = false
        } else {
            let enabled = productionWanted || productionStartPending || controller?.isRunning == true
            eatingPauseMenuItem.title = "I am eating!"
            eatingPauseMenuItem.state = .off
            eatingPauseMenuItem.isEnabled = enabled
        }
    }

    private var eatingPauseIsActive: Bool {
        systemPauseReasons.contains(.eating)
    }

    @objc private func toggleProduction() {
        if eatingPauseIsActive {
            cancelEatingPause(source: "manual enable")
            return
        }

        if canManuallyResumePausedProduction {
            start(.production, overrideCurrentPauseApps: true)
            return
        }

        if productionWanted || controller?.isRunning == true {
            stopProduction()
        } else {
            start(.production, overrideCurrentPauseApps: true)
        }
    }

    @objc private func startEatingPause() {
        guard productionWanted || productionStartPending || controller?.isRunning == true else { return }

        eatingPauseTimer?.invalidate()
        eatingPauseEndDate = Date(timeIntervalSinceNow: eatingPauseDuration)
        eatingPauseTimer = Timer.scheduledTimer(withTimeInterval: eatingPauseDuration, repeats: false) { [weak self] _ in
            self?.finishEatingPause()
        }
        eatingPauseTimer?.tolerance = eatingPauseTimerTolerance
        setSystemPauseReason(.eating, active: true, source: "eating button")
        syncProductionToggleMenuItem()
        syncEatingPauseMenuItem()
        log.write("eating pause started durationSeconds=\(Int(eatingPauseDuration))")
    }

    private func finishEatingPause() {
        eatingPauseTimer?.invalidate()
        eatingPauseTimer = nil
        eatingPauseEndDate = nil
        setSystemPauseReason(.eating, active: false, source: "eating timer")
        syncProductionToggleMenuItem()
        syncEatingPauseMenuItem()
        log.write("eating pause ended")
    }

    private func cancelEatingPause(source: String) {
        guard eatingPauseTimer != nil || eatingPauseEndDate != nil || systemPauseReasons.contains(.eating) else { return }

        eatingPauseTimer?.invalidate()
        eatingPauseTimer = nil
        eatingPauseEndDate = nil
        setSystemPauseReason(.eating, active: false, source: source)
        syncProductionToggleMenuItem()
        syncEatingPauseMenuItem()
        log.write("eating pause canceled source=\(source)")
    }

    private func stopProduction() {
        productionWanted = false
        productionStartPending = false
        clearManualPauseAppOverrides(source: "manual stop")
        cancelEatingPause(source: "manual stop")
        stopPauseReconcileTimer()
        updateStatus("Stopped", state: .empty)
        stopAlertIconFlash()
        controller?.stop()
    }

    private func startAlertIconFlash() {
        guard alertFlashTimer == nil else { return }
        pulseAlertIcon()
        alertFlashTimer = Timer.scheduledTimer(withTimeInterval: alertFlashPeriod, repeats: true) { [weak self] _ in
            self?.pulseAlertIcon()
        }
        alertFlashTimer?.tolerance = 0.04
    }

    private func stopAlertIconFlash() {
        alertFlashTimer?.invalidate()
        alertFlashTimer = nil
        alertFlashOffWorkItem?.cancel()
        alertFlashOffWorkItem = nil
    }

    private func pulseAlertIcon() {
        setAlertIconVisible(true)

        alertFlashOffWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.setAlertIconVisible(false)
        }
        alertFlashOffWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + alertFlashOnDuration, execute: workItem)
    }

    private func setAlertIconVisible(_ visible: Bool) {
        if visible {
            configureAlertBubbleButton()
        } else {
            configureAlertRestingButton()
        }
    }

    @objc private func toggleDebugPreview() {
        if let debugPreviewWindow {
            controller?.setDebugFrameHandler(nil)
            debugPreviewWindow.close()
            self.debugPreviewWindow = nil
            debugPreviewMenuItem.title = "Show Debug Preview"
            return
        }

        let preview = DebugPreviewWindowController()
        debugPreviewWindow = preview
        debugPreviewMenuItem.title = "Hide Debug Preview"
        preview.onHandFaceLimitChanged = { [weak self] limit in
            self?.controller?.setMaxHandFaceRatio(limit)
        }
        preview.onClose = { [weak self, weak preview] in
            guard let self else { return }
            if self.debugPreviewWindow === preview {
                self.controller?.setDebugFrameHandler(nil)
                self.debugPreviewWindow = nil
                self.debugPreviewMenuItem.title = "Show Debug Preview"
            }
        }
        controller?.setDebugFrameHandler { [weak preview] frame in
            DispatchQueue.main.async {
                preview?.update(frame: frame)
            }
        }
        preview.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)

        if !productionWanted && controller?.isRunning != true {
            start(.production)
        }
    }

    @objc private func quit() {
        controller?.setDebugFrameHandler(nil)
        debugPreviewWindow?.close()
        stopProduction()
        NSApp.terminate(nil)
    }
}

private let encouragementLines = [
    "You can do it! ✨",
    "Fight the urge...",
    "Hands stay gentle 💛",
    "Let it pass.",
    "Not this time!",
    "Ride it out 🌊",
    "Keep the streak!",
    "Soft hands now.",
    "You are steering.",
    "Breathe, hands down.",
    "Protect your progress.",
    "Win this moment!",
    "One clean minute.",
    "Future you cheers!",
    "Nope, not today.",
    "Urge detected, denied.",
    "Brain, we're busy.",
    "Tiny win loading...",
    "Back to keyboard!",
    "You've got this! 💪"
]

private let encouragementRotationInterval: TimeInterval = 3 * 60 * 60
private let encouragementQuietStartHour = 1
private let encouragementQuietEndHour = 8
private let eatingPauseDuration: TimeInterval = 30 * 60
private let eatingPauseTimerTolerance: TimeInterval = 5

private enum UserDefaultsKeys {
    static let autoEnableOnExternalPower = "autoEnableWhileCharging"
    static let autoEnableOnAirPodsPro = "autoEnableOnAirPodsPro"
    static let dailyStreakStartDate = "dailyStreakStartDate"
}

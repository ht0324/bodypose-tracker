import Foundation
import IOKit.ps

struct PowerState: Equatable {
    let isConnectedToExternalPower: Bool
    let isCharging: Bool

    var canAutoEnableOnExternalPower: Bool {
        isConnectedToExternalPower
    }
}

final class PowerStateMonitor {
    typealias Handler = (_ state: PowerState, _ source: String) -> Void

    private let onChange: Handler
    private var runLoopSource: CFRunLoopSource?
    private var lastState: PowerState?

    init(onChange: @escaping Handler) {
        self.onChange = onChange
    }

    deinit {
        stop()
    }

    func start() {
        let context = Unmanaged.passUnretained(self).toOpaque()
        if let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let monitor = Unmanaged<PowerStateMonitor>.fromOpaque(context).takeUnretainedValue()
            monitor.publishCurrentState(source: "notification")
        }, context)?.takeRetainedValue() {
            runLoopSource = source
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
        }

        DispatchQueue.main.async { [weak self] in
            self?.publishCurrentState(source: "startup")
        }
    }

    func stop() {
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .defaultMode)
        }
        runLoopSource = nil
    }

    func currentState() -> PowerState {
        let snapshot = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        let sources = IOPSCopyPowerSourcesList(snapshot).takeRetainedValue() as NSArray

        var connectedToExternalPower = false
        var charging = false

        for source in sources {
            guard let unmanagedDescription = IOPSGetPowerSourceDescription(snapshot, source as CFTypeRef) else {
                continue
            }
            let description = unmanagedDescription.takeUnretainedValue() as NSDictionary
            let powerSourceState = description[kIOPSPowerSourceStateKey] as? String
            let isCharging = description[kIOPSIsChargingKey] as? Bool == true

            connectedToExternalPower = connectedToExternalPower || powerSourceState == kIOPSACPowerValue
            charging = charging || isCharging
        }

        return PowerState(
            isConnectedToExternalPower: connectedToExternalPower,
            isCharging: charging
        )
    }

    private func publishCurrentState(source: String) {
        let state = currentState()
        guard state != lastState else { return }

        lastState = state
        onChange(state, source)
    }
}

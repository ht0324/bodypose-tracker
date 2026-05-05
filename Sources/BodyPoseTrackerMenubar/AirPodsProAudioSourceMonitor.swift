import CoreAudio
import Foundation

struct AirPodsProAudioSourceState: Equatable {
    let isActive: Bool
    let activeDeviceNames: [String]
    let connectedDeviceNames: [String]

    var canAutoEnableOnAirPodsPro: Bool {
        isActive
    }
}

final class AirPodsProAudioSourceMonitor {
    typealias Handler = (_ state: AirPodsProAudioSourceState, _ source: String) -> Void

    private let onChange: Handler
    private var registeredPropertySelectors: [AudioObjectPropertySelector] = []
    private var lastState: AirPodsProAudioSourceState?

    init(onChange: @escaping Handler) {
        self.onChange = onChange
    }

    deinit {
        stop()
    }

    func start(publishInitialState: Bool) {
        if registeredPropertySelectors.isEmpty {
            let context = Unmanaged.passUnretained(self).toOpaque()
            for selector in monitoredPropertySelectors {
                var address = audioHardwarePropertyAddress(selector)
                let status = AudioObjectAddPropertyListener(
                    AudioObjectID(kAudioObjectSystemObject),
                    &address,
                    Self.audioRouteChanged,
                    context
                )
                if status == noErr {
                    registeredPropertySelectors.append(selector)
                }
            }
        }

        if publishInitialState {
            DispatchQueue.main.async { [weak self] in
                self?.publishCurrentState(source: "startup", force: true)
            }
        } else if lastState == nil {
            lastState = currentState()
        }
    }

    func stop() {
        for selector in registeredPropertySelectors {
            var address = audioHardwarePropertyAddress(selector)
            let context = Unmanaged.passUnretained(self).toOpaque()
            AudioObjectRemovePropertyListener(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                Self.audioRouteChanged,
                context
            )
        }
        registeredPropertySelectors = []
        lastState = nil
    }

    func currentState() -> AirPodsProAudioSourceState {
        let connectedDeviceNames = audioDeviceIDs()
            .compactMap { deviceID -> String? in
                guard
                    isBluetoothAudioDevice(deviceID),
                    let name = audioDeviceName(for: deviceID),
                    matchesAirPodsPro(name)
                else {
                    return nil
                }
                return name
            }

        let activeDeviceNames = activeOutputDeviceIDs()
            .compactMap { deviceID -> String? in
                guard
                    isBluetoothAudioDevice(deviceID),
                    let name = audioDeviceName(for: deviceID),
                    matchesAirPodsPro(name)
                else {
                    return nil
                }
                return name
            }

        return AirPodsProAudioSourceState(
            isActive: !activeDeviceNames.isEmpty,
            activeDeviceNames: Array(Set(activeDeviceNames)).sorted(),
            connectedDeviceNames: Array(Set(connectedDeviceNames)).sorted()
        )
    }

    private func publishCurrentState(source: String, force: Bool = false) {
        let state = currentState()
        guard force || state != lastState else { return }

        lastState = state
        onChange(state, source)
    }

    private static let audioRouteChanged: AudioObjectPropertyListenerProc = { _, addressCount, addresses, context in
        guard let context else { return noErr }
        let monitor = Unmanaged<AirPodsProAudioSourceMonitor>.fromOpaque(context).takeUnretainedValue()
        let changedSelectors = UnsafeBufferPointer(start: addresses, count: Int(addressCount)).map(\.mSelector)
        let source = changedSelectors.contains(where: { $0 != kAudioHardwarePropertyDevices })
            ? "default-route"
            : "device-list"

        DispatchQueue.main.async {
            monitor.publishCurrentState(source: source)
        }
        return noErr
    }

    private func audioDeviceIDs() -> [AudioDeviceID] {
        var address = audioHardwarePropertyAddress(kAudioHardwarePropertyDevices)
        var dataSize: UInt32 = 0

        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize
        ) == noErr else {
            return []
        }

        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        guard count > 0 else { return [] }

        var devices = [AudioDeviceID](repeating: 0, count: count)
        let status = devices.withUnsafeMutableBufferPointer { buffer -> OSStatus in
            guard let baseAddress = buffer.baseAddress else { return noErr }
            return AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                0,
                nil,
                &dataSize,
                baseAddress
            )
        }

        return status == noErr ? devices : []
    }

    private var monitoredPropertySelectors: [AudioObjectPropertySelector] {
        [
            kAudioHardwarePropertyDevices,
            kAudioHardwarePropertyDefaultOutputDevice,
            kAudioHardwarePropertyDefaultSystemOutputDevice
        ]
    }

    private func activeOutputDeviceIDs() -> [AudioDeviceID] {
        [
            defaultAudioDeviceID(for: kAudioHardwarePropertyDefaultOutputDevice),
            defaultAudioDeviceID(for: kAudioHardwarePropertyDefaultSystemOutputDevice)
        ]
        .compactMap { $0 }
    }

    private func defaultAudioDeviceID(for selector: AudioObjectPropertySelector) -> AudioDeviceID? {
        var address = audioHardwarePropertyAddress(selector)
        var deviceID = AudioDeviceID(0)
        var dataSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize,
            &deviceID
        )

        guard status == noErr, deviceID != 0 else { return nil }
        return deviceID
    }

    private func audioHardwarePropertyAddress(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private func audioDeviceName(for deviceID: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceNameCFString,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: CFString?
        var dataSize = UInt32(MemoryLayout<CFString?>.size)
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, $0)
        }

        guard status == noErr, let value else { return nil }
        return value as String
    }

    private func isBluetoothAudioDevice(_ deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var transportType: UInt32 = 0
        var dataSize = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, &transportType)

        return status == noErr && transportType == kAudioDeviceTransportTypeBluetooth
    }

    private func matchesAirPodsPro(_ name: String) -> Bool {
        let normalized = name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        return normalized.contains("airpods pro")
    }
}

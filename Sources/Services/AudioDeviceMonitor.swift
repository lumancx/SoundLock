import CoreAudio
import Foundation

// ---------------------------------------------------------------------------
// CoreAudio C callbacks need a free function pointer, so we keep a weak
// module-private reference to the live monitor. CoreAudio fires these on its
// own thread; we always hop to main before touching observable state.
// ---------------------------------------------------------------------------
private weak var _sharedMonitor: AudioDeviceMonitor?

private let _outputListener: AudioObjectPropertyListenerProc = { _, _, _, _ in
    DispatchQueue.main.async { _sharedMonitor?.handleDeviceChange(input: false) }
    return noErr
}
private let _inputListener: AudioObjectPropertyListenerProc = { _, _, _, _ in
    DispatchQueue.main.async { _sharedMonitor?.handleDeviceChange(input: true) }
    return noErr
}
private let _devicesListener: AudioObjectPropertyListenerProc = { _, _, _, _ in
    DispatchQueue.main.async { _sharedMonitor?.handleDeviceListChange() }
    return noErr
}

struct AudioHardware {
    var enumerate: () -> (output: [AudioDevice], input: [AudioDevice])
    var getDefault: (_ input: Bool) -> AudioDeviceID
    var setDefault: (_ id: AudioDeviceID, _ input: Bool) -> OSStatus
    var isAirPlay: (_ id: AudioDeviceID) -> Bool = { _ in false }

    static let coreAudio = AudioHardware(
        enumerate: CoreAudioBridge.enumeratePhysicalDevices,
        getDefault: { CoreAudioBridge.getDefaultDevice(input: $0) },
        setDefault: { CoreAudioBridge.setDefaultDevice($0, input: $1) },
        isAirPlay: CoreAudioBridge.isAirPlay
    )
}

/// Orchestrator: owns device lists + priority lists, registers CoreAudio
/// listeners, asserts priority, and forwards volume/mute sync to the
/// dedicated services.
final class AudioDeviceMonitor: ObservableObject {

    // MARK: - Published state

    @Published var outputDevices: [AudioDevice] = []
    @Published var inputDevices: [AudioDevice] = []
    @Published private(set) var defaultOutputID: AudioDeviceID = 0

    @Published var priorityOutputList: [PriorityDevice] = [] {
        didSet { repository.scheduleSaveOutputs(priorityOutputList) }
    }
    @Published var priorityInputList: [PriorityDevice] = [] {
        didSet { repository.scheduleSaveInputs(priorityInputList) }
    }

    @Published var guardEnabled: Bool = false {
        didSet {
            UserDefaults.standard.set(guardEnabled, forKey: Constants.DefaultsKey.guardEnabled)
            if guardEnabled {
                assertPriority(input: false)
                assertPriority(input: true)
            }
        }
    }

    /// The default output when it is an AirPlay device, else nil.
    @Published private(set) var activeAirPlayOutput: AudioDevice?

    // MARK: - Dependencies

    let volume: AudioVolumeService
    let mute: AudioMuteService
    private let repository: PriorityListRepository
    private let hardware: AudioHardware

    // MARK: - Property addresses (stored once)

    private var outputAddr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: 0)
    private var inputAddr  = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,  mScope: kAudioObjectPropertyScopeGlobal, mElement: 0)
    private var devicesAddr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,            mScope: kAudioObjectPropertyScopeGlobal, mElement: 0)

    // BT-retry work items — cancelled on every new device-list event so rapid
    // connect/disconnect cycles don't pile up stale closures on the main queue.
    private var retryItems: [DispatchWorkItem] = []

    var onNewOutputDevice: ((AudioDevice) -> Void)?
    private var hasEnumerated = false
    var promptsSuppressedUntil = Date.distantPast

    // MARK: - Computed

    var currentPriorityOutput: AudioDevice? {
        topConnected(list: priorityOutputList, in: outputDevices, input: false)
    }
    var currentPriorityInput: AudioDevice? {
        topConnected(list: priorityInputList, in: inputDevices, input: true)
    }
    /// Output the popover shows and controls: the device the user hears.
    var displayedOutput: AudioDevice? {
        activeAirPlayOutput ?? currentPriorityOutput
    }

    // MARK: - Init

    init(volume: AudioVolumeService, mute: AudioMuteService, repository: PriorityListRepository, hardware: AudioHardware = .coreAudio) {
        self.volume = volume
        self.mute = mute
        self.repository = repository
        self.hardware = hardware
        self.guardEnabled = UserDefaults.standard.object(forKey: Constants.DefaultsKey.guardEnabled) as? Bool ?? true
        self.priorityOutputList = repository.loadOutputs()
        self.priorityInputList = repository.loadInputs()
    }

    // MARK: - Monitoring lifecycle

    func startMonitoring() {
        _sharedMonitor = self
        refreshDevices()
        // Assert immediately so changes made while the app was closed or the
        // guard was off are corrected before the first UI frame.
        assertPriority(input: false)
        assertPriority(input: true)
        let sys = AudioObjectID(kAudioObjectSystemObject)
        AudioObjectAddPropertyListener(sys, &outputAddr,  _outputListener,  nil)
        AudioObjectAddPropertyListener(sys, &inputAddr,   _inputListener,   nil)
        AudioObjectAddPropertyListener(sys, &devicesAddr, _devicesListener, nil)
    }

    func stopMonitoring() {
        retryItems.forEach { $0.cancel() }
        retryItems.removeAll()
        repository.cancelPending()
        let sys = AudioObjectID(kAudioObjectSystemObject)
        AudioObjectRemovePropertyListener(sys, &outputAddr,  _outputListener,  nil)
        AudioObjectRemovePropertyListener(sys, &inputAddr,   _inputListener,   nil)
        AudioObjectRemovePropertyListener(sys, &devicesAddr, _devicesListener, nil)
        _sharedMonitor = nil
    }

    // MARK: - Device refresh

    func refreshDevices() {
        let (out, inp) = hardware.enumerate()
        let previousOutputUIDs = Set(outputDevices.map(\.uid))
        let isInitial = !hasEnumerated
        hasEnumerated = true
        outputDevices = out
        inputDevices = inp
        reconcilePriorityLists()
        syncAudioState()

        guard !isInitial, Date() >= promptsSuppressedUntil else { return }
        for device in out where !previousOutputUIDs.contains(device.uid) {
            // An AirPlay device appears only once the user has selected it.
            if device.isAirPlay { continue }
            if guardEnabled && currentPriorityOutput?.uid == device.uid { continue }
            if !guardEnabled && hardware.getDefault(false) == device.id { continue }
            onNewOutputDevice?(device)
        }
    }

    func pairedInput(for output: AudioDevice) -> AudioDevice? {
        if let sameDevice = inputDevices.first(where: { $0.uid == output.uid }) { return sameDevice }
        if output.uid.hasSuffix(":output") {
            let inputUID = output.uid.dropLast(":output".count) + ":input"
            return inputDevices.first { $0.uid == inputUID }
        }
        return inputDevices.first { !output.modelUID.isEmpty && $0.modelUID == output.modelUID && $0.name == output.name }
    }

    func switchTo(_ device: AudioDevice, input: Bool) {
        guard let live = (input ? inputDevices : outputDevices).first(where: { $0.uid == device.uid }) else { return }
        let list: ReferenceWritableKeyPath<AudioDeviceMonitor, [PriorityDevice]> = input ? \.priorityInputList : \.priorityOutputList
        self[keyPath: list].removeAll { AudioDeviceIdentityResolver.matchDevice(for: $0, in: [live], input: input) != nil }
        self[keyPath: list].insert(PriorityDevice(device: live, input: input), at: 0)
        let err = hardware.setDefault(live.id, input)
        if err != noErr {
            NSLog("[SoundLock] setDefault failed (input=%d, deviceID=%d): OSStatus %d", input, live.id, err)
        }
        syncAudioState()
    }

    // MARK: - Priority list CRUD

    func addToPriority(_ device: AudioDevice, input: Bool) {
        if input {
            guard !AudioDeviceIdentityResolver.isRepresented(device, in: priorityInputList, input: true) else { return }
            priorityInputList.append(PriorityDevice(device: device, input: true))
        } else {
            guard !AudioDeviceIdentityResolver.isRepresented(device, in: priorityOutputList, input: false) else { return }
            priorityOutputList.append(PriorityDevice(device: device, input: false))
        }
        assertPriority(input: input)
        syncAudioState()
    }

    func removeFromPriority(stableKey: String, input: Bool) {
        if input { priorityInputList.removeAll { $0.identityKey(input: true) == stableKey } }
        else      { priorityOutputList.removeAll { $0.identityKey(input: false) == stableKey } }
        assertPriority(input: input)
        syncAudioState()
    }

    func movePriority(from: IndexSet, to: Int, input: Bool) {
        if input { priorityInputList.move(fromOffsets: from, toOffset: to) }
        else      { priorityOutputList.move(fromOffsets: from, toOffset: to) }
        assertPriority(input: input)
        syncAudioState()
    }

    func isRepresentedInPriority(_ device: AudioDevice, input: Bool) -> Bool {
        AudioDeviceIdentityResolver.isRepresented(
            device,
            in: input ? priorityInputList : priorityOutputList,
            input: input
        )
    }

    func isPriorityDeviceConnected(_ entry: PriorityDevice, input: Bool) -> Bool {
        AudioDeviceIdentityResolver.matchDevice(
            for: entry,
            in: input ? inputDevices : outputDevices,
            input: input
        ) != nil
    }

    // MARK: - Listener callbacks

    func handleDeviceChange(input: Bool) {
        assertPriority(input: input)
        syncAudioState()
        if !input {
            let current = hardware.getDefault(false)
            if current != defaultOutputID { defaultOutputID = current }
        }
    }

    func handleDeviceListChange() {
        retryItems.forEach { $0.cancel() }
        retryItems.removeAll()

        refreshDevices()
        assertPriority(input: false)
        assertPriority(input: true)

        // Cover macOS's delayed BT auto-switch (fires 1-3 s after pairing).
        // First retry re-enumerates so newly assigned IDs are picked up.
        for (index, delay) in Constants.Timing.btRecoveryDelays.enumerated() {
            let shouldRefresh = (index == 0)
            let item = DispatchWorkItem { [weak self] in
                guard let self else { return }
                if shouldRefresh { self.refreshDevices() }
                guard self.guardEnabled else { return }
                self.assertPriority(input: false)
                self.assertPriority(input: true)
            }
            retryItems.append(item)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
        }
    }

    // MARK: - Private

    private func syncAudioState() {
        updateActiveAirPlayOutput()
        volume.syncFromDevices(output: displayedOutput, input: currentPriorityInput)
        mute.syncFromDevices(output: displayedOutput, input: currentPriorityInput)
    }

    private func updateActiveAirPlayOutput() {
        let current = hardware.getDefault(false)
        var next: AudioDevice? = nil
        if hardware.isAirPlay(current) {
            // The default can change before the device list event arrives.
            next = outputDevices.first { $0.id == current }
                ?? hardware.enumerate().output.first { $0.id == current }
        }
        if next != activeAirPlayOutput { activeAirPlayOutput = next }
    }

    private func assertPriority(input: Bool) {
        guard guardEnabled else { return }
        let list      = input ? priorityInputList : priorityOutputList
        let connected = input ? inputDevices       : outputDevices
        guard let bestEntry = list.first(where: { AudioDeviceIdentityResolver.matchDevice(for: $0, in: connected, input: input) != nil }),
              let bestDevice = AudioDeviceIdentityResolver.matchDevice(for: bestEntry, in: connected, input: input)
        else { return }
        let current = hardware.getDefault(input)
        // Keep an AirPlay output: macOS never selects AirPlay on its own, so the user chose it.
        if !input, hardware.isAirPlay(current) { return }
        if current != bestDevice.id {
            let err = hardware.setDefault(bestDevice.id, input)
            if err != noErr {
                NSLog("[SoundLock] setDefault failed (input=%d, deviceID=%d): OSStatus %d", input, bestDevice.id, err)
            }
        }
    }

    private func reconcilePriorityLists() {
        let nextOutputs = AudioDeviceIdentityResolver.reconcile(priorityOutputList, with: outputDevices, input: false) { message in
            NSLog("%@", message)
        }
        if nextOutputs != priorityOutputList {
            priorityOutputList = nextOutputs
        }

        let nextInputs = AudioDeviceIdentityResolver.reconcile(priorityInputList, with: inputDevices, input: true) { message in
            NSLog("%@", message)
        }
        if nextInputs != priorityInputList {
            priorityInputList = nextInputs
        }
    }

    private func topConnected(list: [PriorityDevice], in devices: [AudioDevice], input: Bool) -> AudioDevice? {
        guard let best = list.first(where: { AudioDeviceIdentityResolver.matchDevice(for: $0, in: devices, input: input) != nil }) else { return nil }
        return AudioDeviceIdentityResolver.matchDevice(for: best, in: devices, input: input)
    }
}

import AppKit
import CoreAudio
import Foundation

private var failures = 0
private var passes = 0

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if condition() {
        passes += 1
    } else {
        failures += 1
        fputs("FAIL: \(message)\n", stderr)
    }
}

private func drain(_ seconds: TimeInterval) {
    RunLoop.main.run(until: Date().addingTimeInterval(seconds))
}

private func device(_ id: AudioDeviceID, _ uid: String, _ name: String, model: String,
                    transport: UInt32, output: Bool) -> AudioDevice {
    AudioDevice(id: id, uid: uid, name: name, modelUID: model, manufacturer: "Test",
                transportType: transport, supportsOutput: output, supportsInput: !output)
}

private let speakers = device(129, "BuiltInSpeakerDevice", "MacBook Pro Speakers", model: "Speaker", transport: kAudioDeviceTransportTypeBuiltIn, output: true)
private let builtInMic = device(136, "BuiltInMicrophoneDevice", "MacBook Pro Microphone", model: "Digital Mic", transport: kAudioDeviceTransportTypeBuiltIn, output: false)
private let robertaOut = device(141, "E4-43-89-32-15-EB:output", "AirPods de Roberta II", model: "2019 4c", transport: kAudioDeviceTransportTypeBluetooth, output: true)
private let robertaIn = device(147, "E4-43-89-32-15-EB:input", "AirPods de Roberta II", model: "2019 4c", transport: kAudioDeviceTransportTypeBluetooth, output: false)
private let lucasOut = device(151, "AA-BB-CC-DD-EE-FF:output", "AirPods do Lucas", model: "2019 4c", transport: kAudioDeviceTransportTypeBluetooth, output: true)
private let lucasIn = device(152, "AA-BB-CC-DD-EE-FF:input", "AirPods do Lucas", model: "2019 4c", transport: kAudioDeviceTransportTypeBluetooth, output: false)
private let monitorHDMI = device(160, "HDMI-LG-27", "LG UltraFine", model: "LG27", transport: kAudioDeviceTransportTypeHDMI, output: true)
private let airPlay = device(180, "AirPlay-Test-Audio", "AirPlay", model: "AirPlay-Test-Audio", transport: kAudioDeviceTransportTypeAirPlay, output: true)
private let usbMic = device(170, "USB-fifine", "fifine Microphone", model: "fifine", transport: kAudioDeviceTransportTypeUSB, output: false)

private final class Rig {
    var outputs: [AudioDevice]
    var inputs: [AudioDevice]
    var defaultOutput: AudioDeviceID
    var defaultInput: AudioDeviceID
    var setCalls: [(id: AudioDeviceID, input: Bool)] = []
    var prompts: [AudioDevice] = []
    var monitor: AudioDeviceMonitor!
    let prompter = NewDevicePromptController()
    var promptsEnabled = true

    init(outputs: [AudioDevice], inputs: [AudioDevice],
         outputPriority: [AudioDevice] = [], inputPriority: [AudioDevice] = [],
         guardOn: Bool = true) {
        self.outputs = outputs
        self.inputs = inputs
        defaultOutput = outputs.first?.id ?? 0
        defaultInput = inputs.first?.id ?? 0
        UserDefaults.standard.set(guardOn, forKey: Constants.DefaultsKey.guardEnabled)
        UserDefaults.standard.removeObject(forKey: Constants.DefaultsKey.priorityOutputList)
        UserDefaults.standard.removeObject(forKey: Constants.DefaultsKey.priorityInputList)

        let hardware = AudioHardware(
            enumerate: { [unowned self] in (self.outputs, self.inputs) },
            getDefault: { [unowned self] input in input ? self.defaultInput : self.defaultOutput },
            setDefault: { [unowned self] id, input in
                let live = (input ? self.inputs : self.outputs).contains { $0.id == id }
                guard live else { return kAudioHardwareBadDeviceError }
                self.setCalls.append((id, input))
                if input { self.defaultInput = id } else { self.defaultOutput = id }
                return noErr
            },
            isAirPlay: { [unowned self] id in self.outputs.contains { $0.id == id && $0.isAirPlay } }
        )
        monitor = AudioDeviceMonitor(volume: AudioVolumeService(), mute: AudioMuteService(),
                                     repository: PriorityListRepository(), hardware: hardware)
        monitor.priorityOutputList = outputPriority.map { PriorityDevice(device: $0, input: false) }
        monitor.priorityInputList = inputPriority.map { PriorityDevice(device: $0, input: true) }
        monitor.onNewOutputDevice = { [unowned self] device in
            self.prompts.append(device)
            guard self.promptsEnabled else { return }
            self.prompter.prompt(for: device, monitor: self.monitor, below: nil)
        }
        monitor.refreshDevices()
        monitor.handleDeviceChange(input: false)
        monitor.handleDeviceChange(input: true)
    }

    func connect(_ devices: AudioDevice..., settle: TimeInterval = 4) {
        for d in devices {
            if d.supportsOutput { outputs.append(d) } else { inputs.append(d) }
        }
        monitor.handleDeviceListChange()
        drain(settle)
    }

    func disconnect(_ devices: AudioDevice..., settle: TimeInterval = 4) {
        let uids = Set(devices.map(\.uid))
        outputs.removeAll { uids.contains($0.uid) }
        inputs.removeAll { uids.contains($0.uid) }
        if !outputs.contains(where: { $0.id == defaultOutput }) { defaultOutput = outputs.first?.id ?? 0 }
        if !inputs.contains(where: { $0.id == defaultInput }) { defaultInput = inputs.first?.id ?? 0 }
        monitor.handleDeviceListChange()
        drain(settle)
    }

    func osSwitchesDefault(to device: AudioDevice) {
        if device.supportsOutput { defaultOutput = device.id } else { defaultInput = device.id }
        monitor.handleDeviceChange(input: !device.supportsOutput)
    }

    /// macOS adds the AirPlay device and makes it default in one step.
    func userSelectsAirPlay(settle: TimeInterval = 4) {
        outputs.append(airPlay)
        defaultOutput = airPlay.id
        monitor.handleDeviceChange(input: false)
        monitor.handleDeviceListChange()
        drain(settle)
    }

    func outputOrder() -> [String] { monitor.priorityOutputList.map(\.name) }
    func inputOrder() -> [String] { monitor.priorityInputList.map(\.name) }

    func click(_ button: PromptButton) {
        guard let panel = prompter.panel else { return }
        let point = NSPoint(x: button.x, y: panel.frame.height - button.yFromTop)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                                           timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: panel.windowNumber, context: nil,
                                           eventNumber: 0, clickCount: 1, pressure: 1)!
            panel.sendEvent(event)
        }
        drain(0.3)
    }

    func tearDown() {
        prompter.dismiss()
        monitor.stopMonitoring()
        drain(0.1)
    }
}

private enum PromptButton {
    case switchOutput, outputAndInput, close
    var x: CGFloat {
        switch self {
        case .switchOutput: return 93
        case .outputAndInput: return 197
        case .close: return 276
        }
    }
    var yFromTop: CGFloat {
        switch self {
        case .switchOutput, .outputAndInput: return 66
        case .close: return 23
        }
    }
}

private func scenario(_ name: String, _ body: () -> Void) {
    let before = failures
    body()
    print("\(failures == before ? "ok  " : "FAIL") \(name)")
}

private func runScenarios() {
    scenario("startup enumeration never prompts") {
        let rig = Rig(outputs: [speakers, robertaOut], inputs: [builtInMic, robertaIn], outputPriority: [speakers])
        drain(0.2)
        expect(rig.prompts.isEmpty, "no prompt for devices present at launch")
        rig.tearDown()
    }

    scenario("new output not in priority list prompts once (BT retries don't duplicate)") {
        let rig = Rig(outputs: [speakers], inputs: [builtInMic], outputPriority: [speakers])
        rig.promptsEnabled = false
        rig.connect(robertaOut, robertaIn)
        expect(rig.prompts.map(\.uid) == [robertaOut.uid], "exactly one prompt, got \(rig.prompts.map(\.name))")
        expect(rig.defaultOutput == speakers.id, "guard keeps speakers until user decides")
        rig.tearDown()
    }

    scenario("input-only device never prompts") {
        let rig = Rig(outputs: [speakers], inputs: [builtInMic], outputPriority: [speakers])
        rig.promptsEnabled = false
        rig.connect(usbMic)
        expect(rig.prompts.isEmpty, "input-only connect must not prompt")
        rig.tearDown()
    }

    scenario("guard on + new device already #1 → auto-switch, no prompt") {
        let rig = Rig(outputs: [speakers], inputs: [builtInMic], outputPriority: [robertaOut, speakers])
        rig.promptsEnabled = false
        rig.connect(robertaOut, robertaIn)
        expect(rig.prompts.isEmpty, "top-priority device is switched by guard, no prompt")
        expect(rig.defaultOutput == robertaOut.id, "guard switched to top-priority device")
        rig.tearDown()
    }

    scenario("guard off + new device already #1 → prompts (nothing auto-switches)") {
        let rig = Rig(outputs: [speakers], inputs: [builtInMic], outputPriority: [robertaOut, speakers], guardOn: false)
        rig.promptsEnabled = false
        rig.connect(robertaOut, robertaIn)
        expect(rig.prompts.map(\.uid) == [robertaOut.uid], "prompt when guard off")
        rig.tearDown()
    }

    scenario("device ranked below #1 prompts") {
        let rig = Rig(outputs: [speakers], inputs: [builtInMic], outputPriority: [speakers, robertaOut])
        rig.promptsEnabled = false
        rig.connect(robertaOut, robertaIn)
        expect(rig.prompts.count == 1, "lower-ranked device prompts")
        rig.tearDown()
    }

    scenario("BT late arrival: device shows up only on retry refresh → one prompt") {
        let rig = Rig(outputs: [speakers], inputs: [builtInMic], outputPriority: [speakers])
        rig.promptsEnabled = false
        rig.monitor.handleDeviceListChange()
        rig.outputs.append(robertaOut)
        rig.inputs.append(robertaIn)
        drain(4)
        expect(rig.prompts.map(\.uid) == [robertaOut.uid], "late device prompted once, got \(rig.prompts.count)")
        rig.tearDown()
    }

    scenario("disconnect + reconnect prompts again; disconnect alone never prompts") {
        let rig = Rig(outputs: [speakers], inputs: [builtInMic], outputPriority: [speakers])
        rig.promptsEnabled = false
        rig.connect(robertaOut, robertaIn)
        rig.disconnect(robertaOut, robertaIn)
        expect(rig.prompts.count == 1, "disconnect must not prompt")
        rig.connect(robertaOut, robertaIn)
        expect(rig.prompts.count == 2, "reconnect prompts again")
        rig.tearDown()
    }

    scenario("two devices at once prompt each; panel shows the latest only") {
        let rig = Rig(outputs: [speakers], inputs: [builtInMic], outputPriority: [speakers])
        rig.connect(robertaOut, monitorHDMI, settle: 0.3)
        expect(Set(rig.prompts.map(\.uid)) == [robertaOut.uid, monitorHDMI.uid], "one prompt per new output")
        expect(NSApp.windows.filter { $0.isVisible && $0 is NSPanel }.count == 1, "single panel visible")
        rig.tearDown()
    }

    scenario("pairing: BT output pairs with its own :input by model+name") {
        let rig = Rig(outputs: [speakers, robertaOut, lucasOut], inputs: [builtInMic, lucasIn, robertaIn])
        expect(rig.monitor.pairedInput(for: robertaOut)?.uid == robertaIn.uid, "Roberta → Roberta mic")
        expect(rig.monitor.pairedInput(for: lucasOut)?.uid == lucasIn.uid, "same model, different name → own mic")
        expect(rig.monitor.pairedInput(for: monitorHDMI) == nil, "output-only device has no pair")
        expect(rig.monitor.pairedInput(for: speakers) == nil, "speakers don't pair with built-in mic")
        rig.tearDown()
    }

    scenario("pairing: device exposing both directions under one uid") {
        let combo = AudioDevice(id: 180, uid: "USB-headset", name: "USB Headset", modelUID: "hs", manufacturer: "T",
                                transportType: kAudioDeviceTransportTypeUSB, supportsOutput: true, supportsInput: true)
        let rig = Rig(outputs: [speakers, combo], inputs: [builtInMic, combo])
        expect(rig.monitor.pairedInput(for: combo)?.uid == combo.uid, "same-uid pairing")
        rig.tearDown()
    }

    scenario("UI: panel appears in front, above normal windows, with buttons; auto-dismisses after 5s") {
        let rig = Rig(outputs: [speakers], inputs: [builtInMic], outputPriority: [speakers])
        rig.connect(robertaOut, robertaIn, settle: 0.3)
        let panel = rig.prompter.panel
        expect(panel?.isVisible == true, "panel visible")
        expect((panel?.level.rawValue ?? 0) > NSWindow.Level.statusBar.rawValue, "panel above status bar / popover level")
        expect(panel?.isKeyWindow == false, "panel must not steal keyboard focus")
        drain(Constants.Timing.newDevicePromptDuration + 0.5)
        expect(rig.prompter.panel == nil, "auto-dismissed after timeout")
        expect(rig.defaultOutput == speakers.id, "timeout keeps current device")
        expect(rig.outputOrder().first == speakers.name, "timeout keeps priority list")
        rig.tearDown()
    }

    scenario("UI: ✕ keeps everything as is, and guard reverts macOS auto-switch") {
        let rig = Rig(outputs: [speakers], inputs: [builtInMic], outputPriority: [speakers], inputPriority: [builtInMic])
        rig.connect(robertaOut, robertaIn, settle: 0.3)
        rig.click(.close)
        expect(rig.prompter.panel == nil, "✕ closes panel")
        rig.osSwitchesDefault(to: robertaOut)
        expect(rig.defaultOutput == speakers.id, "guard reverted macOS auto-switch")
        expect(rig.outputOrder() == [speakers.name], "list untouched")
        rig.tearDown()
    }

    scenario("UI: Switch Output → output #1 + default, input untouched, guard holds it") {
        let rig = Rig(outputs: [speakers], inputs: [builtInMic], outputPriority: [speakers], inputPriority: [builtInMic])
        rig.connect(robertaOut, robertaIn, settle: 0.3)
        rig.click(.switchOutput)
        expect(rig.prompter.panel == nil, "panel closes after switching")
        expect(rig.defaultOutput == robertaOut.id, "default output = AirPods")
        expect(rig.defaultInput == builtInMic.id, "input untouched")
        expect(rig.outputOrder() == [robertaOut.name, speakers.name], "AirPods promoted to #1, got \(rig.outputOrder())")
        expect(rig.inputOrder() == [builtInMic.name], "input list untouched")
        drain(4)
        rig.monitor.handleDeviceChange(input: false)
        expect(rig.defaultOutput == robertaOut.id, "guard keeps AirPods after retries")
        rig.tearDown()
    }

    scenario("UI: Output & Input → both promoted and defaulted") {
        let rig = Rig(outputs: [speakers], inputs: [builtInMic], outputPriority: [speakers], inputPriority: [builtInMic])
        rig.connect(robertaOut, robertaIn, settle: 0.3)
        rig.click(.outputAndInput)
        expect(rig.defaultOutput == robertaOut.id, "default output = AirPods")
        expect(rig.defaultInput == robertaIn.id, "default input = AirPods mic")
        expect(rig.inputOrder() == [robertaIn.name, builtInMic.name], "mic promoted, got \(rig.inputOrder())")
        rig.tearDown()
    }

    scenario("switch moves an existing lower-ranked entry instead of duplicating it") {
        let rig = Rig(outputs: [speakers], inputs: [builtInMic], outputPriority: [speakers, monitorHDMI, robertaOut])
        rig.connect(robertaOut, robertaIn, settle: 0.3)
        rig.click(.switchOutput)
        expect(rig.outputOrder() == [robertaOut.name, speakers.name, monitorHDMI.name], "no duplicate, got \(rig.outputOrder())")
        rig.tearDown()
    }

    scenario("switch after device re-enumerated with a new id uses the live id") {
        let rig = Rig(outputs: [speakers], inputs: [builtInMic], outputPriority: [speakers])
        rig.connect(robertaOut, robertaIn, settle: 0.3)
        let reborn = device(999, robertaOut.uid, robertaOut.name, model: robertaOut.modelUID, transport: kAudioDeviceTransportTypeBluetooth, output: true)
        rig.outputs = [speakers, reborn]
        rig.monitor.refreshDevices()
        rig.click(.switchOutput)
        expect(rig.defaultOutput == 999, "switched using live id 999, got \(rig.defaultOutput)")
        rig.tearDown()
    }

    scenario("manual Refresh with no hardware change never prompts") {
        let rig = Rig(outputs: [speakers, robertaOut], inputs: [builtInMic, robertaIn], outputPriority: [speakers])
        rig.promptsEnabled = false
        rig.monitor.refreshDevices()
        rig.monitor.refreshDevices()
        expect(rig.prompts.isEmpty, "refresh alone must not prompt")
        rig.tearDown()
    }

    scenario("staggered connects inside BT retry window prompt once each") {
        let rig = Rig(outputs: [speakers], inputs: [builtInMic], outputPriority: [speakers])
        rig.promptsEnabled = false
        rig.connect(robertaOut, robertaIn, settle: 1)
        rig.connect(monitorHDMI, settle: 4)
        expect(rig.prompts.map(\.uid) == [robertaOut.uid, monitorHDMI.uid], "got \(rig.prompts.map(\.name))")
        rig.tearDown()
    }

    scenario("flapping connect/disconnect/connect → latest prompt only on screen") {
        let rig = Rig(outputs: [speakers], inputs: [builtInMic], outputPriority: [speakers])
        rig.connect(robertaOut, robertaIn, settle: 0.1)
        rig.disconnect(robertaOut, robertaIn, settle: 0.1)
        rig.connect(lucasOut, lucasIn, settle: 0.3)
        expect(NSApp.windows.filter { $0.isVisible && $0 is NSPanel }.count == 1, "one panel")
        rig.click(.switchOutput)
        expect(rig.defaultOutput == lucasOut.id, "switch acts on latest device")
        rig.tearDown()
    }

    scenario("wired device reconnecting with rotated uid and already #1 → no prompt") {
        let dac = device(200, "USB-DAC-uid-A", "Schiit DAC", model: "schiit-1", transport: kAudioDeviceTransportTypeUSB, output: true)
        let dacRotated = device(201, "USB-DAC-uid-B", "Schiit DAC", model: "schiit-1", transport: kAudioDeviceTransportTypeUSB, output: true)
        let rig = Rig(outputs: [speakers], inputs: [builtInMic], outputPriority: [dac, speakers])
        rig.promptsEnabled = false
        rig.connect(dacRotated)
        expect(rig.prompts.isEmpty, "identity match by model keeps it #1, got \(rig.prompts.map(\.uid))")
        expect(rig.defaultOutput == dacRotated.id, "guard switched to rotated DAC")
        rig.tearDown()
    }

    scenario("empty priority list: switch adds device as the only entry") {
        let rig = Rig(outputs: [speakers], inputs: [builtInMic])
        rig.connect(robertaOut, robertaIn, settle: 0.3)
        expect(rig.prompts.count == 1, "prompts with empty list")
        rig.click(.switchOutput)
        expect(rig.outputOrder() == [robertaOut.name], "got \(rig.outputOrder())")
        expect(rig.defaultOutput == robertaOut.id, "switched")
        rig.tearDown()
    }

    scenario("switch to A then to B: B #1, A #2, no duplicates") {
        let rig = Rig(outputs: [speakers], inputs: [builtInMic], outputPriority: [speakers])
        rig.connect(robertaOut, robertaIn, settle: 0.3)
        rig.click(.switchOutput)
        rig.connect(monitorHDMI, settle: 0.3)
        rig.click(.switchOutput)
        expect(rig.outputOrder() == [monitorHDMI.name, robertaOut.name, speakers.name], "got \(rig.outputOrder())")
        expect(rig.defaultOutput == monitorHDMI.id, "default = latest choice")
        rig.tearDown()
    }

    scenario("double click on Switch is harmless") {
        let rig = Rig(outputs: [speakers], inputs: [builtInMic], outputPriority: [speakers])
        rig.connect(robertaOut, robertaIn, settle: 0.3)
        rig.click(.switchOutput)
        rig.click(.switchOutput)
        expect(rig.outputOrder() == [robertaOut.name, speakers.name], "got \(rig.outputOrder())")
        rig.tearDown()
    }

    scenario("pairing: empty modelUID never pairs by model") {
        let out = device(210, "GEN-OUT", "Generic BT", model: "", transport: kAudioDeviceTransportTypeBluetooth, output: true)
        let inp = device(211, "GEN-IN", "Generic BT", model: "", transport: kAudioDeviceTransportTypeBluetooth, output: false)
        let rig = Rig(outputs: [speakers, out], inputs: [builtInMic, inp])
        expect(rig.monitor.pairedInput(for: out) == nil, "empty modelUID must not pair")
        rig.tearDown()
    }

    scenario("mic arriving after output: Output & Input appears once mic shows up") {
        let rig = Rig(outputs: [speakers], inputs: [builtInMic], outputPriority: [speakers], inputPriority: [builtInMic])
        rig.connect(robertaOut, settle: 0.3)
        rig.click(.outputAndInput)
        expect(rig.defaultInput == builtInMic.id, "no Output & Input button before mic exists")
        expect(rig.prompter.panel != nil, "click on missing button leaves prompt open")
        rig.inputs.append(robertaIn)
        rig.monitor.refreshDevices()
        drain(0.2)
        rig.click(.outputAndInput)
        expect(rig.defaultOutput == robertaOut.id, "output switched")
        expect(rig.defaultInput == robertaIn.id, "late mic switched via refreshed prompt")
        rig.tearDown()
    }

    scenario("guard off + macOS already made new device default → no prompt") {
        let rig = Rig(outputs: [speakers], inputs: [builtInMic], outputPriority: [speakers], guardOn: false)
        rig.promptsEnabled = false
        rig.outputs.append(robertaOut)
        rig.defaultOutput = robertaOut.id
        rig.monitor.handleDeviceListChange()
        drain(0.3)
        expect(rig.prompts.isEmpty, "already playing on it, nothing to ask")
        rig.tearDown()
    }

    scenario("after system wake, re-enumerated devices don't prompt; prompts resume later") {
        let rig = Rig(outputs: [speakers], inputs: [builtInMic], outputPriority: [speakers])
        rig.promptsEnabled = false
        rig.monitor.promptsSuppressedUntil = Date().addingTimeInterval(1)
        rig.connect(monitorHDMI, settle: 0.3)
        expect(rig.prompts.isEmpty, "suppressed right after wake")
        drain(1)
        rig.disconnect(monitorHDMI, settle: 0.1)
        rig.connect(monitorHDMI, settle: 0.3)
        expect(rig.prompts.count == 1, "prompts resume after suppression window")
        rig.tearDown()
    }

    scenario("UI: new prompt resets the 5s timer") {
        let rig = Rig(outputs: [speakers], inputs: [builtInMic], outputPriority: [speakers])
        rig.connect(robertaOut, robertaIn, settle: 3)
        rig.connect(monitorHDMI, settle: 3)
        expect(rig.prompter.panel != nil, "second prompt still visible 3s after it appeared")
        drain(2.5)
        expect(rig.prompter.panel == nil, "second prompt gone after its own 5s")
        rig.tearDown()
    }

    scenario("UI: long device name keeps fixed width and working buttons") {
        let long = device(220, "BT-long:output", String(repeating: "Very Long Bluetooth Speaker Name ", count: 6), model: "long", transport: kAudioDeviceTransportTypeBluetooth, output: true)
        let rig = Rig(outputs: [speakers], inputs: [builtInMic], outputPriority: [speakers])
        rig.connect(long, settle: 0.3)
        expect(rig.prompter.panel?.frame.width == Constants.UI.popoverWidth, "width \(rig.prompter.panel?.frame.width ?? 0)")
        rig.click(.switchOutput)
        expect(rig.defaultOutput == long.id, "buttons still reachable")
        rig.tearDown()
    }

    scenario("UI: panel is non-activating, joins all spaces, stays on screen for any anchor") {
        let controller = NewDevicePromptController()
        guard let screen = NSScreen.main?.visibleFrame else { return }
        for anchor in [nil, NSRect(x: screen.maxX - 5, y: screen.maxY, width: 24, height: 24),
                       NSRect(x: screen.minX, y: screen.maxY, width: 24, height: 24),
                       NSRect(x: -10_000, y: -10_000, width: 24, height: 24)] as [NSRect?] {
            controller.show(deviceName: "X", hasInput: true, below: anchor) { _ in }
            let frame = controller.panel?.frame ?? .zero
            expect(screen.contains(frame), "panel \(frame) inside \(screen) for anchor \(String(describing: anchor))")
        }
        let panel = controller.panel
        expect(panel?.styleMask.contains(.nonactivatingPanel) == true, "non-activating")
        expect(panel?.collectionBehavior.contains(.canJoinAllSpaces) == true, "all spaces")
        expect(panel?.collectionBehavior.contains(.fullScreenAuxiliary) == true, "over full-screen apps")
        expect(NSApp.isActive == false, "showing prompt doesn't activate app")
        controller.dismiss()
        expect(controller.panel == nil, "dismiss clears panel")
        controller.dismiss()
    }

    scenario("guard off: macOS auto-switches to prompted device → prompt closes") {
        let rig = Rig(outputs: [speakers], inputs: [builtInMic], outputPriority: [speakers], guardOn: false)
        rig.connect(robertaOut, robertaIn, settle: 0.3)
        expect(rig.prompter.panel != nil, "prompt shown before macOS switches")
        rig.osSwitchesDefault(to: robertaOut)
        drain(0.2)
        expect(rig.prompter.panel == nil, "prompt closed once device is already playing")
        expect(rig.outputOrder() == [speakers.name], "list untouched")
        rig.tearDown()
    }

    scenario("guard on: macOS auto-switch while prompt open → guard reverts, prompt stays") {
        let rig = Rig(outputs: [speakers], inputs: [builtInMic], outputPriority: [speakers])
        rig.connect(robertaOut, robertaIn, settle: 0.3)
        rig.osSwitchesDefault(to: robertaOut)
        drain(0.2)
        expect(rig.defaultOutput == speakers.id, "guard reverted")
        expect(rig.prompter.panel != nil, "user still gets to choose")
        rig.tearDown()
    }

    scenario("guard off: BT late arrival still prompts via retry refresh") {
        let rig = Rig(outputs: [speakers], inputs: [builtInMic], outputPriority: [speakers], guardOn: false)
        rig.promptsEnabled = false
        rig.monitor.handleDeviceListChange()
        rig.outputs.append(robertaOut)
        drain(4)
        expect(rig.prompts.map(\.uid) == [robertaOut.uid], "late device prompted with guard off, got \(rig.prompts.count)")
        rig.tearDown()
    }

    scenario("pairing: two default-named same-model AirPods pair by MAC, not by name") {
        let mineOut = device(230, "11-11:output", "AirPods", model: "2019 4c", transport: kAudioDeviceTransportTypeBluetooth, output: true)
        let mineIn = device(231, "11-11:input", "AirPods", model: "2019 4c", transport: kAudioDeviceTransportTypeBluetooth, output: false)
        let theirsIn = device(232, "22-22:input", "AirPods", model: "2019 4c", transport: kAudioDeviceTransportTypeBluetooth, output: false)
        let rig = Rig(outputs: [speakers, mineOut], inputs: [builtInMic, theirsIn, mineIn])
        expect(rig.monitor.pairedInput(for: mineOut)?.uid == mineIn.uid, "got \(rig.monitor.pairedInput(for: mineOut)?.uid ?? "nil")")
        rig.inputs = [builtInMic, theirsIn]
        rig.monitor.refreshDevices()
        expect(rig.monitor.pairedInput(for: mineOut) == nil, "never falls back to someone else's mic")
        rig.tearDown()
    }

    scenario("prompts muted while asleep (suppressed indefinitely until wake)") {
        let rig = Rig(outputs: [speakers], inputs: [builtInMic], outputPriority: [speakers])
        rig.promptsEnabled = false
        rig.monitor.promptsSuppressedUntil = .distantFuture
        rig.connect(monitorHDMI, settle: 0.3)
        expect(rig.prompts.isEmpty, "no prompt during sleep")
        rig.tearDown()
    }

    scenario("guard off: Switch Output still changes default immediately") {
        let rig = Rig(outputs: [speakers], inputs: [builtInMic], outputPriority: [speakers], guardOn: false)
        rig.connect(robertaOut, robertaIn, settle: 0.3)
        rig.click(.switchOutput)
        expect(rig.defaultOutput == robertaOut.id, "default switched without guard")
        rig.tearDown()
    }

    scenario("output-only device: no Output & Input action") {
        let rig = Rig(outputs: [speakers], inputs: [builtInMic], outputPriority: [speakers], inputPriority: [builtInMic])
        rig.connect(monitorHDMI, settle: 0.3)
        rig.click(.outputAndInput)
        expect(rig.defaultInput == builtInMic.id, "input unchanged for output-only device")
        rig.tearDown()
    }

    scenario("device disconnects while prompt open → prompt closes, nothing set") {
        let rig = Rig(outputs: [speakers], inputs: [builtInMic], outputPriority: [speakers])
        rig.connect(robertaOut, robertaIn, settle: 0.3)
        rig.outputs.removeAll { $0.uid == robertaOut.uid }
        rig.inputs.removeAll { $0.uid == robertaIn.uid }
        rig.monitor.refreshDevices()
        drain(0.2)
        expect(rig.prompter.panel == nil, "prompt dismissed when its device disconnects")
        rig.setCalls.removeAll()
        rig.click(.switchOutput)
        expect(rig.setCalls.isEmpty, "no default set for a gone device")
        expect(rig.defaultOutput == speakers.id, "stays on speakers")
        expect(rig.outputOrder() == [speakers.name], "gone device not promoted")
        rig.tearDown()
    }

    scenario("AirPlay selected by the user is kept, no prompt, popover follows it") {
        let rig = Rig(outputs: [speakers], inputs: [builtInMic], outputPriority: [speakers])
        rig.promptsEnabled = false
        rig.userSelectsAirPlay()
        expect(rig.defaultOutput == airPlay.id, "guard keeps AirPlay")
        expect(rig.setCalls.isEmpty, "no default set while on AirPlay")
        expect(rig.prompts.isEmpty, "no prompt for AirPlay")
        expect(rig.monitor.activeAirPlayOutput?.uid == airPlay.uid, "AirPlay reported active")
        expect(rig.monitor.displayedOutput?.uid == airPlay.uid, "popover controls AirPlay")
        rig.tearDown()
    }

    scenario("AirPlay does not keep input from priority") {
        let rig = Rig(outputs: [speakers], inputs: [builtInMic, usbMic], outputPriority: [speakers], inputPriority: [usbMic])
        rig.userSelectsAirPlay()
        rig.osSwitchesDefault(to: builtInMic)
        expect(rig.defaultInput == usbMic.id, "input priority still applied")
        rig.tearDown()
    }

    scenario("leaving AirPlay resumes output priority") {
        let rig = Rig(outputs: [speakers, monitorHDMI], inputs: [builtInMic], outputPriority: [speakers, monitorHDMI])
        rig.promptsEnabled = false
        rig.userSelectsAirPlay()
        rig.osSwitchesDefault(to: monitorHDMI)
        expect(rig.defaultOutput == speakers.id, "guard restores top priority device")
        expect(rig.monitor.activeAirPlayOutput == nil, "AirPlay no longer active")
        rig.disconnect(airPlay)
        expect(rig.defaultOutput == speakers.id, "stays on top priority device")
        rig.tearDown()
    }

    scenario("setting persists and defaults to off") {
        UserDefaults.standard.removeObject(forKey: Constants.DefaultsKey.promptOnNewOutputDevice)
        expect(AppSettings().promptOnNewOutputDevice == false, "opt-in: off by default")
        AppSettings().promptOnNewOutputDevice = true
        expect(AppSettings().promptOnNewOutputDevice == true, "persisted across instances")
        UserDefaults.standard.removeObject(forKey: Constants.DefaultsKey.promptOnNewOutputDevice)
    }
}

@main
struct NewDevicePromptTests {
    static func main() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        runScenarios()
        print("\(passes) checks passed, \(failures) failed")
        exit(failures == 0 ? 0 : 1)
    }
}

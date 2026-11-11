import AVFoundation
import CoreAudio
import SameSofaCore

/// Small Core Audio property reads.
private enum AudioObject {
    static func value<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                         scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, default initial: T) -> T? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectHasProperty(object, &address) else { return nil }
        var value = initial
        var size = UInt32(MemoryLayout<T>.size)
        let status = withUnsafeMutablePointer(to: &value) { AudioObjectGetPropertyData(object, &address, 0, nil, &size, $0) }
        return status == noErr ? value : nil
    }

    static func name(_ object: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &name) == noErr, let name else { return nil }
        return name.takeRetainedValue() as String
    }

    static func streamCount(_ object: AudioObjectID, scope: AudioObjectPropertyScope) -> Int {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size) == noErr else { return 0 }
        return Int(size) / MemoryLayout<AudioStreamID>.size
    }

    static func defaultDevice(_ selector: AudioObjectPropertySelector) -> AudioDeviceID? {
        guard let device = value(AudioObjectID(kAudioObjectSystemObject), selector, default: AudioDeviceID(0)),
              device != kAudioObjectUnknown else { return nil }
        return device
    }

    static func transport(_ device: AudioDeviceID) -> UInt32 {
        value(device, kAudioDevicePropertyTransportType, default: UInt32(0)) ?? 0
    }

    static func allDevices() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }
        var devices = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &devices) == noErr else { return [] }
        return devices
    }
}

private func fourCharacters(_ code: UInt32) -> String {
    let bytes = [UInt8(code >> 24 & 0xff), UInt8(code >> 16 & 0xff), UInt8(code >> 8 & 0xff), UInt8(code & 0xff)]
    return String(bytes: bytes, encoding: .ascii) ?? ""
}

private func transportKind(_ raw: UInt32) -> OutputRoute.Transport {
    switch raw {
    case kAudioDeviceTransportTypeBuiltIn: return .builtIn
    case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: return .bluetooth
    case kAudioDeviceTransportTypeUSB: return .usb
    case kAudioDeviceTransportTypeHDMI: return .hdmi
    case kAudioDeviceTransportTypeDisplayPort: return .displayPort
    case kAudioDeviceTransportTypeAirPlay: return .airPlay
    case kAudioDeviceTransportTypeThunderbolt: return .thunderbolt
    case kAudioDeviceTransportTypeVirtual: return .virtual
    case kAudioDeviceTransportTypeAggregate: return .aggregate
    default: return .other
    }
}

/// The Mac's current sound output.
public enum OutputDevice {
    public static func currentRoute() -> OutputRoute {
        guard let device = AudioObject.defaultDevice(kAudioHardwarePropertyDefaultOutputDevice) else { return .unknown }
        let source = AudioObject.value(device, kAudioDevicePropertyDataSource, scope: kAudioDevicePropertyScopeOutput, default: UInt32(0))
        return OutputRoute(name: AudioObject.name(device) ?? "Unknown output",
                           transport: transportKind(AudioObject.transport(device)),
                           dataSource: source.map(fourCharacters),
                           hasInput: AudioObject.streamCount(device, scope: kAudioDevicePropertyScopeInput) > 0)
    }
}

/// One sound device as Core Audio describes it, for one direction.
public struct AudioDeviceInfo: Equatable, Sendable {
    public var id: UInt32
    public var name: String
    public var transport: OutputRoute.Transport
    /// Nominal sample rate (0 when the device does not say).
    public var sampleRate: Double
    /// Channels in this direction.
    public var channels: Int

    /// "built-in, 48000 Hz, 3 channels": no device names (they can contain a person's name).
    public var summary: String {
        "\(transport.rawValue), \(Int(sampleRate)) Hz, \(channels) channel\(channels == 1 ? "" : "s")"
    }
}

/// The sound devices the call's audio depends on.
public enum AudioDevices {
    static func channelCount(_ device: AudioDeviceID, scope: AudioObjectPropertyScope) -> Int {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr, size >= UInt32(MemoryLayout<AudioBufferList>.size) else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    static func info(_ device: AudioDeviceID, scope: AudioObjectPropertyScope) -> AudioDeviceInfo {
        AudioDeviceInfo(id: device, name: AudioObject.name(device) ?? "Unknown device", transport: transportKind(AudioObject.transport(device)),
                        sampleRate: AudioObject.value(device, kAudioDevicePropertyNominalSampleRate, default: Float64(0)) ?? 0,
                        channels: channelCount(device, scope: scope))
    }

    public static func defaultOutput() -> AudioDeviceInfo? {
        AudioObject.defaultDevice(kAudioHardwarePropertyDefaultOutputDevice).map { info($0, scope: kAudioDevicePropertyScopeOutput) }
    }

    public static func defaultInput() -> AudioDeviceInfo? {
        AudioObject.defaultDevice(kAudioHardwarePropertyDefaultInputDevice).map { info($0, scope: kAudioDevicePropertyScopeInput) }
    }

    /// Every device that can record.
    public static func inputs() -> [AudioDeviceInfo] {
        AudioObject.allDevices().filter { AudioObject.streamCount($0, scope: kAudioDevicePropertyScopeInput) > 0 }
            .map { info($0, scope: kAudioDevicePropertyScopeInput) }.filter { $0.channels > 0 }
    }

    public static func outputs() -> [AudioDeviceInfo] {
        AudioObject.allDevices().filter { AudioObject.streamCount($0, scope: kAudioDevicePropertyScopeOutput) > 0 }
            .map { info($0, scope: kAudioDevicePropertyScopeOutput) }.filter { $0.channels > 0 }
    }

    /// The microphone a call records from: the default one, except that a
    /// Bluetooth headset's microphone is passed over for a built-in one.
    /// Using the headset's own microphone switches it to its telephone
    /// mode, and the film then plays in telephone quality.
    public static func preferredInput() -> AudioDeviceInfo? {
        guard let current = defaultInput() else { return nil }
        guard current.transport == .bluetooth else { return current }
        return inputs().first { $0.transport == .builtIn } ?? current
    }

    /// Makes `device` the system's default microphone or sound output (tests only).
    @discardableResult
    public static func setDefault(_ device: UInt32, input: Bool) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: input ? kAudioHardwarePropertyDefaultInputDevice : kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value = device
        return AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, UInt32(MemoryLayout<AudioDeviceID>.size), &value) == noErr
    }
}

/// The devices (and the microphone's format) an audio engine was built
/// for. When this changes the engine has to be built again.
struct AudioDeviceSignature: Equatable {
    var output: AudioDeviceID?
    var input: AudioDeviceID?
    var inputRate = 0.0
    var inputChannels = 0

    static func current(pinnedInput: AudioDeviceID? = nil) -> AudioDeviceSignature {
        var signature = AudioDeviceSignature(output: AudioObject.defaultDevice(kAudioHardwarePropertyDefaultOutputDevice))
        let input = pinnedInput.map { AudioDevices.info($0, scope: kAudioDevicePropertyScopeInput) } ?? AudioDevices.preferredInput()
        if let input, input.channels > 0 {
            signature.input = input.id
            signature.inputRate = input.sampleRate
            signature.inputChannels = input.channels
        }
        return signature
    }
}

enum InputDevice {
    /// Makes the engine's input record from `device` when that is not the
    /// default microphone (see `AudioDevices.preferredInput`). Returns false
    /// when the device could not be selected (the default one is used then).
    @discardableResult
    static func select(_ device: AudioDeviceID, for input: AVAudioInputNode) -> Bool {
        guard device != AudioObject.defaultDevice(kAudioHardwarePropertyDefaultInputDevice) else { return true }
        guard let unit = input.audioUnit else { return false }
        var wanted = device
        let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                          &wanted, UInt32(MemoryLayout<AudioDeviceID>.size))
        if status != noErr { NSLog("SameSofa: could not select the microphone (\(status)); using the default one") }
        return status == noErr
    }

    /// Name of the default microphone, for the quality readout.
    static var defaultName: String? {
        AudioObject.defaultDevice(kAudioHardwarePropertyDefaultInputDevice).flatMap(AudioObject.name)
    }
}

/// What each channel of a film's audio track is, in the order the player delivers them.
enum ChannelLayoutReader {
    static func roles(for description: CMAudioFormatDescription) -> [ChannelRole]? {
        var size = 0
        guard let layout = CMAudioFormatDescriptionGetChannelLayout(description, sizeOut: &size), size > 0 else { return nil }
        if layout.pointee.mChannelLayoutTag == kAudioChannelLayoutTag_UseChannelDescriptions {
            return roles(of: layout)
        }
        guard layout.pointee.mChannelLayoutTag != kAudioChannelLayoutTag_UseChannelBitmap else { return nil }
        // Expand a layout tag ("MPEG 5.1 D") into its list of channels.
        var tag = layout.pointee.mChannelLayoutTag
        var expandedSize: UInt32 = 0
        guard AudioFormatGetPropertyInfo(kAudioFormatProperty_ChannelLayoutForTag, UInt32(MemoryLayout<AudioChannelLayoutTag>.size),
                                         &tag, &expandedSize) == noErr, expandedSize > 0 else { return nil }
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: Int(expandedSize), alignment: MemoryLayout<AudioChannelLayout>.alignment)
        defer { buffer.deallocate() }
        guard AudioFormatGetProperty(kAudioFormatProperty_ChannelLayoutForTag, UInt32(MemoryLayout<AudioChannelLayoutTag>.size),
                                     &tag, &expandedSize, buffer) == noErr else { return nil }
        return roles(of: UnsafePointer(buffer.assumingMemoryBound(to: AudioChannelLayout.self)))
    }

    private static func roles(of layout: UnsafePointer<AudioChannelLayout>) -> [ChannelRole]? {
        let count = Int(layout.pointee.mNumberChannelDescriptions)
        guard count > 0 else { return nil }
        let descriptions = UnsafeBufferPointer(
            start: UnsafeRawPointer(layout).advanced(by: MemoryLayout<AudioChannelLayout>.offset(of: \.mChannelDescriptions)!)
                .assumingMemoryBound(to: AudioChannelDescription.self), count: count)
        return descriptions.map { role(for: $0.mChannelLabel) }
    }

    static func role(for label: AudioChannelLabel) -> ChannelRole {
        switch label {
        case kAudioChannelLabel_Left, kAudioChannelLabel_LeftCenter, kAudioChannelLabel_LeftWide: return .left
        case kAudioChannelLabel_Right, kAudioChannelLabel_RightCenter, kAudioChannelLabel_RightWide: return .right
        case kAudioChannelLabel_Center: return .centre
        case kAudioChannelLabel_Mono: return .mono
        case kAudioChannelLabel_LFEScreen, kAudioChannelLabel_LFE2: return .lfe
        case kAudioChannelLabel_LeftSurround, kAudioChannelLabel_LeftSurroundDirect, kAudioChannelLabel_RearSurroundLeft,
             kAudioChannelLabel_LeftTopFront, kAudioChannelLabel_LeftTopRear, kAudioChannelLabel_LeftTopMiddle:
            return .leftSurround
        case kAudioChannelLabel_RightSurround, kAudioChannelLabel_RightSurroundDirect, kAudioChannelLabel_RearSurroundRight,
             kAudioChannelLabel_RightTopFront, kAudioChannelLabel_RightTopRear, kAudioChannelLabel_RightTopMiddle:
            return .rightSurround
        case kAudioChannelLabel_CenterSurround, kAudioChannelLabel_TopCenterSurround: return .centreSurround
        default: return .other
        }
    }
}

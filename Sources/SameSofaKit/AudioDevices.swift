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

/// The Mac's current sound output.
public enum OutputDevice {
    public static func currentRoute() -> OutputRoute {
        guard let device = AudioObject.defaultDevice(kAudioHardwarePropertyDefaultOutputDevice) else { return .unknown }
        let transport: OutputRoute.Transport
        switch AudioObject.transport(device) {
        case kAudioDeviceTransportTypeBuiltIn: transport = .builtIn
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: transport = .bluetooth
        case kAudioDeviceTransportTypeUSB: transport = .usb
        case kAudioDeviceTransportTypeHDMI: transport = .hdmi
        case kAudioDeviceTransportTypeDisplayPort: transport = .displayPort
        case kAudioDeviceTransportTypeAirPlay: transport = .airPlay
        case kAudioDeviceTransportTypeThunderbolt: transport = .thunderbolt
        case kAudioDeviceTransportTypeVirtual: transport = .virtual
        case kAudioDeviceTransportTypeAggregate: transport = .aggregate
        default: transport = .other
        }
        let source = AudioObject.value(device, kAudioDevicePropertyDataSource, scope: kAudioDevicePropertyScopeOutput, default: UInt32(0))
        return OutputRoute(name: AudioObject.name(device) ?? "Unknown output",
                           transport: transport,
                           dataSource: source.map(fourCharacters),
                           hasInput: AudioObject.streamCount(device, scope: kAudioDevicePropertyScopeInput) > 0)
    }
}

enum InputDevice {
    /// Using a Bluetooth headset's own microphone switches the headset to its
    /// telephone mode, and the film then plays in telephone quality. If the
    /// default microphone is a Bluetooth one and the Mac has a built-in
    /// microphone, record from the built-in one instead.
    static func preferBuiltInOverBluetooth(for input: AVAudioInputNode) {
        guard let current = AudioObject.defaultDevice(kAudioHardwarePropertyDefaultInputDevice) else { return }
        let transport = AudioObject.transport(current)
        guard transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE else { return }
        guard var builtIn = AudioObject.allDevices().first(where: {
            AudioObject.transport($0) == kAudioDeviceTransportTypeBuiltIn
                && AudioObject.streamCount($0, scope: kAudioDevicePropertyScopeInput) > 0
        }), let unit = input.audioUnit else { return }
        let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                          &builtIn, UInt32(MemoryLayout<AudioDeviceID>.size))
        if status == noErr {
            NSLog("SameSofa: using the built-in microphone so the Bluetooth headphones stay in high quality")
        } else {
            NSLog("SameSofa: could not select the built-in microphone (\(status)); using the default one")
        }
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

import CoreAudio
import Foundation
import os

/// Mutes the Mac's speakers while you dictate, so YouTube, music or a call can't get into the
/// microphone, and puts them back exactly as they were the moment you stop.
///
/// It only steps in when something is actually playing, and never unmutes sound you muted yourself.
/// If the app quits unexpectedly while it has the sound muted, the next launch unmutes it.
@MainActor
final class SystemAudioSilencer {
    /// What we changed, so it can be undone precisely.
    private enum Change {
        case muted(AudioDeviceID)
        case volume(AudioDeviceID, Float32)   // for devices without a mute switch
    }

    private var change: Change?
    private let log = Logger(subsystem: "com.natfirst.akassistant", category: "Audio")
    private static let crashFlag = "systemAudioMutedByAKAssistant"
    private static let crashVolume = "systemAudioVolumeBeforeAKAssistant"

    init() {
        // Left muted by a crash or force-quit last time: give the sound back.
        if UserDefaults.standard.bool(forKey: Self.crashFlag), let device = Self.defaultOutputDevice() {
            let savedVolume = UserDefaults.standard.float(forKey: Self.crashVolume)
            if savedVolume > 0 { _ = Self.setVolume(savedVolume, on: device) } else { _ = Self.setMute(false, on: device) }
            UserDefaults.standard.set(false, forKey: Self.crashFlag)
            UserDefaults.standard.removeObject(forKey: Self.crashVolume)
        }
    }

    /// Silences the speakers if something is playing. Call before the microphone starts.
    func silence() {
        guard change == nil, let device = Self.defaultOutputDevice() else { return }
        // Nothing playing (or already muted by you): leave everything alone.
        guard Self.isPlaying(device), Self.isMuted(device) != true else { return }

        if Self.setMute(true, on: device) {
            change = .muted(device)
        } else if let volume = Self.volume(device), volume > 0, Self.setVolume(0, on: device) {
            change = .volume(device, volume)
            UserDefaults.standard.set(volume, forKey: Self.crashVolume)
        } else {
            log.info("Couldn't silence the output device; recording with the speakers on")
            return
        }
        UserDefaults.standard.set(true, forKey: Self.crashFlag)
    }

    /// Puts the speakers back the way they were.
    func restore() {
        guard let change else { return }
        switch change {
        case .muted(let device): _ = Self.setMute(false, on: device)
        case .volume(let device, let volume): _ = Self.setVolume(volume, on: device)
        }
        self.change = nil
        UserDefaults.standard.set(false, forKey: Self.crashFlag)
        UserDefaults.standard.removeObject(forKey: Self.crashVolume)
    }

    // MARK: - Core Audio

    private static func address(_ selector: AudioObjectPropertySelector,
                                scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private static func defaultOutputDevice() -> AudioDeviceID? {
        var address = address(kAudioHardwarePropertyDefaultOutputDevice)
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        return status == noErr && device != 0 ? device : nil
    }

    /// True while any app is sending sound to this device.
    private static func isPlaying(_ device: AudioDeviceID) -> Bool {
        var address = address(kAudioDevicePropertyDeviceIsRunningSomewhere)
        var running = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(device, &address, 0, nil, &size, &running) == noErr && running != 0
    }

    private static func isMuted(_ device: AudioDeviceID) -> Bool? {
        var address = address(kAudioDevicePropertyMute, scope: kAudioDevicePropertyScopeOutput)
        guard AudioObjectHasProperty(device, &address) else { return nil }
        var muted = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &muted) == noErr else { return nil }
        return muted != 0
    }

    private static func setMute(_ mute: Bool, on device: AudioDeviceID) -> Bool {
        var address = address(kAudioDevicePropertyMute, scope: kAudioDevicePropertyScopeOutput)
        var settable = DarwinBoolean(false)
        guard AudioObjectHasProperty(device, &address),
              AudioObjectIsPropertySettable(device, &address, &settable) == noErr, settable.boolValue else { return false }
        var value = UInt32(mute ? 1 : 0)
        return AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value) == noErr
    }

    private static func volume(_ device: AudioDeviceID) -> Float32? {
        var address = address(kAudioDevicePropertyVolumeScalar, scope: kAudioDevicePropertyScopeOutput)
        guard AudioObjectHasProperty(device, &address) else { return nil }
        var volume = Float32(0)
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &volume) == noErr else { return nil }
        return volume
    }

    private static func setVolume(_ volume: Float32, on device: AudioDeviceID) -> Bool {
        var address = address(kAudioDevicePropertyVolumeScalar, scope: kAudioDevicePropertyScopeOutput)
        var settable = DarwinBoolean(false)
        guard AudioObjectHasProperty(device, &address),
              AudioObjectIsPropertySettable(device, &address, &settable) == noErr, settable.boolValue else { return false }
        var value = volume
        return AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &value) == noErr
    }
}

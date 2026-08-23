import CoreAudio
import Foundation
import os

private let log = Logger(subsystem: "com.marcelwagenlander.spoty", category: "audiodevice")

/// Notices when the system's default output device changes.
///
/// librespot resolves `cpal::default_host().default_output_device()` once, inside the sink
/// factory closure, and nothing re-evaluates it — so plugging in AirPods leaves audio on
/// the old device. There is no config key for the audio device (`device.name` is the
/// Spotify Connect identity, not the CoreAudio output) and the control socket has no
/// restart command, so the only lever is the TUI's own `RestartIntegratedClient` binding.
final class AudioDeviceWatcher: @unchecked Sendable {
    private var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    private var listenerBlock: AudioObjectPropertyListenerBlock?
    private let onChange: @Sendable () -> Void

    init(onChange: @escaping @Sendable () -> Void) {
        self.onChange = onChange
    }

    func start() {
        guard listenerBlock == nil else { return }
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self else { return }
            log.info("default output device changed")
            self.onChange()
        }
        listenerBlock = block
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, block
        )
        if status != noErr {
            log.warning("could not observe default output device: \(status)")
            listenerBlock = nil
        }
    }

    func stop() {
        guard let block = listenerBlock else { return }
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, block
        )
        listenerBlock = nil
    }

    deinit { stop() }
}

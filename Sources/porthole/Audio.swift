import AppKit
import AVFoundation
import CoreAudio
import Foundation

/// Records what this Mac plays through a Core Audio process tap and summarizes it
/// so an agent can tell whether, when and how loud something played. Unlike
/// ScreenCaptureKit, a tap hears every process, command-line tools included.
final class AudioRecorder {
    private var file: AVAudioFile?
    private let path: String
    private var format: AVAudioFormat?
    private var windowSamples = 0
    private var windowSumSquares: Double = 0
    private var peak: Float = 0
    private var levels: [Double] = []
    private var frames: Int64 = 0
    private var writeError: Error?
    private let lock = NSLock()

    static let window = 0.1

    private init(path: String) { self.path = path }

    static func record(seconds: Double, app: String?, to path: String) throws -> [String: Any] {
        try AudioRecorder(path: path).run(seconds: seconds, app: app)
    }

    /// Core Audio delivers notifications on the main run loop by default, which the
    /// server's main thread never runs; let the HAL use its own thread instead.
    private static let halThread: Void = {
        var addr = CoreAudioProperty.address(kAudioHardwarePropertyRunLoop)
        var loop: CFRunLoop? = nil
        AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, UInt32(MemoryLayout<CFRunLoop?>.size), &loop)
    }()

    private func run(seconds: Double, app: String?) throws -> [String: Any] {
        AudioRecorder.halThread
        var matched: [String] = []
        let desc: CATapDescription
        if let app, !app.isEmpty {
            let procs = try AudioProcesses.matching(app)
            matched = procs.map(\.label)
            desc = CATapDescription(stereoMixdownOfProcesses: procs.map(\.object))
        } else {
            desc = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        }
        desc.uuid = UUID()
        desc.isPrivate = true
        desc.muteBehavior = .unmuted
        desc.name = "porthole"

        var tap = AudioObjectID(kAudioObjectUnknown)
        try check(AudioHardwareCreateProcessTap(desc, &tap), "create the audio tap")
        defer { AudioHardwareDestroyProcessTap(tap) }

        var asbd = try CoreAudioProperty.read(tap, kAudioTapPropertyFormat, AudioStreamBasicDescription())
        guard let fmt = AVAudioFormat(streamDescription: &asbd) else { throw NetError("unsupported tap format") }
        format = fmt

        let output = try CoreAudioProperty.read(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice, AudioObjectID(kAudioObjectUnknown))
        let outputUID = try CoreAudioProperty.readString(output, kAudioDevicePropertyDeviceUID)
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "porthole-tap",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true, kAudioSubTapUIDKey: desc.uuid.uuidString]],
        ]
        var device = AudioObjectID(kAudioObjectUnknown)
        try check(AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &device), "create the capture device")
        defer { AudioHardwareDestroyAggregateDevice(device) }

        var proc: AudioDeviceIOProcID?
        try check(AudioDeviceCreateIOProcIDWithBlock(&proc, device, DispatchQueue(label: "porthole.audio")) { [self] _, input, _, _, _ in
            receive(input)
        }, "attach to the capture device")
        defer { if let proc { AudioDeviceDestroyIOProcID(device, proc) } }

        try check(AudioDeviceStart(device, proc), "start capturing")
        // The device takes most of a second to deliver its first buffer; start the
        // clock then, so a sound triggered right after the call is still heard.
        let started = Date()
        while Date().timeIntervalSince(started) < 3 {
            lock.lock(); let n = callbacks; lock.unlock()
            if n > 0 { break }
            if Thread.isMainThread { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) } else { usleep(10_000) }
        }
        let startupDelay = Date().timeIntervalSince(started)
        if Thread.isMainThread {
            RunLoop.current.run(until: Date().addingTimeInterval(seconds))
        } else {
            Thread.sleep(forTimeInterval: seconds)
        }
        var diag: [String: Any] = ["tap_format": "\(asbd.mSampleRate) Hz, \(asbd.mChannelsPerFrame) ch, flags \(asbd.mFormatFlags)"]
        diag["device_running"] = (try? CoreAudioProperty.read(device, kAudioDevicePropertyDeviceIsRunning, UInt32(0))) ?? 99
        var streamsAddr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: kAudioObjectPropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        AudioObjectGetPropertyDataSize(device, &streamsAddr, 0, nil, &size)
        diag["input_streams"] = Int(size) / MemoryLayout<AudioObjectID>.size
        diag["output_device"] = outputUID
        AudioDeviceStop(device, proc)
        var summary = summarize(seconds: seconds, matched: matched)
        summary["startup_seconds"] = round1(startupDelay)
        lock.lock(); diag["callbacks"] = callbacks; lock.unlock()
        if frames == 0 { summary["diagnostics"] = diag }
        return summary
    }

    private var callbacks = 0

    private func receive(_ input: UnsafePointer<AudioBufferList>) {
        lock.lock(); defer { lock.unlock() }
        callbacks += 1
        // The capture device's input carries the output device's own input streams
        // (a USB mic, say) ahead of the tap, so the tap is the last buffer.
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        guard let format, let tapBuffer = buffers.last else { return }
        var single = AudioBufferList(mNumberBuffers: 1, mBuffers: tapBuffer)
        guard let pcm = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: &single, deallocator: nil) else { return }
        do {
            if file == nil {
                file = try AVAudioFile(forWriting: URL(fileURLWithPath: path), settings: format.settings, commonFormat: format.commonFormat, interleaved: format.isInterleaved)
            }
            try file?.write(from: pcm)
        } catch {
            writeError = error
        }
        frames += Int64(pcm.frameLength)
        measure(pcm)
    }

    private func summarize(seconds: Double, matched: [String]) -> [String: Any] {
        lock.lock(); defer { lock.unlock() }
        flushWindow()
        file = nil
        let rate = format?.sampleRate ?? 48000
        let threshold = -50.0
        let loud = levels.enumerated().filter { $0.element > threshold }
        var summary: [String: Any] = [
            "path": path,
            "seconds": round1(Double(frames) / rate),
            "requested_seconds": seconds,
            "peak_dbfs": round1(db(Double(peak))),
            "silent": loud.isEmpty,
            "window_seconds": AudioRecorder.window,
            // One level per window, in dBFS, floored at -90.
            "levels_dbfs": levels.map { round1(max($0, -90)) },
        ]
        if !matched.isEmpty { summary["processes"] = matched }
        if let first = loud.first, let last = loud.last {
            summary["sound_from"] = round1(Double(first.offset) * AudioRecorder.window)
            summary["sound_to"] = round1(Double(last.offset + 1) * AudioRecorder.window)
            summary["loud_fraction"] = round1(Double(loud.count) / Double(max(levels.count, 1)))
        }
        if let writeError { summary["write_error"] = writeError.localizedDescription }
        if frames == 0 {
            summary["note"] = "no audio arrived; check that Porthole is allowed under System Settings › Privacy & Security › Screen & System Audio Recording"
        } else if loud.isEmpty {
            summary["note"] = "only silence arrived; if something did play, Porthole may lack System Audio Recording permission (a denied tap records silence)"
        }
        return summary
    }

    private func measure(_ pcm: AVAudioPCMBuffer) {
        guard let channels = pcm.floatChannelData else { return }
        let n = Int(pcm.frameLength)
        let chans = Int(pcm.format.channelCount)
        let stride = pcm.stride
        let perWindow = Int((format?.sampleRate ?? 48000) * AudioRecorder.window)
        for i in 0..<n {
            var sq: Float = 0
            for c in 0..<chans {
                // Interleaved data lives in one buffer; channel c is at offset c.
                let v = pcm.format.isInterleaved ? channels[0][i * stride + c] : channels[c][i * stride]
                sq += v * v
                peak = max(peak, abs(v))
            }
            windowSumSquares += Double(sq / Float(max(chans, 1)))
            windowSamples += 1
            if windowSamples >= perWindow { flushWindow() }
        }
    }

    private func flushWindow() {
        guard windowSamples > 0 else { return }
        levels.append(db((windowSumSquares / Double(windowSamples)).squareRoot()))
        windowSamples = 0
        windowSumSquares = 0
    }

    private func check(_ status: OSStatus, _ what: String) throws {
        guard status == noErr else { throw NetError("could not \(what) (OSStatus \(status))") }
    }

    private func db(_ amplitude: Double) -> Double { amplitude > 0 ? 20 * log10(amplitude) : -120 }
    private func round1(_ x: Double) -> Double { (x * 10).rounded() / 10 }
}

enum CoreAudioProperty {
    static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }

    static func read<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ initial: T) throws -> T {
        var addr = address(selector)
        var value = initial
        var size = UInt32(MemoryLayout<T>.size)
        let status = AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value)
        guard status == noErr else { throw NetError("Core Audio property \(selector) failed (OSStatus \(status))") }
        return value
    }

    static func readString(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) throws -> String {
        var addr = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value)
        guard status == noErr, let s = value?.takeRetainedValue() else { throw NetError("Core Audio property \(selector) failed (OSStatus \(status))") }
        return s as String
    }

    static func readArray(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) throws -> [AudioObjectID] {
        var addr = address(selector)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &addr, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &ids)
        guard status == noErr else { throw NetError("Core Audio property \(selector) failed (OSStatus \(status))") }
        return ids
    }
}

enum AudioProcesses {
    struct Proc {
        let object: AudioObjectID
        let pid: pid_t
        let label: String
    }

    /// Core Audio's process objects whose bundle ID, app name or executable name matches.
    static func matching(_ query: String) throws -> [Proc] {
        let needle = query.lowercased()
        let objects = try CoreAudioProperty.readArray(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyProcessObjectList)
        var all: [Proc] = []
        var matches: [Proc] = []
        for obj in objects {
            guard let pid = try? CoreAudioProperty.read(obj, kAudioProcessPropertyPID, pid_t(0)) else { continue }
            let bundle = (try? CoreAudioProperty.readString(obj, kAudioProcessPropertyBundleID)) ?? ""
            let appName = NSRunningApplication(processIdentifier: pid)?.localizedName ?? ""
            let exe = executableName(pid)
            let label = "\(appName.isEmpty ? exe : appName) (pid \(pid)\(bundle.isEmpty ? "" : ", \(bundle)"))"
            let p = Proc(object: obj, pid: pid, label: label)
            all.append(p)
            if [bundle, appName, exe].contains(where: { !$0.isEmpty && ($0.lowercased() == needle || $0.lowercased().contains(needle)) }) {
                matches.append(p)
            }
        }
        guard !matches.isEmpty else {
            throw NetError("no process using audio matches \"\(query)\" (a process appears once it opens audio); known: \(all.map(\.label).joined(separator: ", "))")
        }
        return matches
    }

    static func executableName(_ pid: pid_t) -> String {
        var buf = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 else { return "" }
        return (String(cString: buf) as NSString).lastPathComponent
    }
}

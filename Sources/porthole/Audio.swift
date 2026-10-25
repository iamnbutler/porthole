import AppKit
import AVFoundation
import CoreAudio
import Foundation

/// Records what this Mac plays through a Core Audio process tap and summarizes it
/// so an agent can tell whether, when and how loud something played. Unlike
/// ScreenCaptureKit, a tap hears every process, command-line tools included.
///
/// The tap only delivers buffers while something is playing, so the timeline is
/// laid out by wall clock: each buffer lands in the window it arrived in, windows
/// with no buffers count as silence, and the WAV is padded with silence to match.
final class AudioRecorder {
    private var file: AVAudioFile?
    private let path: String
    private var format: AVAudioFormat?
    private var start = Date()
    private var windows: [Int: (sumSquares: Double, samples: Int)] = [:]
    private var peak: Float = 0
    private var framesWritten: Int64 = 0
    private var framesHeard: Int64 = 0
    private var writeError: Error?
    private let lock = NSLock()

    static let window = 0.1

    private init(path: String) { self.path = path }

    /// `onStart` runs as soon as capture has started, so a sound it triggers is heard from its first moment.
    static func record(seconds: Double, app: String?, to path: String, onStart: (() -> Void)? = nil) throws -> [String: Any] {
        try AudioRecorder(path: path).run(seconds: seconds, app: app, onStart: onStart)
    }

    /// Core Audio delivers notifications on the main run loop by default, which the
    /// server's main thread never runs; let the HAL use its own thread instead.
    private static let halThread: Void = {
        var addr = CoreAudioProperty.address(kAudioHardwarePropertyRunLoop)
        var loop: CFRunLoop? = nil
        AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, UInt32(MemoryLayout<CFRunLoop?>.size), &loop)
    }()

    private func run(seconds: Double, app: String?, onStart: (() -> Void)?) throws -> [String: Any] {
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
        file = try AVAudioFile(forWriting: URL(fileURLWithPath: path), settings: fmt.settings, commonFormat: fmt.commonFormat, interleaved: fmt.isInterleaved)

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

        lock.lock(); start = Date(); lock.unlock()
        try check(AudioDeviceStart(device, proc), "start capturing")
        onStart?()
        if Thread.isMainThread {
            RunLoop.current.run(until: start.addingTimeInterval(seconds))
        } else {
            Thread.sleep(until: start.addingTimeInterval(seconds))
        }
        AudioDeviceStop(device, proc)
        return summarize(seconds: seconds, matched: matched)
    }

    private func receive(_ input: UnsafePointer<AudioBufferList>) {
        lock.lock(); defer { lock.unlock() }
        // The capture device's input carries the output device's own input streams
        // (a USB mic, say) ahead of the tap, so the tap is the last buffer.
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        guard let format, let tapBuffer = buffers.last else { return }
        var single = AudioBufferList(mNumberBuffers: 1, mBuffers: tapBuffer)
        guard let pcm = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: &single, deallocator: nil), pcm.frameLength > 0 else { return }

        // Place the buffer by arrival time: it ends now, so it began a buffer's length ago.
        let rate = format.sampleRate
        let begins = max(0, Date().timeIntervalSince(start) - Double(pcm.frameLength) / rate)
        padSilence(until: Int64(begins * rate))
        do { try file?.write(from: pcm) } catch { writeError = error }
        measure(pcm, from: begins)
        framesWritten += Int64(pcm.frameLength)
        framesHeard += Int64(pcm.frameLength)
    }

    /// Writes zeros so the WAV's timeline matches the wall clock across gaps.
    private func padSilence(until frame: Int64, ignoringJitter: Bool = true) {
        guard let format, let file else { return }
        var missing = frame - framesWritten
        // Mid-recording, ignore jitter shorter than a window.
        if ignoringJitter, Double(missing) <= format.sampleRate * AudioRecorder.window { return }
        let chunk = AVAudioFrameCount(4096)
        guard let zeros = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) else { return }
        while missing > 0 {
            let n = AVAudioFrameCount(min(Int64(chunk), missing))
            zeros.frameLength = n
            let list = UnsafeMutableAudioBufferListPointer(zeros.mutableAudioBufferList)
            for b in list { if let d = b.mData { memset(d, 0, Int(b.mDataByteSize)) } }
            do { try file.write(from: zeros) } catch { writeError = error; return }
            framesWritten += Int64(n)
            missing -= Int64(n)
        }
    }

    private func measure(_ pcm: AVAudioPCMBuffer, from begins: Double) {
        guard let channels = pcm.floatChannelData else { return }
        let n = Int(pcm.frameLength)
        let chans = Int(pcm.format.channelCount)
        let stride = pcm.stride
        let rate = pcm.format.sampleRate
        for i in 0..<n {
            var sq: Float = 0
            for c in 0..<chans {
                // Interleaved data lives in one buffer; channel c is at offset c.
                let v = pcm.format.isInterleaved ? channels[0][i * stride + c] : channels[c][i * stride]
                sq += v * v
                peak = max(peak, abs(v))
            }
            let w = Int((begins + Double(i) / rate) / AudioRecorder.window)
            var acc = windows[w] ?? (0, 0)
            acc.sumSquares += Double(sq / Float(max(chans, 1)))
            acc.samples += 1
            windows[w] = acc
        }
    }

    private func summarize(seconds: Double, matched: [String]) -> [String: Any] {
        lock.lock(); defer { lock.unlock() }
        let rate = format?.sampleRate ?? 48000
        padSilence(until: Int64(seconds * rate), ignoringJitter: false)
        file = nil
        let count = Int((seconds / AudioRecorder.window).rounded(.up))
        let levels: [Double] = (0..<count).map { w in
            guard let acc = windows[w], acc.samples > 0 else { return -90 }
            return max(db((acc.sumSquares / Double(acc.samples)).squareRoot()), -90)
        }
        let threshold = -50.0
        let loud = levels.enumerated().filter { $0.element > threshold }
        var summary: [String: Any] = [
            "path": path,
            "seconds": seconds,
            "audio_seconds": round1(Double(framesHeard) / rate),
            "peak_dbfs": round1(db(Double(peak))),
            "silent": loud.isEmpty,
            "window_seconds": AudioRecorder.window,
            // One level per window from the start of recording, in dBFS, floored at -90.
            "levels_dbfs": levels.map(round1),
        ]
        if !matched.isEmpty { summary["processes"] = matched }
        if let first = loud.first, let last = loud.last {
            summary["sound_from"] = round1(Double(first.offset) * AudioRecorder.window)
            summary["sound_to"] = round1(Double(last.offset + 1) * AudioRecorder.window)
            summary["loud_fraction"] = round1(Double(loud.count) / Double(max(levels.count, 1)))
        }
        if let writeError { summary["write_error"] = writeError.localizedDescription }
        if framesHeard == 0 {
            summary["note"] = "nothing played: the tap delivers audio only while something is playing. If something did play, check Porthole under System Settings › Privacy & Security › Screen & System Audio Recording"
        }
        return summary
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

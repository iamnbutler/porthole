import AVFoundation
import Foundation
import ScreenCaptureKit

/// Records system or per-app audio with ScreenCaptureKit and summarizes it so an
/// agent can tell whether, when and how loud something played.
final class AudioRecorder: NSObject, SCStreamOutput, SCStreamDelegate {
    private var file: AVAudioFile?
    private let path: String
    private var windowSamples = 0
    private var windowSumSquares: Double = 0
    private var peak: Float = 0
    private var levels: [Double] = []
    private var frames: Int64 = 0
    private var sampleRate: Double = 48000
    private var writeError: Error?
    private var streamError: Error?
    private let lock = NSLock()

    static let window = 0.1

    private init(path: String) { self.path = path }

    static func record(seconds: Double, app: String?, to path: String) throws -> [String: Any] {
        let r = AudioRecorder(path: path)
        let done = DispatchSemaphore(value: 0)
        var result: Result<[String: Any], Error> = .failure(NetError("audio recording did not finish"))
        Task.detached {
            do { result = .success(try await r.run(seconds: seconds, app: app)) } catch { result = .failure(error) }
            done.signal()
        }
        done.wait()
        return try result.get()
    }

    private func run(seconds: Double, app: String?) async throws -> [String: Any] {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        } catch {
            throw NetError("cannot list shareable content (\(error.localizedDescription)); grant Porthole Screen Recording in System Settings")
        }
        guard let display = content.displays.first else { throw NetError("no display to attach the audio capture to") }

        var matched: [String] = []
        let filter: SCContentFilter
        if let app, !app.isEmpty {
            let needle = app.lowercased()
            let apps = content.applications.filter {
                $0.bundleIdentifier.lowercased() == needle || $0.applicationName.lowercased() == needle
                    || $0.applicationName.lowercased().contains(needle)
            }
            guard !apps.isEmpty else {
                let names = content.applications.map(\.applicationName).filter { !$0.isEmpty }.sorted()
                throw NetError("no running app matches \"\(app)\"; running: \(names.joined(separator: ", "))")
            }
            matched = apps.map { "\($0.applicationName) (\($0.bundleIdentifier))" }
            filter = SCContentFilter(display: display, including: apps, exceptingWindows: [])
        } else {
            filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        }

        let cfg = SCStreamConfiguration()
        cfg.capturesAudio = true
        cfg.excludesCurrentProcessAudio = true
        cfg.sampleRate = 48000
        cfg.channelCount = 2
        // Video is required by the stream but unused: keep it tiny and slow.
        cfg.width = 2
        cfg.height = 2
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: 1)

        let stream = SCStream(filter: filter, configuration: cfg, delegate: self)
        let queue = DispatchQueue(label: "porthole.audio")
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: DispatchQueue(label: "porthole.video"))
        try await stream.startCapture()
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        try? await stream.stopCapture()
        return try summarize(seconds: seconds, matched: matched)
    }

    private func summarize(seconds: Double, matched: [String]) throws -> [String: Any] {
        lock.lock(); defer { lock.unlock() }
        if let streamError { throw NetError("audio capture failed: \(streamError.localizedDescription)") }
        if let writeError { throw NetError("writing \(path) failed: \(writeError.localizedDescription)") }
        flushWindow()
        file = nil

        let peakDb = db(Double(peak))
        let threshold = -50.0
        let loud = levels.enumerated().filter { $0.element > threshold }
        var summary: [String: Any] = [
            "path": path,
            "seconds": Double(frames) / sampleRate,
            "requested_seconds": seconds,
            "peak_dbfs": round1(peakDb),
            "silent": loud.isEmpty,
            "window_seconds": AudioRecorder.window,
            // One level per window, in dBFS, floored at -90.
            "levels_dbfs": levels.map { round1(max($0, -90)) },
        ]
        if !matched.isEmpty { summary["apps"] = matched }
        if let first = loud.first, let last = loud.last {
            summary["sound_from"] = round1(Double(first.offset) * AudioRecorder.window)
            summary["sound_to"] = round1(Double(last.offset + 1) * AudioRecorder.window)
            summary["loud_fraction"] = round1(Double(loud.count) / Double(max(levels.count, 1)))
        }
        if frames == 0 {
            summary["note"] = "no audio buffers arrived; the source may be silent (ScreenCaptureKit sends nothing while nothing plays) or Screen Recording may be denied"
        }
        return summary
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        lock.lock(); streamError = error; lock.unlock()
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sb.isValid, let desc = sb.formatDescription,
              let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(desc)
        else { return }
        var asbd = asbdPtr.pointee
        guard let format = AVAudioFormat(streamDescription: &asbd) else { return }
        let count = AVAudioFrameCount(CMSampleBufferGetNumSamples(sb))
        guard count > 0, let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count) else { return }
        pcm.frameLength = count
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(sb, at: 0, frameCount: Int32(count), into: pcm.mutableAudioBufferList) == noErr else { return }

        lock.lock(); defer { lock.unlock() }
        do {
            if file == nil {
                sampleRate = format.sampleRate
                file = try AVAudioFile(forWriting: URL(fileURLWithPath: path), settings: format.settings, commonFormat: format.commonFormat, interleaved: format.isInterleaved)
            }
            try file?.write(from: pcm)
        } catch {
            writeError = error
        }
        frames += Int64(count)
        measure(pcm)
    }

    private func measure(_ pcm: AVAudioPCMBuffer) {
        guard let channels = pcm.floatChannelData else { return }
        let n = Int(pcm.frameLength)
        let chans = Int(pcm.format.channelCount)
        let stride = pcm.stride
        let perWindow = Int(sampleRate * AudioRecorder.window)
        for i in 0..<n {
            var sq: Float = 0
            for c in 0..<chans {
                let v = channels[c][i * stride]
                sq += v * v
                peak = max(peak, abs(v))
            }
            windowSumSquares += Double(sq / Float(chans))
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

    private func db(_ amplitude: Double) -> Double { amplitude > 0 ? 20 * log10(amplitude) : -120 }
    private func round1(_ x: Double) -> Double { (x * 10).rounded() / 10 }
}

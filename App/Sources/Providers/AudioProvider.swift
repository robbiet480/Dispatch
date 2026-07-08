import AVFAudio
import DispatchKit
import Foundation

/// Samples ambient audio for ~2 seconds via AVAudioRecorder metering and
/// reports average/peak dBFS (raw −160…0; display conversion is
/// AudioLevel.displayValue).
struct AudioProvider: SensorProvider {
    let kind = SensorKind.audio

    func capture() async throws -> SensorPayload {
        guard await AVAudioApplication.requestRecordPermission() else {
            throw ProviderError("microphone permission denied")
        }
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement)
        try session.setActive(true)
        defer { try? session.setActive(false) }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("dispatch-audio-probe.m4a")
        let recorder = try AVAudioRecorder(url: url, settings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 22050,
            AVNumberOfChannelsKey: 1,
        ])
        recorder.isMeteringEnabled = true
        recorder.record()
        defer {
            recorder.stop()
            try? FileManager.default.removeItem(at: url)
        }

        var averages: [Double] = []
        var peaks: [Double] = []
        for _ in 0..<8 { // 8 × 250 ms = 2 s
            try await Task.sleep(for: .milliseconds(250))
            recorder.updateMeters()
            averages.append(Double(recorder.averagePower(forChannel: 0)))
            peaks.append(Double(recorder.peakPower(forChannel: 0)))
        }
        let avg = averages.reduce(0, +) / Double(averages.count)
        let peak = peaks.max() ?? avg
        return .audio(AudioSample(avg: avg, peak: peak))
    }
}

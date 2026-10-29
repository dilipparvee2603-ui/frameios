import Foundation
import SwiftUI
import ffmpegkit

// MARK: - Log Entry
struct AppLogEntry: Identifiable {
    let id = UUID()
    let timestamp: Date
    let tag: String
    let message: String
    let isError: Bool

    var formattedTime: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: timestamp)
    }

    var fullFormatted: String {
        let prefix = isError ? "[ERROR]" : "[INFO]"
        return "\(formattedTime) \(prefix) [\(tag)]: \(message)"
    }
}

// MARK: - Centralized App Logger
final class AppLogger: ObservableObject {
    static let shared = AppLogger()

    @Published var logs: [AppLogEntry] = []
    private let maxEntries = 250

    private init() {
        log(tag: "SYSTEM", message: "CFX FrameStudio initialized", isError: false)
        setupFFmpegLogListener()
    }

    func log(tag: String, message: String, isError: Bool = false) {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        DispatchQueue.main.async {
            let entry = AppLogEntry(timestamp: Date(), tag: tag, message: trimmed, isError: isError)
            self.logs.append(entry)
            if self.logs.count > self.maxEntries {
                self.logs.removeFirst(self.logs.count - self.maxEntries)
            }
        }
    }

    func error(tag: String, message: String) {
        log(tag: tag, message: message, isError: true)
    }

    func getFullLogString() -> String {
        if logs.isEmpty {
            return "No logs recorded."
        }
        return logs.map { $0.fullFormatted }.joined(separator: "\n")
    }

    func clearLogs() {
        DispatchQueue.main.async {
            self.logs.removeAll()
            self.log(tag: "SYSTEM", message: "Logs cleared", isError: false)
        }
    }

    var errorCount: Int {
        logs.filter { $0.isError }.count
    }

    private func setupFFmpegLogListener() {
        FFmpegKitConfig.enableLogCallback { log in
            guard let log = log else { return }
            let level = log.getLevel()
            let message = log.getMessage() ?? ""
            let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)

            // AV_LOG_ERROR = 16, AV_LOG_FATAL = 8, AV_LOG_PANIC = 0
            if level <= 16 && !trimmed.isEmpty {
                AppLogger.shared.error(tag: "FFMPEG", message: trimmed)
            }
        }
    }
}


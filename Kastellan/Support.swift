import Foundation
import UserNotifications
import AppKit

/// Beobachtet das pending/-Verzeichnis und meldet Änderungen.
final class PendingWatcher: @unchecked Sendable {
    private var source: DispatchSourceFileSystemObject?
    private var fd: Int32 = -1
    private let onChange: @Sendable () -> Void
    private var timer: DispatchSourceTimer?

    init(directory: URL, onChange: @escaping @Sendable () -> Void) {
        self.onChange = onChange
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        fd = open(directory.path, O_EVTONLY)
        if fd >= 0 {
            let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .global())
            src.setEventHandler { [onChange] in onChange() }
            src.setCancelHandler { [fd] in close(fd) }
            src.resume()
            source = src
        }
        // Zusätzlich alle 5 s, falls ein Ereignis verloren geht (atomares Rename aus einem anderen Prozess).
        let t = DispatchSource.makeTimerSource(queue: .global())
        t.schedule(deadline: .now() + 5, repeating: 5)
        t.setEventHandler { [onChange] in onChange() }
        t.resume()
        timer = t
    }

    deinit {
        source?.cancel()
        timer?.cancel()
    }
}

enum Notifier {
    nonisolated(unsafe) private static var requested = false

    static func notify(title: String, body: String) {
        let center = UNUserNotificationCenter.current()
        if !requested {
            requested = true
            center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}

extension Date {
    var short: String { formatted(date: .abbreviated, time: .shortened) }
}

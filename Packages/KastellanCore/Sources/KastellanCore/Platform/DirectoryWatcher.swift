import Foundation

/// Beobachtet Verzeichnisse und ruft den Handler entprellt auf, wenn sich darin etwas ändert.
/// Auf macOS über kqueue (`DispatchSource`), auf Linux und Windows durch Abfragen der
/// Änderungszeiten alle zwei Sekunden. Für Freigaben, Rechte und Verbindungen reicht das.
public final class DirectoryWatcher: @unchecked Sendable {
    private let queue = DispatchQueue(label: "kastellan.watch")
    private var pending = false
    #if canImport(Darwin)
    private var sources: [DispatchSourceFileSystemObject] = []
    #else
    private var timer: DispatchSourceTimer?
    private var snapshot: [String: Date] = [:]
    #endif

    public init(paths: [String], onChange: @escaping @Sendable () -> Void) {
        #if canImport(Darwin)
        for path in paths {
            let fd = open(path, O_EVTONLY)
            guard fd >= 0 else { continue }
            let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename], queue: queue)
            src.setEventHandler { [weak self] in self?.fire(onChange) }
            src.setCancelHandler { close(fd) }
            src.resume()
            sources.append(src)
        }
        #else
        snapshot = Self.scan(paths)
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 2, repeating: 2)
        t.setEventHandler { [weak self] in
            guard let self else { return }
            let now = Self.scan(paths)
            if now != self.snapshot { self.snapshot = now; onChange() }
        }
        t.resume()
        timer = t
        #endif
    }

    deinit {
        #if canImport(Darwin)
        sources.forEach { $0.cancel() }
        #else
        timer?.cancel()
        #endif
    }

    private func fire(_ onChange: @escaping @Sendable () -> Void) {
        guard !pending else { return }
        pending = true
        queue.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.pending = false
            onChange()
        }
    }

    #if !canImport(Darwin)
    static func scan(_ paths: [String]) -> [String: Date] {
        var out: [String: Date] = [:]
        let fm = FileManager.default
        for dir in paths {
            for name in (try? fm.contentsOfDirectory(atPath: dir)) ?? [] {
                let full = (dir as NSString).appendingPathComponent(name)
                if let date = (try? fm.attributesOfItem(atPath: full))?[.modificationDate] as? Date { out[full] = date }
            }
        }
        return out
    }
    #endif
}

/// Läuft das Programm in einem interaktiven Terminal?
public enum TerminalCheck {
    public static var stdinIsTerminal: Bool {
        #if os(Windows)
        _isatty(0) != 0
        #else
        isatty(0) != 0
        #endif
    }
}

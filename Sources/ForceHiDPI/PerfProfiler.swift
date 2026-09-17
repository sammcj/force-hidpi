import Foundation
import IOKit

/// Optional system-level performance sampler. Writes one flat JSON record per
/// sample to a JSONL file so enabled/disabled runs can be compared with a
/// plain groupby on the config fields carried in every line.
///
/// The app's own cost is negligible; what matters is WindowServer CPU and GPU
/// load from compositing the 2x virtual display, so those are the headline
/// metrics. `ps` is used for per-process stats because libproc refuses
/// cross-user queries without root.
final class PerfProfiler {
    struct Config: Equatable {
        var active: Bool
        var hdr: Bool
        var scale: Double
        var hz: Double
        var panel: String?
    }

    private struct Header: Encodable {
        let t: String
        let appVersion: String
        let macos: String
        let chip: String?
        let intervalS: Double
        let note = "ws_cpu/app_cpu are ps %cpu, a decaying ~1 min average. Idle desktop only."
    }

    private struct Sample: Encodable {
        let t: String
        let active: Bool
        let hdr: Bool
        let scale: Double
        let hz: Double
        let panel: String?
        let wsCpu: Double?
        let wsRssMb: Double?
        let appCpu: Double?
        let gpuUtil: Double?
        let gpuMemMb: Double?
        let powerW: Double?
        let onBattery: Bool?
        let thermal: String
    }

    static let logDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/force-hidpi")

    private static let interval: TimeInterval = 5.0
    /// Retention: a new file per calendar day, old files pruned by age then
    /// by total size, oldest first.
    private static let maxAge: TimeInterval = 90 * 86_400
    private static let maxTotalBytes: Int64 = 200 * 1_048_576
    private let queue = DispatchQueue(label: "com.force-hidpi.perf", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var file: FileHandle?
    private var fileDay: Int?
    private var config: Config
    private let appVersion: String
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.keyEncodingStrategy = .convertToSnakeCase
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return e
    }()
    private let clock = ISO8601DateFormatter()

    var isRunning: Bool { timer != nil }

    init(appVersion: String, config: Config) {
        self.appVersion = appVersion
        self.config = config
    }

    func start() {
        guard timer == nil else { return }
        queue.sync { openFile() }
        guard file != nil else { return }

        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 1, repeating: Self.interval)
        t.setEventHandler { [weak self] in self?.sample() }
        t.resume()
        timer = t
    }

    func stop() {
        timer?.cancel()
        timer = nil
        queue.sync {
            try? file?.close()
            file = nil
        }
    }

    func update(_ config: Config) {
        queue.async { self.config = config }
    }

    // MARK: - Files

    /// Opens a fresh log file, writing the header, after pruning old ones.
    /// Runs on `queue`.
    private func openFile() {
        let dir = Self.logDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        Self.prune(in: dir)
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyyMMdd-HHmmss"
        let now = Date()
        let url = dir.appendingPathComponent("perf-\(stamp.string(from: now)).jsonl")
        guard FileManager.default.createFile(atPath: url.path, contents: nil),
              let handle = try? FileHandle(forWritingTo: url)
        else {
            print("perf: cannot open \(url.path)")
            return
        }
        file = handle
        fileDay = Calendar.current.ordinality(of: .day, in: .era, for: now)
        print("perf: logging to \(url.path)")

        write(Header(t: clock.string(from: now), appVersion: appVersion,
                     macos: ProcessInfo.processInfo.operatingSystemVersionString,
                     chip: Self.sysctlString("machdep.cpu.brand_string"),
                     intervalS: Self.interval))
    }

    private func rotateIfNewDay() {
        let today = Calendar.current.ordinality(of: .day, in: .era, for: Date())
        guard let fileDay, fileDay != today else { return }
        try? file?.close()
        file = nil
        openFile()
    }

    /// Deletes perf logs older than `maxAge`, then the oldest remaining until
    /// the directory is under `maxTotalBytes`.
    private static func prune(in dir: URL) {
        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]
        ) else { return }
        var logs = urls
            .filter { $0.lastPathComponent.hasPrefix("perf-") && $0.pathExtension == "jsonl" }
            .compactMap { url -> (url: URL, date: Date, size: Int64)? in
                guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
                      let date = values.contentModificationDate
                else { return nil }
                return (url, date, Int64(values.fileSize ?? 0))
            }
            .sorted { $0.date < $1.date }

        let cutoff = Date().addingTimeInterval(-maxAge)
        var total = logs.reduce(Int64(0)) { $0 + $1.size }
        while let oldest = logs.first, oldest.date < cutoff || total > maxTotalBytes {
            try? fm.removeItem(at: oldest.url)
            total -= oldest.size
            logs.removeFirst()
        }
    }

    // MARK: - Sampling

    private func sample() {
        rotateIfNewDay()
        let cfg = config
        let procs = Self.processStats()
        let gpu = Self.gpuStats()
        let power = Self.batteryPower()
        let s = Sample(
            t: clock.string(from: Date()),
            active: cfg.active, hdr: cfg.hdr, scale: cfg.scale, hz: cfg.hz, panel: cfg.panel,
            wsCpu: procs.windowServer?.cpu,
            wsRssMb: procs.windowServer.map { Self.round1($0.rssKb / 1024) },
            appCpu: procs.app?.cpu,
            gpuUtil: gpu?.util,
            gpuMemMb: gpu.map { Self.round1($0.memBytes / 1_048_576) },
            powerW: power.map { Self.round1($0.watts) },
            onBattery: power?.onBattery,
            thermal: Self.thermalName(ProcessInfo.processInfo.thermalState)
        )
        write(s)
    }

    private func write<T: Encodable>(_ record: T) {
        guard let file, var data = try? encoder.encode(record) else { return }
        data.append(0x0A)
        try? file.write(contentsOf: data)
    }

    // MARK: - Collectors

    private struct ProcStat {
        let cpu: Double
        let rssKb: Double
    }

    /// One `ps` call covers both WindowServer and ourselves.
    private static func processStats() -> (windowServer: ProcStat?, app: ProcStat?) {
        let ps = Process()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-axo", "pid=,%cpu=,rss=,comm="]
        let pipe = Pipe()
        ps.standardOutput = pipe
        ps.standardError = FileHandle.nullDevice
        guard (try? ps.run()) != nil else { return (nil, nil) }
        let out = pipe.fileHandleForReading.readDataToEndOfFile()
        ps.waitUntilExit()
        guard let text = String(data: out, encoding: .utf8) else { return (nil, nil) }

        let selfPid = String(ProcessInfo.processInfo.processIdentifier)
        var ws: ProcStat?
        var app: ProcStat?
        for line in text.split(separator: "\n") {
            let cols = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
            guard cols.count == 4, let cpu = Double(cols[1]), let rss = Double(cols[2]) else { continue }
            if cols[3].hasSuffix("/WindowServer") {
                ws = ProcStat(cpu: cpu, rssKb: rss)
            } else if cols[0] == selfPid {
                app = ProcStat(cpu: cpu, rssKb: rss)
            }
        }
        return (ws, app)
    }

    private static func gpuStats() -> (util: Double, memBytes: Double)? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault,
                                           IOServiceMatching("IOAccelerator"),
                                           &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        var service = IOIteratorNext(iterator)
        while service != 0 {
            defer { IOObjectRelease(service); service = IOIteratorNext(iterator) }
            guard let stats = IORegistryEntryCreateCFProperty(
                service, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0
            )?.takeRetainedValue() as? [String: Any],
                let util = stats["Device Utilization %"] as? Double
            else { continue }
            let mem = stats["In use system memory"] as? Double ?? 0
            return (util, mem)
        }
        return nil
    }

    /// Battery discharge/charge power. Only meaningful when on battery; on
    /// mains the amperage reflects charging, not system draw.
    private static func batteryPower() -> (watts: Double, onBattery: Bool)? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault,
                                                  IOServiceMatching("IOPMPowerSource"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        func prop<T>(_ key: String) -> T? {
            IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? T
        }
        guard let mA: Double = prop("InstantAmperage"), let mV: Double = prop("Voltage") else { return nil }
        let external: Bool = prop("ExternalConnected") ?? false
        return (abs(mA * mV / 1_000_000), !external)
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return nil }
        return String(cString: buf)
    }

    private static func round1(_ value: Double) -> Double {
        (value * 10).rounded() / 10
    }

    private static func thermalName(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }
}

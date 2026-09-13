import Darwin
import Foundation

enum MeasurementMode: String, CaseIterable, Codable, Sendable {
    case empty, idle, burst, settings, menu, real, native, badge, model, legacyModel
    case menuShell, menuAttached, engine
}

struct MeasurementOptions: Sendable {
    let mode: MeasurementMode
    let duration: Int

    static let usage = """
    codex-gauge-performance --mode empty|idle|burst|settings|menu|real|native|badge|model|legacyModel|menuShell|menuAttached|engine [--duration SECONDS]
    Defaults: idle, 600 seconds; burst 340 seconds; settings 60 seconds; menu 10 seconds.
    Duration: 1...86400; burst requires at least 340; settings at least 30; menu at least 5.
    Run in a logged-in macOS GUI session. No build or installation is performed.
    real uses verified automatic Codex executable discovery and the existing account.
    native, badge and model are diagnostic-only modes without a provider; empty remains the baseline.
    menu opens the app-owned native menu twice and cancels each tracking session with one timer.
    menuShell/menuAttached isolate an empty menu; engine runs synthetic refresh with no status item.
    Other provider modes use synthetic data and never launch Codex.
    Output: initial and final JSON resource records; no quota values or paths.
    CPU percentages represent one core; child CPU covers reaped owned children only.
    """

    init(arguments: [String]) throws {
        var mode = MeasurementMode.idle
        var duration: Int?
        var seen = Set<String>()
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            guard seen.insert(argument).inserted, index + 1 < arguments.count else {
                throw InvalidArguments()
            }
            let value = arguments[index + 1]
            switch argument {
            case "--mode":
                guard let selected = MeasurementMode(rawValue: value) else {
                    throw InvalidArguments()
                }
                mode = selected
            case "--duration":
                guard let seconds = Int(value), (1...86_400).contains(seconds) else {
                    throw InvalidArguments()
                }
                duration = seconds
            default:
                throw InvalidArguments()
            }
            index += 2
        }
        let defaultDuration: Int
        switch mode {
        case .burst: defaultDuration = 340
        case .settings: defaultDuration = 60
        case .menu: defaultDuration = 10
        default: defaultDuration = 600
        }
        let selectedDuration = duration ?? defaultDuration
        guard mode != .burst || selectedDuration >= 340,
              mode != .settings || selectedDuration >= 30,
              mode != .menu || selectedDuration >= 5 else {
            throw InvalidArguments()
        }
        self.mode = mode
        self.duration = selectedDuration
    }

    struct InvalidArguments: Error {}
}

struct ResourceSnapshot: Encodable, Sendable {
    let appUserCPUSeconds: Double?
    let appSystemCPUSeconds: Double?
    let appResidentBytes: UInt64?
    let appPeakResidentBytes: Int64?
    let terminatedOwnedChildrenUserCPUSeconds: Double?
    let terminatedOwnedChildrenSystemCPUSeconds: Double?

    static func capture() -> Self {
        var app = rusage()
        var children = rusage()
        let appOK = getrusage(RUSAGE_SELF, &app) == 0
        let childrenOK = getrusage(RUSAGE_CHILDREN, &children) == 0
        return Self(
            appUserCPUSeconds: appOK ? seconds(app.ru_utime) : nil,
            appSystemCPUSeconds: appOK ? seconds(app.ru_stime) : nil,
            appResidentBytes: residentBytes(),
            appPeakResidentBytes: appOK ? Int64(app.ru_maxrss) : nil,
            terminatedOwnedChildrenUserCPUSeconds: childrenOK ? seconds(children.ru_utime) : nil,
            terminatedOwnedChildrenSystemCPUSeconds: childrenOK ? seconds(children.ru_stime) : nil
        )
    }

    var appCPUSeconds: Double? {
        guard let appUserCPUSeconds, let appSystemCPUSeconds else { return nil }
        return appUserCPUSeconds + appSystemCPUSeconds
    }

    var childrenCPUSeconds: Double? {
        guard let terminatedOwnedChildrenUserCPUSeconds,
              let terminatedOwnedChildrenSystemCPUSeconds else { return nil }
        return terminatedOwnedChildrenUserCPUSeconds + terminatedOwnedChildrenSystemCPUSeconds
    }

    private static func seconds(_ value: timeval) -> Double {
        Double(value.tv_sec) + Double(value.tv_usec) / 1_000_000
    }

    private static func residentBytes() -> UInt64? {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size
        )
        let capacity = Int(count)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: capacity) { rebound in
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), rebound, &count)
            }
        }
        return result == KERN_SUCCESS ? UInt64(info.resident_size) : nil
    }
}

struct ResourceDelta: Encodable, Sendable {
    let elapsedSeconds: Double
    let appCPUSeconds: Double?
    let appAverageCPUPercentOfOneCore: Double?
    let terminatedOwnedChildrenCPUSeconds: Double?
    let terminatedOwnedChildrenAverageCPUPercentOfOneCore: Double?

    init(initial: ResourceSnapshot, final: ResourceSnapshot, elapsed: Double) {
        elapsedSeconds = elapsed
        appCPUSeconds = Self.difference(initial.appCPUSeconds, final.appCPUSeconds)
        terminatedOwnedChildrenCPUSeconds = Self.difference(
            initial.childrenCPUSeconds, final.childrenCPUSeconds
        )
        appAverageCPUPercentOfOneCore = appCPUSeconds.map { 100 * $0 / max(elapsed, 0.001) }
        terminatedOwnedChildrenAverageCPUPercentOfOneCore = terminatedOwnedChildrenCPUSeconds.map {
            100 * $0 / max(elapsed, 0.001)
        }
    }

    private static func difference(_ initial: Double?, _ final: Double?) -> Double? {
        guard let initial, let final else { return nil }
        return max(0, final - initial)
    }
}

struct MeasurementTimingValidity: Encodable, Sendable {
    let requestedDurationSeconds: Int
    let continuousElapsedSeconds: Double
    let awakeElapsedSeconds: Double
    let estimatedSleepSeconds: Double
    let overrunSeconds: Double
    let maximumOverrunSeconds = 5.0
    let maximumEstimatedSleepSeconds = 1.0
    let isValid: Bool

    init(requestedDuration: Int, continuousElapsed: Double, awakeElapsed: Double) {
        requestedDurationSeconds = requestedDuration
        continuousElapsedSeconds = continuousElapsed
        awakeElapsedSeconds = awakeElapsed
        estimatedSleepSeconds = max(0, continuousElapsed - awakeElapsed)
        overrunSeconds = max(0, continuousElapsed - Double(requestedDuration))
        isValid = continuousElapsed >= Double(requestedDuration)
            && overrunSeconds <= maximumOverrunSeconds
            && estimatedSleepSeconds <= maximumEstimatedSleepSeconds
    }
}

struct MeasurementMetadata: Encodable, Sendable {
    let mode: MeasurementMode
    let requestedDurationSeconds: Int
    let providerKind: String
    let diagnosticOnly: Bool
    let operatingSystem: String
    let architecture: String
    let buildConfiguration: String
    let logicalProcessorCount: Int
    let hostLowPowerMode: Bool
    let coordinatorLowPowerMode = false
    let refreshProfile = "balanced"
    let childCPUScope = "getrusage_rusage_children_reaped_owned_children_only"
    let sessionCounterScope = "session_leases_not_observed_operating_system_process_counts"

    init(options: MeasurementOptions) {
        mode = options.mode
        requestedDurationSeconds = options.duration
        switch options.mode {
        case .native, .badge, .model, .legacyModel, .menuShell, .menuAttached, .engine:
            diagnosticOnly = true
        default:
            diagnosticOnly = false
        }
        switch options.mode {
        case .empty, .native, .badge, .model, .legacyModel, .menuShell, .menuAttached:
            providerKind = "none"
        case .real: providerKind = "real_codex"
        default: providerKind = "synthetic_no_child_processes"
        }
        let version = ProcessInfo.processInfo.operatingSystemVersion
        operatingSystem = "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
        #if arch(arm64)
        architecture = "arm64"
        #else
        architecture = "x86_64"
        #endif
        #if DEBUG
        buildConfiguration = "debug"
        #else
        buildConfiguration = "release"
        #endif
        logicalProcessorCount = ProcessInfo.processInfo.processorCount
        hostLowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
    }
}

func elapsedSeconds(since start: ContinuousClock.Instant) -> Double {
    let components = start.duration(to: ContinuousClock().now).components
    return Double(components.seconds) + Double(components.attoseconds) / 1e18
}

func awakeElapsedSeconds(since start: SuspendingClock.Instant) -> Double {
    let components = start.duration(to: SuspendingClock().now).components
    return Double(components.seconds) + Double(components.attoseconds) / 1e18
}

func writeMeasurement<T: Encodable>(_ value: T) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    // Only the explicitly defined metadata/counter records may reach this output.
    guard var data = try? encoder.encode(value) else { return }
    data.append(0x0A)
    try? FileHandle.standardOutput.write(contentsOf: data)
}

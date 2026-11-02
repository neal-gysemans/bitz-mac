import AppKit
import Combine
import CoreGraphics
import Darwin
import Foundation
import IOKit.pwr_mgt

// MARK: - Real Apple Silicon Hardware Sensor Reader

/// Reads live Apple Silicon die temperature sensors (`IOHIDEventSystemClient`) and
/// Mach kernel CPU load ticks (`host_statistics` with `HOST_CPU_LOAD_INFO`) without
/// requiring root privileges or private headers.
@MainActor
public final class AppleSiliconHardwareSensors {
    public static let shared = AppleSiliconHardwareSensors()

    private var previousCPUTicks: (user: UInt64, system: UInt64, idle: UInt64, nice: UInt64)?

    // MARK: - Cached Pointers and Functions
    typealias CreateFn = @convention(c) (CFAllocator?) -> Unmanaged<AnyObject>?
    typealias SetMatchingFn = @convention(c) (AnyObject, CFDictionary) -> Void
    typealias CopyServicesFn = @convention(c) (AnyObject) -> Unmanaged<CFArray>?
    typealias CopyEventFn = @convention(c) (AnyObject, Int64, Int32, Int64) -> Unmanaged<AnyObject>?
    typealias GetFloatFn = @convention(c) (AnyObject, Int32) -> Double

    nonisolated(unsafe) private var ioKitHandle: UnsafeMutableRawPointer?
    nonisolated(unsafe) private var cachedClient: AnyObject?
    nonisolated(unsafe) private var cachedThermalServices: [AnyObject]?
    nonisolated(unsafe) private var copyServices: CopyServicesFn?
    nonisolated(unsafe) private var copyEvent: CopyEventFn?
    nonisolated(unsafe) private var getFloat: GetFloatFn?
    private var lastTemperatureSample: (celsius: Double, timestamp: TimeInterval)?

    public init() {
        // Cache IOHID pointers so we don't dlopen / dlsym every 5 seconds.
        if let handle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW) {
            self.ioKitHandle = handle
            if let createSym = dlsym(handle, "IOHIDEventSystemClientCreate"),
               let matchSym = dlsym(handle, "IOHIDEventSystemClientSetMatching"),
               let servicesSym = dlsym(handle, "IOHIDEventSystemClientCopyServices"),
               let eventSym = dlsym(handle, "IOHIDServiceClientCopyEvent"),
               let floatSym = dlsym(handle, "IOHIDEventGetFloatValue") {

                let create = unsafeBitCast(createSym, to: CreateFn.self)
                let setMatching = unsafeBitCast(matchSym, to: SetMatchingFn.self)
                self.copyServices = unsafeBitCast(servicesSym, to: CopyServicesFn.self)
                self.copyEvent = unsafeBitCast(eventSym, to: CopyEventFn.self)
                self.getFloat = unsafeBitCast(floatSym, to: GetFloatFn.self)

                if let client = create(kCFAllocatorDefault)?.takeRetainedValue() {
                    let matching: [String: Int] = ["PrimaryUsagePage": 0xff00, "PrimaryUsage": 5]
                    setMatching(client, matching as CFDictionary)
                    self.cachedClient = client
                }
            }
        }
    }

    deinit {
        self.cachedThermalServices = nil
        self.cachedClient = nil
        self.copyServices = nil
        self.copyEvent = nil
        self.getFloat = nil
        if let handle = ioKitHandle {
            dlclose(handle)
        }
    }

    /// Queries Apple Silicon `IOHIDEventSystemClient` thermal sensors (`PrimaryUsagePage: 0xFF00`, `PrimaryUsage: 5`)
    /// and returns the maximum active die/SOC temperature in degrees Celsius.
    /// Caches active thermal service handles and throttles synchronous Mach IPC when the system is cool (#70).
    public func readMaxDieTemperatureCelsius() -> Double? {
        guard let client = cachedClient,
              let copyServices = copyServices,
              let copyEvent = copyEvent,
              let getFloat = getFloat else {
            return nil
        }

        let now = ProcessInfo.processInfo.systemUptime
        if let cached = lastTemperatureSample {
            let isNominalAndCool = ProcessInfo.processInfo.thermalState == .nominal && cached.celsius < 70.0
            let ttl: TimeInterval = isNominalAndCool ? 15.0 : 2.0
            if now >= cached.timestamp && (now - cached.timestamp) < ttl {
                return cached.celsius
            }
        }

        if let services = cachedThermalServices, !services.isEmpty {
            var maxTemp: Double?
            for service in services {
                if let event = copyEvent(service, 15, 0, 0)?.takeRetainedValue() {
                    let celsius = getFloat(event, 15 << 16)
                    if celsius > 15.0 && celsius < 130.0 {
                        if let currentMax = maxTemp {
                            if celsius > currentMax { maxTemp = celsius }
                        } else {
                            maxTemp = celsius
                        }
                    }
                }
            }
            if let resolved = maxTemp {
                lastTemperatureSample = (resolved, now)
                return resolved
            }
            cachedThermalServices = nil
        }

        guard let servicesRef = copyServices(client)?.takeRetainedValue() else {
            return nil
        }
        let count = CFArrayGetCount(servicesRef)
        var discoveredServices: [AnyObject] = []
        discoveredServices.reserveCapacity(count)
        var maxTemp: Double?

        for index in 0..<count {
            guard let rawPtr = CFArrayGetValueAtIndex(servicesRef, index) else { continue }
            let service = Unmanaged<AnyObject>.fromOpaque(rawPtr).takeUnretainedValue()
            if let event = copyEvent(service, 15, 0, 0)?.takeRetainedValue() {
                let celsius = getFloat(event, 15 << 16)
                if celsius > 15.0 && celsius < 130.0 {
                    discoveredServices.append(service)
                    if let currentMax = maxTemp {
                        if celsius > currentMax { maxTemp = celsius }
                    } else {
                        maxTemp = celsius
                    }
                }
            }
        }

        if !discoveredServices.isEmpty {
            cachedThermalServices = discoveredServices
        }
        if let resolved = maxTemp {
            lastTemperatureSample = (resolved, now)
        }
        return maxTemp
    }

    /// Reads real-time system-wide CPU load percentage (`0.0 ... 100.0`) from the Mach kernel via `HOST_CPU_LOAD_INFO`.
    public func readSystemCPULoadPercentage() -> Double? {
        var size = mach_msg_type_number_t(
            MemoryLayout<host_cpu_load_info_data_t>.stride / MemoryLayout<integer_t>.stride
        )
        var cpuLoad = host_cpu_load_info()
        let hostPort = mach_host_self()
        let result = withUnsafeMutablePointer(to: &cpuLoad) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(size)) {
                host_statistics(hostPort, HOST_CPU_LOAD_INFO, $0, &size)
            }
        }
        MachCompatibility.deallocateHostPort(hostPort)
        guard result == KERN_SUCCESS else { return nil }

        let current = (
            user: UInt64(cpuLoad.cpu_ticks.0),
            system: UInt64(cpuLoad.cpu_ticks.1),
            idle: UInt64(cpuLoad.cpu_ticks.2),
            nice: UInt64(cpuLoad.cpu_ticks.3)
        )
        defer { previousCPUTicks = current }

        guard let previous = previousCPUTicks else {
            let total = current.user + current.system + current.idle + current.nice
            guard total > 0 else { return 0.0 }
            let busy = current.user + current.system + current.nice
            return (Double(busy) / Double(total)) * 100.0
        }

        let userDelta = current.user >= previous.user ? current.user - previous.user : 0
        let systemDelta = current.system >= previous.system ? current.system - previous.system : 0
        let idleDelta = current.idle >= previous.idle ? current.idle - previous.idle : 0
        let niceDelta = current.nice >= previous.nice ? current.nice - previous.nice : 0

        let totalDelta = userDelta + systemDelta + idleDelta + niceDelta
        guard totalDelta > 0 else { return 0.0 }
        let busyDelta = userDelta + systemDelta + niceDelta
        return (Double(busyDelta) / Double(totalDelta)) * 100.0
    }

    private static let displaySleepAssertionTypes: Set<String> = [
        "PreventUserIdleDisplaySleep",
        "NoDisplaySleepAssertion"
    ]

    private static let ignoredSystemProcesses: Set<String> = [
        "powerd", "windowserver", "loginwindow", "caffeinate", "amphetamine", "coreaudiod"
    ]

    private static let meetingProcessKeywords: [String] = [
        "zoom", "teams", "slack", "webex", "facetime"
    ]

    private static let browserAndMediaProcessKeywords: [String] = [
        "firefox", "plugin-container", "zen", "waterfox",
        "chrome", "brave", "edgemac", "microsoft edge", "arc", "thebrowser", "opera", "vivaldi",
        "safari", "webkit",
        "vlc", "iina", "quicktime", "tv", "netflix", "prime", "disney", "twitch", "youtube",
        "plex", "infuse", "mpv", "elmedia", "movist", "crunchyroll", "hulu"
    ]

    private static let mediaAssertionNameKeywords: [String] = [
        "video-playing", "audio-playing", "media playback", "video wake lock",
        "webkit media", "playing video", "movie", "streaming"
    ]

    /// Queries macOS Power Management (`IOPMCopyAssertionsByProcess`) to detect whether a browser or
    /// media player process is currently holding an active display-sleep prevention assertion
    /// (`PreventUserIdleDisplaySleep` or `NoDisplaySleepAssertion`), indicating active video playback.
    public static func isDisplaySleepPreventedByMediaPlayback() -> Bool {
        var assertionsByPID: Unmanaged<CFDictionary>?
        let status = IOPMCopyAssertionsByProcess(&assertionsByPID)
        guard status == kIOReturnSuccess,
              let pidMap = assertionsByPID?.takeRetainedValue() as? [Int: [[String: Any]]] else {
            return false
        }

        for (_, assertions) in pidMap {
            for assertion in assertions {
                let trueType = (assertion["AssertionTrueType"] as? String) ?? ""
                let assertType = (assertion["AssertType"] as? String) ?? ""
                guard AppleSiliconHardwareSensors.displaySleepAssertionTypes.contains(trueType) || AppleSiliconHardwareSensors.displaySleepAssertionTypes.contains(assertType) else {
                    continue
                }
                if let level = assertion["AssertLevel"] as? Int, level == 0 {
                    continue
                }
                let processName = ((assertion["Process Name"] as? String) ?? "").lowercased()
                let assertName = ((assertion["AssertName"] as? String) ?? "").lowercased()

                if AppleSiliconHardwareSensors.ignoredSystemProcesses.contains(processName) {
                    continue
                }
                if AppleSiliconHardwareSensors.meetingProcessKeywords.contains(where: { processName.contains($0) }) {
                    continue
                }
                if AppleSiliconHardwareSensors.browserAndMediaProcessKeywords.contains(where: { processName.contains($0) }) ||
                   AppleSiliconHardwareSensors.mediaAssertionNameKeywords.contains(where: { assertName.contains($0) }) {
                    return true
                }
            }
        }
        return false
    }
}

// MARK: - Browser Active Tab Reader (Zero-Permission Firefox mozLz40 Session Reader)

/// Reads the active browser tab URL and title from Firefox's live `recovery.jsonlz4` session store
/// without requiring Accessibility or AppleEvents permissions.
@MainActor
public enum BrowserTabTelemetryReader {
    private static var cachedFirefoxSession: (path: String, modDate: Date, preferStreaming: Bool, url: String?, title: String?)?
    private static var cachedChromiumSession: (path: String, modDate: Date, url: String?)?
    private static let chromiumProfileCandidates: [String] = ["Default", "Profile 1", "Profile 2", "Profile 3", ""]

    // Cached base directories for chromium browsers
    private static let braveBaseDirs = ["BraveSoftware/Brave-Browser"]
    private static let edgeBaseDirs = ["Microsoft Edge"]
    private static let arcBaseDirs = ["Arc/User Data"]
    private static let operaBaseDirs = ["com.operasoftware.Opera", "com.operasoftware.OperaGX"]
    private static let vivaldiBaseDirs = ["Vivaldi"]
    private static let chromeBaseDirs = ["Google/Chrome", "Google/Chrome Canary", "Chromium"]

    /// Decompresses a Mozilla `mozLz40\0` LZ4 block into raw JSON `Data`.
    public static func decompressMozLZ4(_ data: Data) -> Data? {
        guard data.count > 12 else { return nil }
        let magic = String(data: data.subdata(in: 0..<7), encoding: .ascii)
        guard magic == "mozLz40" else { return nil }

        let expectedSize = data.subdata(in: 8..<12).withUnsafeBytes {
            $0.load(as: UInt32.self).littleEndian
        }
        guard expectedSize > 0 && expectedSize < 50_000_000 else { return nil }

        var out = Data()
        out.reserveCapacity(Int(expectedSize))

        let src = [UInt8](data.subdata(in: 12..<data.count))
        var ip = 0
        let end = src.count

        while ip < end {
            let token = Int(src[ip])
            ip += 1

            var literalLength = token >> 4
            if literalLength == 15 {
                while ip < end {
                    let s = Int(src[ip])
                    ip += 1
                    literalLength += s
                    if s != 255 { break }
                }
            }
            guard ip + literalLength <= end else { break }
            out.append(contentsOf: src[ip..<(ip + literalLength)])
            ip += literalLength

            if ip >= end { break }
            guard ip + 2 <= end else { break }
            let offset = Int(src[ip]) | (Int(src[ip + 1]) << 8)
            ip += 2
            guard offset > 0 && offset <= out.count else { break }

            var matchLength = (token & 0x0F) + 4
            if (token & 0x0F) == 15 {
                while ip < end {
                    let s = Int(src[ip])
                    ip += 1
                    matchLength += s
                    if s != 255 { break }
                }
            }

            let matchStart = out.count - offset
            for i in 0..<matchLength {
                out.append(out[matchStart + i])
            }
        }
        return out
    }

    /// Reads the currently selected tab's `(url, title)` from the user's active Firefox profile.
    /// When `preferStreamingTabWhenVideoPlaying` is `true` (e.g., Firefox holds a `video-playing` power assertion
    /// while `recovery.jsonlz4` has not yet flushed a recent tab switch or video is in Picture-in-Picture),
    /// falls back to the most recently accessed open streaming/social tab in the session if the selected tab is not one.
    public static func readActiveFirefoxTab(preferStreamingTabWhenVideoPlaying: Bool = false) -> (url: String?, title: String?) {
        let fm = FileManager.default
        let profilesDir = fm.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Firefox/Profiles")
        guard let profiles = try? fm.contentsOfDirectory(at: profilesDir, includingPropertiesForKeys: nil) else {
            return (nil, nil)
        }

        var latestSessionURL: URL?
        var latestModDate: Date = .distantPast

        for profile in profiles {
            let candidate = profile.appendingPathComponent("sessionstore-backups/recovery.jsonlz4")
            if let attrs = try? fm.attributesOfItem(atPath: candidate.path),
               let modDate = attrs[.modificationDate] as? Date,
               modDate > latestModDate {
                latestModDate = modDate
                latestSessionURL = candidate
            }
        }

        guard let sessionFile = latestSessionURL else {
            return (nil, nil)
        }
        if let cached = cachedFirefoxSession,
           cached.path == sessionFile.path,
           cached.modDate == latestModDate,
           cached.preferStreaming == preferStreamingTabWhenVideoPlaying {
            return (cached.url, cached.title)
        }
        guard let raw = try? Data(contentsOf: sessionFile),
              let decompressed = decompressMozLZ4(raw),
              let json = try? JSONSerialization.jsonObject(with: decompressed) as? [String: Any],
              let windows = json["windows"] as? [[String: Any]],
              !windows.isEmpty else {
            return (nil, nil)
        }

        let selectedWinIdx = max(0, min(windows.count - 1, ((json["selectedWindow"] as? Int) ?? 1) - 1))
        let win = windows[selectedWinIdx]
        guard let tabs = win["tabs"] as? [[String: Any]], !tabs.isEmpty else {
            return (nil, nil)
        }

        let selectedTabIdx = max(0, min(tabs.count - 1, ((win["selected"] as? Int) ?? 1) - 1))
        let tab = tabs[selectedTabIdx]
        guard let entries = tab["entries"] as? [[String: Any]], !entries.isEmpty else {
            return (nil, nil)
        }

        let entryIdx = max(0, min(entries.count - 1, ((tab["index"] as? Int) ?? entries.count) - 1))
        let entry = entries[entryIdx]
        let selectedURL = entry["url"] as? String
        let selectedTitle = entry["title"] as? String

        if preferStreamingTabWhenVideoPlaying &&
           !ActivityMonitorService.containsDopamineStreamingOrSocialKeyword(url: selectedURL, title: selectedTitle) {
            var bestStreamingTab: (url: String?, title: String?, lastAccessed: Int64)? = nil
            for w in windows {
                guard let wTabs = w["tabs"] as? [[String: Any]] else { continue }
                for t in wTabs {
                    guard let tEntries = t["entries"] as? [[String: Any]], !tEntries.isEmpty else { continue }
                    let tIdx = max(0, min(tEntries.count - 1, ((t["index"] as? Int) ?? tEntries.count) - 1))
                    let tEntry = tEntries[tIdx]
                    let tURL = tEntry["url"] as? String
                    let tTitle = tEntry["title"] as? String
                    if ActivityMonitorService.containsDopamineStreamingOrSocialKeyword(url: tURL, title: tTitle) {
                        let accessed = (t["lastAccessed"] as? Int64) ?? Int64((t["lastAccessed"] as? Int) ?? 0)
                        if bestStreamingTab == nil || accessed > (bestStreamingTab?.lastAccessed ?? -1) {
                            bestStreamingTab = (tURL, tTitle, accessed)
                        }
                    }
                }
            }
            if let found = bestStreamingTab {
                cachedFirefoxSession = (sessionFile.path, latestModDate, preferStreamingTabWhenVideoPlaying, found.url, found.title)
                return (found.url, found.title)
            }
        }

        cachedFirefoxSession = (sessionFile.path, latestModDate, preferStreamingTabWhenVideoPlaying, selectedURL, selectedTitle)
        return (selectedURL, selectedTitle)
    }

    /// Extracts the most recently navigated `http(s)://` URL from a Chromium `SNSS` session buffer.
    public static func extractLatestURLFromChromiumSNSS(_ data: Data) -> String? {
        guard !data.isEmpty else { return nil }
        let tailSize = min(data.count, 65_536)
        let slice = data.subdata(in: (data.count - tailSize)..<data.count)
        let ascii = String(decoding: slice, as: UTF8.self)

        var lastValidURL: String? = nil
        var searchRange = ascii.startIndex..<ascii.endIndex
        while let range = ascii.range(of: "https://", options: [], range: searchRange) ??
                          ascii.range(of: "http://", options: [], range: searchRange) {
            let sub = ascii[range.lowerBound...]
            var urlChars: [Character] = []
            for ch in sub {
                if let scalar = ch.unicodeScalars.first,
                   scalar.value >= 0x21 && scalar.value <= 0x7E && ch != "\"" && ch != "'" && ch != "<" && ch != ">" {
                    urlChars.append(ch)
                } else {
                    break
                }
            }
            let candidate = String(urlChars)
            if candidate.count > 10,
               !candidate.contains("google.com/complete/search"),
               !candidate.contains("accounts.google.com/RotateCookies"),
               !candidate.contains("chrome-extension://"),
               URL(string: candidate)?.host != nil {
                lastValidURL = candidate
            }
            searchRange = range.upperBound..<ascii.endIndex
        }
        return lastValidURL
    }

    /// Reads the latest active tab URL from Chromium-based browsers (Chrome, Brave, Edge, Arc, Opera, Vivaldi)
    /// without requiring Accessibility or AppleEvents permissions.
    public static func readActiveChromiumTab(forBundleID bundleID: String) -> (url: String?, title: String?) {
        let lower = bundleID.lowercased()
        let fm = FileManager.default
        let appSupport = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")

        let relativeBaseDirs: [String]
        if lower.contains("brave") {
            relativeBaseDirs = braveBaseDirs
        } else if lower.contains("edgemac") || lower.contains("microsoft.edge") {
            relativeBaseDirs = edgeBaseDirs
        } else if lower.contains("thebrowser") || lower.contains("arc") {
            relativeBaseDirs = arcBaseDirs
        } else if lower.contains("opera") {
            relativeBaseDirs = operaBaseDirs
        } else if lower.contains("vivaldi") {
            relativeBaseDirs = vivaldiBaseDirs
        } else {
            relativeBaseDirs = chromeBaseDirs
        }

        var newestSessionFile: URL? = nil
        var newestModDate: Date = .distantPast

        for rel in relativeBaseDirs {
            let baseDir = appSupport.appendingPathComponent(rel)
            for prof in chromiumProfileCandidates {
                let sessionsDir = prof.isEmpty
                    ? baseDir.appendingPathComponent("Sessions")
                    : baseDir.appendingPathComponent(prof).appendingPathComponent("Sessions")
                guard let files = try? fm.contentsOfDirectory(at: sessionsDir, includingPropertiesForKeys: [.contentModificationDateKey]) else {
                    continue
                }
                for file in files where file.lastPathComponent.hasPrefix("Session_") {
                    if let attrs = try? fm.attributesOfItem(atPath: file.path),
                       let modDate = attrs[.modificationDate] as? Date,
                       modDate > newestModDate {
                        newestModDate = modDate
                        newestSessionFile = file
                    }
                }
            }
        }

        guard let sessionFile = newestSessionFile else {
            return (nil, nil)
        }
        if let cached = cachedChromiumSession,
           cached.path == sessionFile.path,
           cached.modDate == newestModDate {
            return (cached.url, nil)
        }
        guard let raw = try? Data(contentsOf: sessionFile),
              let url = extractLatestURLFromChromiumSNSS(raw) else {
            return (nil, nil)
        }
        cachedChromiumSession = (sessionFile.path, newestModDate, url)
        return (url, nil)
    }

    /// Reads the currently active tab URL and title from Safari via AppleScript if permitted,
    /// or returns `(nil, nil)` without throwing or hanging.
    public static func readActiveSafariTab() -> (url: String?, title: String?) {
        let scriptSource = """
        tell application "Safari"
            if (count of windows) > 0 then
                set currentTab to current tab of front window
                return {URL of currentTab, name of currentTab}
            end if
        end tell
        return {"", ""}
        """
        guard let script = NSAppleScript(source: scriptSource) else {
            return (nil, nil)
        }
        var errorInfo: NSDictionary?
        let descriptor = script.executeAndReturnError(&errorInfo)
        guard errorInfo == nil, descriptor.numberOfItems >= 2 else {
            return (nil, nil)
        }
        let url = descriptor.atIndex(1)?.stringValue
        let title = descriptor.atIndex(2)?.stringValue
        let cleanURL = (url?.isEmpty ?? true) ? nil : url
        let cleanTitle = (title?.isEmpty ?? true) ? nil : title
        return (cleanURL, cleanTitle)
    }
}

// MARK: - ActivityTelemetryProviding Seam

/// Protocol abstracting macOS foreground application, user input idle duration,
/// and system thermal state queries for deterministic, privacy-safe telemetry.
@MainActor
public protocol ActivityTelemetryProviding {
    /// Returns the bundle identifier of the currently active foreground application, if any.
    func frontmostBundleIdentifier() -> String?

    /// Returns the localized name of the currently active foreground application, if any.
    func frontmostApplicationName() -> String?

    /// Returns the number of seconds elapsed since the last mouse or keyboard event.
    func secondsSinceLastInput() -> TimeInterval

    /// Returns the current macOS system thermal state.
    func thermalState() -> ProcessInfo.ThermalState

    /// Returns an optional CPU package/die temperature in Celsius if available.
    func cpuTemperatureCelsius() -> Double?

    /// Returns an optional system-wide CPU load percentage (`0.0 ... 100.0`) if available.
    func cpuLoadPercentage() -> Double?

    /// Returns the URL of the currently active browser tab, if the frontmost app is a supported browser.
    func activeBrowserTabURL() -> String?

    /// Returns the title of the currently active browser tab, if the frontmost app is a supported browser.
    func activeBrowserTabTitle() -> String?

    /// Returns the URL and title of the currently active browser tab as a single tuple, if available.
    func activeBrowserTab() -> (url: String?, title: String?)

    /// Returns `true` if a browser or media player is actively playing video and preventing macOS display sleep.
    func isVideoPlaybackActive() -> Bool

    /// Returns the current timestamp for deterministic break duration calculation.
    func now() -> Date
}

extension ActivityTelemetryProviding {
    public func frontmostApplicationName() -> String? {
        frontmostBundleIdentifier()
    }

    public func cpuLoadPercentage() -> Double? {
        nil
    }

    public func activeBrowserTabURL() -> String? {
        nil
    }

    public func activeBrowserTabTitle() -> String? {
        nil
    }

    public func activeBrowserTab() -> (url: String?, title: String?) {
        (activeBrowserTabURL(), activeBrowserTabTitle())
    }

    public func isVideoPlaybackActive() -> Bool {
        false
    }
}

/// Production macOS telemetry provider backed by `NSWorkspace`, `CGEventSource`, `ProcessInfo`,
/// and `AppleSiliconHardwareSensors` (`IOHIDEventSystemClient` + Mach `HOST_CPU_LOAD_INFO`).
/// Strictly complies with `C-003` (zero Accessibility or keylogging APIs).
@MainActor
public struct SystemActivityTelemetryProvider: ActivityTelemetryProviding {
    public init() {}

    public func frontmostBundleIdentifier() -> String? {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    }

    public func frontmostApplicationName() -> String? {
        NSWorkspace.shared.frontmostApplication?.localizedName
    }

    private static let trackedInputEventTypes: [CGEventType] = [
        .mouseMoved,
        .leftMouseDown,
        .leftMouseUp,
        .rightMouseDown,
        .scrollWheel,
        .keyDown,
        .flagsChanged
    ]

    public func secondsSinceLastInput() -> TimeInterval {
        Self.trackedInputEventTypes
            .map { CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0) }
            .min() ?? 0.0
    }

    public func thermalState() -> ProcessInfo.ThermalState {
        ProcessInfo.processInfo.thermalState
    }

    public func cpuTemperatureCelsius() -> Double? {
        AppleSiliconHardwareSensors.shared.readMaxDieTemperatureCelsius()
    }

    public func cpuLoadPercentage() -> Double? {
        AppleSiliconHardwareSensors.shared.readSystemCPULoadPercentage()
    }

    public func activeBrowserTab() -> (url: String?, title: String?) {
        guard let bundleID = frontmostBundleIdentifier()?.lowercased() else {
            return (nil, nil)
        }
        if bundleID.contains("firefox") || bundleID.contains("zen") || bundleID.contains("waterfox") {
            return BrowserTabTelemetryReader.readActiveFirefoxTab(
                preferStreamingTabWhenVideoPlaying: isVideoPlaybackActive()
            )
        }
        if bundleID.contains("chrome") || bundleID.contains("brave") || bundleID.contains("edgemac") ||
           bundleID.contains("thebrowser") || bundleID.contains("opera") || bundleID.contains("vivaldi") {
            return BrowserTabTelemetryReader.readActiveChromiumTab(forBundleID: bundleID)
        }
        if bundleID.contains("safari") {
            return BrowserTabTelemetryReader.readActiveSafariTab()
        }
        return (nil, nil)
    }

    public func activeBrowserTabURL() -> String? {
        activeBrowserTab().url
    }

    public func activeBrowserTabTitle() -> String? {
        activeBrowserTab().title
    }

    public func isVideoPlaybackActive() -> Bool {
        AppleSiliconHardwareSensors.isDisplaySleepPreventedByMediaPlayback()
    }

    public func now() -> Date {
        Date()
    }
}

// MARK: - ActivityMonitorService

/// Monitors active foreground application bundle identifiers, user input idle breaks,
/// and live hardware thermal/CPU sensors to drive `WellnessPointEngine` updates.
@MainActor
public final class ActivityMonitorService: ObservableObject {
    /// Default whitelist of productive developer, creative, and office bundle identifiers.
    public static let defaultProductiveBundleIDs: Set<String> = [
        // Code Editors, IDEs & AI Coding Assistants
        "com.apple.dt.Xcode",
        "com.microsoft.VSCode",
        "com.microsoft.VSCodeInsiders",
        "com.google.antigravity",
        "com.google.antigravity-ide",
        "com.google.GeminiMacOS",
        "com.openai.chat",
        "com.anthropic.claudefordesktop",
        "com.todesktop.230313mzl4w4u92", // Cursor
        "com.exafunction.windsurf",
        "dev.zed.Zed",
        "com.sublimetext.4",
        "com.sublimetext.3",
        "com.panic.Nova",
        "abnerworks.Typora",

        // Terminals
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "dev.warp.Warp-Stable",
        "com.mitchellh.ghostty",
        "io.alacritty",
        "net.kovidgoyal.kitty",
        "co.zeit.hyper",

        // JetBrains & Android Studio
        "com.jetbrains.intellij",
        "com.jetbrains.intellij.ce",
        "com.jetbrains.pycharm",
        "com.jetbrains.pycharm.ce",
        "com.jetbrains.WebStorm",
        "com.jetbrains.goland",
        "com.jetbrains.CLion",
        "com.jetbrains.rider",
        "com.jetbrains.PhpStorm",
        "com.jetbrains.rubymine",
        "com.jetbrains.datagrip",
        "com.google.android.studio",

        // DevOps, Git, Databases & API Clients
        "com.docker.docker",
        "com.postmanlabs.mac",
        "com.insomnia.app",
        "com.tinyapp.TablePlus",
        "com.sequel-ace.sequel-ace",
        "com.mongodb.compass",
        "com.github.GitHubClient",
        "com.sublimemerge",
        "com.torusknot.SourceTreeNotMAS",
        "com.axosoft.gitkraken",

        // Microsoft Office & Teams Suite
        "com.microsoft.Word",
        "com.microsoft.Excel",
        "com.microsoft.Powerpoint",
        "com.microsoft.Outlook",
        "com.microsoft.onenote.mac",
        "com.microsoft.teams",
        "com.microsoft.teams2",
        "com.microsoft.to-do-mac",
        "com.microsoft.rdc.macos",

        // Apple iWork & Native Productivity Apps
        "com.apple.iWork.Pages",
        "com.apple.iWork.Numbers",
        "com.apple.iWork.Keynote",
        "com.apple.Notes",
        "com.apple.iCal",
        "com.apple.reminders",
        "com.apple.mail",
        "com.apple.TextEdit",
        "com.apple.Preview",
        "com.apple.freeform",
        "org.libreoffice.script",

        // Collaboration, Notes, Design & Project Management
        "com.tinyspeck.slackmacgap",
        "us.zoom.xos",
        "notion.id",
        "md.obsidian",
        "com.linear",
        "com.figma.Desktop",
        "com.bohemiancoding.sketch3",
        "com.canva.CanvaDesktop",
        "com.miro.miro",
        "com.atlassian.trello",
        "com.todoist.mac.Todoist",
        "com.culturedcode.ThingsMac",
        "com.flexibits.fantastical2.mac",
        "com.1password.1password"
    ]

    /// Substring keywords that also identify developer, creative, and office productivity tools by bundle ID.
    private static let productiveBundleKeywords: [String] = [
        "xcode", "vscode", "terminal", "iterm", "warp", "ghostty", "alacritty", "kitty",
        "jetbrains", "intellij", "pycharm", "webstorm", "goland", "clion", "phpstorm", "rubymine", "datagrip", "android.studio",
        "antigravity", "cursor", "windsurf", "zed", "sublimetext", "sublimemerge",
        "docker", "postman", "insomnia", "tableplus", "sequel", "gitkraken", "sourcetree", "githubclient",
        "gemini", "claude", "openai",
        "microsoft.word", "microsoft.excel", "microsoft.powerpoint", "microsoft.outlook", "microsoft.onenote", "microsoft.teams", "microsoft.to-do",
        "iwork.pages", "iwork.numbers", "iwork.keynote", "libreoffice",
        "apple.notes", "apple.ical", "apple.reminders", "apple.mail", "apple.textedit", "apple.preview", "apple.freeform",
        "slack", "zoom.xos", "notion", "obsidian", "linear", "figma", "sketch", "canva", "miro", "trello", "todoist", "thingsmac"
    ]

    /// Browser bundle ID keywords where work/research tabs (like GitHub, docs, Stack Overflow) are productive,
    /// while streaming & social media tabs (YouTube, Netflix, Instagram, Facebook, TikTok, etc.) drain PTS.
    private static let browserBundleKeywords: [String] = [
        "firefox", "chrome", "brave", "edgemac", "thebrowser.browser", "opera", "zen-browser", "waterfox", "safari"
    ]

    /// Streaming, video, and social media domains/keywords that trigger Dopamine Drain (`-1.5 PTS`).
    public static let dopamineStreamingAndSocialKeywords: [String] = [
        // Video & Streaming Providers
        "youtube.com", "youtu.be", "netflix.com", "twitch.tv", "disneyplus.com",
        "primevideo.com", "hbomax.com", "max.com", "hulu.com", "tv.apple.com",
        "crunchyroll.com", "dailymotion.com", "vimeo.com", "kick.com", "plex.tv",
        "peacocktv.com", "paramountplus.com", "viaplay.", "videoland.",
        // Social Media & Doomscrolling
        "facebook.com", "fb.com", "instagram.com", "tiktok.com", "twitter.com",
        "x.com/", "reddit.com", "snapchat.com", "pinterest.com", "9gag.com",
        "imgur.com", "threads.net", "bsky.app", "tumblr.com", "buzzfeed.com",
        // Personal Chat & Gaming Sites
        "web.whatsapp.com", "discord.com", "web.telegram.org", "messenger.com",
        "steampowered.com", "roblox.com", "epicgames.com"
    ]

    /// Native media, video player, streaming, and gaming application bundle ID keywords that represent
    /// passive entertainment or gaming rather than an offline recharge break.
    public static let dopamineMediaAndGameBundleKeywords: [String] = [
        "com.apple.tv", "quicktimeplayer", "org.videolan.vlc", "com.colliderli.iina",
        "netflix", "primevideo", "disneyplus", "twitch", "youtube", "crunchyroll",
        "plex", "infuse", "mpv", "elmedia", "movist", "hulu",
        "steampowered", "valvesoftware.steam", "roblox", "epicgames", "riotgames", "battlenet"
    ]

    /// Work meeting and collaboration call bundle ID keywords where video/screen sharing is productive work.
    private static let workMeetingBundleKeywords: [String] = [
        "zoom.xos", "microsoft.teams", "slack", "webex", "facetime"
    ]

    /// Browser tab title keywords indicating a streaming or social media distraction.
    private static let dopamineTitleKeywords: [String] = [
        "youtube", "netflix", "twitch", "disney+", "prime video",
        "instagram", "facebook", "tiktok", "reddit"
    ]

    public let engine: WellnessPointEngine
    public let telemetry: ActivityTelemetryProviding
    public let productiveBundleIDs: Set<String>
    public let idleBreakThresholdSeconds: TimeInterval
    public let overheatingTemperatureThresholdCelsius: Double
    public let overheatingCPULoadThresholdPercent: Double

    public static let customProductiveKey = "customProductiveBundleIDs"
    public static let customDistractionKey = "customDistractionBundleIDs"

    @Published public private(set) var customProductiveIDs: Set<String> = []
    @Published public private(set) var customDistractionIDs: Set<String> = []

    @Published public private(set) var isMonitoring: Bool = false
    @Published public private(set) var isOnBreak: Bool = false
    @Published public private(set) var breakStartedAt: Date? = nil
    @Published public private(set) var isOverheatingActive: Bool = false
    @Published public private(set) var isWatchingMediaOrDistraction: Bool = false
    @Published public var isManualOverrideActive: Bool = false

    @Published public private(set) var lastTemperatureCelsius: Double? = nil
    @Published public private(set) var lastCPULoadPercentage: Double? = nil
    @Published public private(set) var lastThermalState: ProcessInfo.ThermalState = .nominal
    @Published public private(set) var lastFrontmostBundleID: String? = nil
    @Published public private(set) var lastFrontmostAppName: String? = nil
    @Published public private(set) var lastIdleSeconds: TimeInterval = 0.0
    @Published public private(set) var lastAppIsProductive: Bool = false

    private var pollingTimer: Timer?
    private var sleepWakeObservers: [NSObjectProtocol] = []
    private var sleepRecordedAt: Date? = nil

    public init(
        engine: WellnessPointEngine,
        telemetry: ActivityTelemetryProviding = SystemActivityTelemetryProvider(),
        productiveBundleIDs: Set<String> = ActivityMonitorService.defaultProductiveBundleIDs,
        idleBreakThresholdSeconds: TimeInterval = 60.0,
        overheatingTemperatureThresholdCelsius: Double = 80.0,
        overheatingCPULoadThresholdPercent: Double = 85.0
    ) {
        self.engine = engine
        self.telemetry = telemetry
        self.productiveBundleIDs = productiveBundleIDs
        self.idleBreakThresholdSeconds = idleBreakThresholdSeconds
        self.overheatingTemperatureThresholdCelsius = overheatingTemperatureThresholdCelsius
        self.overheatingCPULoadThresholdPercent = overheatingCPULoadThresholdPercent

        if let storedProd = UserDefaults.standard.stringArray(forKey: Self.customProductiveKey) {
            self.customProductiveIDs = Set(storedProd)
        }
        if let storedDist = UserDefaults.standard.stringArray(forKey: Self.customDistractionKey) {
            self.customDistractionIDs = Set(storedDist)
        }
    }

    /// Marks the currently active frontmost application as explicitly productive or a distraction.
    public func markFrontmostApp(asProductive isProductive: Bool) {
        guard let bundleID = lastFrontmostBundleID, !bundleID.isEmpty else { return }
        if isProductive {
            customProductiveIDs.insert(bundleID)
            customDistractionIDs.remove(bundleID)
        } else {
            customDistractionIDs.insert(bundleID)
            customProductiveIDs.remove(bundleID)
        }
        UserDefaults.standard.set(Array(customProductiveIDs), forKey: Self.customProductiveKey)
        UserDefaults.standard.set(Array(customDistractionIDs), forKey: Self.customDistractionKey)
        performSampleTick()
    }

    /// Resets any custom classification rule for the current frontmost application back to default.
    public func resetFrontmostAppRule() {
        guard let bundleID = lastFrontmostBundleID, !bundleID.isEmpty else { return }
        customProductiveIDs.remove(bundleID)
        customDistractionIDs.remove(bundleID)
        UserDefaults.standard.set(Array(customProductiveIDs), forKey: Self.customProductiveKey)
        UserDefaults.standard.set(Array(customDistractionIDs), forKey: Self.customDistractionKey)
        performSampleTick()
    }

    /// Returns `true` if custom productive, `false` if custom distraction, or `nil` if default.
    public var frontmostAppCustomRule: Bool? {
        guard let bundleID = lastFrontmostBundleID, !bundleID.isEmpty else { return nil }
        if customProductiveIDs.contains(bundleID) { return true }
        if customDistractionIDs.contains(bundleID) { return false }
        return nil
    }

    /// Static helper returning `true` if the given browser tab URL or title belongs to a streaming or social media platform.
    public static func containsDopamineStreamingOrSocialKeyword(url: String?, title: String? = nil) -> Bool {
        if let url = url?.lowercased() {
            if dopamineStreamingAndSocialKeywords.contains(where: { url.contains($0) }) {
                return true
            }
        }
        if let title = title?.lowercased() {
            if ActivityMonitorService.dopamineTitleKeywords.contains(where: { title.contains($0) }) {
                return true
            }
        }
        return false
    }

    /// Returns `true` if the given browser tab URL or title belongs to a streaming or social media platform
    /// (YouTube, Netflix, Disney+, Twitch, Facebook, Instagram, TikTok, X/Twitter, Reddit, etc.).
    public func isDopamineStreamingOrSocialTab(url: String?, title: String? = nil) -> Bool {
        Self.containsDopamineStreamingOrSocialKeyword(url: url, title: title)
    }

    /// Returns `true` if the given bundle identifier belongs to a native streaming, media player, or gaming application.
    public func isDopamineMediaOrGameBundleID(_ bundleID: String?) -> Bool {
        guard let lower = bundleID?.lowercased() else { return false }
        return Self.dopamineMediaAndGameBundleKeywords.contains(where: { lower.contains($0) })
    }

    /// Returns `true` if the given bundle identifier belongs to a work meeting / video conferencing application.
    public func isWorkMeetingBundleID(_ bundleID: String?) -> Bool {
        guard let lower = bundleID?.lowercased() else { return false }
        return Self.workMeetingBundleKeywords.contains(where: { lower.contains($0) })
    }

    /// Returns `true` if the given bundle identifier (and optional active browser tab URL/title)
    /// represents productive work or research rather than streaming/social media distraction.
    public func isProductiveBundleID(
        _ bundleID: String?,
        activeTabURL: String? = nil,
        activeTabTitle: String? = nil,
        isVideoPlaying: Bool = false
    ) -> Bool {
        guard let bundleID else { return false }
        if customDistractionIDs.contains(bundleID) {
            return false
        }
        if customProductiveIDs.contains(bundleID) {
            return true
        }
        if isDopamineStreamingOrSocialTab(url: activeTabURL, title: activeTabTitle) {
            return false
        }
        if isDopamineMediaOrGameBundleID(bundleID) {
            return false
        }
        if let url = activeTabURL, !url.isEmpty {
            return true
        }
        let lower = bundleID.lowercased()
        let isBrowser = Self.browserBundleKeywords.contains(where: { lower.contains($0) }) || lower.contains("safari")
        if isBrowser && isVideoPlaying {
            return false
        }
        if productiveBundleIDs.contains(bundleID) {
            return true
        }
        if Self.productiveBundleKeywords.contains(where: { lower.contains($0) }) {
            return true
        }
        if Self.browserBundleKeywords.contains(where: { lower.contains($0) }) && !lower.contains("safari") {
            return true
        }
        return false
    }

    /// Starts periodic telemetry sampling on the main run loop with timer coalescing tolerance (`NFR-001`).
    public func startMonitoring(intervalSeconds: TimeInterval = 5.0) {
        stopMonitoring()
        isMonitoring = true
        performSampleTick()

        let timer = Timer(timeInterval: intervalSeconds, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.performSampleTick()
            }
        }
        timer.tolerance = intervalSeconds * 0.2
        RunLoop.main.add(timer, forMode: .common)
        pollingTimer = timer

        // Register sleep / wake & screen sleep observers for offline recharge tracking
        let workspace = NSWorkspace.shared.notificationCenter
        let sleepObs = workspace.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleSystemSleepOrLock()
            }
        }
        let wakeObs = workspace.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleSystemWakeOrUnlock()
            }
        }
        let screenSleepObs = workspace.addObserver(
            forName: NSWorkspace.screensDidSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleSystemSleepOrLock()
            }
        }
        let screenWakeObs = workspace.addObserver(
            forName: NSWorkspace.screensDidWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleSystemWakeOrUnlock()
            }
        }
        sleepWakeObservers = [sleepObs, wakeObs, screenSleepObs, screenWakeObs]
    }

    /// Handles system or display going to sleep / screen lock.
    public func handleSystemSleepOrLock() {
        if sleepRecordedAt == nil {
            sleepRecordedAt = telemetry.now()
        }
    }

    /// Handles system or display wake / unlock, restoring points for offline breaks (> 2.0 min).
    public func handleSystemWakeOrUnlock() {
        guard let slept = sleepRecordedAt else { return }
        let elapsedMinutes = max(0.0, telemetry.now().timeIntervalSince(slept) / 60.0)
        sleepRecordedAt = nil
        if elapsedMinutes > 2.0 {
            engine.applyOfflineBreak(minutes: elapsedMinutes)
        }
        isOnBreak = false
        breakStartedAt = nil
        performSampleTick()
    }

    /// Stops periodic telemetry sampling and unregisters sleep/wake observers.
    public func stopMonitoring() {
        pollingTimer?.invalidate()
        pollingTimer = nil
        let center = NSWorkspace.shared.notificationCenter
        for obs in sleepWakeObservers {
            center.removeObserver(obs)
        }
        sleepWakeObservers.removeAll()
        isMonitoring = false
    }

    /// Clears any manual state override and immediately re-evaluates live hardware and activity sensors.
    public func clearManualOverride() {
        isManualOverrideActive = false
        isOverheatingActive = false
        engine.triggerThermalWarning(isOverheating: false)
        engine.setChargingState(false)
        performSampleTick()
    }

    /// Executes a single telemetry sample cycle:
    /// 1. Samples real CPU die temperature (`°C`), CPU load (`%`), and `ProcessInfo.ThermalState`.
    /// 2. Checks idle time via `secondsSinceLastInput()` for offline break entry/restoration.
    /// 3. Evaluates foreground app bundle identifier when actively working.
    public func performSampleTick() {
        let idleSeconds = telemetry.secondsSinceLastInput()
        lastIdleSeconds = idleSeconds
        let currentTime = telemetry.now()

        let frontmostBundleID = telemetry.frontmostBundleIdentifier()
        let activeTab = telemetry.activeBrowserTab()
        let activeTabURL = activeTab.url
        let activeTabTitle = activeTab.title
        lastFrontmostBundleID = frontmostBundleID

        let baseAppName = telemetry.frontmostApplicationName() ?? frontmostBundleID ?? "Unknown"
        if let urlStr = activeTabURL, let host = URL(string: urlStr)?.host {
            let cleanHost = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
            lastFrontmostAppName = "\(baseAppName) [\(cleanHost)]"
        } else {
            lastFrontmostAppName = baseAppName
        }

        let isDopamineTab = isDopamineStreamingOrSocialTab(url: activeTabURL, title: activeTabTitle)
        let isEntertainmentApp = isDopamineMediaOrGameBundleID(frontmostBundleID)
        let isVideoPlaying = telemetry.isVideoPlaybackActive() && !isWorkMeetingBundleID(frontmostBundleID)
        let watchingMediaOrDistraction = isDopamineTab || isEntertainmentApp || isVideoPlaying
        isWatchingMediaOrDistraction = watchingMediaOrDistraction

        let isProductive = isProductiveBundleID(
            frontmostBundleID,
            activeTabURL: activeTabURL,
            activeTabTitle: activeTabTitle,
            isVideoPlaying: isVideoPlaying
        )
        lastAppIsProductive = isProductive

        if isManualOverrideActive {
            let state = telemetry.thermalState()
            let tempCelsius = telemetry.cpuTemperatureCelsius()
            let cpuLoad = telemetry.cpuLoadPercentage()
            lastThermalState = state
            lastTemperatureCelsius = tempCelsius
            lastCPULoadPercentage = cpuLoad
            engine.latestTemperatureCelsius = tempCelsius
            engine.latestCPULoadPercentage = cpuLoad
            return
        }

        evaluateThermalSample()

        if idleSeconds >= idleBreakThresholdSeconds {
            // When the user is watching YouTube, Netflix, or any video/streaming distraction hands-free
            // without moving their mouse, do NOT enter Charging Mode — keep draining PTS!
            if watchingMediaOrDistraction {
                if isOnBreak {
                    isOnBreak = false
                    breakStartedAt = nil
                }
                lastAppIsProductive = false
                engine.evaluateWorkTick(isProductiveApp: false)
                return
            }

            if !isOnBreak {
                isOnBreak = true
                breakStartedAt = currentTime.addingTimeInterval(-idleSeconds)
            }
            engine.setChargingState(true)
            return
        }

        if isOnBreak {
            let startTime = breakStartedAt ?? currentTime
            let elapsedMinutes = max(0.0, currentTime.timeIntervalSince(startTime) / 60.0)
            isOnBreak = false
            breakStartedAt = nil
            engine.applyOfflineBreak(minutes: elapsedMinutes)
        }

        engine.evaluateWorkTick(isProductiveApp: isProductive)
    }

    private func evaluateThermalSample() {
        let state = telemetry.thermalState()
        let tempCelsius = telemetry.cpuTemperatureCelsius()
        let cpuLoad = telemetry.cpuLoadPercentage()

        lastThermalState = state
        lastTemperatureCelsius = tempCelsius
        lastCPULoadPercentage = cpuLoad
        engine.latestTemperatureCelsius = tempCelsius
        engine.latestCPULoadPercentage = cpuLoad

        let effectiveTemp = tempCelsius ?? 0.0
        let effectiveLoad = cpuLoad ?? 0.0
        let isHotTemp = effectiveTemp > overheatingTemperatureThresholdCelsius
        let isHighCPU = effectiveLoad > overheatingCPULoadThresholdPercent
        let shouldOverheat = (state == .critical || state == .serious || isHotTemp || isHighCPU)

        if shouldOverheat {
            isOverheatingActive = true
            let actionMessage: String
            if isHotTemp && isHighCPU {
                actionMessage = String(
                    format: "🔥 %.0f°C (%.0f%% CPU) — CLOSE HEAVY TABS OR BUILDS TO COOL DOWN!",
                    effectiveTemp,
                    effectiveLoad
                )
            } else if isHotTemp {
                actionMessage = String(
                    format: "🔥 %.0f°C HOT — QUIT UNUSED APPS OR DOCKER TO COOL DOWN!",
                    effectiveTemp
                )
            } else if isHighCPU {
                actionMessage = String(
                    format: "🔥 %.0f%% CPU LOAD — QUIT HEAVY BACKGROUND APPS TO COOL DOWN!",
                    effectiveLoad
                )
            } else {
                actionMessage = WellnessPointEngine.thermalWarningText
            }
            engine.triggerThermalWarning(isOverheating: true, actionMessage: actionMessage)
        } else if isOverheatingActive {
            isOverheatingActive = false
            engine.triggerThermalWarning(isOverheating: false)
        }
    }
}

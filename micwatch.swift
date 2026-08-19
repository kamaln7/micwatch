// Meeting detection: any app holding the mic = you're on a call.
// Covers Slack huddles, Zoom, Meet and anything else with zero per-app code.
//
// Two CoreAudio layers, because neither alone does the job:
//   - devices tell us WHEN recording starts/stops, and are the only ones that
//     actually deliver property-change notifications (process-level properties
//     accept a listener and then never fire — verified across 39 objects).
//   - processes tell us WHICH app, which devices can't.
import AVFoundation
import AppKit
import CoreAudio
import Darwin
import ServiceManagement
import SwiftUI

setvbuf(stdout, nil, _IONBF, 0)

let systemObject = AudioObjectID(kAudioObjectSystemObject)

func prop(_ sel: AudioObjectPropertySelector,
          _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: sel, mScope: scope, mElement: kAudioObjectPropertyElementMain)
}

/// Reads a fixed-size property. Only for trivial types — anything holding an
/// object reference needs its ownership handled explicitly, as bundleID does.
func read<T>(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector, _ empty: T) -> T? {
    var address = prop(selector)
    var value = empty
    var size = UInt32(MemoryLayout<T>.size)
    let status = withUnsafeMutableBytes(of: &value) { buffer in
        AudioObjectGetPropertyData(id, &address, 0, nil, &size, buffer.baseAddress!)
    }
    return status == noErr ? value : nil
}

func objectList(_ id: AudioObjectID, _ sel: AudioObjectPropertySelector) -> [AudioObjectID] {
    var addr = prop(sel)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr else { return [] }
    var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &ids) == noErr else { return [] }
    return ids
}

func inputDevices() -> [AudioObjectID] {
    objectList(systemObject, kAudioHardwarePropertyDevices).filter { id in
        var addr = prop(kAudioDevicePropertyStreams, kAudioObjectPropertyScopeInput)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr && size > 0
    }
}

// MARK: - Who is recording

/// AudioHardware.h: "The caller is responsible for releasing the returned
/// CFObject." Taking it as Unmanaged and calling takeRetainedValue consumes that
/// +1; bridging straight to CFString? would leak one string per call, and this
/// runs for every audio process on every mic event.
func bundleID(_ id: AudioObjectID) -> String? {
    var address = prop(kAudioProcessPropertyBundleID)
    var value: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    let status = withUnsafeMutableBytes(of: &value) { buffer in
        AudioObjectGetPropertyData(id, &address, 0, nil, &size, buffer.baseAddress!)
    }
    guard status == noErr, let name = value?.takeRetainedValue() as String? else { return nil }
    return name.isEmpty ? nil : name
}

/// Electron/Chromium put the mic in a helper process that isn't a GUI app
/// (Slack huddles surface as com.tinyspeck.slackmacgap.helper), so walk up to
/// the first ancestor macOS considers an app.
/// The name from a process's own bundle. NSRunningApplication only knows about
/// processes LaunchServices launched, so anything started directly — a helper, or
/// a bundle run from a shell — has no localizedName despite having a perfectly
/// good one in its Info.plist.
func bundleName(of pid: pid_t) -> String? {
    var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
    guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }

    // …/Foo.app/Contents/MacOS/foo — walk up looking for the wrapper
    var directory = URL(fileURLWithPath: String(cString: buffer))
    for _ in 0..<4 {
        directory.deleteLastPathComponent()
        guard directory.pathExtension != "app" else {
            let bundle = Bundle(url: directory)
            return bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                ?? bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String
        }
    }
    return nil
}

func appName(_ pid: pid_t) -> String? {
    var pid = pid
    for _ in 0..<5 {
        if let name = NSRunningApplication(processIdentifier: pid)?.localizedName { return name }
        if let name = bundleName(of: pid) { return name }
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size, info.pbi_ppid > 1 else { return nil }
        pid = pid_t(info.pbi_ppid)
    }
    return nil
}

func execName(_ pid: pid_t) -> String {
    var buf = [CChar](repeating: 0, count: Int(MAXPATHLEN))
    return proc_name(pid, &buf, UInt32(buf.count)) > 0 ? String(cString: buf) : "pid \(pid)"
}

/// Apps currently recording. Empty = no meeting.
func appsOnMic() -> [String] {
    var seen = Set<String>()
    return objectList(systemObject, kAudioHardwarePropertyProcessObjectList).compactMap { id -> String? in
        guard read(id, kAudioProcessPropertyIsRunningInput, UInt32(0)) == 1,
              let pid = read(id, kAudioProcessPropertyPID, pid_t(0)) else { return nil }
        let name = appName(pid) ?? bundleID(id) ?? execName(pid)
        return seen.insert(name).inserted ? name : nil
    }
}

// MARK: - Home Assistant

/// ~/.config/micwatch.json — non-secret settings only.
/// The token lives in the Keychain, not here.
struct Config: Codable, Equatable {
    var url: String        // e.g. "http://homeassistant.local:8123"
    var entity: String     // e.g. "media_player.kitchen"
    var entityName: String?        // friendly_name, so the UI needn't derive one
    var homeRouter: String?        // gateway MAC of the home network
    var requireHomeNetwork: Bool?  // optional: older config files predate both

    static let path = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/micwatch.json")

    static func load() -> Config? {
        guard let data = try? Data(contentsOf: path) else { return nil }
        return try? JSONDecoder().decode(Config.self, from: data)
    }

    /// Writes only when something actually differs. Comparing values rather than
    /// encoded bytes means reformatting the file by hand isn't treated as a
    /// change, and a write that would change nothing never touches the file —
    /// which matters to anything watching it, editors included.
    func save() throws {
        guard Config.load() != self else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: Config.path.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try encoder.encode(self).write(to: Config.path)
    }
}

/// Long-lived access token, in its own file rather than the config file, so the
/// config stays safe to read and copy.
///
/// Not the Keychain. A Keychain ACL only grants silent access to a stable code
/// identity, and Apple's guidance is that this works with Developer ID signing
/// but not with a self-signed certificate: the item records a cdhash per build,
/// so every rebuild prompts again. Paying for that protection with a password
/// prompt on every build, and still not getting it, is the worst of both.
let tokenPath = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".config/micwatch-token")

func loadToken() -> String? {
    if let contents = try? String(contentsOf: tokenPath, encoding: .utf8) {
        let token = contents.trimmingCharacters(in: .whitespacesAndNewlines)
        return token.isEmpty ? nil : token
    }
    return nil
}

@discardableResult
func saveToken(_ token: String) -> Bool {
    do {
        try FileManager.default.createDirectory(at: tokenPath.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try token.write(to: tokenPath, atomically: true, encoding: .utf8)
        // Owner-only, and set after writing so it applies to the final file
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tokenPath.path)
        return true
    } catch {
        NSLog("micwatch: could not write \(tokenPath.path): \(error.localizedDescription)")
        return false
    }
}

/// Synchronous because every caller is a one-shot with nothing else to do.
func haRequest(_ path: String, base: String, token: String,
               method: String = "GET", body: Data? = nil) -> (status: Int, data: Data)? {
    guard let url = URL(string: base + path) else { return nil }
    var request = URLRequest(url: url, timeoutInterval: 5)
    request.httpMethod = method
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    if let body {
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    }
    var result: (Int, Data)?
    let done = DispatchSemaphore(value: 0)
    URLSession.shared.dataTask(with: request) { data, response, _ in
        if let http = response as? HTTPURLResponse, let data { result = (http.statusCode, data) }
        done.signal()
    }.resume()
    _ = done.wait(timeout: .now() + 6)
    return result
}

/// Convenience for the saved configuration.
func haRequest(_ path: String, method: String = "GET", body: Data? = nil) -> (status: Int, data: Data)? {
    guard let config = Config.load(), let token = loadToken() else { return nil }
    return haRequest(path, base: config.url, token: token, method: method, body: body)
}

/// Prints the configured entity's state, so you can confirm auth and entity id
/// before anything depends on them.
func haState() -> Never {
    guard let config = Config.load() else {
        print("""
        No config. Create \(Config.path.path):
          {"url": "http://homeassistant.local:8123", "entity": "media_player.your_speaker"}
        """)
        exit(1)
    }
    guard loadToken() != nil else {
        print("""
        No token stored. Open Settings from the menu bar icon to add one.
        """)
        exit(1)
    }
    guard let (status, data) = haRequest("/api/states/\(config.entity)") else {
        print("FAIL: no response from \(config.url) — is it reachable from here?")
        exit(1)
    }
    guard status == 200 else {
        let hint = status == 401 ? "  (token rejected)" : status == 404 ? "  (no such entity)" : ""
        print("FAIL: HTTP \(status)\(hint)\n\(String(data: data, encoding: .utf8) ?? "")")
        exit(1)
    }
    let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    let state = json["state"] as? String ?? "?"
    let attrs = json["attributes"] as? [String: Any] ?? [:]
    print("gateway: \(gatewayMAC() ?? "unknown")  home gate: " +
          (config.requireHomeNetwork == true
           ? (onHomeNetwork(config) ? "on, at home" : "on, away — would not pause")
           : "off"))
    print("\(config.entity): \(state)")
    for key in ["media_title", "media_artist", "volume_level", "friendly_name"] {
        if let value = attrs[key] { print("  \(key): \(value)") }
    }
    exit(0)
}

// MARK: - Home network

func shell(_ path: String, _ arguments: [String]) -> String? {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: path)
    task.arguments = arguments
    let pipe = Pipe()
    task.standardOutput = pipe
    task.standardError = FileHandle.nullDevice
    guard (try? task.run()) != nil else { return nil }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    task.waitUntilExit()
    return String(data: data, encoding: .utf8)
}

/// MAC address of the default gateway — i.e. which router we're behind.
///
/// The SSID would need the com.apple.developer.networking.wifi-info entitlement
/// (paid developer program) plus Location Services permission, and identifies the
/// network far more loosely: every café chain reuses the same names. This needs no
/// permission at all and names your specific hardware.
func gatewayMAC() -> String? {
    guard let route = shell("/sbin/route", ["-n", "get", "default"]),
          let line = route.split(separator: "\n").first(where: { $0.contains("gateway:") }) else { return nil }
    let gateway = line.replacingOccurrences(of: "gateway:", with: "").trimmingCharacters(in: .whitespaces)
    guard !gateway.isEmpty, let arp = shell("/usr/sbin/arp", ["-n", gateway]),
          let at = arp.range(of: " at ") else { return nil }
    let mac = arp[at.upperBound...].prefix { $0 != " " }
    // arp drops leading zeros ("0:1c:.."), so pad before comparing
    let octets = mac.split(separator: ":").map { $0.count == 1 ? "0" + $0 : String($0) }
    guard octets.count == 6 else { return nil }
    return octets.joined(separator: ":").lowercased()
}

/// True when no home network is configured, or we're on it.
func onHomeNetwork(_ config: Config) -> Bool {
    guard config.requireHomeNetwork == true, let home = config.homeRouter, !home.isEmpty else { return true }
    return gatewayMAC() == home.lowercased()
}

// MARK: - Pause control

/// Pauses the configured player when a meeting starts, and resumes it afterwards.
final class MusicControl {
    /// Resume only what we paused. If it was already paused, or you paused it
    /// yourself mid-meeting, the meeting ending shouldn't start it playing.
    private var pausedByUs = false
    private let queue = DispatchQueue(label: "micwatch.ha")

    /// Called on the main thread whenever we pause or resume, so the menu bar
    /// can show it. The network work stays off the main thread; only the result
    /// crosses over.
    var onPausedChange: ((Bool) -> Void)?

    func micActive(_ active: Bool, allowed: Bool) {
        queue.async { self.apply(active, allowed) }   // network, so never on the main thread
    }

    private func apply(_ active: Bool, _ allowed: Bool) {
        guard let config = Config.load(), !config.entity.isEmpty, loadToken() != nil else { return }
        if active {
            guard !pausedByUs, allowed else { return }
            guard onHomeNetwork(config) else {
                print("  not on the home network (gateway \(gatewayMAC() ?? "unknown")) — leaving it alone")
                return
            }
            let state = playerState(config)
            guard state == "playing" else {
                print("  \(config.entity) is \(state ?? "unreachable") — leaving it alone")
                return
            }
            if call("media_pause", config) {
                pausedByUs = true
                print("  paused \(config.entity)")
                DispatchQueue.main.async { self.onPausedChange?(true) }
            }
        } else if pausedByUs {
            pausedByUs = false
            print(call("media_play", config) ? "  resumed \(config.entity)" : "  could not resume \(config.entity)")
            DispatchQueue.main.async { self.onPausedChange?(false) }
        }
    }

    /// Pause again after resuming by hand. Same guards as an automatic
    /// pause: it only acts if the player is actually playing.
    func pauseNow() {
        queue.async { self.apply(true, true) }
    }

    /// Resume immediately, while the mic is still held. The meeting ending later won't touch it
    /// again, because we're no longer holding it paused.
    func resumeNow() {
        queue.async {
            guard self.pausedByUs, let config = Config.load() else { return }
            self.pausedByUs = false
            print(self.call("media_play", config) ? "  resumed \(config.entity) on request"
                                                  : "  could not resume \(config.entity)")
            DispatchQueue.main.async { self.onPausedChange?(false) }
        }
    }

    /// Let go without resuming: the speaker stays paused and micwatch forgets it
    /// ever touched it, so nothing starts playing later on its own.
    func abandon() {
        queue.async {
            guard self.pausedByUs else { return }
            self.pausedByUs = false
            print("  leaving it paused")
            DispatchQueue.main.async { self.onPausedChange?(false) }
        }
    }

    private func playerState(_ config: Config) -> String? {
        guard let (status, data) = haRequest("/api/states/\(config.entity)"), status == 200,
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        rememberName(from: json, config)
        return json["state"] as? String
    }

    /// Keep the stored display name current. Backfills configs written before
    /// names were stored, and follows a rename in Home Assistant without asking
    /// you to re-pick the player. Config.save writes nothing if it matches.
    private func rememberName(from json: [String: Any], _ config: Config) {
        guard let name = (json["attributes"] as? [String: Any])?["friendly_name"] as? String,
              !name.isEmpty, name != config.entityName else { return }
        var updated = config
        updated.entityName = name
        try? updated.save()
    }

    private func call(_ service: String, _ config: Config) -> Bool {
        let body = try? JSONSerialization.data(withJSONObject: ["entity_id": config.entity])
        guard let (status, _) = haRequest("/api/services/media_player/\(service)",
                                          method: "POST", body: body) else { return false }
        return status == 200
    }
}

// MARK: - Settings window

struct EntityOption: Identifiable, Hashable {
    let id: String              // entity_id
    let name: String            // friendly_name, falling back to the id
    let deviceClass: String?    // "speaker", "tv", …
    let grouped: Bool           // part of a multi-speaker group

    /// Enough to tell a speaker from the television at a glance.
    var symbol: String {
        if grouped { return "hifispeaker.2.fill" }
        switch deviceClass {
        case "tv":       return "tv"
        case "speaker":  return "hifispeaker.fill"
        case "receiver": return "hifireceiver.fill"
        default:         return "play.square"
        }
    }
}

enum Reachability { case unknown, checking, reachable, unreachable }

@MainActor
final class SettingsModel: ObservableObject {
    @Published var reachability = Reachability.unknown
    @Published var saved = false
    @Published var requireHome = false
    @Published var homeRouter = ""
    /// Filled in by refreshRouter, never in the initializer: reading it spawns
    /// subprocesses, and doing that while SwiftUI builds the view re-enters
    /// layout and trips an AttributeGraph precondition.
    @Published var currentRouter = ""
    /// Held so it can be removed — each time the window opens it builds a new model
    private var observer: NSObjectProtocol?
    @Published var url = ""   // empty, so first launch shows no state rather than a failure
    @Published var token = ""
    @Published var entities: [EntityOption] = []
    @Published var selected = ""
    @Published var status = ""
    @Published var failed = false
    @Published var busy = false

    /// HA's token page, derived from whatever URL is currently typed.
    var tokenPageURL: URL? {
        let base = url.trimmingCharacters(in: .whitespaces)
        guard base.hasPrefix("http"), let url = URL(string: base) else { return nil }
        return url.appendingPathComponent("profile/security")
    }

    init() {
        if let config = Config.load() {
            url = config.url
            selected = config.entity
            homeRouter = config.homeRouter ?? ""
            requireHome = config.requireHomeNetwork == true
        }
        if let saved = loadToken() { token = saved }

        observer = NotificationCenter.default.addObserver(
            forName: .configChanged, object: nil, queue: .main
        ) { [weak self] _ in
            self?.reloadFromDisk()
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    /// Any HTTP response means the server answered. A 401 or 405 counts — this
    /// runs before there's a token, so being rejected still proves it's there.
    ///
    /// Driven by .task(id:), which debounces and cancels superseded probes for
    /// free, and runs outside SwiftUI's update pass — publishing from inside one
    /// trips an AttributeGraph precondition and aborts the process.
    func check() async {
        let base = url.trimmingCharacters(in: .whitespaces)
        guard base.hasPrefix("http"), let target = URL(string: base) else {
            reachability = .unknown
            return
        }
        reachability = .checking
        var request = URLRequest(url: target, timeoutInterval: 3)
        request.httpMethod = "HEAD"
        do {
            _ = try await URLSession.shared.data(for: request)
            reachability = .reachable
        } catch {
            reachability = Task.isCancelled ? .checking : .unreachable
        }
    }

    /// Fetches every entity and keeps the media players. Doubles as the auth
    /// check — if the token is wrong this is where you find out, by name.
    func connect() async {
        busy = true
        status = ""
        defer { busy = false }

        let base = url.trimmingCharacters(in: .whitespaces)
        guard let endpoint = URL(string: base + "/api/states") else {
            fail("That doesn't look like a URL")
            return
        }
        var request = URLRequest(url: endpoint, timeoutInterval: 10)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard code == 200 else {
                fail(code == 401 ? "Token rejected" : "HTTP \(code)")
                return
            }
            let states = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] ?? []
            entities = states.compactMap { entity in
                guard let id = entity["entity_id"] as? String, id.hasPrefix("media_player.") else { return nil }
                let attributes = entity["attributes"] as? [String: Any]
                let members = attributes?["group_members"] as? [String] ?? []
                return EntityOption(id: id,
                                    name: attributes?["friendly_name"] as? String ?? id,
                                    deviceClass: attributes?["device_class"] as? String,
                                    grouped: members.count > 1)
            }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

            guard !entities.isEmpty else {
                fail("Connected, but no media players found")
                return
            }
            if !entities.contains(where: { $0.id == selected }) {
                selected = entities[0].id
            }
            failed = false
            status = "Found \(entities.count) media players"
            saveToken(token)     // proven to work, so keep it
            persist()
        } catch {
            fail("No response — is \(base) reachable from this Mac?")
        }
    }

    /// Picks up an edit made outside the app. Skipped while micwatch itself is
    /// frontmost, so it can't overwrite what you're in the middle of typing —
    /// isKeyWindow was the wrong test, since a window can stay key within an
    /// inactive app and that's exactly the case here.
    private func reloadFromDisk() {
        guard !NSApp.isActive, let config = Config.load() else { return }
        url = config.url
        selected = config.entity
        homeRouter = config.homeRouter ?? ""
        requireHome = config.requireHomeNetwork == true
    }

    /// Connect straight away when the settings are already filled in, so the
    /// player list is there without a click.
    func connectIfReady() async {
        guard entities.isEmpty, !url.isEmpty, !token.isEmpty, !busy else { return }
        await connect()
    }

    /// Reads the current gateway off the main thread — it shells out, so it has
    /// no business blocking the UI.
    func refreshRouter() async {
        currentRouter = await Task.detached(priority: .utility) { gatewayMAC() }.value ?? ""
    }

    /// Remember whichever router we're behind right now as "home".
    func captureRouter() async {
        await refreshRouter()
        guard !currentRouter.isEmpty else {
            fail("Could not read the router address — are you on Wi-Fi?")
            return
        }
        homeRouter = currentRouter
        persist()
    }

    var onHomeNow: Bool {
        !homeRouter.isEmpty &&
            homeRouter.caseInsensitiveCompare(currentRouter) == .orderedSame
    }

    private func fail(_ message: String) {
        failed = true
        status = message
        entities = []
    }

    /// Writes whatever is filled in so far. Called as each field settles, so
    /// closing the window half way through never loses what you typed.
    func persist() {
        let base = url.trimmingCharacters(in: .whitespaces)
        guard !base.isEmpty else { return }
        do {
            try Config(url: base, entity: selected,
                       entityName: entities.first { $0.id == selected }?.name
                           ?? Config.load()?.entityName,
                       homeRouter: homeRouter.isEmpty ? nil : homeRouter,
                       requireHomeNetwork: requireHome).save()
            saved = true
        } catch {
            fail("Could not write \(Config.path.path)")
        }
    }
}

struct SettingsView: View {
    @StateObject private var model = SettingsModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Home Assistant").font(.headline)

            VStack(alignment: .leading, spacing: 4) {
                Text("Server URL").font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    TextField("http://homeassistant.local:8123", text: $model.url)
                        .textFieldStyle(.roundedBorder)
                    switch model.reachability {
                    case .unknown:
                        Image(systemName: "circle.dashed").foregroundStyle(.tertiary)
                    case .checking:
                        ProgressView().controlSize(.small)
                    case .reachable:
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    case .unreachable:
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                    }
                }
                if model.reachability == .unreachable {
                    Text("No answer from that address").font(.caption).foregroundStyle(.red)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Long-lived access token").font(.caption).foregroundStyle(.secondary)
                SecureField("Paste token", text: $model.token)
                    .textFieldStyle(.roundedBorder)
                if let tokenPage = model.tokenPageURL {
                    Link("Create a token in Home Assistant →", destination: tokenPage)
                        .font(.caption)
                }
                Text("Scroll to Long-lived access tokens → Create Token. Stored in your Keychain.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 10) {
                Button(model.busy ? "Connecting…" : "Connect") {
                    Task { await model.connect() }
                }
                .disabled(model.busy || model.url.isEmpty || model.token.isEmpty)
                if !model.status.isEmpty {
                    Text(model.status).font(.caption)
                        .foregroundStyle(model.failed ? Color.red : Color.secondary)
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                Text("Pause this player when the mic is in use").font(.caption).foregroundStyle(.secondary)
                Picker("", selection: $model.selected) {
                    if model.entities.isEmpty {
                        // Keep a tag matching the selection, or the Picker has nothing to show
                        Text(model.selected.isEmpty ? "Connect to load players" : model.selected)
                            .tag(model.selected)
                    } else {
                        ForEach(model.entities) { entity in
                            Label(entity.name, systemImage: entity.symbol).tag(entity.id)
                        }
                    }
                }
                .labelsHidden()
                .disabled(model.entities.isEmpty)
                .onChange(of: model.selected) { model.persist() }
                Text(model.selected.isEmpty ? "Nothing selected yet" : model.selected)
                    .font(.caption).foregroundStyle(.tertiary)
            }
            Divider()

            Toggle("Only pause when I'm on my home network", isOn: $model.requireHome)
                .onChange(of: model.requireHome) { model.persist() }

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    TextField("aa:bb:cc:dd:ee:ff", text: $model.homeRouter)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                        .onChange(of: model.homeRouter) { model.persist() }
                        .onSubmit { model.persist() }
                    Button("Use current") {
                        Task { await model.captureRouter() }
                    }
                }

                HStack(spacing: 6) {
                    if model.homeRouter.isEmpty {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        Text("No router set — nothing will pause")
                            .font(.caption).foregroundStyle(.orange)
                    } else {
                        Image(systemName: model.onHomeNow ? "house.fill" : "airplane")
                            .foregroundStyle(model.onHomeNow ? Color.green : Color.secondary)
                        Text(model.onHomeNow ? "You're on this network now" : "Not on this network right now")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(model.currentRouter.isEmpty ? "no router found" : "currently \(model.currentRouter)")
                        .font(.system(.caption2, design: .monospaced)).foregroundStyle(.tertiary)
                }

                Text("The router's MAC address identifies your network without needing location "
                     + "permission. Type it in directly if you'd rather set it while away.")
                    .font(.caption).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
            }
            .disabled(!model.requireHome)

            // Always present, so saving doesn't change the window's height
            Button(action: openConfigInEditor) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(model.saved ? "Saved to \(Config.path.path)" : " ")
                        .font(.caption).foregroundStyle(.secondary)
                    if model.saved {
                        Text("↗").font(.caption).foregroundStyle(Color.accentColor)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())     // the whole line, not just the glyph
            }
            .buttonStyle(.plain)
            .disabled(!model.saved)
            .help("Open in TextEdit")
        }
        .padding(18)
        .frame(width: 460)
        .task {
            await model.refreshRouter()
            await model.connectIfReady()
        }
        .task(id: model.url) {
            try? await Task.sleep(nanoseconds: 600_000_000)   // debounce typing
            guard !Task.isCancelled else { return }
            await model.check()
        }
    }
}

/// Accessory apps are hidden from the Dock and cmd-tab, which makes a settings
/// window impossible to get back to once it loses focus. Become a regular app
/// while it's open, and go back to menu-bar-only when it closes.
final class SettingsWindowDelegate: NSObject, NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }

    /// cmd-Q shouldn't kill a menu bar app just because its settings window is
    /// showing — the only way out is Quit in the menu bar.
    @objc func closeSettings() {
        Settings.window?.performClose(nil)
    }
}

enum Settings {
    static var window: NSWindow?
    static let windowDelegate = SettingsWindowDelegate()

    static func show() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 580),
                             styleMask: [.titled, .closable], backing: .buffered, defer: false)
            w.title = "micwatch Settings"
            w.contentView = NSHostingView(rootView: SettingsView())
            w.isReleasedWhenClosed = false
            w.delegate = windowDelegate           // delegate is weak, hence the static
            w.center()
            window = w
        }
        let content = NSHostingView(rootView: SettingsView())   // fresh, so .task re-runs
        window?.contentView = content
        window?.setContentSize(content.fittingSize)             // no dead space at the bottom
        NSApp.setActivationPolicy(.regular)       // puts us in the Dock and cmd-tab
        NSApp.activate(ignoringOtherApps: true)
        window?.initialFirstResponder = nil
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(nil)           // open with nothing focused or highlighted
    }
}

// MARK: - Event source

/// Calls `onChange` whenever any input device starts or stops running.
/// Costs nothing while idle — no timer, no wakeups.
final class MicMonitor {
    private let queue = DispatchQueue(label: "micwatch.audio")
    private var listeners: [AudioObjectID: AudioObjectPropertyListenerBlock] = [:]  // queue only
    private var deviceListListener: AudioObjectPropertyListenerBlock?
    private let onChange: () -> Void

    init(onChange: @escaping () -> Void) { self.onChange = onChange }

    func start() {
        var addr = prop(kAudioHardwarePropertyDevices)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.sync() }
        deviceListListener = block
        AudioObjectAddPropertyListenerBlock(systemObject, &addr, queue, block)  // AirPods connecting, etc.
        queue.async { self.sync() }
    }

    /// Listen on devices that appeared, forget ones that went away.
    /// Always on `queue`, which is what keeps `listeners` consistent.
    private func sync() {
        let live = Set(inputDevices())
        var addr = prop(kAudioDevicePropertyDeviceIsRunningSomewhere)
        for id in live.subtracting(listeners.keys) {
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.onChange() }
            if AudioObjectAddPropertyListenerBlock(id, &addr, queue, block) == noErr { listeners[id] = block }
        }
        for id in Set(listeners.keys).subtracting(live) {
            if let block = listeners.removeValue(forKey: id) {
                AudioObjectRemovePropertyListenerBlock(id, &addr, queue, block)  // needs the same block
            }
        }
        onChange()
    }
}

// MARK: - Watching the config file

extension Notification.Name {
    static let configChanged = Notification.Name("micwatch.configChanged")
}

/// Reloads when ~/.config/micwatch.json changes underneath us, so hand-editing
/// it doesn't need a restart.
final class ConfigWatcher {
    private var source: DispatchSourceFileSystemObject?
    private var descriptor: CInt = -1
    private var pending: Task<Void, Never>?

    init() { start() }

    /// A single save arrives as several events — write, extend and attrib — so
    /// collapse a burst into one reload.
    private func notifyOnce() {
        pending?.cancel()
        pending = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            NotificationCenter.default.post(name: .configChanged, object: nil)
        }
    }

    private func start() {
        descriptor = open(Config.path.path, O_EVTONLY)
        guard descriptor >= 0 else {
            // Not written yet — look again shortly rather than giving up
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.start() }
            return
        }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .extend, .attrib, .delete, .rename],
            queue: .main)

        source.setEventHandler { [weak self] in
            guard let self, let source = self.source else { return }
            self.notifyOnce()
            // Editors save by writing a new file and renaming it over the old
            // one, which leaves this descriptor watching something unlinked.
            if source.data.contains(.delete) || source.data.contains(.rename) {
                self.restart()
            }
        }
        source.setCancelHandler { [weak self] in
            guard let self, self.descriptor >= 0 else { return }
            close(self.descriptor)
            self.descriptor = -1
        }
        self.source = source
        source.resume()
    }

    private func restart() {
        source?.cancel()
        source = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in self?.start() }
    }
}

/// TextEdit specifically, rather than whatever claims .json — this is a file you
/// want to glance at and tweak, not open a project for.
func openConfigInEditor() {
    let textEdit = URL(fileURLWithPath: "/System/Applications/TextEdit.app")
    NSWorkspace.shared.open([Config.path], withApplicationAt: textEdit,
                            configuration: NSWorkspace.OpenConfiguration())
}

// MARK: - Pause overlay

/// A transient panel shown when the music is paused, offering the choices that
/// only make sense for this particular pause. It fades itself out — the default,
/// if you ignore it, is simply to resume when the mic is released.
///
/// Not @MainActor: every caller is already on the main thread (menu actions,
/// tracking areas, and the paused callback which hops there itself), and the
/// annotation only makes those call sites fail to compile.
final class PauseOverlay {
    static let shared = PauseOverlay()
    private var panel: NSPanel?
    private var dismissal: Task<Void, Never>?

    struct Actions {
        let resume: () -> Void
        let pauseAgain: () -> Void
        let disable: (Int) -> Void
    }

    func show(player: String, apps: [String], isPaused: Bool, actions: Actions) {
        dismiss()

        let view = PauseOverlayView(player: player, apps: apps, isPaused: isPaused, actions: actions,
                                    hover: { [weak self] inside in self?.keepAlive(inside) },
                                    close: { [weak self] in self?.dismiss() })
        let hosting = NSHostingView(rootView: view)
        hosting.frame.size = hosting.fittingSize

        // Non-activating: it must never steal focus from whatever you're doing,
        // least of all whatever just took the mic.
        let panel = NSPanel(contentRect: hosting.frame,
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.contentView = hosting
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.animationBehavior = .utilityWindow

        position(panel)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            panel.animator().alphaValue = 1
        }
        self.panel = panel

        armDismissal(after: .seconds(6))
    }

    /// True while the pointer is over the panel — reading the options shouldn't
    /// race the timer that hides them. Leaving re-arms a shorter one.
    func keepAlive(_ inside: Bool) {
        dismissal?.cancel()
        if !inside { armDismissal(after: .seconds(2)) }
    }

    private func armDismissal(after delay: Duration) {
        dismissal?.cancel()
        dismissal = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.dismiss()
        }
    }

    var isShowing: Bool { panel != nil }

    /// Under the menu bar, tucked against the right edge like the system's own
    /// menu extras, and clamped so it can't run off a small display.
    private func position(_ panel: NSPanel) {
        guard let screen = NSScreen.main else { return }
        let margin: CGFloat = 12
        let size = panel.frame.size
        let x = min(screen.visibleFrame.maxX - size.width - margin,
                    screen.frame.maxX - size.width - margin)
        let y = screen.visibleFrame.maxY - size.height - margin
        panel.setFrameOrigin(NSPoint(x: max(screen.frame.minX + margin, x), y: y))
    }

    func dismiss() {
        dismissal?.cancel()
        guard let panel else { return }
        self.panel = nil
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            panel.animator().alphaValue = 0
        } completionHandler: {
            panel.orderOut(nil)
        }
    }
}

/// Track and artwork for the overlay. Loaded when it appears rather than passed
/// in, so showing the panel is never blocked on a network round trip.
@MainActor
final class NowPlaying: ObservableObject {
    @Published var title: String?
    @Published var artist: String?
    @Published var artwork: NSImage?

    func load(entity: String) async {
        guard let config = Config.load(), let token = loadToken() else { return }
        guard let (status, data) = await Task.detached(priority: .userInitiated, operation: {
            haRequest("/api/states/\(entity)", base: config.url, token: token)
        }).value, status == 200,
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let attributes = json["attributes"] as? [String: Any] else { return }

        title = attributes["media_title"] as? String
        artist = attributes["media_artist"] as? String ?? attributes["media_album_name"] as? String

        // entity_picture is a path on the HA host, already carrying its own
        // signed token, so it needs no Authorization header of ours.
        guard let path = attributes["entity_picture"] as? String,
              let url = URL(string: path.hasPrefix("http") ? path : config.url + path),
              let (bytes, _) = try? await URLSession.shared.data(from: url) else { return }
        artwork = NSImage(data: bytes)
    }
}

struct PauseOverlayView: View {
    @StateObject private var nowPlaying = NowPlaying()
    @State private var hovering = false
    let player: String
    let apps: [String]
    let isPaused: Bool
    let actions: PauseOverlay.Actions
    let hover: (Bool) -> Void
    let close: () -> Void

    /// Anything that fell back to a bundle id — "com.tinyspeck.slackmacgap" —
    /// reads better as its last component.
    private var micHolders: String {
        apps.map { name in
            guard name.contains("."), !name.contains(" ") else { return name }
            return (name.split(separator: ".").last.map(String.init) ?? name).capitalized
        }
        .joined(separator: ", ")
    }

    /// Home Assistant's own friendly_name when we have it — deriving from the
    /// entity id turns "Lounge TV" into "Lounge Tv" and mangles anything with
    /// a model number in it.
    private var displayName: String {
        if let stored = Config.load()?.entityName, !stored.isEmpty { return stored }
        let derived = player.split(separator: ".").dropFirst().joined(separator: ".")
            .replacingOccurrences(of: "_", with: " ").capitalized
        return derived.isEmpty ? player : derived
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            card
            if hovering {
                Button(action: close) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 17))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(Color(nsColor: .labelColor), Color(nsColor: .windowBackgroundColor))
                }
                .buttonStyle(.plain)
                .help("Dismiss")
                .offset(x: -5, y: -5)
                .transition(.opacity.combined(with: .scale(scale: 0.8)))
            }
        }
        .padding(7)                          // room for the close button to overhang
        .animation(.easeOut(duration: 0.12), value: hovering)
        .task { await nowPlaying.load(entity: player) }
        .onHover { inside in
            hovering = inside
            hover(inside)
        }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 11) {
                artworkView
                // Not paused says nothing about the speaker — it may be idle,
                // stopped or off — so the title describes the meeting instead.
                VStack(alignment: .leading, spacing: 2) {
                    Text(isPaused ? "Paused \(displayName)" : "Mic in use")
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)

                    if let track = nowPlaying.title {
                        Text([track, nowPlaying.artist].compactMap { $0 }.joined(separator: " — "))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    if !micHolders.isEmpty {
                        Text(micHolders)
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }

            HStack(spacing: 8) {
                Spacer(minLength: 0)
                if isPaused {
                    Button("Resume") { actions.resume(); close() }
                    Menu("Resume and disable") {
                        durations
                    }
                    .menuStyle(.button)
                    .fixedSize()
                } else {
                    Button("Pause \(displayName)") { actions.pauseAgain(); close() }
                    Menu("Disable") {
                        durations
                    }
                    .menuStyle(.button)
                    .fixedSize()
                }
            }
            .controlSize(.small)
        }
        .padding(14)
        .frame(width: 360, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(.separator, lineWidth: 0.5)
        )
    }

    /// Album art when there is any, the state glyph when there isn't — same
    /// footprint either way, so the card doesn't resize when artwork arrives.
    @ViewBuilder private var artworkView: some View {
        ZStack {
            if let artwork = nowPlaying.artwork {
                Image(nsImage: artwork)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(.quaternary)
                    .overlay {
                        Image(systemName: isPaused ? "pause.fill" : "mic.fill")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
            }
        }
        .frame(width: 38, height: 38)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(.separator.opacity(0.6), lineWidth: 0.5)
        )
    }

    @ViewBuilder private var durations: some View {
        Button("For 1 hour") { actions.disable(1); close() }
        Button("For 3 hours") { actions.disable(3); close() }
        Button("For 1 day") { actions.disable(24); close() }
        Button("For 1 week") { actions.disable(168); close() }
        Button("Until I re-enable it") { actions.disable(0); close() }
    }
}

// MARK: - Menu bar

/// Why micwatch would or wouldn't act right now.
enum Availability {
    case micInUse([String])
    case ready
    case snoozed(until: Date?)     // nil means until manually re-enabled
    case away
    case unreachable(String)
    case unconfigured

    /// Only the first two will pause anything.
    var active: Bool {
        switch self {
        case .micInUse, .ready: return true
        default: return false
        }
    }
}

final class Watcher: NSObject, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private var current: [String] = []          // main thread only
    private var monitor: MicMonitor?
    private let music = MusicControl()
    private var snoozeUntil: Date?
    private var reachable: Bool?                // nil until we've actually tried
    private var mediaPaused = false
    private var shownSymbol = ""                // so render can tell a real change
    private var pendingPause: Task<Void, Never>?

    // Built once, mutated in place — see buildMenu
    private let statusLine = NSMenuItem()
    private let disableItem = NSMenuItem(title: "Disable", action: nil, keyEquivalent: "")
    private let loginItem = NSMenuItem(title: "Open at Login",
                                       action: #selector(toggleLoginItem), keyEquivalent: "")
    private var disableChoices = NSMenu()
    private var hoverTimer: Timer?
    private var configWatcher: ConfigWatcher?
    private var pointerWasOnIcon = false

    func start() {
        let menu = buildMenu()
        menu.delegate = self                    // menuNeedsUpdate refreshes it before display
        rebuild()                               // so the first open is already correct
        item.menu = menu
        render()



        music.onPausedChange = { [weak self] paused in
            guard let self else { return }
            self.mediaPaused = paused
            self.render()
            self.rebuild()
            self.watchForHover(self.overlayWorthShowing)
            if paused { self.showOverlay() } else { PauseOverlay.shared.dismiss() }
        }

        configWatcher = ConfigWatcher()
        NotificationCenter.default.addObserver(forName: .configChanged, object: nil, queue: .main) {
            [weak self] _ in
            self?.rebuild()
            self?.render()
        }

        monitor = MicMonitor { [weak self] in self?.tick() }
        monitor?.start()

        // ponytail: 5min backstop, insurance against the listeners going quiet —
        // which is not hypothetical, the process-level ones did exactly that. Also
        // what eventually clears an expired snooze if you never open the menu.
        Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { _ in self.tick() }

        if Config.load()?.entity.isEmpty ?? true { Settings.show() }
    }

    /// Listeners fire on a background queue, so everything here hops to main.
    func tick() {
        DispatchQueue.main.async {
            let apps = appsOnMic()
            if apps != self.current {
                let wasActive = !self.current.isEmpty
                self.current = apps
                let isActive = !apps.isEmpty

                print("\(Date().formatted(date: .omitted, time: .standard))  " +
                      (apps.isEmpty ? "MIC FREE" : "MIC IN USE  " + apps.joined(separator: ", ")))

                switch (wasActive, isActive) {
                case (false, true):  self.schedulePause()
                case (true, false):
                    self.cancelPendingPause()
                    self.music.micActive(false, allowed: true)
                default: break       // mic still held, the app list just changed
                }
            }
            self.watchForHover(self.overlayWorthShowing)
            self.render()   // cheap, and catches a snooze that has expired
        }
    }

    /// Wait a moment before pausing, so an app that grabs the mic and drops it
    /// straight away doesn't interrupt your music. Short enough to still feel
    /// immediate — resuming is never delayed.
    private static let pauseDelay = Duration.milliseconds(250)

    private func schedulePause() {
        pendingPause?.cancel()
        pendingPause = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Watcher.pauseDelay)
            guard let self, !Task.isCancelled, !self.current.isEmpty else { return }
            self.music.micActive(true, allowed: self.availability().active)
        }
    }

    private func cancelPendingPause() {
        pendingPause?.cancel()
        pendingPause = nil
    }

    private func availability() -> Availability {
        if let until = snoozeUntil {
            if until == .distantFuture { return .snoozed(until: nil) }
            if until > Date() { return .snoozed(until: until) }
            snoozeUntil = nil                   // expired
        }
        guard let config = Config.load(), !config.entity.isEmpty, loadToken() != nil else { return .unconfigured }
        if !onHomeNetwork(config) { return .away }
        if reachable == false { return .unreachable(config.url) }
        return current.isEmpty ? .ready : .micInUse(current)
    }

    // MARK: Rendering

    /// Faded means it won't act on a meeting.
    private var restingAlpha: CGFloat { availability().active ? 1.0 : 0.4 }

    /// The status bar sets items flush against each other. A couple of points of
    /// trailing space stops ours crowding its neighbour.
    private func paddedSymbol(_ name: String, _ description: String) -> NSImage? {
        guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: description) else {
            return nil
        }
        let trailing: CGFloat = 3
        let padded = NSImage(size: NSSize(width: symbol.size.width + trailing, height: symbol.size.height))
        padded.lockFocus()
        symbol.draw(at: .zero, from: .zero, operation: .sourceOver, fraction: 1)
        padded.unlockFocus()
        padded.isTemplate = true    // so it still follows the menu bar's appearance
        return padded
    }

    /// Crossfades when the icon actually changes, and does nothing visible
    /// otherwise. Swapping the image mid-fade is what reads as janky — the
    /// change has to happen at the trough, while nothing is on screen.
    private func render() {
        guard let button = item.button else { return }

        // Only two states worth showing: paused, or not. A separate "in a meeting"
        // icon would flash for the 250ms before pausing and would also appear when
        // disabled, where nothing is going to happen anyway.
        let symbol = mediaPaused ? "pause.circle.fill" : "mic.slash"
        let description = mediaPaused ? "Music paused, mic in use" : "Not paused"

        guard symbol != shownSymbol else {
            button.alphaValue = restingAlpha    // same icon, just the enabled state moved
            return
        }
        shownSymbol = symbol

        let image = paddedSymbol(symbol, description)
        guard button.image != nil else {
            button.image = image                // first draw, nothing to fade from
            button.alphaValue = restingAlpha
            return
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.10
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            button.animator().alphaValue = 0
        } completionHandler: {
            button.image = image
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                context.timingFunction = CAMediaTimingFunction(name: .easeIn)
                button.animator().alphaValue = self.restingAlpha
            }
        }
    }

    /// Two lines: a coloured dot with a headline, and a quieter detail line.
    /// The dot is a real image in the icon column, not a bullet inlined in the
    /// text, so both lines start at the same place as every other item's title.
    /// One line, one icon, at the same size as every other item — a two-line
    /// title can't be aligned against AppKit's own layout, and the detail reads
    /// better folded into the sentence than stacked beneath it.
    private func statusTitle(_ state: Availability) -> (dot: NSImage?, title: String) {
        let colour: NSColor, text: String

        switch state {
        case .micInUse(let apps):
            colour = .systemGreen
            let player = Config.load().map { $0.entityName ?? $0.entity } ?? ""
            text = mediaPaused ? "Paused \(player)"
                               : "Mic in use by \(apps.joined(separator: ", "))"
        case .ready:
            colour = .systemGreen
            text = "Watching the mic"
        case .snoozed(let until):
            colour = .systemOrange
            text = until.map { "Disabled until \($0.formatted(date: .omitted, time: .shortened))" }
                ?? "Disabled"
        case .away:
            colour = .systemGray
            text = "Away from home"
        case .unreachable:
            colour = .systemRed
            text = "Home Assistant unreachable"
        case .unconfigured:
            colour = .systemRed
            text = "Not set up yet"
        }
        return (symbol("circle.fill", color: colour), text)
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false           // the status line stays greyed out

        statusLine.isEnabled = false
        menu.addItem(statusLine)
        menu.addItem(.separator())

        let choices = NSMenu()
        for (label, hours) in [("For 1 hour", 1), ("For 3 hours", 3),
                               ("For 1 day", 24), ("For 1 week", 168),
                               ("Until I re-enable it", 0)] {
            let choice = target(NSMenuItem(title: label, action: #selector(snooze(_:)), keyEquivalent: ""))
            choice.tag = hours
            choices.addItem(choice)
        }
        disableChoices = choices
        disableItem.image = symbol("moon.zzz")
        menu.addItem(target(disableItem))

        menu.addItem(.separator())
        menu.addItem(target(loginItem))

        let settings = target(NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ","))
        settings.image = symbol("gearshape")
        menu.addItem(settings)

        let quit = NSMenuItem(title: "Quit micwatch",
                              action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.image = symbol("power")
        menu.addItem(quit)
        return menu
    }

    /// Updates the existing items in place — same count, same order, so the menu
    /// never resizes while it's open.
    private func rebuild() {
        let state = availability()
        let status = statusTitle(state)
        statusLine.image = status.dot
        statusLine.title = status.title

        if case .snoozed = state {
            disableItem.title = "Enable now"
            disableItem.submenu = nil
            disableItem.action = #selector(enableNow)
        } else {
            disableItem.title = "Disable"
            disableItem.submenu = disableChoices
            disableItem.action = nil
        }
        let launches = SMAppService.mainApp.status == .enabled
        loginItem.image = symbol(launches ? "checkmark.circle.fill" : "circle")

    }

    /// Menu icons at the system's own menu-item size.
    private func symbol(_ name: String, color: NSColor? = nil, pointSize: CGFloat = 13) -> NSImage? {
        var configuration = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .regular)
        if let color { configuration = configuration.applying(.init(paletteColors: [color])) }
        return NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration)
    }

    private func target(_ menuItem: NSMenuItem) -> NSMenuItem {
        menuItem.target = self
        return menuItem
    }

    // MARK: Actions

    /// Refresh on open — free, because nothing runs while the menu is closed.
    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuild()
        probeReachability()
    }

    /// One HEAD request, off the main thread; the menu redraws if the answer changed.
    private func probeReachability() {
        guard let config = Config.load(), let url = URL(string: config.url) else { return }
        var request = URLRequest(url: url, timeoutInterval: 3)
        request.httpMethod = "HEAD"
        URLSession.shared.dataTask(with: request) { [weak self] _, response, _ in
            DispatchQueue.main.async {
                guard let self, self.reachable != (response != nil) else { return }
                self.reachable = response != nil
                self.rebuild()
                self.render()
            }
        }.resume()
    }

    @objc private func snooze(_ sender: NSMenuItem) {
        snoozeUntil = sender.tag == 0 ? .distantFuture
                                      : Date().addingTimeInterval(TimeInterval(sender.tag) * 3600)
        rebuild(); render()
    }

    /// The choices that apply to this pause only, so they live in the overlay
    /// rather than the menu, where they'd read as settings.
    private var overlayWorthShowing: Bool { mediaPaused || !current.isEmpty }

    private func showOverlay() {
        guard overlayWorthShowing, let config = Config.load() else { return }
        PauseOverlay.shared.show(
            player: config.entity,
            apps: current,
            isPaused: mediaPaused,
            actions: .init(
                resume: { [weak self] in
                    guard let self else { return }
                    self.music.resumeNow()
                },
                pauseAgain: { [weak self] in self?.music.pauseNow() },
                disable: { [weak self] hours in
                    guard let self else { return }
                    self.music.resumeNow()      // no-op unless we're the ones holding it
                    self.snoozeUntil = hours == 0 ? .distantFuture
                                                  : Date().addingTimeInterval(TimeInterval(hours) * 3600)
                    self.rebuild()
                    self.render()
                }
            )
        )
    }

    /// Asking where the pointer is, rather than waiting to be told.
    ///
    /// NSTrackingArea on the status item never delivered — NSStatusBarButton does
    /// its own tracking and the owner here isn't a responder — and a global
    /// mouseMoved monitor didn't fire either. NSEvent.mouseLocation is a plain
    /// query: no event routing to fail, no permission to be missing. It only runs
    /// while something is paused, which is the only time there's anything to show.
    private func watchForHover(_ watching: Bool) {
        hoverTimer?.invalidate()
        hoverTimer = nil
        pointerWasOnIcon = false
        guard watching else { return }
        hoverTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            self?.hoverCheck()
        }
    }

    private func hoverCheck() {
        guard let frame = item.button?.window?.frame else { return }
        let onIcon = frame.contains(NSEvent.mouseLocation)
        defer { pointerWasOnIcon = onIcon }

        // Only on arrival, so a pointer resting on the icon doesn't refire the
        // overlay the moment it times out.
        guard onIcon, !pointerWasOnIcon, overlayWorthShowing, !PauseOverlay.shared.isShowing else { return }
        showOverlay()
    }

    @objc private func enableNow() {
        snoozeUntil = nil
        rebuild(); render()
    }

    /// SMAppService registers the bundle itself — no launchd plist to write, and
    /// macOS keeps it working across moves and updates.
    @objc private func toggleLoginItem() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSLog("micwatch: could not change the login item: \(error.localizedDescription)")
        }
        rebuild()
    }

    @objc private func openSettings() { Settings.show() }
}

// MARK: - Checks

/// Opens the mic on ourselves and asserts the listener path notices — not just
/// that a scan would. Process-level listeners silently never fired; only an
/// end-to-end check catches that.
func selftest() -> Never {
    if !appsOnMic().isEmpty {
        print("SKIP: mic already in use by \(appsOnMic().joined(separator: ", "))"); exit(2)
    }
    let fired = DispatchSemaphore(value: 0)
    var sawApps: [String] = []
    let monitor = MicMonitor {
        let apps = appsOnMic()
        if !apps.isEmpty { sawApps = apps; fired.signal() }
    }
    monitor.start()

    let session = AVCaptureSession()
    guard let dev = AVCaptureDevice.default(for: .audio),
          let input = try? AVCaptureDeviceInput(device: dev), session.canAddInput(input) else {
        print("FAIL: no mic access (grant Microphone permission to this terminal)"); exit(1)
    }
    session.addInput(input)
    let output = AVCaptureAudioDataOutput()  // without an output the device never starts
    if session.canAddOutput(output) { session.addOutput(output) }
    session.startRunning()

    guard fired.wait(timeout: .now() + 5) == .success else {
        print("FAIL: mic open but no listener fired within 5s"); exit(1)
    }
    session.stopRunning()
    Thread.sleep(forTimeInterval: 1)
    precondition(appsOnMic().isEmpty, "mic closed but still reported in use")
    print("PASS: listener fired for \(sawApps.joined(separator: ", "))")
    exit(0)
}

// MARK: - Entry

if CommandLine.arguments.contains("--selftest") { selftest() }
if CommandLine.arguments.contains("--ha-state") { haState() }
if let i = CommandLine.arguments.firstIndex(of: "--hold") {   // hold the mic, to test from another shell
    let secs = Double(CommandLine.arguments.count > i + 1 ? CommandLine.arguments[i + 1] : "5") ?? 5
    let session = AVCaptureSession()
    guard let dev = AVCaptureDevice.default(for: .audio),
          let input = try? AVCaptureDeviceInput(device: dev) else { print("no mic"); exit(1) }
    session.addInput(input)
    let output = AVCaptureAudioDataOutput()
    if session.canAddOutput(output) { session.addOutput(output) }
    session.startRunning()
    print("holding mic \(secs)s")
    Thread.sleep(forTimeInterval: secs)
    exit(0)
}
if CommandLine.arguments.contains("--once") {
    let apps = appsOnMic()
    print(apps.isEmpty ? "idle" : "mic in use: \(apps.joined(separator: ", "))")
    exit(0)
}

/// Without a main menu there are no key equivalents, so cmd-C/V do nothing in the
/// settings fields — right-click still works, which is what makes it look like a
/// text field bug rather than a missing menu. Nothing here is ever displayed
/// unless the settings window is open.
func installEditMenu() {
    let edit = NSMenu(title: "Edit")
    for (title, action, key) in [("Undo", "undo:", "z"), ("Redo", "redo:", "Z"),
                                 ("Cut", "cut:", "x"), ("Copy", "copy:", "c"),
                                 ("Paste", "paste:", "v"), ("Select All", "selectAll:", "a")] {
        edit.addItem(NSMenuItem(title: title, action: Selector((action)), keyEquivalent: key))
    }
    let editItem = NSMenuItem()
    editItem.submenu = edit

    let appMenu = NSMenu()
    for (title, key) in [("Close Settings", "w"), ("Close Settings", "q")] {
        let close = NSMenuItem(title: title, action: #selector(SettingsWindowDelegate.closeSettings),
                               keyEquivalent: key)
        close.target = Settings.windowDelegate
        appMenu.addItem(close)
    }
    let appItem = NSMenuItem()
    appItem.submenu = appMenu

    let main = NSMenu()
    main.addItem(appItem)
    main.addItem(editItem)
    NSApp.mainMenu = main
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)  // menu bar only, no Dock icon
installEditMenu()
let watcher = Watcher()
watcher.start()
app.run()

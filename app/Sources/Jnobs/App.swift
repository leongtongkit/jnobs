import SwiftUI
import AppKit
import os

@main
struct JnobsApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarPopover(delegate: delegate)
        } label: {
            MenuBarLabel(delegate: delegate)
        }
        .menuBarExtraStyle(.window)

        Window("Jnobs Console", id: "settings") {
            ConsoleWindow(delegate: delegate)
        }
        .windowResizability(.contentSize)
    }
}

/// The menubar status icon, redrawn when the underlying device state changes
/// or the system master volume / mute state changes.
private struct MenuBarLabel: View {
    @ObservedObject var delegate: AppDelegate
    @ObservedObject var dm: DeviceManager
    @ObservedObject var vol = MasterVolumeMonitor.shared
    init(delegate: AppDelegate) {
        self.delegate = delegate
        self.dm = delegate.deviceManager
    }
    var body: some View {
        MenuBarIcon(state: dm.state, volume: vol.volume, muted: vol.muted)
    }
}

/// Hands off to MenuBarContent once the renderer is wired up
/// (LEDRenderer is constructed in applicationDidFinishLaunching).
private struct MenuBarPopover: View {
    @ObservedObject var delegate: AppDelegate
    var body: some View {
        if let r = delegate.renderer, let tap = delegate.router?.tapRouter {
            MenuBarContent(
                delegate: delegate,
                dm: delegate.deviceManager,
                renderer: r,
                tapRouter: tap,
                onQuit: { NSApplication.shared.terminate(nil) }
            )
        } else {
            ProgressView().frame(width: 360, height: 120)
        }
    }
}

private struct ConsoleWindow: View {
    @ObservedObject var delegate: AppDelegate
    var body: some View {
        if let r = delegate.renderer, let tap = delegate.router?.tapRouter {
            SettingsView(
                delegate: delegate,
                dm: delegate.deviceManager,
                renderer: r,
                tapRouter: tap
            )
        } else {
            ProgressView().frame(width: 560, height: 720)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    let log = Logger(subsystem: "net.jfound.jnobs", category: "App")
    @Published var deviceManager = DeviceManager()
    @Published var config: AppConfig = ConfigStore.load()
    var router: ActionRouter!
    /// Published so SwiftUI's wrappers re-evaluate once it's been constructed
    /// in applicationDidFinishLaunching.
    @Published var renderer: LEDRenderer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu-bar-only app, no Dock icon.
        NSApp.setActivationPolicy(.accessory)
        router = ActionRouter(config: config, deviceManager: deviceManager)
        let r = LEDRenderer(deviceManager: deviceManager, router: router)
        renderer = r

        deviceManager.addSubscriber { [weak self] ev in
            guard let self else { return }
            Task { @MainActor in
                self.router.handle(event: ev)
            }
        }

        if !FileManager.default.fileExists(atPath: ConfigStore.fileURL.path) {
            ConfigStore.save(.default)
        }

        deviceManager.start()
        r.start()
        CoreAudioVolume.logDiagnostics()

        // Start the local HTTP control server (used by the Stream Deck plugin
        // and any other localhost integration). Bound to 127.0.0.1:49152.
        JnobsHTTP.shared.delegate = self
        JnobsHTTP.shared.start()

        log.info("Jnobs launched")
    }

    func applicationWillTerminate(_ notification: Notification) {
        renderer?.stop()
    }

    func reloadConfig() {
        let cfg = ConfigStore.load()
        config = cfg
        router.updateConfig(cfg)
    }

    /// Mutate config in place, persist, and push to the router. Also pushes
    /// a state change over HTTP/SSE so any Stream Deck plugins reflect it.
    func updateConfig(_ transform: (inout AppConfig) -> Void) {
        let prev = config
        var cfg = config
        transform(&cfg)
        config = cfg
        router?.updateConfig(cfg)
        if cfg.activeProfileName != prev.activeProfileName
            || cfg.profiles.map(\.name) != prev.profiles.map(\.name) {
            JnobsHTTP.shared.broadcastStateChange()
        }
    }

    func resetConfig() {
        config = .default
        ConfigStore.save(.default)
        router?.updateConfig(.default)
    }
}

// MARK: - Stream Deck / HTTP control surface

extension AppDelegate: JnobsHTTPDelegate {
    func httpCurrentSnapshot() -> JnobsHTTPSnapshot {
        JnobsHTTPSnapshot(
            activeProfile: config.activeProfileName,
            profileNames: config.profiles.map(\.name),
            micMuted: router?.micMuted ?? false,
            systemMuted: router?.systemMuted ?? false
        )
    }

    func httpLoadProfile(named name: String) {
        updateConfig { $0.loadProfile(named: name) }
        JnobsHTTP.shared.broadcastStateChange()
    }

    func httpCycleProfile(direction: Int) {
        guard !config.profiles.isEmpty else { return }
        let names = config.profiles.map(\.name)
        let currentIdx = names.firstIndex(where: { $0 == config.activeProfileName }) ?? -1
        let nextIdx = ((currentIdx + direction) % names.count + names.count) % names.count
        updateConfig { $0.loadProfile(named: names[nextIdx]) }
        JnobsHTTP.shared.broadcastStateChange()
    }

    func httpFireButton(index: Int) {
        // Synthesize a press+release straight into the router so long-press
        // logic stays consistent (40 ms hold counts as a short tap).
        router?.handle(event: .buttonPressed(index: index))
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) { [weak self] in
            self?.router?.handle(event: .buttonReleased(index: index))
        }
    }

    func httpSetMicMute(value: Bool?) {
        let target = value ?? !(CoreAudioVolume.getMicMute() ?? false)
        _ = CoreAudioVolume.setMicMute(target)
    }

    func httpSetSystemMute(value: Bool?) {
        let target = value ?? !(CoreAudioVolume.getMasterMute() ?? false)
        _ = CoreAudioVolume.setMasterMute(target)
    }
}

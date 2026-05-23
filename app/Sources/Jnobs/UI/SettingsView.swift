import SwiftUI

/// Console window — the full Jnobs control surface, arranged into tabs so the
/// content fits the window without scrolling: Device (home), Controls (knobs +
/// buttons), Lighting, and Routing (per-app output).
struct SettingsView: View {
    @ObservedObject var delegate: AppDelegate
    @ObservedObject var dm: DeviceManager
    @ObservedObject var renderer: LEDRenderer
    @ObservedObject var tapRouter: TapRouter

    @State private var tab: ConsoleTab = .device

    var body: some View {
        VStack(spacing: 0) {
            ConsoleHeader(delegate: delegate, dm: dm)
            Divider().overlay(Jn.stroke)
            ConsoleTabBar(selected: $tab)
            Divider().overlay(Jn.stroke)

            ZStack(alignment: .topLeading) {
                // Reserve the content box so all tabs share the same layout
                // frame — no resize jank when switching.
                Color.clear

                ForEach(ConsoleTab.allCases) { t in
                    if t == tab {
                        content(for: t)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                            .padding(18)
                            .transition(.opacity)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(.easeInOut(duration: 0.16), value: tab)

            Divider().overlay(Jn.stroke)
            ConsoleFooter(delegate: delegate)
        }
        .frame(width: 560, height: 680)
        .jnPanelBackground()
        .environment(\.colorScheme, .dark)
    }

    @ViewBuilder
    private func content(for tab: ConsoleTab) -> some View {
        switch tab {
        case .device:
            VStack(spacing: 14) {
                DeviceKnobsCard(delegate: delegate, dm: dm, renderer: renderer)
                    .frame(maxHeight: .infinity)
                DeviceButtonsCard(delegate: delegate, dm: dm)
                    .frame(maxHeight: .infinity)
            }

        case .controls:
            VStack(spacing: 14) {
                SectionCard(title: "KNOBS", symbol: "dial.medium.fill") {
                    VStack(spacing: 6) {
                        ForEach(0..<5, id: \.self) { i in
                            KnobRow(
                                index: i,
                                binding: delegate.config.knobs[i],
                                value: dm.knobPercents[safe: i] ?? 0,
                                onChange: { v in delegate.updateConfig { $0.knobs[i] = v } }
                            )
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                }
                .frame(maxHeight: .infinity)

                SectionCard(title: "BUTTONS", symbol: "button.programmable") {
                    VStack(spacing: 6) {
                        ForEach(0..<5, id: \.self) { i in
                            ButtonRow(
                                index: i,
                                binding: delegate.config.buttons[i],
                                longBinding: delegate.config.buttonsLong[safe: i] ?? .none,
                                flashing: dm.buttonFlash[safe: i] ?? false,
                                onChange: { v in delegate.updateConfig { $0.buttons[i] = v } },
                                onChangeLong: { v in delegate.updateConfig {
                                    while $0.buttonsLong.count <= i { $0.buttonsLong.append(.none) }
                                    $0.buttonsLong[i] = v
                                } }
                            )
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                }
                .frame(maxHeight: .infinity)
            }

        case .lighting:
            VStack(spacing: 14) {
                SectionCard(title: "LIGHTING", symbol: "lightspectrum.horizontal") {
                    VStack(spacing: 6) {
                        ForEach(0..<5, id: \.self) { i in
                            LightRow(
                                index: i,
                                binding: delegate.config.lights[i],
                                onChange: { v in delegate.updateConfig { $0.lights[i] = v } }
                            )
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                }
                .frame(maxHeight: .infinity)

                LivePreviewCard(renderer: renderer)
            }

        case .routing:
            SectionCard(title: "PER-APP OUTPUT", symbol: "arrow.triangle.branch") {
                RoutingSection(delegate: delegate, tapRouter: tapRouter)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
            .frame(maxHeight: .infinity)
        }
    }
}

// MARK: - Tabs

private enum ConsoleTab: String, CaseIterable, Identifiable {
    case device, controls, lighting, routing
    var id: String { rawValue }

    var title: String {
        switch self {
        case .device:   return "Device"
        case .controls: return "Controls"
        case .lighting: return "Lighting"
        case .routing:  return "Routing"
        }
    }

    var symbol: String {
        switch self {
        case .device:   return "antenna.radiowaves.left.and.right"
        case .controls: return "dial.medium.fill"
        case .lighting: return "lightspectrum.horizontal"
        case .routing:  return "arrow.triangle.branch"
        }
    }
}

private struct ConsoleTabBar: View {
    @Binding var selected: ConsoleTab

    var body: some View {
        HStack(spacing: 4) {
            ForEach(ConsoleTab.allCases) { t in
                Button {
                    selected = t
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: t.symbol)
                            .font(.system(size: 11, weight: .semibold))
                        Text(t.title.uppercased())
                            .font(.system(size: 10, weight: .heavy, design: .rounded))
                            .tracking(1.4)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .foregroundStyle(selected == t ? Jn.mint : Jn.inkMute)
                    .background(
                        ZStack {
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(selected == t ? Jn.cardHi.opacity(0.75) : Color.clear)
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .stroke(selected == t ? Jn.mint.opacity(0.35) : Color.clear,
                                        lineWidth: 1)
                        }
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .animation(.easeOut(duration: 0.12), value: selected)
    }
}

// MARK: - Header

private struct ConsoleHeader: View {
    @ObservedObject var delegate: AppDelegate
    @ObservedObject var dm: DeviceManager
    private var connected: Bool { if case .connected = dm.state { return true }; return false }

    private var pillText: String {
        switch dm.state {
        case .connected(let p):
            let id = dm.lastDeviceId.map { " · #\($0)" } ?? ""
            return "\(URL(fileURLWithPath: p).lastPathComponent)\(id)"
        case .connecting: return "Connecting…"
        case .disconnected: return "Plug in the device"
        case .error(let e): return "Error: \(e)"
        }
    }

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(LinearGradient(
                        colors: [Jn.cardHi, Jn.card],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    ))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(Jn.stroke, lineWidth: 1)
                    )
                    .frame(width: 36, height: 36)
                Circle()
                    .fill(Jn.mint)
                    .frame(width: 8, height: 8)
                    .shadow(color: Jn.mint.opacity(0.8), radius: 5)
            }
            VStack(alignment: .leading, spacing: 1) {
                Wordmark(size: 22)
                Text("CONSOLE · turn up mixer")
                    .font(.system(size: 9, weight: .heavy, design: .rounded))
                    .tracking(1.6)
                    .foregroundStyle(Jn.inkFaint)
            }
            Spacer()
            ProfileMenu(delegate: delegate)
            StatusPill(connected: connected, text: pillText)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }
}

/// Header menu that lets the user snapshot the current state as a new
/// profile, switch to a saved one, or manage existing profiles (overwrite
/// with current state / delete).
private struct ProfileMenu: View {
    @ObservedObject var delegate: AppDelegate
    @State private var promptingName = false
    @State private var newName: String = ""

    var body: some View {
        Menu {
            Section {
                Button("Save current as new profile…") { promptingName = true }
            }
            if !delegate.config.profiles.isEmpty {
                Section("Load profile") {
                    ForEach(delegate.config.profiles) { p in
                        Button {
                            delegate.updateConfig { $0.loadProfile(named: p.name) }
                        } label: {
                            HStack {
                                Text(p.name)
                                if p.name == delegate.config.activeProfileName {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                }
                Section("Manage profile") {
                    ForEach(delegate.config.profiles) { p in
                        Menu(p.name) {
                            Button("Update from current state") {
                                delegate.updateConfig { $0.saveProfile(named: p.name) }
                            }
                            Button("Delete", role: .destructive) {
                                delegate.updateConfig { $0.deleteProfile(named: p.name) }
                            }
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "rectangle.stack.fill")
                    .font(.system(size: 10, weight: .semibold))
                Text(delegate.config.activeProfileName ?? "Profiles")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .lineLimit(1)
            }
            .foregroundStyle(Jn.ink)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(
                Capsule().fill(Jn.cardHi.opacity(0.65))
                    .overlay(Capsule().stroke(Jn.stroke, lineWidth: 1))
            )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .alert("Save profile", isPresented: $promptingName) {
            TextField("Profile name", text: $newName)
            Button("Save") {
                let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { return }
                delegate.updateConfig { $0.saveProfile(named: name) }
                newName = ""
            }
            Button("Cancel", role: .cancel) { newName = "" }
        } message: {
            Text("Captures the current knob, button, long-press, and light bindings.")
        }
    }
}

// MARK: - Device tab cards

private struct DeviceKnobsCard: View {
    @ObservedObject var delegate: AppDelegate
    @ObservedObject var dm: DeviceManager
    @ObservedObject var renderer: LEDRenderer
    private var config: AppConfig { delegate.config }
    private var connected: Bool { if case .connected = dm.state { return true }; return false }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionCaption(text: "Knobs", symbol: "dial.medium.fill")
            HStack(alignment: .center, spacing: 12) {
                ForEach(0..<5, id: \.self) { i in
                    KnobDial(
                        percent: dm.knobPercents[safe: i] ?? 0,
                        ledColors: ledColors(for: i),
                        label: knobLabel(for: i),
                        sublabel: "\(Int(dm.knobPercents[safe: i] ?? 0))%",
                        size: 88,
                        isLive: connected
                    )
                    .frame(maxWidth: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
        .jnCard(padding: 16)
    }

    private func ledColors(for knob: Int) -> [Color] {
        guard knob < renderer.currentSlots.count else {
            return [Jn.mintDim.opacity(0.3), Jn.mintDim.opacity(0.3), Jn.mintDim.opacity(0.3)]
        }
        return renderer.currentSlots[knob].map { rgb -> Color in
            if rgb.r < 4 && rgb.g < 4 && rgb.b < 4 {
                return Color.white.opacity(0.08)
            }
            return rgb.swiftColor
        }
    }

    private func knobLabel(for i: Int) -> String {
        guard i < config.knobs.count else { return "K\(i+1)" }
        switch config.knobs[i] {
        case .masterVolume:      return "Master"
        case .micVolume:         return "Mic"
        case .brightness:        return "Display"
        case .lightBrightness:   return "LEDs"
        case .spotifyVolume:     return "Spotify"
        case .musicAppVolume:    return "Music"
        case .appVolume(let b):  return b.isEmpty ? "App" : AppNames.short(b)
        case .none:              return "–"
        }
    }
}

private struct DeviceButtonsCard: View {
    @ObservedObject var delegate: AppDelegate
    @ObservedObject var dm: DeviceManager
    private var config: AppConfig { delegate.config }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionCaption(text: "Buttons", symbol: "button.programmable")
            HStack(spacing: 12) {
                ForEach(0..<5, id: \.self) { i in
                    ButtonPad(
                        index: i,
                        label: buttonLabel(for: i),
                        pressed: dm.buttonFlash[safe: i] ?? false,
                        size: 56
                    )
                    .frame(maxWidth: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
        .jnCard(padding: 16)
    }

    private func buttonLabel(for i: Int) -> String {
        guard i < config.buttons.count else { return "" }
        return config.buttons[i].displayName
    }
}

private struct LivePreviewCard: View {
    @ObservedObject var renderer: LEDRenderer

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionCaption(text: "Live preview", symbol: "eye")
            HStack(spacing: 0) {
                ForEach(0..<5, id: \.self) { knob in
                    VStack(spacing: 6) {
                        HStack(spacing: 6) {
                            ForEach(0..<3, id: \.self) { led in
                                let c = color(knob: knob, led: led)
                                Circle()
                                    .fill(c)
                                    .frame(width: 13, height: 13)
                                    .shadow(color: c.opacity(0.75), radius: 5)
                                    .overlay(Circle().stroke(Color.white.opacity(0.15), lineWidth: 0.5))
                            }
                        }
                        Text("K\(knob + 1)")
                            .font(.system(size: 9, weight: .medium, design: .rounded))
                            .foregroundStyle(Jn.inkFaint)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .jnCard(padding: 14)
    }

    private func color(knob: Int, led: Int) -> Color {
        guard knob < renderer.currentSlots.count,
              led < renderer.currentSlots[knob].count else {
            return Color.white.opacity(0.08)
        }
        let rgb = renderer.currentSlots[knob][led]
        if rgb.r < 4 && rgb.g < 4 && rgb.b < 4 {
            return Color.white.opacity(0.08)
        }
        return rgb.swiftColor
    }
}

// MARK: - Section card

private struct SectionCard<Content: View>: View {
    let title: String
    let symbol: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionCaption(text: title, symbol: symbol)
            content.jnCard(padding: 14)
        }
    }
}

// MARK: - Rows

private struct KnobRow: View {
    let index: Int
    let binding: KnobBinding
    let value: Double
    let onChange: (KnobBinding) -> Void

    var body: some View {
        HStack(spacing: 12) {
            numberBadge(index + 1)
            Picker("", selection: Binding(get: { pickerTag }, set: handlePick)) {
                ForEach(KnobBinding.pickable) { opt in
                    Label(opt.displayName, systemImage: opt.symbol).tag(opt)
                }
            }
            .labelsHidden()
            .frame(maxWidth: 170, alignment: .leading)

            if binding.isAppVolume {
                AppPicker(bundleID: binding.appVolumeBundleID ?? "") { bid in
                    onChange(.appVolume(bundleID: bid))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Spacer()
            }

            inlineMeter(value: value / 100.0)
            Text("\(Int(value))%")
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(Jn.inkMute)
                .frame(width: 34, alignment: .trailing)
        }
        .padding(.vertical, 2)
    }

    private var pickerTag: KnobBinding {
        binding.isAppVolume ? .appVolume(bundleID: "") : binding
    }

    private func handlePick(_ newValue: KnobBinding) {
        if newValue.isAppVolume {
            onChange(.appVolume(bundleID: binding.appVolumeBundleID ?? ""))
        } else {
            onChange(newValue)
        }
    }
}

private struct ButtonRow: View {
    let index: Int
    let binding: ButtonBinding
    let longBinding: ButtonBinding
    let flashing: Bool
    let onChange: (ButtonBinding) -> Void
    let onChangeLong: (ButtonBinding) -> Void

    var body: some View {
        HStack(spacing: 10) {
            numberBadge(index + 1, flashing: flashing)
            Picker("", selection: Binding(get: { pickerValue }, set: onChange)) {
                ForEach(ButtonBinding.pickable) { opt in
                    Label(opt.displayName, systemImage: opt.symbol).tag(opt)
                }
            }
            .labelsHidden()
            .frame(maxWidth: .infinity, alignment: .leading)

            Text("hold")
                .font(.system(size: 9, weight: .heavy, design: .rounded))
                .tracking(0.8)
                .foregroundStyle(Jn.inkFaint)

            Picker("", selection: Binding(get: { longPickerValue }, set: onChangeLong)) {
                ForEach(ButtonBinding.pickable) { opt in
                    Label(opt.displayName, systemImage: opt.symbol).tag(opt)
                }
            }
            .labelsHidden()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 2)
    }

    private var pickerValue: ButtonBinding {
        ButtonBinding.pickable.contains(binding) ? binding : .none
    }
    private var longPickerValue: ButtonBinding {
        ButtonBinding.pickable.contains(longBinding) ? longBinding : .none
    }
}

private struct LightRow: View {
    let index: Int
    let binding: LightBinding
    let onChange: (LightBinding) -> Void

    var body: some View {
        HStack(spacing: 12) {
            numberBadge(index + 1)
            Picker("", selection: Binding(
                get: { binding.kind },
                set: { kind in
                    onChange(.make(kind: kind, primary: binding.primaryColor, secondary: binding.secondaryColor))
                }
            )) {
                ForEach(LightKind.allCases) { k in Text(k.displayName).tag(k) }
            }
            .labelsHidden()
            .frame(maxWidth: .infinity, alignment: .leading)

            if binding.usesPrimaryColor {
                JnColorWell(rgb: Binding(
                    get: { binding.primaryColor },
                    set: { onChange(.make(kind: binding.kind, primary: $0, secondary: binding.secondaryColor)) }
                ))
            }
            if binding.usesSecondaryColor {
                JnColorWell(rgb: Binding(
                    get: { binding.secondaryColor },
                    set: { onChange(.make(kind: binding.kind, primary: binding.primaryColor, secondary: $0)) }
                ))
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Routing

private struct RoutingSection: View {
    @ObservedObject var delegate: AppDelegate
    @ObservedObject var tapRouter: TapRouter

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if delegate.config.appRoutes.isEmpty {
                Text("No app routes — add one below to send a specific app's audio to a different output.")
                    .font(.caption)
                    .foregroundStyle(Jn.inkMute)
            } else {
                ForEach(delegate.config.appRoutes) { route in
                    RouteRow(
                        route: route,
                        state: tapRouter.states[route.bundleID],
                        onChangeDevice: { setDevice(route.bundleID, $0) },
                        onToggleMute: { tapRouter.setMuted(bundleID: route.bundleID, !(tapRouter.isMuted(bundleID: route.bundleID))) },
                        onRemove: { remove(route.bundleID) }
                    )
                }
            }
            Divider().overlay(Jn.stroke).padding(.vertical, 2)
            AddRouteRow(onAdd: add)
            Text("Green = built and audio flowing. Amber = built but quiet. Gray = waiting for app. Red = broken.")
                .font(.caption2)
                .foregroundStyle(Jn.inkFaint)
        }
    }

    private func setDevice(_ bundleID: String, _ uid: String?) {
        delegate.updateConfig { c in
            if let i = c.appRoutes.firstIndex(where: { $0.bundleID == bundleID }) {
                c.appRoutes[i].outputDeviceUID = uid
            }
        }
    }
    private func remove(_ bundleID: String) {
        delegate.updateConfig { c in c.appRoutes.removeAll { $0.bundleID == bundleID } }
    }
    private func add(_ bundleID: String) {
        delegate.updateConfig { c in
            if !c.appRoutes.contains(where: { $0.bundleID == bundleID }) {
                c.appRoutes.append(AppRoute(bundleID: bundleID, outputDeviceUID: nil))
            }
        }
    }
}

private struct RouteRow: View {
    let route: AppRoute
    let state: RouteState?
    let onChangeDevice: (String?) -> Void
    let onToggleMute: () -> Void
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            RouteStatusDot(status: state?.status, level: state?.level ?? 0, muted: state?.muted ?? false)
            Image(systemName: state?.muted == true ? "app.dashed" : "app.fill")
                .foregroundStyle(state?.muted == true ? Jn.inkMute : Jn.mint)
            Text(AppNames.short(route.bundleID))
                .frame(width: 124, alignment: .leading).lineLimit(1)
                .foregroundStyle(state?.muted == true ? Jn.inkMute : Jn.ink)
            Image(systemName: "arrow.right").foregroundStyle(Jn.inkFaint)
            OutputDevicePicker(uid: route.outputDeviceUID, onPick: onChangeDevice)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                TonePinger.shared.play(deviceUID: route.outputDeviceUID)
            } label: {
                Image(systemName: state?.muted == true ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .foregroundStyle(state?.muted == true ? Color.orange.opacity(0.75) : Jn.mint.opacity(0.85))
            }
            .buttonStyle(.borderless)
            .help("Tap: ping output. Long-press: mute/unmute.")
            .simultaneousGesture(LongPressGesture(minimumDuration: 0.45).onEnded { _ in onToggleMute() })
            Button(role: .destructive) { onRemove() } label: {
                Image(systemName: "trash").foregroundStyle(Color.red.opacity(0.7))
            }
            .buttonStyle(.borderless)
        }
    }
}

/// Small colored dot that summarizes a route's state at a glance.
///   green pulse = built and audio flowing (peak-hold RMS > 0)
///   amber       = built but silent
///   gray        = pending (target app not producing audio yet)
///   red         = broken (Core Audio rejected our tap/aggregate)
///   ringed gray = muted
private struct RouteStatusDot: View {
    let status: RouteState.Status?
    let level: Float
    let muted: Bool

    private var color: Color {
        if muted { return Color.orange.opacity(0.5) }
        switch status {
        case nil, .pending: return Color.white.opacity(0.22)
        case .broken:       return Color.red.opacity(0.78)
        case .built:        return level > 0.005 ? Jn.mint : Color.orange.opacity(0.7)
        }
    }

    private var glowing: Bool {
        if muted || status != .built { return false }
        return level > 0.005
    }

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 9, height: 9)
            .overlay(
                Circle().stroke(Color.white.opacity(muted ? 0.5 : 0.15), lineWidth: muted ? 1.2 : 0.5)
            )
            .shadow(color: color.opacity(glowing ? 0.9 : 0), radius: glowing ? 5 : 0)
            .animation(.easeOut(duration: 0.12), value: level)
            .animation(.easeOut(duration: 0.12), value: muted)
    }
}

private struct AddRouteRow: View {
    let onAdd: (String) -> Void
    @State private var selected = ""

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "plus.circle.fill").foregroundStyle(Jn.mint)
            AppPicker(bundleID: selected) { bid in
                guard !bid.isEmpty else { return }
                onAdd(bid)
                selected = ""
            }
            .frame(width: 200, alignment: .leading)
            Text("add an app to route").font(.caption).foregroundStyle(Jn.inkMute)
            Spacer()
        }
    }
}

private struct OutputDevicePicker: View {
    let uid: String?
    let onPick: (String?) -> Void

    var body: some View {
        Picker("", selection: Binding(
            get: { uid ?? "" },
            set: { onPick($0.isEmpty ? nil : $0) }
        )) {
            Text("System default").tag("")
            ForEach(devices, id: \.uid) { d in
                Text(d.name).tag(d.uid)
            }
        }
        .labelsHidden()
    }

    private var devices: [(uid: String, name: String)] { AudioDevices.outputs() }
}

// MARK: - App picker

private struct AppPicker: View {
    let bundleID: String
    let onPick: (String) -> Void

    var body: some View {
        Picker("", selection: Binding(get: { bundleID }, set: onPick)) {
            Text("Choose app…").tag("")
            ForEach(apps, id: \.self) { bid in
                Text(AppNames.short(bid)).tag(bid)
            }
            if !bundleID.isEmpty && !apps.contains(bundleID) {
                Text(AppNames.short(bundleID)).tag(bundleID)
            }
        }
        .labelsHidden()
    }

    private var apps: [String] { AudioProcesses.appBundleIDs() }
}

// MARK: - Footer

private struct ConsoleFooter: View {
    @ObservedObject var delegate: AppDelegate
    @State private var launchAtLogin = LoginItem.isEnabled
    @State private var showDiagnostics = false

    var body: some View {
        HStack(spacing: 14) {
            Toggle(isOn: Binding(
                get: { launchAtLogin },
                set: { v in launchAtLogin = v; LoginItem.setEnabled(v) }
            )) {
                Text("Launch at login")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(Jn.inkMute)
            }
            .toggleStyle(.checkbox)
            Toggle(isOn: Binding(
                get: { delegate.config.autoMuteMic },
                set: { v in delegate.updateConfig { $0.autoMuteMic = v } }
            )) {
                Text("Auto-mute mic")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(Jn.inkMute)
            }
            .toggleStyle(.checkbox)
            .help("Mute the system mic when silent; unmute on detected speech.")
            Spacer()
            footerButton("Diagnostics", system: "doc.text.magnifyingglass") {
                showDiagnostics = true
            }
            footerButton("Reset", system: "arrow.uturn.left") {
                delegate.resetConfig()
            }
            footerButton("Edit config", system: "doc.text") {
                NSWorkspace.shared.open(ConfigStore.fileURL)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .sheet(isPresented: $showDiagnostics) {
            DiagnosticsSheet(sink: DiagSink.shared)
        }
    }

    @ViewBuilder
    private func footerButton(_ title: String, system: String,
                              onTap: @escaping () -> Void) -> some View {
        Button(action: onTap) {
            HStack(spacing: 5) {
                Image(systemName: system).font(.system(size: 10, weight: .semibold))
                Text(title).font(.system(size: 11, weight: .semibold, design: .rounded))
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            .foregroundStyle(Jn.ink)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Jn.cardHi.opacity(0.5))
                    .overlay(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .stroke(Jn.stroke, lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Shared bits

private func numberBadge(_ n: Int, flashing: Bool = false) -> some View {
    Text("\(n)")
        .font(.system(size: 12, weight: .heavy, design: .rounded).monospacedDigit())
        .frame(width: 26, height: 26)
        .foregroundStyle(flashing ? .black : Jn.inkMute)
        .background(
            Circle()
                .fill(flashing ? Jn.mintGlow : Jn.cardHi.opacity(0.55))
                .overlay(Circle().stroke(flashing ? Jn.mintGlow : Jn.stroke, lineWidth: 0.5))
                .shadow(color: flashing ? Jn.mint.opacity(0.7) : .clear, radius: 6)
        )
        .animation(.easeOut(duration: 0.12), value: flashing)
}

private func inlineMeter(value: Double) -> some View {
    let v = max(0, min(1, value))
    return GeometryReader { geo in
        ZStack(alignment: .leading) {
            Capsule()
                .fill(Jn.cardHi.opacity(0.6))
                .overlay(Capsule().stroke(Jn.stroke, lineWidth: 0.5))
            Capsule()
                .fill(LinearGradient(
                    colors: [Jn.mintDim, Jn.mint, Jn.mintGlow],
                    startPoint: .leading, endPoint: .trailing
                ))
                .frame(width: max(2, geo.size.width * v))
                .shadow(color: Jn.mint.opacity(0.5), radius: 2)
        }
    }
    .frame(width: 80, height: 6)
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

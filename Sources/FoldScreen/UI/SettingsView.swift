import AppKit
import SwiftUI

/// Which pane the settings window is showing.
private enum SettingsPane: String, CaseIterable, Identifiable {
    case general
    case appearance
    case lid
    case about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "通用"
        case .appearance: return "外观"
        case .lid: return "开合"
        case .about: return "关于"
        }
    }

    /// SF Symbols is the platform's own icon set, so the sidebar matches every
    /// other settings window on the system.
    var symbol: String {
        switch self {
        case .general: return "switch.2"
        case .appearance: return "square.on.square.dashed"
        case .lid: return "laptopcomputer"
        case .about: return "info.circle"
        }
    }
}

/// The settings window.
///
/// Built on a `NavigationSplitView` with grouped forms, which is the layout
/// macOS users already know from System Settings. The unusual part of this app
/// is the effect itself, so the settings deliberately stay conventional.
struct SettingsView: View {
    @ObservedObject var store: SettingsStore
    @ObservedObject var effect: LiveFold
    @ObservedObject var preview: FoldPreview

    @State private var pane: SettingsPane = .general

    var body: some View {
        NavigationSplitView {
            List(SettingsPane.allCases, selection: $pane) { item in
                NavigationLink(value: item) {
                    Label(item.title, systemImage: item.symbol)
                }
            }
            .navigationSplitViewColumnWidth(min: 168, ideal: 176, max: 200)
            .listStyle(.sidebar)
            .safeAreaInset(edge: .bottom) {
                statusFooter
            }
        } detail: {
            ScrollView {
                detail
                    .padding(20)
                    .frame(maxWidth: 560, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .navigationTitle(pane.title)
        }
        .frame(minWidth: 720, minHeight: 560)
    }

    @ViewBuilder
    private var detail: some View {
        switch pane {
        case .general: generalPane
        case .appearance: appearancePane
        case .lid: lidPane
        case .about: aboutPane
        }
    }

    // MARK: - Footer

    /// A persistent state line, so the window always answers "is it on?" without
    /// the user having to find the right pane.
    private var statusFooter: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(effect.state.isRunning ? Color.green : Color.secondary.opacity(0.5))
                .frame(width: 7, height: 7)
            Text(effect.state.isRunning ? "效果已启用" : "效果已暂停")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: - General

    private var generalPane: some View {
        VStack(alignment: .leading, spacing: 18) {
            SectionCard("桌面效果") {
                VStack(alignment: .leading, spacing: 0) {
                    LabeledRow(
                        title: effect.state == .starting ? "正在连接…" : "启用合盖弯屏",
                        detail: "让桌面跟随翻盖角度一起弯折。"
                    ) {
                        Toggle("", isOn: Binding(
                            get: { effect.isEnabled },
                            set: { effect.setEnabled($0) }))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .disabled(effect.state == .starting)
                    }
                    Divider()
                    LabeledRow(
                        title: "登录时打开",
                        detail: "在菜单栏启动，并恢复上次的开关状态。"
                    ) {
                        Toggle("", isOn: Binding(
                            get: { effect.openAtLogin },
                            set: { effect.setOpenAtLogin($0) }))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                    }
                    Divider()
                    Text(effect.detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                }
            }

            SectionCard("屏幕录制权限") {
                VStack(alignment: .leading, spacing: 10) {
                    LabeledRow(
                        title: effect.hasScreenRecordingPermission ? "已获得权限" : "尚未获得权限",
                        detail: effect.hasScreenRecordingPermission
                            ? "系统已允许读取屏幕，效果可以正常启动。"
                            : "效果需要读取屏幕内容才能把它弯起来，请到系统设置里勾选本应用。"
                    ) {
                        Image(systemName: effect.hasScreenRecordingPermission
                            ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .font(.title3)
                            .foregroundStyle(effect.hasScreenRecordingPermission
                                ? Color.green : Color.orange)
                    }
                    Divider()
                    VStack(alignment: .leading, spacing: 10) {
                        Text(
                            "画面帧只在内存中停留一瞬，不写入磁盘、不上传，也不采集声音。"
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                        HStack(spacing: 8) {
                            Button("打开屏幕录制设置…") {
                                guard
                                    let url = URL(
                                        string:
                                            "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
                                    )
                                else { return }
                                NSWorkspace.shared.open(url)
                            }
                            Button("重新检查") {
                                effect.refreshPermissionStatus()
                                effect.recheckPermission()
                            }
                            .disabled(!effect.isEnabled)
                            Button("重新打开") {
                                effect.relaunch()
                            }
                            .help("macOS 有时要重启应用才会让新授权的权限生效。")
                        }
                        .controlSize(.regular)
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            SectionCard("使用方式") {
                VStack(alignment: .leading, spacing: 0) {
                    InfoRow(
                        symbol: "escape", title: "随时暂停",
                        detail: "效果出现时按 Escape 立刻恢复桌面。")
                    Divider()
                    InfoRow(
                        symbol: "menubar.rectangle", title: "常驻菜单栏",
                        detail: "关掉这个窗口不会退出，程序继续在菜单栏待命。")
                    Divider()
                    InfoRow(
                        symbol: "display", title: "只作用于内置屏",
                        detail: "外接显示器不受影响，睡眠与切换显示器后会自动重连。")
                }
            }
        }
    }

    // MARK: - Appearance

    private var appearancePane: some View {
        VStack(alignment: .leading, spacing: 18) {
            SectionCard("预览") {
                VStack(spacing: 14) {
                    Text("用内置画面预览折角，不需要屏幕录制权限。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    ZStack(alignment: .bottom) {
                        FoldPreviewView(preview: preview)
                            .aspectRatio(1.6, contentMode: .fit)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        Button {
                            if preview.isPlaying { preview.pause() } else { preview.play() }
                        } label: {
                            Label(
                                preview.isPlaying ? "暂停" : "播放折角",
                                systemImage: preview.isPlaying ? "pause.fill" : "play.fill")
                        }
                        .controlSize(.large)
                        .buttonStyle(.borderedProminent)
                        .padding(.bottom, 14)
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(.separator)
                    }

                    HStack(spacing: 10) {
                        Image(systemName: "laptopcomputer")
                            .foregroundStyle(.secondary)
                        Slider(value: Binding(
                            get: { preview.angle },
                            set: { preview.angle = $0; preview.scrub() }
                        ), in: 12...135)
                        .accessibilityLabel("预览翻盖角度")
                        Text("\(Int(preview.angle))°")
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 42, alignment: .trailing)
                    }
                }
                .padding(14)
            }

            SectionCard("外观") {
                VStack(alignment: .leading, spacing: 0) {
                    LabeledRow(title: "风格", detail: store.settings.preset.detail) {
                        Picker("", selection: Binding(
                            get: { store.settings.preset },
                            set: { store.settings.preset = $0 }))
                        {
                            ForEach(FoldPreset.allCases) { preset in
                                Text(preset.title).tag(preset)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .frame(width: 210)
                    }
                    Divider()
                    SliderRow(
                        title: "透视", detail: "上方两角向内收拢的程度。",
                        value: Binding(
                            get: { store.settings.perspective },
                            set: { store.settings.perspective = $0 }))
                    Divider()
                    SliderRow(
                        title: "虚化", detail: "桌面朝上方逐渐变模糊的强度。",
                        value: Binding(
                            get: { store.settings.blur },
                            set: { store.settings.blur = $0 }))
                    Divider()
                    SliderRow(
                        title: "阴影", detail: "折起两侧的暗部深度。",
                        value: Binding(
                            get: { store.settings.shade },
                            set: { store.settings.shade = $0 }))
                }
            }

            Button {
                store.reset()
            } label: {
                Label("恢复默认外观", systemImage: "arrow.uturn.backward")
            }
            .controlSize(.regular)
        }
    }

    // MARK: - Lid

    private var lidPane: some View {
        VStack(alignment: .leading, spacing: 18) {
            SectionCard("翻盖传感器") {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(effect.lidAngle == nil ? "未检测到传感器" : "传感器已连接")
                                .font(.callout.weight(.medium))
                            Text("当前翻盖角度。读不到角度时可以用下面的手动角度。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 12)
                        Text(effect.lidAngle.map { "\(Int($0))°" } ?? "—")
                            .font(.system(size: 26, weight: .light).monospacedDigit())
                    }
                    .padding(14)

                    Divider()
                    LabeledRow(title: "跟随物理翻盖", detail: "关掉后改用固定的桌面角度。") {
                        Toggle("", isOn: Binding(
                            get: { store.settings.followLid },
                            set: { store.settings.followLid = $0 }))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                    }

                    if !store.settings.followLid {
                        Divider()
                        SliderRow(
                            title: "桌面角度", detail: "启用后固定用这个角度驱动效果。",
                            range: 12...135, showsDegrees: true,
                            value: Binding(
                                get: { store.settings.manualAngle },
                                set: { store.settings.manualAngle = $0 }))
                    }
                }
            }

            SectionCard("动作与声音") {
                VStack(alignment: .leading, spacing: 0) {
                    SliderRow(
                        title: "完全展开角度",
                        detail: "高于这个角度时桌面保持原样，不弯也不糊。",
                        range: 80...135, showsDegrees: true,
                        value: Binding(
                            get: { store.settings.clearAngle },
                            set: { store.settings.clearAngle = $0 }))
                    Divider()
                    LabeledRow(title: "展开完成时轻响一声", detail: "桌面完全恢复后播一下提示音。") {
                        Toggle("", isOn: Binding(
                            get: { store.settings.sound },
                            set: { store.settings.sound = $0 }))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                    }
                }
            }

            Text("翻盖传感器的报文格式苹果没有公开，不同机型和系统版本可能读不到。读不到时用「外观」里的预览一样能看效果。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - About

    private var aboutPane: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 64, height: 64)
                VStack(alignment: .leading, spacing: 4) {
                    Text("合盖弯屏")
                        .font(.title2.weight(.semibold))
                    Text("RuiC-FoldScreen \(Self.version)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Text("合上盖子的过程里，让桌面跟着一起弯下去。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)

            SectionCard("工作原理") {
                VStack(alignment: .leading, spacing: 10) {
                    Text(
                        "翻盖角度由内置 HID 传感器读出，桌面由 ScreenCaptureKit 抓帧，再由一段 Metal 着色器按视角投影压出折角并逐层虚化。整条链路只读、不落盘。"
                    )
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            SectionCard("许可") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("MIT 许可，自由使用与修改。")
                        .font(.callout)
                    Text("折叠桌面这一主意最早的公开实现是 Bendy，本项目是一份独立的复刻实现，与 Bendy 及 Apple 均无关联。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private static var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    }
}

// MARK: - Building blocks

/// A titled group of rows, matching the grouped-card look of System Settings.
private struct SectionCard<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.callout.weight(.semibold))
                .padding(.leading, 2)
            VStack(alignment: .leading, spacing: 0) {
                content
            }
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(.separator)
            }
        }
    }
}

/// Label on the left, control on the right.
private struct LabeledRow<Control: View>: View {
    let title: String
    let detail: String
    @ViewBuilder let control: Control

    init(title: String, detail: String, @ViewBuilder control: () -> Control) {
        self.title = title
        self.detail = detail
        self.control = control()
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.callout)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            control
        }
        .padding(14)
    }
}

/// A labelled slider with a live numeric readout.
private struct SliderRow: View {
    let title: String
    let detail: String
    var range: ClosedRange<Double> = 0...1
    var showsDegrees: Bool = false
    @Binding var value: Double

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.callout)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Slider(value: $value, in: range)
                .frame(width: 150)
                .accessibilityLabel(title)
            Text(showsDegrees ? "\(Int(value))°" : "\(Int(value * 100))%")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .trailing)
        }
        .padding(14)
    }
}

/// An icon, a title, and one line of explanation. Read-only.
private struct InfoRow: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: symbol)
                .font(.body)
                .foregroundStyle(.secondary)
                .frame(width: 22, alignment: .center)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.callout)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
    }
}

import AppKit
import SwiftUI

private let windowColor = Color(red: 0.055, green: 0.077, blue: 0.069)
private let panel = Color(red: 0.085, green: 0.113, blue: 0.100)
private let foreground = Color(red: 0.95, green: 0.97, blue: 0.93)
private let muted = Color(red: 0.67, green: 0.73, blue: 0.69)
private let accent = Color(red: 0.74, green: 0.93, blue: 0.63)
private let line = Color.white.opacity(0.10)

extension LightState {
    var label: String {
        switch self {
        case .idle: "Đang rảnh"
        case .working: "Đang làm việc"
        case .waiting: "Đang chờ"
        case .success: "Hoàn tất"
        case .error: "Có lỗi"
        }
    }

    var shortLabel: String {
        switch self {
        case .idle: "Tắt đèn"
        case .working: "Làm việc"
        case .waiting: "Chờ"
        case .success: "Hoàn tất"
        case .error: "Lỗi"
        }
    }

    var symbol: String {
        switch self {
        case .idle: "power"
        case .working: "bolt"
        case .waiting: "pause"
        case .success: "checkmark"
        case .error: "exclamationmark"
        }
    }

    var tint: Color {
        switch self {
        case .idle: muted
        case .working: Color(red: 0.98, green: 0.76, blue: 0.33)
        case .waiting: Color(red: 1, green: 0.84, blue: 0.51)
        case .success: accent
        case .error: Color(red: 1, green: 0.47, blue: 0.41)
        }
    }
}

@MainActor
struct DesktopView: View {
    @ObservedObject var model: DesktopModel
    @State private var showingSetup = false
    @State private var showingDevices = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 23) {
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("LocalAgentLight")
                            .font(.system(size: 32, weight: .semibold))
                        Text("Đèn trạng thái cho Claude Code và Codex")
                            .font(.callout)
                            .foregroundStyle(muted)
                    }
                    Spacer()
                    Label("Cục bộ", systemImage: "lock.shield")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(accent)
                        .padding(.horizontal, 13)
                        .padding(.vertical, 8)
                        .background(accent.opacity(0.08), in: Capsule())
                        .overlay { Capsule().strokeBorder(accent.opacity(0.18)) }
                }

                HStack(alignment: .top, spacing: 18) {
                    StatusPanel(state: model.state, source: model.source, confirmation: model.confirmation, mode: model.mode)
                        .frame(maxWidth: .infinity)
                    VStack(alignment: .leading, spacing: 15) {
                        Label("Thiết bị", systemImage: "lightbulb")
                            .font(.headline)
                        Text(deviceName)
                            .font(.title2.weight(.semibold))
                        Label(model.connected ? "Đã kết nối" : "Chưa kết nối",
                              systemImage: model.connected ? "checkmark.circle.fill" : "circle.dashed")
                            .font(.callout.weight(.medium))
                            .foregroundStyle(model.connected ? accent : muted)
                        Text(model.connectionMessage)
                            .font(.callout)
                            .foregroundStyle(muted)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                        Divider().overlay(line)
                        Toggle("Tắt tiếng báo", systemImage: "speaker.slash", isOn: $model.silent)
                            .toggleStyle(.switch)
                            .tint(accent)
                            .font(.callout)
                        HStack {
                            Button("Đổi thiết bị…") { showingDevices = true }
                            if !model.running && !model.switching {
                                Button("Thử lại", action: model.retry)
                            }
                        }
                    }
                    .padding(21)
                    .frame(width: 270, height: 291, alignment: .topLeading)
                    .background(panel, in: RoundedRectangle(cornerRadius: 20))
                    .overlay { RoundedRectangle(cornerRadius: 20).strokeBorder(line) }
                }

                VStack(alignment: .leading, spacing: 12) {
                    Text("Thử trạng thái").font(.headline)
                    HStack(spacing: 9) {
                        ForEach([LightState.working, .waiting, .success, .error, .idle], id: \.rawValue) { state in
                            Button { model.preview(state) } label: {
                                Label(state.shortLabel, systemImage: state.symbol)
                                    .font(.callout.weight(.medium))
                                    .frame(maxWidth: .infinity, minHeight: 35)
                            }
                            .buttonStyle(PreviewButtonStyle(selected: model.state == state, tint: state.tint))
                            .disabled(!model.running || model.switching)
                        }
                    }
                }

                Divider().overlay(line)
                HStack {
                    Label(model.running ? "Đang nhận hook cục bộ" : "Chưa nhận hook", systemImage: model.running ? "waveform.path" : "pause.circle")
                        .font(.callout)
                        .foregroundStyle(muted)
                    Spacer()
                    Button { showingSetup = true } label: {
                        Label("Thiết lập hook", systemImage: "terminal")
                    }
                    .controlSize(.large)
                }
            }
            .padding(.horizontal, 28)
            .padding(.top, 32)
            .padding(.bottom, 24)
        }
        .background(windowColor.ignoresSafeArea())
        .foregroundStyle(foreground)
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showingSetup) { HookSetupView() }
        .sheet(isPresented: $showingDevices, onDismiss: model.finishScan) { DevicePickerView(model: model) }
    }

    private var deviceName: String {
        switch model.mode {
        case .promLight: "PromLight"
        case .ble: "AgentCore-Light"
        case .preview: "Mô phỏng"
        }
    }
}

private struct PreviewButtonStyle: ButtonStyle {
    let selected: Bool
    let tint: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(selected ? tint : foreground)
            .background(selected ? tint.opacity(0.13) : panel, in: RoundedRectangle(cornerRadius: 9))
            .overlay { RoundedRectangle(cornerRadius: 9).strokeBorder(selected ? tint.opacity(0.52) : line) }
            .opacity(configuration.isPressed ? 0.65 : 1)
    }
}

private struct StatusPanel: View {
    let state: LightState
    let source: String
    let confirmation: String
    let mode: LightMode

    var body: some View {
        HStack(spacing: 15) {
            VStack(alignment: .leading, spacing: 12) {
                Label("Trạng thái hiện tại", systemImage: "waveform.path")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(muted)
                Text(state.label)
                    .font(.system(size: 37, weight: .semibold))
                    .foregroundStyle(foreground)
                    .minimumScaleFactor(0.75)
                    .lineLimit(2)
                    .accessibilityAddTraits(.isHeader)
                Text(source).font(.callout).foregroundStyle(muted)
                Spacer(minLength: 10)
                if !confirmation.isEmpty {
                    Label(confirmation, systemImage: "checkmark.circle")
                        .font(.callout)
                        .foregroundStyle(accent)
                }
            }
            .padding(.vertical, 25)
            .frame(maxWidth: .infinity, alignment: .leading)
            LightIllustration(state: state, mode: mode)
                .frame(width: 135, height: 221)
                .accessibilityHidden(true)
        }
        .padding(.leading, 24)
        .padding(.trailing, 16)
        .frame(height: 291)
        .background {
            RoundedRectangle(cornerRadius: 20)
                .fill(RadialGradient(colors: [state.tint.opacity(0.19), panel], center: .trailing, startRadius: 1, endRadius: 345))
        }
        .overlay { RoundedRectangle(cornerRadius: 20).strokeBorder(line) }
    }
}

private struct LightIllustration: View {
    let state: LightState
    let mode: LightMode

    var body: some View {
        ZStack {
            Circle().strokeBorder(Color.white.opacity(0.08)).frame(width: 128)
            Circle().strokeBorder(Color.white.opacity(0.06)).frame(width: 112)
            VStack(spacing: 9) {
                lamp(.error, active: state == .error, tint: LightState.error.tint)
                lamp(.waiting, active: state == .working || state == .waiting, tint: middleTint)
                lamp(.success, active: state == .success, tint: accent)
            }
            .padding(11)
            .background(windowColor, in: RoundedRectangle(cornerRadius: 28))
            .overlay { RoundedRectangle(cornerRadius: 28).strokeBorder(Color.white.opacity(0.16)) }
            .shadow(color: .black.opacity(0.4), radius: 18, x: 4, y: 10)
        }
    }

    private var middleTint: Color {
        if case .ble = mode, state == .working { return .blue }
        return LightState.working.tint
    }

    private func lamp(_ marker: LightState, active: Bool, tint: Color) -> some View {
        Circle()
            .fill(RadialGradient(colors: active ? [tint, tint.opacity(0.65)] : [panel, windowColor],
                                 center: .topLeading, startRadius: 2, endRadius: 42))
            .overlay { Circle().strokeBorder(active ? tint : line) }
            .shadow(color: active ? tint.opacity(0.42) : .clear, radius: 11)
            .overlay {
                if active {
                    Image(systemName: state == .working ? state.symbol : marker.symbol)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(windowColor)
                }
            }
            .frame(width: 39, height: 39)
    }
}

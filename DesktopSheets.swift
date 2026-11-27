import AppKit
import SwiftUI

@MainActor
struct DevicePickerView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: DesktopModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Thiết bị Bluetooth")
                .font(.title2.bold())
            Button {
                model.begin(.promLight)
                dismiss()
            } label: {
                Label("Dùng PromLight", systemImage: "lightbulb")
            }
            .buttonStyle(.borderedProminent)
            Text("Kết nối PromLight trong phần Bluetooth của macOS trước.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Divider()
            HStack {
                Text("AgentCore-Light V0.4").font(.headline)
                Spacer()
                if model.scanning { ProgressView().controlSize(.small) }
                Button("Quét Bluetooth", action: model.scan).disabled(model.scanning)
            }
            if !model.devices.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(model.devices, id: \.self) { id in
                            Button {
                                model.begin(.ble(id))
                                dismiss()
                            } label: {
                                Label(id.uuidString, systemImage: "lightbulb")
                                    .font(.system(.callout, design: .monospaced))
                            }
                        }
                    }
                }
                .frame(maxHeight: 115)
            }
            HStack {
                Button("Mô phỏng") {
                    model.begin(.preview)
                    dismiss()
                }
                Spacer()
                Button("Xong") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(24)
        .frame(width: 460)
    }
}

@MainActor
struct HookSetupView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var agent = Agent.claude
    @State private var copiedAgent: Agent?
    private var path: String {
        agent == .claude ? "~/.claude/settings.json" : "~/.codex/hooks.json"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            Text("Thiết lập hook")
                .font(.title2.bold())
            Picker("Công cụ", selection: $agent) {
                Text("Claude Code").tag(Agent.claude)
                Text("Codex").tag(Agent.codex)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Text("Gộp mẫu vào \(path). Nếu đã có hook cho cùng sự kiện, thêm nhóm mới vào mảng hiện có.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if agent == .codex {
                Text("Nếu Codex yêu cầu xác nhận, mở Settings → Hooks để duyệt lệnh.")
                    .foregroundStyle(.secondary)
            }
            ScrollView {
                Text(template)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
            }
            .frame(height: 182)
            .background(.black.opacity(0.22), in: RoundedRectangle(cornerRadius: 10))
            HStack {
                Button("Mở thư mục cấu hình", action: openConfiguration)
                Spacer()
                Button("Xong") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(copiedAgent == agent ? "Đã sao chép" : "Sao chép JSON", action: copyTemplate)
                    .buttonStyle(.borderedProminent)
                    .disabled(template.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 540)
    }

    private var template: String { (try? hookTemplate(agent)) ?? "" }

    private func openConfiguration() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let folder = home.appendingPathComponent(agent == .claude ? ".claude" : ".codex", isDirectory: true)
        NSWorkspace.shared.open(FileManager.default.fileExists(atPath: folder.path) ? folder : home)
    }

    private func copyTemplate() {
        NSPasteboard.general.clearContents()
        copiedAgent = NSPasteboard.general.setString(template, forType: .string) ? agent : nil
    }
}

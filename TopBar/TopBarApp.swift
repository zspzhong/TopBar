//
//  TopBarApp.swift
//  TopBar
//
//  Created by ER on 2026/3/20.
//

import SwiftUI
import ServiceManagement

@main
struct TopBarApp: App {
    @StateObject private var monitor = SystemMonitor()
    @State private var launchAtLogin: Bool = (SMAppService.mainApp.status == .enabled)

    @AppStorage("showCPU")     private var showCPU     = true
    @AppStorage("showMemory")  private var showMemory  = true
    @AppStorage("showNetwork") private var showNetwork = true

    var body: some Scene {
        MenuBarExtra {
            // ── 详情（始终显示完整信息）──────────────────────
            Section("系统状态") {
                Text("CPU：\(Int(monitor.cpuUsage * 100))%")
                Text("内存：\(String(format: "%.1f", monitor.usedMemoryGB)) / \(String(format: "%.0f", monitor.totalMemoryGB)) GB  压力：\(Int(monitor.memoryPressure * 100))%")
                Text("网络：↑ \(speedString(monitor.uploadSpeed))  ↓ \(speedString(monitor.downloadSpeed))")
            }

            // ── 显示设置 ─────────────────────────────────────
            Section("显示设置") {
                Toggle("CPU 占用率", isOn: $showCPU)
                Toggle("内存用量",   isOn: $showMemory)
                Toggle("网速",       isOn: $showNetwork)
            }

            Divider()

            Toggle("开机自启动", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) {
                    do {
                        if launchAtLogin {
                            try SMAppService.mainApp.register()
                        } else {
                            try SMAppService.mainApp.unregister()
                        }
                    } catch {
                        launchAtLogin = (SMAppService.mainApp.status == .enabled)
                    }
                }

            Divider()

            // ── 关于子菜单 ────────────────────────────────────
            Menu("关于") {
                Text("v\(AppConfig.currentVersion)")
                    .disabled(true)
                Divider()
                Button("Check for Updates...") {
                    UpdateManager.shared.checkForUpdates()
                }
                Button("View on GitHub") {
                    NSWorkspace.shared.open(URL(string: AppConfig.githubRepo)!)
                }
            }

            Divider()

            Button("打开活动监视器") {
                NSWorkspace.shared.open(
                    URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app")
                )
            }
            Button("退出 TopBar") {
                NSApplication.shared.terminate(nil)
            }
        } label: {
            menuLabelView
        }
    }

    // MARK: - Label

    @ViewBuilder
    private var menuLabelView: some View {
        let parts = labelParts
        if parts.isEmpty {
            Image(systemName: "cpu")
        } else {
            Text(parts.joined(separator: " | "))
                .font(.system(size: 12).monospacedDigit())
                .foregroundColor(cpuColor)
        }
    }

    private var labelParts: [String] {
        var parts: [String] = []
        if showCPU     { parts.append("C:\(Int(monitor.cpuUsage * 100))%") }
        if showMemory  { parts.append("\(String(format: "%.1f", monitor.usedMemoryGB))GB") }
        if showNetwork { parts.append("↓\(speedString(monitor.downloadSpeed))") }
        return parts
    }

    // MARK: - Helpers

    private var cpuColor: Color {
        switch monitor.cpuUsage {
        case 0.9...: return .red
        case 0.7...: return .orange
        default:     return .primary
        }
    }

    private func speedString(_ kbs: Double) -> String {
        kbs >= 1024
            ? String(format: "%.1fMB/s", kbs / 1024)
            : String(format: "%.1fKB/s", kbs)
    }
}

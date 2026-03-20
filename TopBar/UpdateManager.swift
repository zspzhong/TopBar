//
//  UpdateManager.swift
//  TopBar
//

import Foundation
import AppKit

@MainActor
class UpdateManager {
    static let shared = UpdateManager()
    private init() {}

    func checkForUpdates() {
        Task {
            do {
                let latest = try await fetchLatestVersion()
                if isNewer(latest, than: AppConfig.currentVersion) {
                    showUpdateAlert(newVersion: latest)
                } else {
                    showNoUpdateAlert()
                }
            } catch {
                showErrorAlert(error)
            }
        }
    }

    // MARK: - Private

    private func fetchLatestVersion() async throws -> String {
        guard let url = URL(string: AppConfig.githubAPI) else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        let (data, _) = try await URLSession.shared.data(for: request)
        let json = try JSONDecoder().decode(GitHubRelease.self, from: data)
        // tag_name 通常为 "v1.2.3"，去掉前缀 v
        return json.tagName.trimmingCharacters(in: .init(charactersIn: "v"))
    }

    /// 简单语义版本比较：latest > current
    private func isNewer(_ latest: String, than current: String) -> Bool {
        let l = latest.split(separator: ".").compactMap { Int($0) }
        let c = current.split(separator: ".").compactMap { Int($0) }
        let count = max(l.count, c.count)
        for i in 0..<count {
            let lv = i < l.count ? l[i] : 0
            let cv = i < c.count ? c[i] : 0
            if lv != cv { return lv > cv }
        }
        return false
    }

    private func showUpdateAlert(newVersion: String) {
        let alert = NSAlert()
        alert.messageText = "发现新版本 v\(newVersion)"
        alert.informativeText = "当前版本：v\(AppConfig.currentVersion)\n是否前往 GitHub 下载最新版本？"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "前往下载")
        alert.addButton(withTitle: "稍后再说")
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(URL(string: AppConfig.githubReleases)!)
        }
    }

    private func showNoUpdateAlert() {
        let alert = NSAlert()
        alert.messageText = "已是最新版本"
        alert.informativeText = "当前版本 v\(AppConfig.currentVersion) 已是最新。"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "好")
        alert.runModal()
    }

    private func showErrorAlert(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "检查更新失败"
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.addButton(withTitle: "好")
        alert.runModal()
    }
}

// MARK: - GitHub API Model

private struct GitHubRelease: Decodable {
    let tagName: String
    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
    }
}

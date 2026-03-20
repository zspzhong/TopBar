//
//  AppConfig.swift
//  TopBar
//

import Foundation

enum AppConfig {
    static let repoOwner = "zspzhong"
    static let repoName  = "TopBar"

    static let githubRepo     = "https://github.com/\(repoOwner)/\(repoName)"
    static let githubReleases = "\(githubRepo)/releases"
    static let githubAPI      = "https://api.github.com/repos/\(repoOwner)/\(repoName)/releases/latest"

    static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }
}

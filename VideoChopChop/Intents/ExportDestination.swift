//
//  ExportDestination.swift
//  VideoChopChop
//

import Foundation

/// The folder exports go into, remembered as a security-scoped bookmark. A sandboxed app only keeps access to a
/// folder it was given through an open panel, so this is how a Siri / Shortcuts export (which can't show a panel)
/// reaches the folder you last chose in the app.
nonisolated enum ExportDestination {
    private static let key = "exportDestinationBookmark"

    static func remember(_ url: URL, defaults: UserDefaults = .standard) {
        guard let data = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
        else { return }
        defaults.set(data, forKey: key)
    }

    /// The remembered folder, or nil if none was chosen yet or it has since been deleted.
    static func resolve(defaults: UserDefaults = .standard) -> URL? {
        guard let data = defaults.data(forKey: key) else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale)
        else { return nil }
        if stale { remember(url, defaults: defaults) }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else { return nil }
        return url
    }
}

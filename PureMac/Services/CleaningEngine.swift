import Foundation

actor CleaningEngine {
    private let fileManager = FileManager.default
    private let dotNetProjectExtensions = Set(["csproj", "fsproj", "vbproj", "shproj", "vcxproj"])
    private let visualStudioArtifactDirectoryNames = Set(["bin", "obj"])

    struct CleaningResult {
        var freedSpace: Int64 = 0
        var itemsCleaned: Int = 0
        var errors: [String] = []
    }

    // MARK: - Public API

    func cleanItems(_ items: [CleanableItem], progressHandler: @Sendable (Double) -> Void) async -> CleaningResult {
        var result = CleaningResult()
        let total = items.count

        for (index, item) in items.enumerated() {
            let progress = Double(index + 1) / Double(total)
            progressHandler(progress)

            if item.category == .purgeableSpace {
                let purged = await cleanPurgeableItem(item)
                result.freedSpace += purged
                if purged > 0 { result.itemsCleaned += 1 }
                continue
            }

            do {
                let itemURL = URL(fileURLWithPath: item.path)
                guard fileManager.fileExists(atPath: item.path) else { continue }

                // Security: resolve symlinks and validate the real path
                let resolved = itemURL.resolvingSymlinksInPath().path
                guard isSafeToDelete(item: item, resolvedPath: resolved) else {
                    let msg = "Skipped symlink or unsafe path: \(item.path) -> \(resolved)"
                    Logger.shared.log(msg, level: .warning)
                    result.errors.append(msg)
                    continue
                }

                try fileManager.removeItem(atPath: item.path)
                result.freedSpace += item.size
                result.itemsCleaned += 1
            } catch {
                result.errors.append("\(item.name): \(error.localizedDescription)")
            }
        }

        return result
    }

    func cleanCategory(_ result: CategoryResult, progressHandler: @Sendable (Double) -> Void) async -> CleaningResult {
        let selectedItems = result.items.filter { $0.isSelected }
        return await cleanItems(selectedItems, progressHandler: progressHandler)
    }

    // MARK: - Purgeable Space

    func purgePurgeableSpace() async -> Int64 {
        // Get current purgeable space first
        let beforeFree = getCurrentFreeSpace()

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        task.arguments = ["apfs", "purgePurgeable", "/"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()

        do {
            try task.run()
            task.waitUntilExit()

            let afterFree = getCurrentFreeSpace()
            let freedSpace = afterFree - beforeFree
            return max(0, freedSpace)
        } catch {
            Logger.shared.log("diskutil purge failed: \(error.localizedDescription)", level: .error)
            return 0
        }
    }

    private func cleanPurgeableItem(_ item: CleanableItem) async -> Int64 {
        if item.path == "/" {
            return await purgePurgeableSpace()
        }

        guard let snapshotDate = snapshotDate(from: item.path) ?? snapshotDate(from: item.name) else {
            return await purgePurgeableSpace()
        }

        return await deleteLocalSnapshot(snapshotDate: snapshotDate)
    }

    private func deleteLocalSnapshot(snapshotDate: String) async -> Int64 {
        let beforeFree = getCurrentFreeSpace()

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/tmutil")
        task.arguments = ["deletelocalsnapshots", snapshotDate]
        task.standardOutput = Pipe()
        task.standardError = Pipe()

        do {
            try task.run()
            task.waitUntilExit()
            let afterFree = getCurrentFreeSpace()
            return max(0, afterFree - beforeFree)
        } catch {
            Logger.shared.log("tmutil deletelocalsnapshots failed: \(error.localizedDescription)", level: .error)
            return 0
        }
    }

    // MARK: - Trash

    func emptyTrash() async -> Int64 {
        let home = fileManager.homeDirectoryForCurrentUser.path
        let trashPath = "\(home)/.Trash"
        var totalFreed: Int64 = 0

        do {
            let contents = try fileManager.contentsOfDirectory(atPath: trashPath)
            for item in contents {
                let fullPath = (trashPath as NSString).appendingPathComponent(item)
                if let attrs = try? fileManager.attributesOfItem(atPath: fullPath) {
                    totalFreed += (attrs[.size] as? Int64) ?? 0
                }
                try fileManager.removeItem(atPath: fullPath)
            }
        } catch {
            Logger.shared.log("Trash cleanup incomplete: \(error.localizedDescription)", level: .warning)
        }

        return totalFreed
    }

    // MARK: - Helpers

    /// Validates that a resolved path is safe to delete.
    /// Prevents symlink attacks where a link in ~/Library/Caches points to ~/.ssh or ~/Documents.
    private func isSafeToDelete(item: CleanableItem, resolvedPath: String) -> Bool {
        let home = fileManager.homeDirectoryForCurrentUser.path
        let normalizedPath = (resolvedPath as NSString).standardizingPath

        if item.category == .systemData {
            return isSafeSystemDataTarget(path: normalizedPath)
        }

        let allowedRoots = [
            "\(home)/Library/Caches",
            "\(home)/Library/Logs",
            "\(home)/Library/Saved Application State",
            "\(home)/Library/HTTPStorages",
            "\(home)/Library/WebKit",
            "\(home)/Library/Containers",
            "\(home)/Library/Group Containers",
            "\(home)/Library/Application Support",
            "\(home)/Library/Preferences",
            "\(home)/Library/LaunchAgents",
            "\(home)/Library/Mail Downloads",
            "\(home)/.Trash",
            "\(home)/Downloads",
            "\(home)/Documents",
            "\(home)/Desktop",
            "/Library/Caches",
            "/Library/Logs",
            "/private/var/log",
            "/private/var/tmp",
            "/tmp",
        ]
        if allowedRoots.contains(where: { root in
            normalizedPath.hasPrefix(root)
        }) {
            return true
        }

        return isVisualStudioBuildArtifact(path: normalizedPath)
    }

    private func isSafeSystemDataTarget(path: String) -> Bool {
        let home = fileManager.homeDirectoryForCurrentUser.path
        let backupRoot = "\(home)/Library/Application Support/MobileSync/Backup/"
        let updateRoots = [
            "\(home)/Library/iTunes/iPhone Software Updates",
            "\(home)/Library/iTunes/iPad Software Updates",
            "\(home)/Library/iTunes/iPod Software Updates",
        ]

        if path.hasPrefix(backupRoot) {
            return true
        }

        if updateRoots.contains(where: { path == $0 || path.hasPrefix("\($0)/") }) {
            return true
        }

        let url = URL(fileURLWithPath: path)
        let appName = url.lastPathComponent
        let parent = url.deletingLastPathComponent().path
        let installerParents = ["/Applications", "\(home)/Applications"]
        return installerParents.contains(parent)
            && appName.hasPrefix("Install macOS ")
            && appName.hasSuffix(".app")
    }

    private func snapshotDate(from value: String) -> String? {
        let pattern = #"\d{4}-\d{2}-\d{2}-\d{6}"#
        guard let range = value.range(of: pattern, options: .regularExpression) else { return nil }
        return String(value[range])
    }

    private func isVisualStudioBuildArtifact(path: String) -> Bool {
        let home = fileManager.homeDirectoryForCurrentUser.path
        guard path.hasPrefix("\(home)/") else { return false }

        let artifactURL = URL(fileURLWithPath: path)
        let artifactName = artifactURL.lastPathComponent.lowercased()
        guard visualStudioArtifactDirectoryNames.contains(artifactName) else { return false }

        let projectDirectory = artifactURL.deletingLastPathComponent().path
        return directoryContainsDotNetProject(at: projectDirectory)
    }

    private func directoryContainsDotNetProject(at path: String) -> Bool {
        guard let contents = try? fileManager.contentsOfDirectory(atPath: path) else { return false }

        return contents.contains { item in
            let itemExtension = URL(fileURLWithPath: item).pathExtension.lowercased()
            return dotNetProjectExtensions.contains(itemExtension)
        }
    }

    private func getCurrentFreeSpace() -> Int64 {
        do {
            let attrs = try fileManager.attributesOfFileSystem(forPath: "/")
            return (attrs[.systemFreeSize] as? Int64) ?? 0
        } catch {
            Logger.shared.log("Cannot read filesystem attributes: \(error.localizedDescription)", level: .warning)
            return 0
        }
    }
}

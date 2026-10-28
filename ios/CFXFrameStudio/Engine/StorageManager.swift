import Foundation
import Photos

struct StorageBreakdown {
    var documentsBytes: Int64 = 0
    var documentsCount: Int = 0
    var tempBytes: Int64 = 0
    var tempCount: Int = 0
    var cacheBytes: Int64 = 0
    var trackedPhotosCount: Int = 0

    var totalBytes: Int64 {
        documentsBytes + tempBytes + cacheBytes
    }
}

/// Centralized manager for measuring, tracking, and purging storage used by CFX FrameStudio
final class StorageManager: ObservableObject {
    static let shared = StorageManager()

    @Published var breakdown: StorageBreakdown = StorageBreakdown()
    @Published var isClearing: Bool = false
    @Published var lastReclaimedMessage: String? = nil

    private let trackedAssetsKey = "cfx_saved_asset_ids"

    private init() {
        refreshStorage()
    }

    // MARK: - Asset Tracking (Camera Roll)

    func trackSavedAsset(localIdentifier: String) {
        var ids = getTrackedAssetIdentifiers()
        if !ids.contains(localIdentifier) {
            ids.append(localIdentifier)
            UserDefaults.standard.set(ids, forKey: trackedAssetsKey)
        }
        refreshStorage()
    }

    func getTrackedAssetIdentifiers() -> [String] {
        return UserDefaults.standard.stringArray(forKey: trackedAssetsKey) ?? []
    }

    func clearTrackedAssetIdentifiers() {
        UserDefaults.standard.removeObject(forKey: trackedAssetsKey)
        refreshStorage()
    }

    // MARK: - Storage Measurement

    func refreshStorage() {
        Task.detached(priority: .userInitiated) {
            let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            let temp = FileManager.default.temporaryDirectory
            let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!

            let docsInfo = self.calculateDirectorySize(url: docs)
            let tempInfo = self.calculateDirectorySize(url: temp)
            let cacheInfo = self.calculateDirectorySize(url: caches)
            let photoIds = self.getTrackedAssetIdentifiers()

            await MainActor.run {
                self.breakdown = StorageBreakdown(
                    documentsBytes: docsInfo.bytes,
                    documentsCount: docsInfo.count,
                    tempBytes: tempInfo.bytes,
                    tempCount: tempInfo.count,
                    cacheBytes: cacheInfo.bytes,
                    trackedPhotosCount: photoIds.count
                )
            }
        }
    }

    // MARK: - Storage Cleanup Operations

    /// Clears temporary staging, MKV remux cache, URL network caches, AND all downloaded files in Documents.
    func clearAllCacheAndDownloads() async -> Int64 {
        await MainActor.run { self.isClearing = true }
        let temp = FileManager.default.temporaryDirectory
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!

        let t = deleteContents(of: temp)
        let c = deleteContents(of: caches)
        let d = deleteContents(of: docs)
        URLCache.shared.removeAllCachedResponses()

        let total = t + c + d
        refreshStorage()
        await MainActor.run {
            self.isClearing = false
            self.lastReclaimedMessage = "Cleared \(self.formatBytes(total)) — all downloaded files & caches deleted!"
        }
        return total
    }

    /// Clears temporary staging, MKV remux cache, and downloaded files.
    func clearTempAndCaches() async -> Int64 {
        return await clearAllCacheAndDownloads()
    }

    /// Clears all files in Documents (On My iPhone > CFX Studio).
    func clearDownloadedFiles() async -> Int64 {
        await MainActor.run { self.isClearing = true }
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let reclaimed = deleteContents(of: docs)

        refreshStorage()
        await MainActor.run {
            self.isClearing = false
            self.lastReclaimedMessage = "Deleted all files from Documents (\(self.formatBytes(reclaimed)) reclaimed)!"
        }
        return reclaimed
    }

    /// Deletes media saved to Photos by CFX FrameStudio.
    func deleteAppMediaFromPhotos() async -> Int {
        await MainActor.run { self.isClearing = true }
        let ids = getTrackedAssetIdentifiers()
        guard !ids.isEmpty else {
            await MainActor.run {
                self.isClearing = false
                self.lastReclaimedMessage = "No tracked media found in Photos library."
            }
            return 0
        }

        let assets = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
        guard assets.count > 0 else {
            clearTrackedAssetIdentifiers()
            await MainActor.run {
                self.isClearing = false
                self.lastReclaimedMessage = "Photos were already removed from Camera Roll."
            }
            return 0
        }

        var deletedCount = 0
        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.deleteAssets(assets)
            }
            deletedCount = assets.count
            clearTrackedAssetIdentifiers()
        } catch {
            print("Failed to delete photos: \(error)")
        }

        refreshStorage()
        let count = deletedCount
        await MainActor.run {
            self.isClearing = false
            if count > 0 {
                self.lastReclaimedMessage = "Successfully removed \(count) items from Camera Roll!"
            }
        }
        return deletedCount
    }

    /// Master deep clean: Purges temporary cache, app caches, downloaded files, and Photos media.
    func masterWipeStorage(includePhotos: Bool) async -> (reclaimedBytes: Int64, deletedPhotos: Int) {
        await MainActor.run { self.isClearing = true }
        let temp = FileManager.default.temporaryDirectory
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!

        let t = deleteContents(of: temp)
        let c = deleteContents(of: caches)
        let d = deleteContents(of: docs)
        URLCache.shared.removeAllCachedResponses()

        var photosCount = 0
        if includePhotos {
            let ids = getTrackedAssetIdentifiers()
            if !ids.isEmpty {
                let assets = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
                if assets.count > 0 {
                    try? await PHPhotoLibrary.shared().performChanges {
                        PHAssetChangeRequest.deleteAssets(assets)
                    }
                    photosCount = assets.count
                }
                clearTrackedAssetIdentifiers()
            }
        }

        let totalBytes = t + c + d
        refreshStorage()
        let count = photosCount
        await MainActor.run {
            self.isClearing = false
            if count > 0 {
                self.lastReclaimedMessage = "Storage Wiped: \(self.formatBytes(totalBytes)) reclaimed + \(count) items removed from Photos!"
            } else {
                self.lastReclaimedMessage = "Storage Wiped: \(self.formatBytes(totalBytes)) reclaimed!"
            }
        }
        return (totalBytes, photosCount)
    }

    // MARK: - Directory Helpers

    private func calculateDirectorySize(url: URL) -> (bytes: Int64, count: Int) {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey], options: [.skipsHiddenFiles]) else {
            return (0, 0)
        }
        var totalBytes: Int64 = 0
        var count = 0
        for case let fileUrl as URL in enumerator {
            guard let values = try? fileUrl.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                  values.isRegularFile == true,
                  let size = values.fileSize else { continue }
            totalBytes += Int64(size)
            count += 1
        }
        return (totalBytes, count)
    }

    private func deleteContents(of url: URL) -> Int64 {
        let fm = FileManager.default
        let (bytes, _) = calculateDirectorySize(url: url)
        guard let items = try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: []) else {
            return 0
        }
        for item in items {
            try? fm.removeItem(at: item)
        }
        return bytes
    }

    func formatBytes(_ bytes: Int64) -> String {
        guard bytes > 0 else { return "0 B" }
        let mb = Double(bytes) / (1024.0 * 1024.0)
        if mb >= 1024.0 {
            return String(format: "%.2f GB", mb / 1024.0)
        } else if mb >= 1.0 {
            return String(format: "%.1f MB", mb)
        } else {
            return String(format: "%.0f KB", Double(bytes) / 1024.0)
        }
    }
}

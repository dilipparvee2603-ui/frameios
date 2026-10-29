import Foundation
import UIKit

// MARK: - Project Storage & Sandbox Manager
final class ProjectStorageManager {
    static let shared = ProjectStorageManager()

    private let fileManager = FileManager.default

    private var projectsDirectory: URL {
        let docs = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
        let dir = docs.appendingPathComponent("Projects", isDirectory: true)
        if !fileManager.fileExists(atPath: dir.path) {
            try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    private init() {}

    // MARK: - Directory for Specific Project
    func projectDirectory(for projectId: UUID) -> URL {
        let dir = projectsDirectory.appendingPathComponent(projectId.uuidString, isDirectory: true)
        if !fileManager.fileExists(atPath: dir.path) {
            try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    func mediaDirectory(for projectId: UUID) -> URL {
        let dir = projectDirectory(for: projectId).appendingPathComponent("Media", isDirectory: true)
        if !fileManager.fileExists(atPath: dir.path) {
            try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    // MARK: - Safe Media Ingestion
    /// Copies imported video into the project's sandbox Media folder so it is immune to /tmp clearing
    func importMedia(from sourceUrl: URL, to projectId: UUID) -> URL {
        let mediaDir = mediaDirectory(for: projectId)
        let ext = sourceUrl.pathExtension.isEmpty ? "mp4" : sourceUrl.pathExtension
        let uniqueName = "clip_\(UUID().uuidString.prefix(8)).\(ext)"
        let destinationUrl = mediaDir.appendingPathComponent(uniqueName)

        do {
            if fileManager.fileExists(atPath: destinationUrl.path) {
                try? fileManager.removeItem(at: destinationUrl)
            }
            try fileManager.copyItem(at: sourceUrl, to: destinationUrl)
            return destinationUrl
        } catch {
            return sourceUrl
        }
    }

    // MARK: - Save Project
    func saveProject(_ project: VideoProject) {
        let dir = projectDirectory(for: project.id)
        let fileUrl = dir.appendingPathComponent("project.json")

        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        encoder.dateEncodingStrategy = .iso8601

        do {
            let data = try encoder.encode(project)
            try data.write(to: fileUrl, options: .atomic)
        } catch {
            print("ProjectStorageManager: Failed to save project \(project.id): \(error)")
        }
    }

    // MARK: - Load Project
    func loadProject(id: UUID) -> VideoProject? {
        let fileUrl = projectDirectory(for: id).appendingPathComponent("project.json")
        guard fileManager.fileExists(atPath: fileUrl.path) else { return nil }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        do {
            let data = try Data(contentsOf: fileUrl)
            return try decoder.decode(VideoProject.self, from: data)
        } catch {
            print("ProjectStorageManager: Failed to load project \(id): \(error)")
            return nil
        }
    }

    // MARK: - List All Projects
    func listProjects() -> [VideoProject] {
        guard let subdirs = try? fileManager.contentsOfDirectory(at: projectsDirectory, includingPropertiesForKeys: [.contentModificationDateKey]) else {
            return []
        }

        var results: [VideoProject] = []
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        for dir in subdirs {
            let projectFile = dir.appendingPathComponent("project.json")
            if fileManager.fileExists(atPath: projectFile.path),
               let data = try? Data(contentsOf: projectFile),
               let project = try? decoder.decode(VideoProject.self, from: data) {
                results.append(project)
            }
        }

        return results.sorted { $0.updatedAt > $1.updatedAt }
    }

    // MARK: - Duplicate Project
    func duplicateProject(_ project: VideoProject) -> VideoProject {
        var copy = project
        copy.id = UUID()
        copy.title = "\(project.title) Copy"
        copy.createdAt = Date()
        copy.updatedAt = Date()

        // Copy media files to new project folder
        let oldMediaDir = mediaDirectory(for: project.id)
        let newMediaDir = mediaDirectory(for: copy.id)

        if let items = try? fileManager.contentsOfDirectory(at: oldMediaDir, includingPropertiesForKeys: nil) {
            for item in items {
                let dest = newMediaDir.appendingPathComponent(item.lastPathComponent)
                try? fileManager.copyItem(at: item, to: dest)
            }
        }

        // Update clip URLs to point to new media directory
        for i in 0..<copy.clips.count {
            let filename = copy.clips[i].sourceUrl.lastPathComponent
            let newUrl = newMediaDir.appendingPathComponent(filename)
            if fileManager.fileExists(atPath: newUrl.path) {
                copy.clips[i].sourceUrl = newUrl
            }
        }

        saveProject(copy)
        return copy
    }

    // MARK: - Delete Project
    func deleteProject(id: UUID) {
        let dir = projectDirectory(for: id)
        try? fileManager.removeItem(at: dir)
    }
}

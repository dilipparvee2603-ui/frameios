import Foundation
import Combine

// MARK: - Editor Undo & Redo Command History Engine
@MainActor
final class EditorUndoManager: ObservableObject {
    @Published var canUndo: Bool = false
    @Published var canRedo: Bool = false

    private var undoStack: [VideoProject] = []
    private var redoStack: [VideoProject] = []
    private let maxHistory: Int = 40

    func recordState(_ project: VideoProject) {
        undoStack.append(project)
        if undoStack.count > maxHistory {
            undoStack.removeFirst()
        }
        redoStack.removeAll()
        updateFlags()
    }

    func undo(current: VideoProject) -> VideoProject? {
        guard let previous = undoStack.popLast() else { return nil }
        redoStack.append(current)
        updateFlags()
        return previous
    }

    func redo(current: VideoProject) -> VideoProject? {
        guard let next = redoStack.popLast() else { return nil }
        undoStack.append(current)
        updateFlags()
        return next
    }

    func clear() {
        undoStack.removeAll()
        redoStack.removeAll()
        updateFlags()
    }

    private func updateFlags() {
        canUndo = !undoStack.isEmpty
        canRedo = !redoStack.isEmpty
    }
}

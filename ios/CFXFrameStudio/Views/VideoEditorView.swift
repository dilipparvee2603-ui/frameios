import SwiftUI
import AVFoundation
import PhotosUI
import UniformTypeIdentifiers

// MARK: - Active Tool Panel Enum
enum EditorToolPanel: String, CaseIterable, Identifiable {
    case trim = "Trim"
    case speed = "Speed"
    case color = "Color"
    case transform = "Transform"
    case audio = "Audio"
    var id: String { rawValue }

    var icon: String {
        switch self {
        case .trim: return "arrow.left.and.right.righttriangle.left.righttriangle.right.fill"
        case .speed: return "gauge.with.dots.needle.bottom.0percent"
        case .color: return "slider.horizontal.3"
        case .transform: return "crop.rotate"
        case .audio: return "speaker.wave.2.fill"
        }
    }
}

// MARK: - Video Editor Main Workspace
struct VideoEditorView: View {
    @Environment(\.dismiss) private var dismiss

    // Project State
    @State private var project: VideoProject
    @StateObject private var undoManager = EditorUndoManager()
    @StateObject private var playerModel = PlayerModel()

    // Timeline & Selection State
    @State private var selectedClipIndex: Int = 0
    @State private var playheadMs: Int64 = 0
    @State private var timelineZoom: Double = 1.0 // 1.0 = normal, 2.0 = zoomed in
    @State private var activeToolPanel: EditorToolPanel? = nil

    // Import State
    @State private var selectedPhotosItem: PhotosPickerItem? = nil
    @State private var showPhotosPicker: Bool = false
    @State private var showFilePicker: Bool = false

    // Export State
    @State private var isExporting: Bool = false
    @State private var exportProgress: Double = 0.0
    @State private var exportStatusMessage: String = ""
    @State private var exportedFileUrl: URL? = nil
    @State private var showShareSheet: Bool = false
    @State private var showExportModal: Bool = false
    @State private var exportErrorMessage: String? = nil

    // Title editing modal
    @State private var showTitleEditor: Bool = false
    @State private var editedTitle: String = ""

    init(existingProject: VideoProject? = nil) {
        _project = State(initialValue: existingProject ?? VideoProject(title: "CFX Project 1"))
    }

    private var selectedClip: EditorClip? {
        guard selectedClipIndex >= 0 && selectedClipIndex < project.clips.count else { return nil }
        return project.clips[selectedClipIndex]
    }

    var body: some View {
        ZStack {
            Color.voidCanvas.ignoresSafeArea()

            VStack(spacing: 0) {
                // 1. Top Navigation & Action Bar
                topBar

                // 2. Main Video Monitor / Preview Canvas
                previewMonitor
                    .frame(height: 240)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 4)

                // 3. Playback Transport & Timecode Bar
                transportBar
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)

                // 4. Horizontal Multi-Clip Timeline
                timelineSection
                    .frame(height: 105)
                    .background(Color.surfaceCard.opacity(0.85))

                Spacer(minLength: 4)

                // 5. Contextual Action Toolbar & Inspector Dock
                bottomEditingDock
            }

            // Export Overlay Modal
            if isExporting {
                exportingOverlay
            }
        }
        .navigationBarBackButtonHidden(true)
        .onAppear {
            setupInitialProject()
        }
        .onDisappear {
            playerModel.cleanup()
            ProjectStorageManager.shared.saveProject(project)
        }
        .sheet(isPresented: $showShareSheet) {
            if let url = exportedFileUrl {
                ShareActivityView(activityItems: [url])
            }
        }
        .photosPicker(isPresented: $showPhotosPicker, selection: $selectedPhotosItem, matching: .videos)
        .onChange(of: selectedPhotosItem) { newItem in
            guard let item = newItem else { return }
            handlePhotosPickerImport(item: item)
        }
        .fileImporter(isPresented: $showFilePicker, allowedContentTypes: [.movie, .video], allowsMultipleSelection: false) { result in
            handleFileImporterResult(result: result)
        }
        .alert("Rename Project", isPresented: $showTitleEditor) {
            TextField("Project Name", text: $editedTitle)
            Button("Save") {
                recordUndo()
                project.title = editedTitle
                ProjectStorageManager.shared.saveProject(project)
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    // MARK: - 1. Top Bar
    @ViewBuilder
    private var topBar: some View {
        HStack(spacing: 8) {
            Button(action: {
                ProjectStorageManager.shared.saveProject(project)
                dismiss()
            }) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(.textPrimary)
                    .frame(width: 32, height: 32)
                    .background(Color.surfaceCard)
                    .clipShape(Circle())
            }

            // Project Title (Tap to rename)
            Button(action: {
                editedTitle = project.title
                showTitleEditor = true
            }) {
                HStack(spacing: 4) {
                    Text(project.title)
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Image(systemName: "pencil")
                        .font(.system(size: 10))
                        .foregroundColor(.textTertiary)
                }
                .frame(maxWidth: 100, alignment: .leading)
            }

            Spacer()

            // Canvas Aspect Ratio Pill
            Menu {
                ForEach(AspectRatioPreset.allCases) { preset in
                    Button(action: {
                        recordUndo()
                        project.canvasAspectRatio = preset
                        ProjectStorageManager.shared.saveProject(project)
                    }) {
                        HStack {
                            Text(preset.rawValue)
                            if project.canvasAspectRatio == preset {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "rectangle.dashed")
                        .font(.system(size: 10, weight: .bold))
                    Text(project.canvasAspectRatio.badgeText)
                        .font(.system(size: 11, weight: .heavy))
                }
                .foregroundColor(.skyAccent)
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
                .background(Color.skyAccent.opacity(0.14))
                .clipShape(Capsule())
                .fixedSize()
            }

            // Undo Button
            Button(action: { performUndo() }) {
                Image(systemName: "arrow.uturn.backward")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(undoManager.canUndo ? .textPrimary : .textTertiary)
                    .frame(width: 32, height: 32)
                    .background(Color.surfaceCard)
                    .clipShape(Circle())
            }
            .disabled(!undoManager.canUndo)

            // Redo Button
            Button(action: { performRedo() }) {
                Image(systemName: "arrow.uturn.forward")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(undoManager.canRedo ? .textPrimary : .textTertiary)
                    .frame(width: 32, height: 32)
                    .background(Color.surfaceCard)
                    .clipShape(Circle())
            }
            .disabled(!undoManager.canRedo)

            // Export Button
            Button(action: { startProjectExport() }) {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 12, weight: .bold))
                    Text("Export")
                        .font(.system(size: 12, weight: .heavy))
                }
                .foregroundColor(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(LinearGradient.brandGradient)
                .clipShape(Capsule())
                .fixedSize()
            }
            .disabled(project.clips.isEmpty || isExporting)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
    }

    // MARK: - 2. Preview Monitor
    @ViewBuilder
    private var previewMonitor: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.surfaceCard)
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(Color.borderHairline, lineWidth: 1)
                )

            if let clip = selectedClip {
                // Live AVPlayer view
                VideoPlayerView(player: playerModel.player)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .scaleEffect(clip.transform.scale)
                    .rotationEffect(Angle(degrees: Double(clip.transform.rotation.rawValue)))
                    .scaleEffect(x: clip.transform.flipH ? -1 : 1, y: clip.transform.flipV ? -1 : 1)
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "film.stack.fill")
                        .font(.system(size: 34))
                        .foregroundColor(.brandAccent)

                    Text("No clips in timeline")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(.textPrimary)

                    HStack(spacing: 12) {
                        Button(action: { showPhotosPicker = true }) {
                            HStack(spacing: 6) {
                                Image(systemName: "photo.on.rectangle")
                                    .font(.system(size: 12, weight: .bold))
                                Text("Camera Roll")
                                    .font(.system(size: 12, weight: .bold))
                            }
                            .foregroundColor(.white)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(Color.brandAccent)
                            .clipShape(Capsule())
                        }

                        Button(action: { showFilePicker = true }) {
                            HStack(spacing: 6) {
                                Image(systemName: "folder.fill")
                                    .font(.system(size: 12, weight: .bold))
                                Text("Files")
                                    .font(.system(size: 12, weight: .bold))
                            }
                            .foregroundColor(.textPrimary)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(Color.elevatedSurface)
                            .clipShape(Capsule())
                        }
                    }
                }
            }

            // Floating Timecode Overlay
            VStack {
                HStack {
                    Spacer()
                    Text("\(formatMs(playheadMs)) / \(formatMs(project.totalTimelineDurationMs))")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundColor(.textPrimary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.voidCanvas.opacity(0.75))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .padding(10)
                }
                Spacer()
            }
        }
    }

    // MARK: - 3. Transport Bar
    @ViewBuilder
    private var transportBar: some View {
        HStack(spacing: 14) {
            // Jump to Start
            Button(action: {
                playheadMs = 0
                syncPlayheadToPlayer()
            }) {
                Image(systemName: "backward.end.fill")
                    .font(.system(size: 13))
                    .foregroundColor(.textSecondary)
            }

            // Play / Pause
            Button(action: {
                if playerModel.isPlaying {
                    playerModel.pause()
                } else {
                    playerModel.play()
                }
            }) {
                Image(systemName: playerModel.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(.textPrimary)
                    .frame(width: 38, height: 38)
                    .background(Color.elevatedSurface)
                    .clipShape(Circle())
                    .overlay(Circle().stroke(Color.borderHairline, lineWidth: 1))
            }

            // Jump to End
            Button(action: {
                playheadMs = project.totalTimelineDurationMs
                syncPlayheadToPlayer()
            }) {
                Image(systemName: "forward.end.fill")
                    .font(.system(size: 13))
                    .foregroundColor(.textSecondary)
            }

            Spacer()

            // Split at Playhead Button (Prominent)
            Button(action: { performSplitAtPlayhead() }) {
                HStack(spacing: 5) {
                    Image(systemName: "scissors")
                        .font(.system(size: 11, weight: .bold))
                    Text("Split")
                        .font(.system(size: 11, weight: .bold))
                }
                .foregroundColor(.brandAccent)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.brandAccent.opacity(0.14))
                .clipShape(Capsule())
                .fixedSize()
            }
            .disabled(project.clips.isEmpty)

            // Add Media (+) Button
            Menu {
                Button(action: { showPhotosPicker = true }) {
                    Label("Import from Photos", systemImage: "photo.on.rectangle")
                }
                Button(action: { showFilePicker = true }) {
                    Label("Import from Files", systemImage: "folder")
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .bold))
                    Text("Add Clip")
                        .font(.system(size: 11, weight: .bold))
                }
                .foregroundColor(.emeraldAccent)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.emeraldAccent.opacity(0.14))
                .clipShape(Capsule())
                .fixedSize()
            }
        }
    }

    // MARK: - 4. Timeline Section
    @ViewBuilder
    private var timelineSection: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                ZStack(alignment: .leading) {
                    if project.clips.isEmpty {
                        // Empty Timeline Placeholder
                        Button(action: { showPhotosPicker = true }) {
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(style: StrokeStyle(lineWidth: 1.5, dash: [6]))
                                .foregroundColor(Color.borderHairlineBright)
                                .frame(width: 160, height: 60)
                                .overlay(
                                    HStack(spacing: 6) {
                                        Image(systemName: "plus.circle.fill")
                                            .foregroundColor(.emeraldAccent)
                                        Text("Add First Clip")
                                            .font(.system(size: 11, weight: .bold))
                                            .foregroundColor(.textSecondary)
                                    }
                                )
                        }
                        .padding(.horizontal, 20)
                        .padding(.top, 20)
                    } else {
                        // Clips Track
                        HStack(spacing: 6) {
                            ForEach(0..<project.clips.count, id: \.self) { idx in
                                let clip = project.clips[idx]
                                let isSelected = idx == selectedClipIndex
                                let clipWidth = max(70, CGFloat(clip.timelineDurationMs) / 35.0 * CGFloat(timelineZoom))

                                ZStack(alignment: .leading) {
                                    RoundedRectangle(cornerRadius: 8)
                                        .fill(isSelected ? Color.elevatedSurface : Color.surfaceCard)
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 8)
                                                .stroke(isSelected ? Color.brandAccent : Color.borderHairline, lineWidth: isSelected ? 2 : 1)
                                        )

                                    VStack(alignment: .leading, spacing: 2) {
                                        HStack {
                                            Text(clip.filename)
                                                .font(.system(size: 10, weight: .bold))
                                                .foregroundColor(.textPrimary)
                                                .lineLimit(1)

                                            Spacer()

                                            // Speed tag if slow-mo
                                            if abs(clip.speedConfig.speedMultiplier - 1.0) > 0.01 {
                                                Text(String(format: "%.2fx", clip.speedConfig.speedMultiplier))
                                                    .font(.system(size: 8.5, weight: .heavy))
                                                    .foregroundColor(.pinkAccent)
                                                    .padding(.horizontal, 4)
                                                    .padding(.vertical, 1)
                                                    .background(Color.pinkAccent.opacity(0.18))
                                                    .clipShape(RoundedRectangle(cornerRadius: 4))
                                            }
                                        }

                                        Spacer()

                                        Text(formatMs(clip.timelineDurationMs))
                                            .font(.system(size: 9, design: .monospaced))
                                            .foregroundColor(.textTertiary)
                                    }
                                    .padding(6)
                                }
                                .frame(width: clipWidth, height: 65)
                                .onTapGesture {
                                    selectedClipIndex = idx
                                    let startMs = project.timelineStartTime(forClipIndex: idx)
                                    playheadMs = startMs
                                    syncPlayheadToPlayer()
                                }
                            }
                        }
                        .padding(.horizontal, 20)
                        .padding(.top, 20)

                        // Playhead Needle
                        let playheadX = 20 + (CGFloat(playheadMs) / 35.0 * CGFloat(timelineZoom))
                        Rectangle()
                            .fill(Color.brandAccent)
                            .frame(width: 2.5, height: 85)
                            .position(x: playheadX, y: 50)
                            .shadow(color: Color.brandAccent.opacity(0.5), radius: 3)
                    }
                }
                .frame(minHeight: 100)
            }
        }
        .clipped()
    }

    // MARK: - 5. Bottom Contextual Editing Dock
    @ViewBuilder
    private var bottomEditingDock: some View {
        VStack(spacing: 6) {
            // Inspector Panel for Active Tool (if open)
            if let tool = activeToolPanel, let clip = selectedClip {
                toolInspectorPanel(tool: tool, clip: clip)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            // Primary Tool Selector Strip
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(EditorToolPanel.allCases) { tool in
                        let isActive = activeToolPanel == tool
                        Button(action: {
                            withAnimation(.easeInOut(duration: 0.18)) {
                                activeToolPanel = (activeToolPanel == tool) ? nil : tool
                            }
                        }) {
                            VStack(spacing: 4) {
                                Image(systemName: tool.icon)
                                    .font(.system(size: 15, weight: .bold))
                                Text(tool.rawValue)
                                    .font(.system(size: 10, weight: .bold))
                            }
                            .foregroundColor(isActive ? .brandAccent : .textSecondary)
                            .frame(width: 58, height: 50)
                            .background(isActive ? Color.brandAccent.opacity(0.16) : Color.surfaceCard)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                            .overlay(
                                RoundedRectangle(cornerRadius: 10)
                                    .stroke(isActive ? Color.brandAccent.opacity(0.4) : Color.borderHairline, lineWidth: 1)
                            )
                        }
                    }

                    // Duplicate Clip
                    Button(action: { performDuplicateClip() }) {
                        VStack(spacing: 4) {
                            Image(systemName: "plus.square.on.square")
                                .font(.system(size: 15, weight: .bold))
                            Text("Duplicate")
                                .font(.system(size: 10, weight: .bold))
                        }
                        .foregroundColor(.skyAccent)
                        .frame(width: 58, height: 50)
                        .background(Color.surfaceCard)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                    .disabled(selectedClip == nil)

                    // Delete Clip
                    Button(action: { performDeleteClip() }) {
                        VStack(spacing: 4) {
                            Image(systemName: "trash.fill")
                                .font(.system(size: 15, weight: .bold))
                            Text("Delete")
                                .font(.system(size: 10, weight: .bold))
                        }
                        .foregroundColor(.brandAccent)
                        .frame(width: 58, height: 50)
                        .background(Color.surfaceCard)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                    .disabled(selectedClip == nil)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
        }
        .padding(.bottom, 20)
        .background(Color.voidCanvas)
    }

    // MARK: - Tool Inspector Panels
    @ViewBuilder
    private func toolInspectorPanel(tool: EditorToolPanel, clip: EditorClip) -> some View {
        GlassCard(cornerRadius: 14, padding: 12) {
            VStack(alignment: .leading, spacing: 10) {
                switch tool {
                case .trim:
                    trimInspector(clip: clip)
                case .speed:
                    speedInspector(clip: clip)
                case .color:
                    colorInspector(clip: clip)
                case .transform:
                    transformInspector(clip: clip)
                case .audio:
                    audioInspector(clip: clip)
                }
            }
        }
        .padding(.horizontal, 16)
    }

    // MARK: - Trim Inspector
    @ViewBuilder
    private func trimInspector(clip: EditorClip) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("PRECISION TRIM")
                    .font(.system(size: 11, weight: .heavy))
                    .foregroundColor(.brandAccent)
                Spacer()
                Text("In: \(formatMs(clip.sourceInPointMs)) | Out: \(formatMs(clip.sourceOutPointMs))")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.textSecondary)
            }

            HStack(spacing: 12) {
                Button(action: {
                    recordUndo()
                    let curSrcMs = clip.mapTimelineOffsetToSourceMs(playheadMs - project.timelineStartTime(forClipIndex: selectedClipIndex))
                    if curSrcMs < clip.sourceOutPointMs - 100 {
                        project.clips[selectedClipIndex].sourceInPointMs = curSrcMs
                    }
                }) {
                    Text("Set Start to Playhead")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.skyAccent)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color.skyAccent.opacity(0.15))
                        .clipShape(Capsule())
                }

                Button(action: {
                    recordUndo()
                    let curSrcMs = clip.mapTimelineOffsetToSourceMs(playheadMs - project.timelineStartTime(forClipIndex: selectedClipIndex))
                    if curSrcMs > clip.sourceInPointMs + 100 {
                        project.clips[selectedClipIndex].sourceOutPointMs = curSrcMs
                    }
                }) {
                    Text("Set End to Playhead")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.emeraldAccent)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color.emeraldAccent.opacity(0.15))
                        .clipShape(Capsule())
                }

                Button(action: {
                    recordUndo()
                    project.clips[selectedClipIndex].sourceInPointMs = 0
                    project.clips[selectedClipIndex].sourceOutPointMs = clip.sourceDurationMs
                }) {
                    Text("Reset")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.textTertiary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color.elevatedSurface)
                        .clipShape(Capsule())
                }
            }
        }
    }

    // MARK: - Speed Inspector
    @ViewBuilder
    private func speedInspector(clip: EditorClip) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("SLOW-MO & RETIMING")
                    .font(.system(size: 11, weight: .heavy))
                    .foregroundColor(.pinkAccent)
                Spacer()
                Text("\(Int(round(clip.speedConfig.speedMultiplier * 100)))% (\(String(format: "%.2fx", clip.speedConfig.speedMultiplier)))")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundColor(.textPrimary)
            }

            // Speed Presets
            HStack(spacing: 6) {
                ForEach([0.10, 0.25, 0.50, 0.75, 1.0], id: \.self) { val in
                    let isSel = abs(clip.speedConfig.speedMultiplier - val) < 0.01
                    Button(action: {
                        recordUndo()
                        project.clips[selectedClipIndex].speedConfig.speedMultiplier = val
                    }) {
                        Text(val == 1.0 ? "1x" : "\(Int(val * 100))%")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(isSel ? .white : .textSecondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(isSel ? Color.pinkAccent : Color.elevatedSurface)
                            .clipShape(Capsule())
                    }
                }
            }

            // Interpolation Mode Picker
            HStack(spacing: 8) {
                Text("Interpolation:")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.textTertiary)

                Picker("Mode", selection: Binding(
                    get: { project.clips[selectedClipIndex].speedConfig.interpolationMode },
                    set: {
                        recordUndo()
                        project.clips[selectedClipIndex].speedConfig.interpolationMode = $0
                    }
                )) {
                    ForEach(SlowMoInterpolationMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(MenuPickerStyle())
                .font(.system(size: 10, weight: .bold))
            }
        }
    }

    // MARK: - Color Inspector
    @ViewBuilder
    private func colorInspector(clip: EditorClip) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("COLOR GRADING")
                .font(.system(size: 11, weight: .heavy))
                .foregroundColor(.amberAccent)

            HStack {
                Text("Contrast")
                    .font(.system(size: 10))
                    .foregroundColor(.textSecondary)
                    .frame(width: 60, alignment: .leading)
                Slider(value: Binding(
                    get: { project.clips[selectedClipIndex].color.contrast },
                    set: { project.clips[selectedClipIndex].color.contrast = $0 }
                ), in: 0.5...1.8)
            }

            HStack {
                Text("Brightness")
                    .font(.system(size: 10))
                    .foregroundColor(.textSecondary)
                    .frame(width: 60, alignment: .leading)
                Slider(value: Binding(
                    get: { project.clips[selectedClipIndex].color.brightness },
                    set: { project.clips[selectedClipIndex].color.brightness = $0 }
                ), in: -0.5...0.5)
            }

            HStack {
                Text("Saturation")
                    .font(.system(size: 10))
                    .foregroundColor(.textSecondary)
                    .frame(width: 60, alignment: .leading)
                Slider(value: Binding(
                    get: { project.clips[selectedClipIndex].color.saturation },
                    set: { project.clips[selectedClipIndex].color.saturation = $0 }
                ), in: 0.0...2.0)
            }
        }
    }

    // MARK: - Transform Inspector
    @ViewBuilder
    private func transformInspector(clip: EditorClip) -> some View {
        HStack(spacing: 12) {
            Button(action: {
                recordUndo()
                project.clips[selectedClipIndex].transform.rotation = clip.transform.rotation.next
            }) {
                Label("Rotate 90°", systemImage: "rotate.right")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.skyAccent)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.skyAccent.opacity(0.15))
                    .clipShape(Capsule())
            }

            Button(action: {
                recordUndo()
                project.clips[selectedClipIndex].transform.flipH.toggle()
            }) {
                Label("Flip H", systemImage: "arrow.left.and.right.righttriangle.left.righttriangle.right")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.textSecondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.elevatedSurface)
                    .clipShape(Capsule())
            }
        }
    }

    // MARK: - Audio Inspector
    @ViewBuilder
    private func audioInspector(clip: EditorClip) -> some View {
        HStack(spacing: 12) {
            Button(action: {
                recordUndo()
                project.clips[selectedClipIndex].isMuted.toggle()
            }) {
                Label(clip.isMuted ? "Unmute" : "Mute", systemImage: clip.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(clip.isMuted ? .brandAccent : .emeraldAccent)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.elevatedSurface)
                    .clipShape(Capsule())
            }

            Slider(value: Binding(
                get: { project.clips[selectedClipIndex].volume },
                set: { project.clips[selectedClipIndex].volume = $0 }
            ), in: 0.0...2.0)
        }
    }

    // MARK: - Exporting Overlay
    @ViewBuilder
    private var exportingOverlay: some View {
        ZStack {
            Color.black.opacity(0.85).ignoresSafeArea()

            VStack(spacing: 16) {
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle(tint: .brandAccent))
                    .scaleEffect(1.3)

                Text(exportStatusMessage)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(.textPrimary)

                ProgressView(value: exportProgress, total: 1.0)
                    .progressViewStyle(LinearProgressViewStyle(tint: .brandAccent))
                    .frame(width: 240)

                Text("\(Int(exportProgress * 100))%")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(.textSecondary)

                Button("Cancel", role: .cancel) {
                    VideoEditorExportEngine.shared.cancel()
                    isExporting = false
                }
                .font(.system(size: 13, weight: .bold))
                .foregroundColor(.textTertiary)
                .padding(.top, 8)
            }
            .padding(24)
            .background(Color.surfaceCard)
            .clipShape(RoundedRectangle(cornerRadius: 18))
        }
    }

    // MARK: - Logic Actions
    private func setupInitialProject() {
        if let clip = project.clips.first {
            playerModel.setup(with: clip.sourceUrl)
        }
    }

    private func syncPlayheadToPlayer() {
        guard let clip = selectedClip else { return }
        let clipStart = project.timelineStartTime(forClipIndex: selectedClipIndex)
        let offsetMs = max(0, min(clip.timelineDurationMs, playheadMs - clipStart))
        let sourceMs = clip.mapTimelineOffsetToSourceMs(offsetMs)

        if playerModel.player.currentItem?.asset as? AVURLAsset == nil ||
           (playerModel.player.currentItem?.asset as? AVURLAsset)?.url != clip.sourceUrl {
            playerModel.setup(with: clip.sourceUrl)
        }
        playerModel.seek(to: sourceMs)
    }

    private func performSplitAtPlayhead() {
        recordUndo()
        if project.splitClip(at: playheadMs) {
            ProjectStorageManager.shared.saveProject(project)
        }
    }

    private func performDuplicateClip() {
        guard let clip = selectedClip else { return }
        recordUndo()
        var clone = clip
        clone.id = UUID()
        project.clips.insert(clone, at: selectedClipIndex + 1)
        selectedClipIndex += 1
        ProjectStorageManager.shared.saveProject(project)
    }

    private func performDeleteClip() {
        guard selectedClip != nil else { return }
        recordUndo()
        project.clips.remove(at: selectedClipIndex)
        selectedClipIndex = max(0, min(project.clips.count - 1, selectedClipIndex))
        ProjectStorageManager.shared.saveProject(project)
    }

    private func recordUndo() {
        undoManager.recordState(project)
    }

    private func performUndo() {
        if let prev = undoManager.undo(current: project) {
            project = prev
            syncPlayheadToPlayer()
        }
    }

    private func performRedo() {
        if let next = undoManager.redo(current: project) {
            project = next
            syncPlayheadToPlayer()
        }
    }

    private func startProjectExport() {
        isExporting = true
        exportProgress = 0.0
        exportStatusMessage = "Initializing render pipeline..."

        let config = ProjectExportConfig(
            resolution: project.canvasAspectRatio,
            targetFps: project.targetFps,
            saveToCameraRoll: true
        )

        Task {
            let result = await VideoEditorExportEngine.shared.exportProject(
                project: project,
                config: config,
                onProgress: { p, msg in
                    DispatchQueue.main.async {
                        exportProgress = p
                        exportStatusMessage = msg
                    }
                }
            )

            DispatchQueue.main.async {
                isExporting = false
                if result.success, let outUrl = result.outputUrl {
                    exportedFileUrl = outUrl
                    showShareSheet = true
                } else {
                    exportErrorMessage = result.errorMessage
                }
            }
        }
    }

    private func handlePhotosPickerImport(item: PhotosPickerItem) {
        Task {
            do {
                if let movie = try await item.loadTransferable(type: MovieTransferable.self) {
                    let ingestedUrl = ProjectStorageManager.shared.importMedia(from: movie.url, to: project.id)
                    let info = try? await VideoEngine.shared.extractVideoInfo(from: ingestedUrl)

                    let durMs = info?.durationMs ?? 5000
                    let newClip = EditorClip(
                        sourceUrl: ingestedUrl,
                        filename: movie.url.lastPathComponent,
                        sourceDurationMs: durMs,
                        sourceInPointMs: 0,
                        sourceOutPointMs: durMs
                    )

                    await MainActor.run {
                        self.selectedPhotosItem = nil
                        self.recordUndo()
                        self.project.clips.append(newClip)
                        self.selectedClipIndex = self.project.clips.count - 1
                        ProjectStorageManager.shared.saveProject(self.project)
                        self.syncPlayheadToPlayer()
                    }
                } else {
                    await MainActor.run {
                        self.selectedPhotosItem = nil
                    }
                }
            } catch {
                print("PhotosPicker load error: \(error)")
                await MainActor.run {
                    self.selectedPhotosItem = nil
                }
            }
        }
    }

    private func handleFileImporterResult(result: Result<[URL], Error>) {
        if case .success(let urls) = result, let url = urls.first {
            _ = url.startAccessingSecurityScopedResource()
            defer { url.stopAccessingSecurityScopedResource() }

            let ingestedUrl = ProjectStorageManager.shared.importMedia(from: url, to: project.id)
            Task {
                let info = try? await VideoEngine.shared.extractVideoInfo(from: ingestedUrl)
                let durMs = info?.durationMs ?? 5000
                let newClip = EditorClip(
                    sourceUrl: ingestedUrl,
                    filename: ingestedUrl.lastPathComponent,
                    sourceDurationMs: durMs,
                    sourceInPointMs: 0,
                    sourceOutPointMs: durMs
                )

                DispatchQueue.main.async {
                    self.recordUndo()
                    self.project.clips.append(newClip)
                    self.selectedClipIndex = self.project.clips.count - 1
                    ProjectStorageManager.shared.saveProject(self.project)
                    self.syncPlayheadToPlayer()
                }
            }
        }
    }

    private func formatMs(_ ms: Int64) -> String {
        let totalSec = Double(max(0, ms)) / 1000.0
        let m = Int(totalSec) / 60
        let s = Int(totalSec) % 60
        let f = Int((totalSec.truncatingRemainder(dividingBy: 1.0)) * 10)
        return String(format: "%02d:%02d.%d", m, s, f)
    }
}

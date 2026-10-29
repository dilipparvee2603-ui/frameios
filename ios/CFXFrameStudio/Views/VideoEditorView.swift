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
    @State private var isImportingMedia: Bool = false
    @State private var importStatusText: String = ""

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
                    .frame(height: 230)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 4)

                // 3. Playback Transport & Timecode Bar
                transportBar
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)

                // 4. Horizontal Multi-Clip Timeline
                timelineSection
                    .frame(height: 120)
                    .background(Color.surfaceCard.opacity(0.85))

                Spacer(minLength: 4)

                // 5. Contextual Action Toolbar & Inspector Dock
                bottomEditingDock
            }

            // Media Ingestion Spinner Overlay
            if isImportingMedia {
                ZStack {
                    Color.black.opacity(0.7).ignoresSafeArea()
                    VStack(spacing: 12) {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: .brandAccent))
                            .scaleEffect(1.3)
                        Text(importStatusText)
                            .font(.system(size: 13, weight: .bold))
                            .foregroundColor(.white)
                    }
                    .padding(24)
                    .background(Color.surfaceCard)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                }
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
                    .font(.system(size: 14, weight: .bold))
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
                .frame(maxWidth: 88, alignment: .leading)
            }

            Spacer(minLength: 2)

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
                        .lineLimit(1)
                }
                .foregroundColor(.skyAccent)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(Color.skyAccent.opacity(0.14))
                .clipShape(Capsule())
            }
            .fixedSize()
            .layoutPriority(1)

            // Undo Button
            Button(action: { performUndo() }) {
                Image(systemName: "arrow.uturn.backward")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(undoManager.canUndo ? .textPrimary : .textTertiary)
                    .frame(width: 30, height: 30)
                    .background(Color.surfaceCard)
                    .clipShape(Circle())
            }
            .disabled(!undoManager.canUndo)

            // Redo Button
            Button(action: { performRedo() }) {
                Image(systemName: "arrow.uturn.forward")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(undoManager.canRedo ? .textPrimary : .textTertiary)
                    .frame(width: 30, height: 30)
                    .background(Color.surfaceCard)
                    .clipShape(Circle())
            }
            .disabled(!undoManager.canRedo)

            // Export Button
            Button(action: { startProjectExport() }) {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 11, weight: .bold))
                    Text("Export")
                        .font(.system(size: 11, weight: .heavy))
                        .lineLimit(1)
                }
                .foregroundColor(.white)
                .padding(.horizontal, 11)
                .padding(.vertical, 7)
                .background(LinearGradient.brandGradient)
                .clipShape(Capsule())
            }
            .fixedSize()
            .layoutPriority(2)
            .disabled(project.clips.isEmpty || isExporting)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }

    // MARK: - 2. Preview Monitor
    @ViewBuilder
    private var previewMonitor: some View {
        GeometryReader { geo in
            let availW = geo.size.width
            let availH = geo.size.height

            ZStack {
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color.surfaceCard)
                    .overlay(
                        RoundedRectangle(cornerRadius: 16)
                            .stroke(Color.borderHairline, lineWidth: 1)
                    )

                if let clip = selectedClip {
                    let ratio: CGFloat = project.canvasAspectRatio.ratioValue ?? (9.0 / 16.0)
                    let canvasSize = computeCanvasDimensions(ratio: ratio, maxW: max(80, availW - 16), maxH: max(80, availH - 16))

                    // Canvas Container Box (Accurately sized to chosen Aspect Ratio)
                    ZStack {
                        Color.black

                        VideoPlayerView(player: playerModel.player)
                            .scaleEffect(clip.transform.scale)
                            .rotationEffect(Angle(degrees: Double(clip.transform.rotation.rawValue)))
                            .scaleEffect(x: clip.transform.flipH ? -1 : 1, y: clip.transform.flipV ? -1 : 1)
                    }
                    .frame(width: canvasSize.width, height: canvasSize.height)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(Color.skyAccent.opacity(0.55), lineWidth: 1.5)
                    )
                    .shadow(color: Color.black.opacity(0.6), radius: 6)

                    // Canvas Aspect Ratio Indicator Tag
                    VStack {
                        HStack {
                            Text(project.canvasAspectRatio.badgeText)
                                .font(.system(size: 9.5, weight: .heavy, design: .monospaced))
                                .foregroundColor(.skyAccent)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3)
                                .background(Color.black.opacity(0.75))
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                                .padding(10)
                            Spacer()
                        }
                        Spacer()
                    }
                } else {
                    VStack(spacing: 14) {
                        Image(systemName: "film.stack.fill")
                            .font(.system(size: 38))
                            .foregroundColor(.brandAccent)

                        VStack(spacing: 4) {
                            Text("No Video Added Yet")
                                .font(.system(size: 15, weight: .bold))
                                .foregroundColor(.textPrimary)

                            Text("Import a video to view real timeline frames & audio")
                                .font(.system(size: 11))
                                .foregroundColor(.textMuted)
                        }

                        HStack(spacing: 12) {
                            Button(action: { showPhotosPicker = true }) {
                                HStack(spacing: 6) {
                                    Image(systemName: "photo.on.rectangle")
                                        .font(.system(size: 12, weight: .bold))
                                    Text("Camera Roll")
                                        .font(.system(size: 12, weight: .bold))
                                }
                                .foregroundColor(.white)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 9)
                                .background(LinearGradient.brandGradient)
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
                                .padding(.horizontal, 16)
                                .padding(.vertical, 9)
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
    }

    private var pointsPerSecond: CGFloat {
        80.0 * CGFloat(timelineZoom)
    }

    private let leadPad: CGFloat = 36.0

    // MARK: - 3. Transport Bar
    @ViewBuilder
    private var transportBar: some View {
        HStack(spacing: 10) {
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
                    let speed = Float(selectedClip?.speedConfig.speedMultiplier ?? 1.0)
                    playerModel.play(rate: speed)
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

            // Timeline Zoom Controls: [-] 1.0x [+]
            HStack(spacing: 4) {
                Button(action: {
                    withAnimation(.easeOut(duration: 0.15)) {
                        timelineZoom = max(0.5, timelineZoom - 0.25)
                    }
                }) {
                    Image(systemName: "minus")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(.textSecondary)
                        .frame(width: 20, height: 20)
                        .background(Color.elevatedSurface)
                        .clipShape(Circle())
                }

                Text(String(format: "%.1fx", timelineZoom))
                    .font(.system(size: 9.5, weight: .heavy, design: .monospaced))
                    .foregroundColor(.textTertiary)
                    .frame(width: 26)

                Button(action: {
                    withAnimation(.easeOut(duration: 0.15)) {
                        timelineZoom = min(4.0, timelineZoom + 0.25)
                    }
                }) {
                    Image(systemName: "plus")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(.textSecondary)
                        .frame(width: 20, height: 20)
                        .background(Color.elevatedSurface)
                        .clipShape(Circle())
                }
            }
            .padding(.horizontal, 5)
            .padding(.vertical, 3)
            .background(Color.surfaceCard)
            .clipShape(Capsule())

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
                if project.clips.isEmpty {
                    // Empty Timeline Placeholder
                    HStack {
                        Spacer()
                        Button(action: { showPhotosPicker = true }) {
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(style: StrokeStyle(lineWidth: 1.5, dash: [6]))
                                .foregroundColor(Color.borderHairlineBright)
                                .frame(width: 200, height: 70)
                                .overlay(
                                    HStack(spacing: 8) {
                                        Image(systemName: "plus.circle.fill")
                                            .font(.system(size: 16))
                                            .foregroundColor(.emeraldAccent)
                                        Text("Tap to Add First Video")
                                            .font(.system(size: 12, weight: .bold))
                                            .foregroundColor(.textSecondary)
                                    }
                                )
                        }
                        Spacer()
                    }
                    .frame(width: max(UIScreen.main.bounds.width, 390), height: 120)
                } else {
                    let totalSec = max(5, Int(ceil(Double(project.totalTimelineDurationMs) / 1000.0)) + 3)
                    let totalClipsWidth = (CGFloat(project.totalTimelineDurationMs) / 1000.0) * pointsPerSecond
                    let totalContentWidth = leadPad + totalClipsWidth + 240.0

                    ZStack(alignment: .topLeading) {
                        // Background track layer
                        VStack(alignment: .leading, spacing: 4) {
                            // Seconds Ruler Row
                            HStack(alignment: .bottom, spacing: 0) {
                                ForEach(0...totalSec, id: \.self) { sec in
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(formatSeconds(sec))
                                            .font(.system(size: 9, weight: .medium, design: .monospaced))
                                            .foregroundColor(.textTertiary)
                                        Rectangle()
                                            .fill(Color.borderHairlineBright)
                                            .frame(width: 1, height: 6)
                                    }
                                    .frame(width: pointsPerSecond, alignment: .leading)
                                }
                            }
                            .padding(.leading, leadPad)

                            // Clips Horizontal Row
                            HStack(spacing: 4) {
                                ForEach(0..<project.clips.count, id: \.self) { idx in
                                    let clip = project.clips[idx]
                                    let isSelected = idx == selectedClipIndex
                                    let clipWidth = max(60, (CGFloat(clip.timelineDurationMs) / 1000.0) * pointsPerSecond)

                                    clipTrackItem(clip: clip, index: idx, isSelected: isSelected, width: clipWidth)
                                }

                                // Trailing spacer allowing playback to scroll past end
                                Spacer()
                                    .frame(width: 240)
                            }
                            .padding(.leading, leadPad)
                        }
                        .frame(width: max(totalContentWidth, UIScreen.main.bounds.width + 120), alignment: .topLeading)

                        // Playhead Needle
                        let playheadX = leadPad + (CGFloat(playheadMs) / 1000.0 * pointsPerSecond)
                        VStack(spacing: 0) {
                            // Draggable Top Cap
                            Capsule()
                                .fill(Color.brandAccent)
                                .frame(width: 14, height: 16)
                                .overlay(
                                    Circle()
                                        .fill(Color.white)
                                        .frame(width: 5, height: 5)
                                )
                                .shadow(color: Color.brandAccent.opacity(0.6), radius: 3)
                                .gesture(
                                    DragGesture(minimumDistance: 1)
                                        .onChanged { value in
                                            let rawX = playheadX + value.translation.width
                                            let clampedX = max(leadPad, rawX)
                                            let newMs = Int64(round(Double(clampedX - leadPad) / Double(pointsPerSecond) * 1000.0))
                                            playheadMs = max(0, min(project.totalTimelineDurationMs, newMs))
                                            syncPlayheadToPlayer()
                                        }
                                )

                            // Vertical Needle Line (allowsHitTesting false so touches pass through to clips)
                            Rectangle()
                                .fill(Color.brandAccent)
                                .frame(width: 2, height: 86)
                                .shadow(color: Color.brandAccent.opacity(0.4), radius: 2)
                                .allowsHitTesting(false)
                        }
                        .offset(x: playheadX - 7, y: 2)
                    }
                    .frame(height: 120)
                }
            }
        }
        .clipped()
    }

    @ViewBuilder
    private func clipTrackItem(clip: EditorClip, index: Int, isSelected: Bool, width: CGFloat) -> some View {
        ZStack(alignment: .leading) {
            // Background Filmstrip Thumbnail Strip (real video frames)
            ClipThumbnailStripView(clip: clip, width: width)
                .clipShape(RoundedRectangle(cornerRadius: 8))

            // Dark gradient overlay for text readability
            LinearGradient(
                colors: [Color.black.opacity(0.65), Color.black.opacity(0.15), Color.black.opacity(0.65)],
                startPoint: .top,
                endPoint: .bottom
            )
            .clipShape(RoundedRectangle(cornerRadius: 8))

            // Border (highlighted when selected)
            RoundedRectangle(cornerRadius: 8)
                .stroke(isSelected ? Color.brandAccent : Color.borderHairline, lineWidth: isSelected ? 2.5 : 1)

            // Visual Trim Handles when selected
            if isSelected {
                HStack {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.brandAccent)
                        .frame(width: 8, height: 42)
                        .overlay(
                            Image(systemName: "chevron.compact.left")
                                .font(.system(size: 8, weight: .heavy))
                                .foregroundColor(.white)
                        )

                    Spacer()

                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.brandAccent)
                        .frame(width: 8, height: 42)
                        .overlay(
                            Image(systemName: "chevron.compact.right")
                                .font(.system(size: 8, weight: .heavy))
                                .foregroundColor(.white)
                        )
                }
                .padding(.horizontal, 2)
            }

            // Clip metadata overlay
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(clip.filename)
                        .font(.system(size: 9.5, weight: .bold))
                        .foregroundColor(.white)
                        .lineLimit(1)
                        .shadow(color: .black, radius: 2)

                    Spacer(minLength: 0)

                    // Speed Pill
                    if abs(clip.speedConfig.speedMultiplier - 1.0) > 0.01 {
                        Text(String(format: "%.2fx", clip.speedConfig.speedMultiplier))
                            .font(.system(size: 8, weight: .heavy))
                            .foregroundColor(.pinkAccent)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Color.black.opacity(0.8))
                            .clipShape(RoundedRectangle(cornerRadius: 3))
                    }
                }

                Spacer()

                HStack {
                    Text(formatMs(clip.timelineDurationMs))
                        .font(.system(size: 8.5, weight: .semibold, design: .monospaced))
                        .foregroundColor(.white.opacity(0.95))
                        .shadow(color: .black, radius: 2)

                    Spacer()

                    if clip.isMuted {
                        Image(systemName: "speaker.slash.fill")
                            .font(.system(size: 8))
                            .foregroundColor(.brandAccent)
                    }
                }
            }
            .padding(5)
        }
        .frame(width: width, height: 62)
        .contentShape(Rectangle())
        .onTapGesture {
            selectedClipIndex = index
            let startMs = project.timelineStartTime(forClipIndex: index)
            playheadMs = startMs
            syncPlayheadToPlayer()
        }
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

    // MARK: - Transform Inspector (Zoom, Aspect Ratio Canvas, Rotate, Flips)
    @ViewBuilder
    private func transformInspector(clip: EditorClip) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            // 1. Aspect Ratio Selector
            VStack(alignment: .leading, spacing: 4) {
                Text("CANVAS ASPECT RATIO")
                    .font(.system(size: 10, weight: .heavy))
                    .foregroundColor(.textTertiary)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(AspectRatioPreset.allCases) { preset in
                            let isSelected = project.canvasAspectRatio == preset
                            Button(action: {
                                recordUndo()
                                project.canvasAspectRatio = preset
                                ProjectStorageManager.shared.saveProject(project)
                            }) {
                                HStack(spacing: 4) {
                                    Image(systemName: "rectangle.dashed")
                                        .font(.system(size: 10, weight: .bold))
                                    Text(preset.badgeText)
                                        .font(.system(size: 11, weight: .bold))
                                }
                                .foregroundColor(isSelected ? .white : .textSecondary)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(isSelected ? Color.skyAccent : Color.surfaceCard)
                                .clipShape(Capsule())
                                .overlay(
                                    Capsule().stroke(isSelected ? Color.skyAccent : Color.borderHairline, lineWidth: 1)
                                )
                            }
                        }
                    }
                }
            }

            Divider().background(Color.borderHairline)

            // 2. Zoom / Scale Control
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("ZOOM / SCALE")
                        .font(.system(size: 10, weight: .heavy))
                        .foregroundColor(.textTertiary)
                    Spacer()
                    Text(String(format: "%.2fx", clip.transform.scale))
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundColor(.brandAccent)

                    Button("Reset") {
                        recordUndo()
                        project.clips[selectedClipIndex].transform.scale = 1.0
                    }
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.textMuted)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.elevatedSurface)
                    .clipShape(Capsule())
                }

                Slider(
                    value: Binding(
                        get: { project.clips[selectedClipIndex].transform.scale },
                        set: { project.clips[selectedClipIndex].transform.scale = $0 }
                    ),
                    in: 0.5...3.0,
                    step: 0.05
                )
                .accentColor(.brandAccent)

                // Quick zoom presets
                HStack(spacing: 6) {
                    ForEach([0.8, 1.0, 1.25, 1.5, 2.0], id: \.self) { z in
                        let isCur = abs(clip.transform.scale - z) < 0.04
                        Button(action: {
                            recordUndo()
                            project.clips[selectedClipIndex].transform.scale = z
                        }) {
                            Text(String(format: "%.1fx", z))
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .foregroundColor(isCur ? .white : .textSecondary)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(isCur ? Color.brandAccent : Color.elevatedSurface)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                    }
                }
            }

            Divider().background(Color.borderHairline)

            // 3. Rotation & Flip Controls
            HStack(spacing: 10) {
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
                    Label(clip.transform.flipH ? "Flipped H" : "Flip H", systemImage: "arrow.left.and.right.righttriangle.left.righttriangle.right")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(clip.transform.flipH ? .emeraldAccent : .textSecondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(clip.transform.flipH ? Color.emeraldAccent.opacity(0.15) : Color.elevatedSurface)
                        .clipShape(Capsule())
                }

                Button(action: {
                    recordUndo()
                    project.clips[selectedClipIndex].transform.flipV.toggle()
                }) {
                    Label(clip.transform.flipV ? "Flipped V" : "Flip V", systemImage: "arrow.up.and.down.righttriangle.up.righttriangle.down")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(clip.transform.flipV ? .emeraldAccent : .textSecondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(clip.transform.flipV ? Color.emeraldAccent.opacity(0.15) : Color.elevatedSurface)
                        .clipShape(Capsule())
                }
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
            playerModel.setup(with: clip.sourceUrl) { [weak playerModel] curMs in
                _ = playerModel
                self.updatePlayheadFromPlayback(sourceMs: curMs)
            }
        }
    }

    private func updatePlayheadFromPlayback(sourceMs: Int64) {
        guard let clip = selectedClip else { return }
        let clipStart = project.timelineStartTime(forClipIndex: selectedClipIndex)
        let timelineOffset = clip.mapSourceMsToTimelineOffset(sourceMs)
        let newPlayhead = clipStart + timelineOffset

        DispatchQueue.main.async {
            self.playheadMs = newPlayhead

            // Auto-advance to next clip if this clip finishes
            if timelineOffset >= clip.timelineDurationMs - 60 {
                if selectedClipIndex + 1 < project.clips.count {
                    selectedClipIndex += 1
                    syncPlayheadToPlayer()
                    let speed = Float(selectedClip?.speedConfig.speedMultiplier ?? 1.0)
                    playerModel.play(rate: speed)
                } else {
                    playerModel.pause()
                }
            }
        }
    }

    private func syncPlayheadToPlayer() {
        guard let clip = selectedClip else { return }
        let clipStart = project.timelineStartTime(forClipIndex: selectedClipIndex)
        let offsetMs = max(0, min(clip.timelineDurationMs, playheadMs - clipStart))
        let sourceMs = clip.mapTimelineOffsetToSourceMs(offsetMs)

        if playerModel.player.currentItem?.asset as? AVURLAsset == nil ||
           (playerModel.player.currentItem?.asset as? AVURLAsset)?.url != clip.sourceUrl {
            playerModel.setup(with: clip.sourceUrl) { [weak playerModel] curMs in
                _ = playerModel
                self.updatePlayheadFromPlayback(sourceMs: curMs)
            }
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
        isImportingMedia = true
        importStatusText = "Reading video from Camera Roll..."

        Task {
            do {
                if let movie = try await item.loadTransferable(type: MovieTransferable.self) {
                    await MainActor.run {
                        self.importStatusText = "Ingesting video into timeline..."
                    }

                    var rawUrl = movie.url
                    if await MKVRemuxEngine.shared.requiresRemuxing(url: rawUrl) {
                        await MainActor.run {
                            self.importStatusText = "Optimizing container for playback..."
                        }
                        if let remuxed = try? await MKVRemuxEngine.shared.remuxToMP4(sourceUrl: rawUrl, onProgress: { _, _ in }) {
                            rawUrl = remuxed
                        }
                    }

                    let ingestedUrl = ProjectStorageManager.shared.importMedia(from: rawUrl, to: project.id)

                    // Extract exact real video duration and track properties
                    let asset = AVURLAsset(url: ingestedUrl, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
                    var durMs: Int64 = 0

                    if let dur = try? await asset.load(.duration) {
                        let sec = CMTimeGetSeconds(dur)
                        if sec.isFinite && sec > 0 {
                            durMs = Int64(round(sec * 1000.0))
                        }
                    }

                    if durMs <= 0 {
                        let sec = CMTimeGetSeconds(asset.duration)
                        if sec.isFinite && sec > 0 {
                            durMs = Int64(round(sec * 1000.0))
                        }
                    }

                    if durMs <= 0 {
                        let info = try? await VideoEngine.shared.extractVideoInfo(from: ingestedUrl)
                        durMs = info?.durationMs ?? 3000
                    }

                    // Auto-detect aspect ratio for first clip if desired
                    if project.clips.isEmpty {
                        if let track = try? await asset.loadTracks(withMediaType: .video).first {
                            if let naturalSize = try? await track.load(.naturalSize),
                               let transform = try? await track.load(.preferredTransform) {
                                let isPortrait = abs(transform.b) == 1.0 && abs(transform.c) == 1.0
                                let w = isPortrait ? naturalSize.height : naturalSize.width
                                let h = isPortrait ? naturalSize.width : naturalSize.height
                                if w > 0 && h > 0 {
                                    if h > w * 1.2 {
                                        project.canvasAspectRatio = .ratio9x16
                                    } else if w > h * 1.2 {
                                        project.canvasAspectRatio = .ratio16x9
                                    }
                                }
                            }
                        }
                    }

                    let rawName = movie.url.lastPathComponent.replacingOccurrences(of: "picker_", with: "")
                    let clipName = rawName.isEmpty ? "Video Clip" : rawName

                    let newClip = EditorClip(
                        sourceUrl: ingestedUrl,
                        filename: clipName,
                        sourceDurationMs: durMs,
                        sourceInPointMs: 0,
                        sourceOutPointMs: durMs
                    )

                    await MainActor.run {
                        self.selectedPhotosItem = nil
                        self.recordUndo()
                        self.project.clips.append(newClip)
                        self.selectedClipIndex = self.project.clips.count - 1
                        self.playheadMs = 0
                        ProjectStorageManager.shared.saveProject(self.project)
                        self.syncPlayheadToPlayer()
                        self.isImportingMedia = false
                    }
                } else {
                    await MainActor.run {
                        self.selectedPhotosItem = nil
                        self.isImportingMedia = false
                    }
                }
            } catch {
                print("PhotosPicker load error: \(error)")
                await MainActor.run {
                    self.selectedPhotosItem = nil
                    self.isImportingMedia = false
                }
            }
        }
    }

    private func handleFileImporterResult(result: Result<[URL], Error>) {
        if case .success(let urls) = result, let url = urls.first {
            _ = url.startAccessingSecurityScopedResource()
            defer { url.stopAccessingSecurityScopedResource() }

            isImportingMedia = true
            importStatusText = "Ingesting video from Files..."

            let ingestedUrl = ProjectStorageManager.shared.importMedia(from: url, to: project.id)
            Task {
                let asset = AVURLAsset(url: ingestedUrl, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
                var durMs: Int64 = 0

                if let dur = try? await asset.load(.duration) {
                    let sec = CMTimeGetSeconds(dur)
                    if sec.isFinite && sec > 0 {
                        durMs = Int64(round(sec * 1000.0))
                    }
                }

                if durMs <= 0 {
                    let sec = CMTimeGetSeconds(asset.duration)
                    if sec.isFinite && sec > 0 {
                        durMs = Int64(round(sec * 1000.0))
                    }
                }

                if durMs <= 0 {
                    let info = try? await VideoEngine.shared.extractVideoInfo(from: ingestedUrl)
                    durMs = info?.durationMs ?? 3000
                }

                let newClip = EditorClip(
                    sourceUrl: ingestedUrl,
                    filename: url.lastPathComponent,
                    sourceDurationMs: durMs,
                    sourceInPointMs: 0,
                    sourceOutPointMs: durMs
                )

                DispatchQueue.main.async {
                    self.recordUndo()
                    self.project.clips.append(newClip)
                    self.selectedClipIndex = self.project.clips.count - 1
                    self.playheadMs = 0
                    ProjectStorageManager.shared.saveProject(self.project)
                    self.syncPlayheadToPlayer()
                    self.isImportingMedia = false
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

    private func formatSeconds(_ sec: Int) -> String {
        let m = sec / 60
        let s = sec % 60
        return String(format: "%02d:%02d", m, s)
    }

    private func computeCanvasDimensions(ratio: CGFloat, maxW: CGFloat, maxH: CGFloat) -> CGSize {
        if ratio < 1.0 {
            let h = maxH
            let w = min(maxW, h * ratio)
            return CGSize(width: w, height: h)
        } else {
            let w = min(maxW, maxH * ratio)
            let h = min(maxH, w / ratio)
            return CGSize(width: w, height: h)
        }
    }
}

// MARK: - Filmstrip Thumbnail Strip
struct ClipThumbnailStripView: View {
    let clip: EditorClip
    let width: CGFloat
    @State private var thumbnails: [UIImage] = []

    var body: some View {
        HStack(spacing: 0) {
            if thumbnails.isEmpty {
                LinearGradient(
                    colors: [Color.surfaceCard, Color.elevatedSurface],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .overlay(
                    HStack(spacing: 4) {
                        Image(systemName: "film")
                            .font(.system(size: 11))
                            .foregroundColor(.textTertiary)
                        Text("Decoding frames...")
                            .font(.system(size: 9))
                            .foregroundColor(.textTertiary)
                    }
                )
            } else {
                ForEach(0..<thumbnails.count, id: \.self) { i in
                    Image(uiImage: thumbnails[i])
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: max(15, width / CGFloat(thumbnails.count)), height: 62)
                        .clipped()
                }
            }
        }
        .onAppear {
            loadThumbnails()
        }
        .onChange(of: clip.id) { _ in loadThumbnails() }
        .onChange(of: clip.sourceInPointMs) { _ in loadThumbnails() }
        .onChange(of: clip.sourceOutPointMs) { _ in loadThumbnails() }
        .onChange(of: width) { _ in loadThumbnails() }
    }

    private func loadThumbnails() {
        let count = max(3, min(10, Int(width / 32.0)))
        ThumbnailCacheService.shared.generateThumbnails(for: clip, count: count) { imgs in
            if !imgs.isEmpty {
                self.thumbnails = imgs
            }
        }
    }
}

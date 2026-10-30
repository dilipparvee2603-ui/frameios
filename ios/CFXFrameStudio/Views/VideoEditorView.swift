import SwiftUI
import AVFoundation
import PhotosUI
import UniformTypeIdentifiers

// MARK: - Active Tool Panel Enum
enum EditorToolPanel: String, CaseIterable, Identifiable {
    case trim = "Trim"
    case speed = "Speed"
    case transform = "Transform"
    case color = "Color"
    case audio = "Audio"
    var id: String { rawValue }

    var icon: String {
        switch self {
        case .trim: return "arrow.left.and.right.righttriangle.left.righttriangle.right.fill"
        case .speed: return "gauge.with.dots.needle.bottom.0percent"
        case .transform: return "crop.rotate"
        case .color: return "slider.horizontal.3"
        case .audio: return "speaker.wave.2.fill"
        }
    }
}

// MARK: - Dedicated Preview Render State for Smooth 60/120Hz Animation
final class PreviewRenderState: ObservableObject {
    @Published var scale: Double = 1.0
    @Published var offsetX: Double = 0.0
    @Published var offsetY: Double = 0.0
    @Published var rotationDegrees: Double = 0.0
    @Published var opacity: Double = 1.0
    @Published var brightness: Double = 0.0
    @Published var contrast: Double = 1.0
    @Published var saturation: Double = 1.0

    func update(
        scale: Double,
        offsetX: Double,
        offsetY: Double,
        rotationDegrees: Double,
        opacity: Double,
        brightness: Double = 0.0,
        contrast: Double = 1.0,
        saturation: Double = 1.0
    ) {
        if abs(self.scale - scale) > 0.0001 ||
           abs(self.offsetX - offsetX) > 0.01 ||
           abs(self.offsetY - offsetY) > 0.01 ||
           abs(self.rotationDegrees - rotationDegrees) > 0.01 ||
           abs(self.opacity - opacity) > 0.001 ||
           abs(self.brightness - brightness) > 0.005 ||
           abs(self.contrast - contrast) > 0.005 ||
           abs(self.saturation - saturation) > 0.005 {
            self.scale = scale
            self.offsetX = offsetX
            self.offsetY = offsetY
            self.rotationDegrees = rotationDegrees
            self.opacity = opacity
            self.brightness = brightness
            self.contrast = contrast
            self.saturation = saturation
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
    @StateObject private var previewState = PreviewRenderState()

    // Timeline & Selection State
    @State private var selectedClipIndex: Int = 0
    @State private var selectedKeyframeId: UUID? = nil
    @State private var playheadMs: Int64 = 0
    @State private var timelineZoom: Double = 1.0 // 1.0 = normal, 2.0 = zoomed in
    @State private var activeToolPanel: EditorToolPanel? = nil
    @State private var isAdvancingClip: Bool = false
    @State private var dragInitialOffset: CGSize? = nil
    @State private var dragInitialScale: Double? = nil
    @State private var dragInitialRotation: Double? = nil
    @State private var dragTrimInitialInMs: Int64? = nil
    @State private var dragTrimInitialOutMs: Int64? = nil
    @State private var dragPlayheadInitialMs: Int64? = nil
    @State private var dragKeyframeInitialTimeMs: Int64? = nil
    @State private var selectedKeyframeEasing: KeyframeEasing = .easeInOut
    @State private var lastTimelineScrollTime: TimeInterval = 0

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

                // 2.5 InShot-Style Keyframe Toolbar
                inshotKeyframeToolbar
                    .padding(.horizontal, 16)
                    .padding(.vertical, 2)

                // 3. Playback Transport & Timecode Bar
                transportBar
                    .padding(.horizontal, 16)
                    .padding(.vertical, 4)

                // 4. Horizontal Multi-Clip Timeline (Video + Audio Tracks)
                timelineSection
                    .frame(height: 148)
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
            playerModel.periodicTickHandler = { curMs in
                self.updatePlayheadFromPlayback(sourceMs: curMs)
            }
            playerModel.onDisplayFrame = { currentSourceSec in
                guard self.playerModel.isPlaying else { return }
                guard self.selectedClipIndex < self.project.clips.count else { return }
                let clip = self.project.clips[self.selectedClipIndex]
                let currentSourceMs = currentSourceSec * 1000.0
                let timelineOffset = clip.mapSourceMsToTimelineOffset(currentSourceMs)
                let anim = clip.evaluatedTransform(at: timelineOffset)
                let animColor = clip.evaluatedColor(at: timelineOffset)
                let rot = clip.hasKeyframes() ? anim.rotationDegrees : Double(clip.transform.rotation.rawValue)
                self.previewState.update(
                    scale: anim.scale,
                    offsetX: anim.offsetX,
                    offsetY: anim.offsetY,
                    rotationDegrees: rot,
                    opacity: anim.opacity,
                    brightness: animColor.brightness,
                    contrast: animColor.contrast,
                    saturation: animColor.saturation
                )
            }
            playerModel.ensureTimeObserver()
            setupInitialProject()
            syncPreviewStateWithPlayhead()
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
        .sheet(isPresented: $showExportModal) {
            ExportSettingsSheet(
                project: project,
                aspectRatio: project.canvasAspectRatio,
                onStartExport: { config in
                    showExportModal = false
                    startProjectExport(config: config)
                }
            )
        }
        .alert("Export Error", isPresented: Binding(
            get: { exportErrorMessage != nil },
            set: { if !$0 { exportErrorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { exportErrorMessage = nil }
        } message: {
            if let msg = exportErrorMessage {
                Text(msg)
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
        HStack(spacing: 6) {
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
                HStack(spacing: 3) {
                    Text(project.title)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Image(systemName: "pencil")
                        .font(.system(size: 9))
                        .foregroundColor(.textTertiary)
                }
                .frame(maxWidth: 80, alignment: .leading)
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
                .frame(height: 32)
                .background(Color.skyAccent.opacity(0.14))
                .clipShape(Capsule())
            }
            .fixedSize()
            .layoutPriority(2)

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

            // Export Button (Fixed non-wrapping capsule)
            Button(action: {
                if !project.clips.isEmpty {
                    showExportModal = true
                }
            }) {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 11, weight: .bold))
                    Text("Export")
                        .font(.system(size: 11, weight: .heavy))
                        .lineLimit(1)
                }
                .foregroundColor(.white)
                .padding(.horizontal, 11)
                .frame(height: 32)
                .background(project.clips.isEmpty ? AnyView(Color.surfaceCard) : AnyView(LinearGradient.brandGradient))
                .clipShape(Capsule())
                .overlay(
                    Capsule().stroke(project.clips.isEmpty ? Color.borderHairline : Color.clear, lineWidth: 1)
                )
            }
            .disabled(project.clips.isEmpty)
            .fixedSize()
            .layoutPriority(10)
            .disabled(project.clips.isEmpty || isExporting)
        }
        .padding(.horizontal, 10)
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
                    let clipStart = project.timelineStartTime(forClipIndex: selectedClipIndex)
                    let clipLocalMs = Double(max(0, min(clip.timelineDurationMs, playheadMs - clipStart)))
                    let animColor = clip.evaluatedColor(at: Int64(clipLocalMs))

                    let curScale = playerModel.isPlaying ? previewState.scale : clip.evaluatedTransform(at: clipLocalMs).scale
                    let curX = playerModel.isPlaying ? previewState.offsetX : clip.evaluatedTransform(at: clipLocalMs).offsetX
                    let curY = playerModel.isPlaying ? previewState.offsetY : clip.evaluatedTransform(at: clipLocalMs).offsetY
                    let curRot = playerModel.isPlaying
                        ? previewState.rotationDegrees
                        : (clip.hasKeyframes() ? clip.evaluatedTransform(at: clipLocalMs).rotationDegrees : Double(clip.transform.rotation.rawValue))
                    let curOp = playerModel.isPlaying ? previewState.opacity : clip.evaluatedTransform(at: clipLocalMs).opacity
                    let curBrightness = playerModel.isPlaying ? previewState.brightness : animColor.brightness
                    let curContrast = playerModel.isPlaying ? previewState.contrast : animColor.contrast
                    let curSaturation = playerModel.isPlaying ? previewState.saturation : animColor.saturation

                    let ratio: CGFloat = project.canvasAspectRatio.ratioValue ?? (9.0 / 16.0)
                    let canvasSize = computeCanvasDimensions(ratio: ratio, maxW: max(80, availW - 16), maxH: max(80, availH - 16))

                    // Canvas Container Box (Accurately sized to chosen Aspect Ratio)
                    ZStack {
                        Color.black

                        VideoPlayerView(player: playerModel.player)
                            .scaleEffect(curScale)
                            .offset(x: curX, y: curY)
                            .rotationEffect(Angle(degrees: curRot))
                            .scaleEffect(x: clip.transform.flipH ? -1 : 1, y: clip.transform.flipV ? -1 : 1)
                            .opacity(curOp)
                            .brightness(curBrightness)
                            .contrast(curContrast)
                            .saturation(curSaturation)
                    }
                    .frame(width: canvasSize.width, height: canvasSize.height)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 2)
                            .onChanged { val in
                                guard selectedClipIndex < project.clips.count else { return }
                                if dragInitialOffset == nil {
                                    recordUndo()
                                    dragInitialOffset = CGSize(
                                        width: curX,
                                        height: curY
                                    )
                                }
                                if let initial = dragInitialOffset {
                                    let newX = initial.width + val.translation.width
                                    let newY = initial.height + val.translation.height
                                    previewState.update(scale: curScale, offsetX: newX, offsetY: newY, rotationDegrees: curRot, opacity: curOp, brightness: curBrightness, contrast: curContrast, saturation: curSaturation)
                                    if clip.hasKeyframes() {
                                        let kf = project.clips[selectedClipIndex].addOrUpdateKeyframe(
                                            at: Int64(clipLocalMs),
                                            positionX: newX,
                                            positionY: newY,
                                            easing: selectedKeyframeEasing
                                        )
                                        selectedKeyframeId = kf.id
                                    } else {
                                        project.clips[selectedClipIndex].transform.offsetX = newX
                                        project.clips[selectedClipIndex].transform.offsetY = newY
                                    }
                                }
                            }
                            .onEnded { _ in
                                dragInitialOffset = nil
                                ProjectStorageManager.shared.saveProject(project)
                            }
                    )
                    .simultaneousGesture(
                        MagnificationGesture()
                            .onChanged { scaleVal in
                                guard selectedClipIndex < project.clips.count else { return }
                                if dragInitialScale == nil {
                                    recordUndo()
                                    dragInitialScale = curScale
                                }
                                if let initial = dragInitialScale {
                                    let newScale = max(0.2, min(5.0, initial * Double(scaleVal)))
                                    previewState.update(scale: newScale, offsetX: curX, offsetY: curY, rotationDegrees: curRot, opacity: curOp, brightness: curBrightness, contrast: curContrast, saturation: curSaturation)
                                    if clip.hasKeyframes() {
                                        let kf = project.clips[selectedClipIndex].addOrUpdateKeyframe(
                                            at: Int64(clipLocalMs),
                                            scale: newScale,
                                            easing: selectedKeyframeEasing
                                        )
                                        selectedKeyframeId = kf.id
                                    } else {
                                        project.clips[selectedClipIndex].transform.scale = newScale
                                    }
                                }
                            }
                            .onEnded { _ in
                                dragInitialScale = nil
                                ProjectStorageManager.shared.saveProject(project)
                            }
                    )
                    .simultaneousGesture(
                        RotationGesture()
                            .onChanged { angle in
                                guard selectedClipIndex < project.clips.count else { return }
                                if dragInitialRotation == nil {
                                    recordUndo()
                                    dragInitialRotation = curRot
                                }
                                if let initial = dragInitialRotation {
                                    let newRot = initial + angle.degrees
                                    previewState.update(scale: curScale, offsetX: curX, offsetY: curY, rotationDegrees: newRot, opacity: curOp, brightness: curBrightness, contrast: curContrast, saturation: curSaturation)
                                    if clip.hasKeyframes() {
                                        let kf = project.clips[selectedClipIndex].addOrUpdateKeyframe(
                                            at: Int64(clipLocalMs),
                                            rotationDegrees: newRot,
                                            easing: selectedKeyframeEasing
                                        )
                                        selectedKeyframeId = kf.id
                                    }
                                }
                            }
                            .onEnded { _ in
                                dragInitialRotation = nil
                                ProjectStorageManager.shared.saveProject(project)
                            }
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(Color.skyAccent.opacity(0.55), lineWidth: 1.5)
                    )
                    .shadow(color: Color.black.opacity(0.6), radius: 6)

                    // Canvas Overlays (Aspect Ratio + Quick Mute Button on Video Player)
                    VStack {
                        HStack {
                            Text(project.canvasAspectRatio.badgeText)
                                .font(.system(size: 9.5, weight: .heavy, design: .monospaced))
                                .foregroundColor(.skyAccent)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3)
                                .background(Color.black.opacity(0.75))
                                .clipShape(RoundedRectangle(cornerRadius: 4))

                            Spacer()

                            // Quick Mute Button directly on the Video Player
                            Button(action: {
                                recordUndo()
                                project.clips[selectedClipIndex].isMuted.toggle()
                                playerModel.player.isMuted = project.clips[selectedClipIndex].isMuted
                            }) {
                                HStack(spacing: 4) {
                                    Image(systemName: clip.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                                        .font(.system(size: 10, weight: .bold))
                                    Text(clip.isMuted ? "MUTED" : "MUTE")
                                        .font(.system(size: 9, weight: .heavy, design: .monospaced))
                                }
                                .foregroundColor(clip.isMuted ? .brandAccent : .emeraldAccent)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Color.black.opacity(0.8))
                                .clipShape(Capsule())
                                .overlay(
                                    Capsule().stroke(clip.isMuted ? Color.brandAccent.opacity(0.7) : Color.emeraldAccent.opacity(0.7), lineWidth: 1)
                                )
                            }
                        }
                        .padding(10)

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
            // Jump to Start or Previous Clip
            Button(action: {
                let curClipStart = project.timelineStartTime(forClipIndex: selectedClipIndex)
                if playheadMs > curClipStart + 400 {
                    playheadMs = curClipStart
                } else if selectedClipIndex > 0 {
                    selectedClipIndex -= 1
                    playheadMs = project.timelineStartTime(forClipIndex: selectedClipIndex)
                } else {
                    playheadMs = 0
                }
                syncPlayheadToPlayer(preservePlayback: playerModel.isPlaying)
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
                    guard let clip = selectedClip else { return }
                    let clipStart = project.timelineStartTime(forClipIndex: selectedClipIndex)

                    // Loop back to start if at the end of the project timeline
                    if playheadMs >= project.totalTimelineDurationMs - 50 {
                        selectedClipIndex = 0
                        playheadMs = 0
                        syncPlayheadToPlayer(preservePlayback: false)
                    } else {
                        // Ensure player is accurately located within trimmed bounds
                        let offsetMs = max(0, min(clip.timelineDurationMs, playheadMs - clipStart))
                        let curSrcMs = clip.mapTimelineOffsetToSourceMs(offsetMs)
                        if curSrcMs < clip.sourceInPointMs || curSrcMs >= clip.sourceOutPointMs - 40 {
                            playheadMs = clipStart
                            playerModel.seek(to: clip.sourceInPointMs, preservePlaybackState: true)
                        } else {
                            playerModel.seek(to: curSrcMs, preservePlaybackState: true)
                        }
                    }

                    playerModel.player.isMuted = clip.isMuted
                    let speed = Float(clip.speedConfig.speedMultiplier)
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

            // Jump to Next Clip or End of Timeline
            Button(action: {
                if selectedClipIndex + 1 < project.clips.count {
                    selectedClipIndex += 1
                    playheadMs = project.timelineStartTime(forClipIndex: selectedClipIndex)
                } else {
                    playheadMs = project.totalTimelineDurationMs
                }
                syncPlayheadToPlayer(preservePlayback: playerModel.isPlaying)
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
                            // Dynamic Adaptive Time Ruler (LibreCuts TimeRulerView)
                            DynamicTimeRulerView(
                                durationMs: project.totalTimelineDurationMs,
                                pointsPerSecond: pointsPerSecond,
                                width: max(totalClipsWidth + 120, UIScreen.main.bounds.width),
                                onSeek: { seekMs in
                                    playheadMs = seekMs
                                    if let activeIdx = project.clipIndex(at: playheadMs), activeIdx != selectedClipIndex {
                                        selectedClipIndex = activeIdx
                                    }
                                    syncPlayheadToPlayer(preservePlayback: playerModel.isPlaying)
                                }
                            )
                            .padding(.leading, leadPad)

                            // Track 1: Clips Horizontal Row
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

                            // Track 2: Dedicated Audio Layer Row
                            HStack(spacing: 4) {
                                ForEach(0..<project.clips.count, id: \.self) { idx in
                                    let clip = project.clips[idx]
                                    let isSelected = idx == selectedClipIndex
                                    let clipWidth = max(60, (CGFloat(clip.timelineDurationMs) / 1000.0) * pointsPerSecond)

                                    audioTrackItem(clip: clip, index: idx, isSelected: isSelected, width: clipWidth)
                                }

                                Spacer()
                                    .frame(width: 240)
                            }
                            .padding(.leading, leadPad)
                        }
                        .frame(width: max(totalContentWidth, UIScreen.main.bounds.width + 120), alignment: .topLeading)

                        // CapCut & LibreCuts Styled Playhead Needle (CustomVideoSeeker)
                        let playheadX = leadPad + (CGFloat(playheadMs) / 1000.0 * pointsPerSecond)
                        ZStack(alignment: .top) {
                            // Touch Target (44pt wide x 136pt tall)
                            Color.white.opacity(0.001)
                                .frame(width: 44, height: 136)
                                .contentShape(Rectangle())

                            // Subtle drop shadow for vertical stem
                            Rectangle()
                                .fill(Color.black.opacity(0.45))
                                .frame(width: 3, height: 124)
                                .offset(x: 1, y: 16)
                                .allowsHitTesting(false)

                            // Primary Needle Stem
                            Rectangle()
                                .fill(Color.brandAccent)
                                .frame(width: 2.0, height: 124)
                                .offset(y: 16)
                                .shadow(color: Color.brandAccent.opacity(0.5), radius: 2)
                                .allowsHitTesting(false)

                            // Teardrop / Shield Playhead Top Handle (LibreCuts CapCut-style)
                            VStack(spacing: 0) {
                                ZStack {
                                    // Glow effect
                                    RoundedRectangle(cornerRadius: 3)
                                        .fill(Color.brandAccent.opacity(0.35))
                                        .frame(width: 18, height: 16)
                                        .blur(radius: 2)

                                    // Shield Head
                                    RoundedRectangle(cornerRadius: 3)
                                        .fill(Color.brandAccent)
                                        .frame(width: 14, height: 14)
                                        .overlay(
                                            Circle()
                                                .fill(Color.white)
                                                .frame(width: 4, height: 4)
                                        )
                                        .shadow(color: Color.black.opacity(0.5), radius: 2, y: 1)
                                }

                                TrianglePointer()
                                    .fill(Color.brandAccent)
                                    .frame(width: 8, height: 5)
                            }
                            .allowsHitTesting(false)
                        }
                        .frame(width: 44, height: 136)
                        .contentShape(Rectangle())
                        .gesture(
                            DragGesture(minimumDistance: 1)
                                .onChanged { value in
                                    if dragPlayheadInitialMs == nil {
                                        dragPlayheadInitialMs = playheadMs
                                        playerModel.pause()
                                    }
                                    if let initialMs = dragPlayheadInitialMs {
                                        let deltaMs = Int64(round(Double(value.translation.width) / Double(pointsPerSecond) * 1000.0))
                                        var newMs = max(0, min(project.totalTimelineDurationMs, initialMs + deltaMs))

                                        // Magnetic Keyframe & Clip Cut Snapping (LibreCuts style)
                                        if let activeIdx = project.clipIndex(at: newMs) {
                                            let activeClip = project.clips[activeIdx]
                                            let clipStart = project.timelineStartTime(forClipIndex: activeIdx)
                                            let localMs = newMs - clipStart
                                            if let snapKf = activeClip.sortedKeyframes.first(where: { abs($0.timeMs - localMs) <= 120 }) {
                                                newMs = clipStart + snapKf.timeMs
                                            }
                                        }

                                        playheadMs = newMs

                                        // Dynamically switch active clip if scrubbing crosses clip boundaries
                                        if let activeIdx = project.clipIndex(at: playheadMs), activeIdx != selectedClipIndex {
                                            selectedClipIndex = activeIdx
                                        }
                                        syncPlayheadToPlayer(preservePlayback: false)
                                    }
                                }
                                .onEnded { _ in
                                    dragPlayheadInitialMs = nil
                                }
                        )
                        .offset(x: playheadX - 22, y: 0)
                        .id("PLAYHEAD_NEEDLE")
                    }
                    .frame(height: 148)
                }
            }
            .onChange(of: playheadMs) { _ in
                if playerModel.isPlaying {
                    let now = Date().timeIntervalSince1970
                    if now - lastTimelineScrollTime > 0.25 {
                        lastTimelineScrollTime = now
                        proxy.scrollTo("PLAYHEAD_NEEDLE", anchor: .center)
                    }
                } else {
                    syncPreviewStateWithPlayhead()
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

            // Diamond Keyframe Markers overlay on clip track (Tappable & Draggable along track)
            if !clip.keyframes.isEmpty {
                ZStack(alignment: .leading) {
                    ForEach(clip.sortedKeyframes) { kf in
                        let kfRatio = CGFloat(max(0, min(clip.timelineDurationMs, kf.timeMs))) / CGFloat(max(1, clip.timelineDurationMs))
                        let markerX = max(4, min(width - 12, kfRatio * width - 4))
                        let clipStart = project.timelineStartTime(forClipIndex: index)
                        let isKeyframeActive = selectedKeyframeId == kf.id || abs((clipStart + kf.timeMs) - playheadMs) <= 60

                        ZStack {
                            Image(systemName: "rhombus.fill")
                                .font(.system(size: isKeyframeActive ? 14 : 9, weight: .heavy))
                                .foregroundColor(isKeyframeActive ? Color.amberAccent : Color.white.opacity(0.85))
                                .shadow(color: Color.black, radius: 2)
                        }
                        .frame(width: 24, height: 28)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            selectedClipIndex = index
                            selectedKeyframeId = kf.id
                            playheadMs = clipStart + kf.timeMs
                            syncPlayheadToPlayer(preservePlayback: playerModel.isPlaying)
                        }
                        .gesture(
                            DragGesture(minimumDistance: 3)
                                .onChanged { val in
                                    if dragKeyframeInitialTimeMs == nil {
                                        recordUndo()
                                        selectedClipIndex = index
                                        selectedKeyframeId = kf.id
                                        dragKeyframeInitialTimeMs = kf.timeMs
                                    }
                                    guard let initialMs = dragKeyframeInitialTimeMs else { return }
                                    let deltaRatio = val.translation.width / max(1, width)
                                    let deltaMs = Int64(deltaRatio * CGFloat(clip.timelineDurationMs))
                                    let targetTimeMs = max(0, min(clip.timelineDurationMs, initialMs + deltaMs))
                                    project.clips[index].moveKeyframe(id: kf.id, newTimeMs: targetTimeMs)
                                    playheadMs = clipStart + targetTimeMs
                                    syncPreviewStateWithPlayhead()
                                    syncPlayheadToPlayer(preservePlayback: false)
                                }
                                .onEnded { _ in
                                    dragKeyframeInitialTimeMs = nil
                                    ProjectStorageManager.shared.saveProject(project)
                                }
                        )
                        .offset(x: markerX - 8, y: 12)
                    }
                }
            }

            // Interactive Draggable Trim Handles when selected
            if isSelected {
                HStack(spacing: 0) {
                    // Left Trim Handle (In-Point)
                    HStack(spacing: 0) {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color.brandAccent)
                            .frame(width: 8, height: 46)
                            .overlay(
                                Image(systemName: "chevron.compact.left")
                                    .font(.system(size: 8, weight: .heavy))
                                    .foregroundColor(.white)
                            )
                        Spacer()
                    }
                    .frame(width: 24, height: 58)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 1)
                            .onChanged { val in
                                if dragTrimInitialInMs == nil {
                                    recordUndo()
                                    dragTrimInitialInMs = clip.sourceInPointMs
                                    playerModel.pause()
                                }
                                if let initialIn = dragTrimInitialInMs {
                                    let deltaMs = Int64(round(Double(val.translation.width) / Double(pointsPerSecond) * 1000.0 * clip.speedConfig.speedMultiplier))
                                    let newInMs = max(0, min(clip.sourceOutPointMs - 100, initialIn + deltaMs))
                                    project.clips[index].sourceInPointMs = newInMs
                                    playerModel.setPlaybackBounds(inMs: newInMs, outMs: clip.sourceOutPointMs)
                                    playerModel.seek(to: newInMs, preservePlaybackState: false)
                                    let clipStart = project.timelineStartTime(forClipIndex: index)
                                    playheadMs = clipStart
                                }
                            }
                            .onEnded { _ in
                                dragTrimInitialInMs = nil
                                ProjectStorageManager.shared.saveProject(project)
                            }
                    )

                    Spacer()

                    // Right Trim Handle (Out-Point)
                    HStack(spacing: 0) {
                        Spacer()
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color.brandAccent)
                            .frame(width: 8, height: 46)
                            .overlay(
                                Image(systemName: "chevron.compact.right")
                                    .font(.system(size: 8, weight: .heavy))
                                    .foregroundColor(.white)
                            )
                    }
                    .frame(width: 24, height: 58)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 1)
                            .onChanged { val in
                                if dragTrimInitialOutMs == nil {
                                    recordUndo()
                                    dragTrimInitialOutMs = clip.sourceOutPointMs
                                    playerModel.pause()
                                }
                                if let initialOut = dragTrimInitialOutMs {
                                    let deltaMs = Int64(round(Double(val.translation.width) / Double(pointsPerSecond) * 1000.0 * clip.speedConfig.speedMultiplier))
                                    let newOutMs = max(clip.sourceInPointMs + 100, min(clip.sourceDurationMs, initialOut + deltaMs))
                                    project.clips[index].sourceOutPointMs = newOutMs
                                    playerModel.setPlaybackBounds(inMs: clip.sourceInPointMs, outMs: newOutMs)
                                    playerModel.seek(to: newOutMs, preservePlaybackState: false)
                                    let clipStart = project.timelineStartTime(forClipIndex: index)
                                    playheadMs = clipStart + project.clips[index].timelineDurationMs
                                }
                            }
                            .onEnded { _ in
                                dragTrimInitialOutMs = nil
                                ProjectStorageManager.shared.saveProject(project)
                            }
                    )
                }
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

    @ViewBuilder
    private func audioTrackItem(clip: EditorClip, index: Int, isSelected: Bool, width: CGFloat) -> some View {
        HStack(spacing: 5) {
            // Mute / Unmute Quick Tap Icon
            Button(action: {
                recordUndo()
                project.clips[index].isMuted.toggle()
                if index == selectedClipIndex {
                    playerModel.player.isMuted = project.clips[index].isMuted
                }
            }) {
                Image(systemName: clip.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundColor(clip.isMuted ? .brandAccent : .emeraldAccent)
                    .frame(width: 18, height: 18)
                    .background(Color.black.opacity(0.5))
                    .clipShape(Circle())
            }

            // Real Audio Waveform Visualization from LibreCuts Architecture
            ClipAudioWaveformView(clip: clip, width: max(20, width - 68), isSelected: isSelected)

            Spacer(minLength: 0)

            // Volume indicator badge
            Text("\(Int(round(clip.volume * 100)))%")
                .font(.system(size: 8, weight: .bold, design: .monospaced))
                .foregroundColor(clip.isMuted ? .textTertiary : .emeraldAccent)
                .padding(.trailing, 2)
        }
        .padding(.horizontal, 4)
        .frame(width: width, height: 26)
        .background(
            isSelected
                ? Color.emeraldAccent.opacity(0.18)
                : Color.surfaceCard.opacity(0.9)
        )
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(isSelected ? Color.emeraldAccent : Color.borderHairline, lineWidth: isSelected ? 1.5 : 0.8)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            selectedClipIndex = index
            activeToolPanel = .audio
            let startMs = project.timelineStartTime(forClipIndex: index)
            playheadMs = startMs
            syncPlayheadToPlayer(preservePlayback: playerModel.isPlaying)
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
                    let clipStart = project.timelineStartTime(forClipIndex: selectedClipIndex)
                    let curSrcMs = clip.mapTimelineOffsetToSourceMs(playheadMs - clipStart)
                    if curSrcMs < clip.sourceOutPointMs - 100 {
                        project.clips[selectedClipIndex].sourceInPointMs = max(0, curSrcMs)
                        playheadMs = clipStart
                        syncPlayheadToPlayer(preservePlayback: false)
                        ProjectStorageManager.shared.saveProject(project)
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
                    let clipStart = project.timelineStartTime(forClipIndex: selectedClipIndex)
                    let curSrcMs = clip.mapTimelineOffsetToSourceMs(playheadMs - clipStart)
                    if curSrcMs > clip.sourceInPointMs + 100 {
                        project.clips[selectedClipIndex].sourceOutPointMs = min(clip.sourceDurationMs, curSrcMs)
                        playheadMs = clipStart
                        syncPlayheadToPlayer(preservePlayback: false)
                        ProjectStorageManager.shared.saveProject(project)
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
                    let clipStart = project.timelineStartTime(forClipIndex: selectedClipIndex)
                    project.clips[selectedClipIndex].sourceInPointMs = 0
                    project.clips[selectedClipIndex].sourceOutPointMs = clip.sourceDurationMs
                    playheadMs = clipStart
                    syncPlayheadToPlayer(preservePlayback: false)
                    ProjectStorageManager.shared.saveProject(project)
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

    // MARK: - InShot-Style Keyframe Toolbar
    @ViewBuilder
    private var inshotKeyframeToolbar: some View {
        if let clip = selectedClip {
            let clipStart = project.timelineStartTime(forClipIndex: selectedClipIndex)
            let clipLocalMs = max(0, min(clip.timelineDurationMs, playheadMs - clipStart))
            let currentKf: ClipKeyframe? = {
                if let id = selectedKeyframeId, let kf = clip.keyframe(byId: id), abs(kf.timeMs - clipLocalMs) <= 60 {
                    return kf
                }
                return clip.keyframe(near: clipLocalMs, toleranceMs: 60)
            }()
            let prevMs = clip.previousKeyframeTime(from: clipLocalMs)
            let nextMs = clip.nextKeyframeTime(from: clipLocalMs)
            let hasKeyframeAtPlayhead = currentKf != nil

            HStack(spacing: 8) {
                // Keyframe Label & Count Indicator
                HStack(spacing: 4) {
                    Image(systemName: "rhombus.fill")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(hasKeyframeAtPlayhead ? .amberAccent : .textSecondary)
                    Text("KEYFRAME")
                        .font(.system(size: 9.5, weight: .heavy, design: .monospaced))
                        .foregroundColor(hasKeyframeAtPlayhead ? .amberAccent : .textSecondary)

                    if !clip.keyframes.isEmpty {
                        Text("\(clip.keyframes.count)")
                            .font(.system(size: 8.5, weight: .heavy, design: .monospaced))
                            .foregroundColor(.white)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.amberAccent.opacity(0.35))
                            .clipShape(Capsule())
                    }
                }

                Spacer(minLength: 4)

                // 1. Previous Keyframe Jump Button
                Button(action: {
                    if let prev = prevMs {
                        playheadMs = clipStart + prev
                        if let prevKf = clip.keyframe(near: prev, toleranceMs: 5) {
                            selectedKeyframeId = prevKf.id
                        }
                        syncPlayheadToPlayer(preservePlayback: playerModel.isPlaying)
                    }
                }) {
                    HStack(spacing: 2) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 8, weight: .bold))
                        Image(systemName: "rhombus.fill")
                            .font(.system(size: 9, weight: .bold))
                    }
                    .foregroundColor(prevMs != nil ? .textPrimary : .textMuted)
                    .frame(width: 32, height: 26)
                    .background(Color.surfaceCard)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .disabled(prevMs == nil)

                // 2. Add / Delete Keyframe Diamond Button (InShot style)
                Button(action: {
                    recordUndo()
                    if let kf = currentKf {
                        project.clips[selectedClipIndex].removeKeyframe(byId: kf.id)
                        selectedKeyframeId = nil
                    } else {
                        let curTransform = clip.evaluatedTransform(at: clipLocalMs)
                        let curColor = clip.evaluatedColor(at: clipLocalMs)
                        let newKf = project.clips[selectedClipIndex].addOrUpdateKeyframe(
                            at: clipLocalMs,
                            positionX: curTransform.offsetX,
                            positionY: curTransform.offsetY,
                            scale: curTransform.scale,
                            rotationDegrees: curTransform.rotationDegrees,
                            opacity: curTransform.opacity,
                            brightness: curColor.brightness,
                            contrast: curColor.contrast,
                            saturation: curColor.saturation,
                            easing: selectedKeyframeEasing
                        )
                        selectedKeyframeId = newKf.id
                    }
                    syncPreviewStateWithPlayhead()
                    ProjectStorageManager.shared.saveProject(project)
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: hasKeyframeAtPlayhead ? "minus.diamond.fill" : "plus.diamond.fill")
                            .font(.system(size: 11, weight: .bold))
                        Text(hasKeyframeAtPlayhead ? "Delete" : "Add Keyframe")
                            .font(.system(size: 10, weight: .bold))
                    }
                    .foregroundColor(hasKeyframeAtPlayhead ? .white : .brandAccent)
                    .padding(.horizontal, 9)
                    .frame(height: 26)
                    .background(hasKeyframeAtPlayhead ? Color.brandAccent : Color.brandAccent.opacity(0.14))
                    .clipShape(Capsule())
                    .overlay(Capsule().stroke(Color.brandAccent.opacity(0.55), lineWidth: 1))
                }

                // 3. Next Keyframe Jump Button
                Button(action: {
                    if let next = nextMs {
                        playheadMs = clipStart + next
                        if let nextKf = clip.keyframe(near: next, toleranceMs: 5) {
                            selectedKeyframeId = nextKf.id
                        }
                        syncPlayheadToPlayer(preservePlayback: playerModel.isPlaying)
                    }
                }) {
                    HStack(spacing: 2) {
                        Image(systemName: "rhombus.fill")
                            .font(.system(size: 9, weight: .bold))
                        Image(systemName: "chevron.right")
                            .font(.system(size: 8, weight: .bold))
                    }
                    .foregroundColor(nextMs != nil ? .textPrimary : .textMuted)
                    .frame(width: 32, height: 26)
                    .background(Color.surfaceCard)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .disabled(nextMs == nil)

                // 4. Easing Curve Selector Menu (Linear, Ease-In, Ease-Out, Ease-In-Out)
                Menu {
                    ForEach(KeyframeEasing.allCases) { easing in
                        Button(action: {
                            recordUndo()
                            selectedKeyframeEasing = easing
                            if let kf = currentKf {
                                project.clips[selectedClipIndex].addOrUpdateKeyframe(id: kf.id, at: kf.timeMs, easing: easing)
                                ProjectStorageManager.shared.saveProject(project)
                            }
                        }) {
                            HStack {
                                Text(easing.rawValue)
                                if (currentKf?.easing ?? selectedKeyframeEasing) == easing {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "waveform.path")
                            .font(.system(size: 9, weight: .bold))
                        Text((currentKf?.easing ?? selectedKeyframeEasing).rawValue)
                            .font(.system(size: 9.5, weight: .heavy))
                            .lineLimit(1)
                    }
                    .foregroundColor(.skyAccent)
                    .padding(.horizontal, 7)
                    .frame(height: 26)
                    .background(Color.skyAccent.opacity(0.14))
                    .clipShape(Capsule())
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Color.elevatedSurface.opacity(0.65))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    // MARK: - Color Inspector
    @ViewBuilder
    private func colorInspector(clip: EditorClip) -> some View {
        let clipStart = project.timelineStartTime(forClipIndex: selectedClipIndex)
        let clipLocalMs = max(0, min(clip.timelineDurationMs, playheadMs - clipStart))
        let animColor = clip.evaluatedColor(at: clipLocalMs)

        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("COLOR GRADING")
                    .font(.system(size: 11, weight: .heavy))
                    .foregroundColor(.amberAccent)
                Spacer()
                Button("Reset Color") {
                    recordUndo()
                    if clip.hasKeyframes() {
                        project.clips[selectedClipIndex].addOrUpdateKeyframe(
                            at: clipLocalMs,
                            brightness: 0.0,
                            contrast: 1.0,
                            saturation: 1.0,
                            easing: selectedKeyframeEasing
                        )
                    } else {
                        project.clips[selectedClipIndex].color = .identity
                    }
                    syncPreviewStateWithPlayhead()
                    ProjectStorageManager.shared.saveProject(project)
                }
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(.textMuted)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.elevatedSurface)
                .clipShape(Capsule())
            }

            // Contrast Slider
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text("Contrast")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.textSecondary)
                    Spacer()
                    Text(String(format: "%.2fx", animColor.contrast))
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundColor(.brandAccent)
                }
                Slider(value: Binding(
                    get: { animColor.contrast },
                    set: { newContrast in
                        if clip.hasKeyframes() {
                            project.clips[selectedClipIndex].addOrUpdateKeyframe(at: clipLocalMs, contrast: newContrast, easing: selectedKeyframeEasing)
                        } else {
                            project.clips[selectedClipIndex].color.contrast = newContrast
                        }
                        syncPreviewStateWithPlayhead()
                    }
                ), in: 0.5...1.8)
                .accentColor(.brandAccent)
            }

            // Brightness Slider
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text("Brightness")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.textSecondary)
                    Spacer()
                    Text(String(format: "%+.2f", animColor.brightness))
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundColor(.skyAccent)
                }
                Slider(value: Binding(
                    get: { animColor.brightness },
                    set: { newBrightness in
                        if clip.hasKeyframes() {
                            project.clips[selectedClipIndex].addOrUpdateKeyframe(at: clipLocalMs, brightness: newBrightness, easing: selectedKeyframeEasing)
                        } else {
                            project.clips[selectedClipIndex].color.brightness = newBrightness
                        }
                        syncPreviewStateWithPlayhead()
                    }
                ), in: -0.5...0.5)
                .accentColor(.skyAccent)
            }

            // Saturation Slider
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text("Saturation")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.textSecondary)
                    Spacer()
                    Text(String(format: "%.2fx", animColor.saturation))
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundColor(.emeraldAccent)
                }
                Slider(value: Binding(
                    get: { animColor.saturation },
                    set: { newSat in
                        if clip.hasKeyframes() {
                            project.clips[selectedClipIndex].addOrUpdateKeyframe(at: clipLocalMs, saturation: newSat, easing: selectedKeyframeEasing)
                        } else {
                            project.clips[selectedClipIndex].color.saturation = newSat
                        }
                        syncPreviewStateWithPlayhead()
                    }
                ), in: 0.0...2.0)
                .accentColor(.emeraldAccent)
            }
        }
    }

    // MARK: - Transform Inspector (Zoom, Aspect Ratio Canvas, Rotate, Flips)
    @ViewBuilder
    private func transformInspector(clip: EditorClip) -> some View {
        let clipStart = project.timelineStartTime(forClipIndex: selectedClipIndex)
        let clipLocalMs = max(0, min(clip.timelineDurationMs, playheadMs - clipStart))
        let animTransform = clip.evaluatedTransform(at: clipLocalMs)

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
                    Text(String(format: "%.2fx", animTransform.scale))
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundColor(.brandAccent)

                    Button("Reset") {
                        recordUndo()
                        if clip.hasKeyframes() {
                            project.clips[selectedClipIndex].addOrUpdateKeyframe(at: clipLocalMs, scale: 1.0, easing: selectedKeyframeEasing)
                        } else {
                            project.clips[selectedClipIndex].transform.scale = 1.0
                        }
                        syncPreviewStateWithPlayhead()
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
                        get: { animTransform.scale },
                        set: { newScale in
                            if clip.hasKeyframes() {
                                project.clips[selectedClipIndex].addOrUpdateKeyframe(at: clipLocalMs, scale: newScale, easing: selectedKeyframeEasing)
                            } else {
                                project.clips[selectedClipIndex].transform.scale = newScale
                            }
                            syncPreviewStateWithPlayhead()
                        }
                    ),
                    in: 0.3...3.5,
                    step: 0.05
                )
                .accentColor(.brandAccent)

                // Quick zoom presets
                HStack(spacing: 6) {
                    ForEach([0.5, 0.8, 1.0, 1.25, 1.5, 2.0], id: \.self) { z in
                        let isCur = abs(animTransform.scale - z) < 0.04
                        Button(action: {
                            recordUndo()
                            if clip.hasKeyframes() {
                                project.clips[selectedClipIndex].addOrUpdateKeyframe(at: clipLocalMs, scale: z, easing: selectedKeyframeEasing)
                            } else {
                                project.clips[selectedClipIndex].transform.scale = z
                            }
                            syncPreviewStateWithPlayhead()
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

            // 3. Position / Move Controls (D-Pad Up, Down, Left, Right)
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("POSITION / MOVE")
                        .font(.system(size: 10, weight: .heavy))
                        .foregroundColor(.textTertiary)
                    Spacer()
                    Text("X: \(Int(round(animTransform.offsetX))) pt  |  Y: \(Int(round(animTransform.offsetY))) pt")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundColor(.skyAccent)

                    Button("Center") {
                        recordUndo()
                        if clip.hasKeyframes() {
                            project.clips[selectedClipIndex].addOrUpdateKeyframe(at: clipLocalMs, positionX: 0.0, positionY: 0.0, easing: selectedKeyframeEasing)
                        } else {
                            project.clips[selectedClipIndex].transform.offsetX = 0.0
                            project.clips[selectedClipIndex].transform.offsetY = 0.0
                        }
                        syncPreviewStateWithPlayhead()
                    }
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.textMuted)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.elevatedSurface)
                    .clipShape(Capsule())
                }

                HStack(spacing: 16) {
                    // D-Pad Directional Arrows
                    VStack(spacing: 4) {
                        // UP
                        Button(action: {
                            recordUndo()
                            if clip.hasKeyframes() {
                                project.clips[selectedClipIndex].addOrUpdateKeyframe(at: clipLocalMs, positionY: animTransform.offsetY - 10.0, easing: selectedKeyframeEasing)
                            } else {
                                project.clips[selectedClipIndex].transform.offsetY -= 10.0
                            }
                            syncPreviewStateWithPlayhead()
                        }) {
                            Image(systemName: "chevron.up")
                                .font(.system(size: 12, weight: .black))
                                .foregroundColor(.textPrimary)
                                .frame(width: 38, height: 28)
                                .background(Color.elevatedSurface)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                        }

                        // LEFT - CENTER - RIGHT
                        HStack(spacing: 4) {
                            Button(action: {
                                recordUndo()
                                if clip.hasKeyframes() {
                                    project.clips[selectedClipIndex].addOrUpdateKeyframe(at: clipLocalMs, positionX: animTransform.offsetX - 10.0, easing: selectedKeyframeEasing)
                                } else {
                                    project.clips[selectedClipIndex].transform.offsetX -= 10.0
                                }
                                syncPreviewStateWithPlayhead()
                            }) {
                                Image(systemName: "chevron.left")
                                    .font(.system(size: 12, weight: .black))
                                    .foregroundColor(.textPrimary)
                                    .frame(width: 38, height: 28)
                                    .background(Color.elevatedSurface)
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                            }

                            Button(action: {
                                recordUndo()
                                if clip.hasKeyframes() {
                                    project.clips[selectedClipIndex].addOrUpdateKeyframe(at: clipLocalMs, positionX: 0.0, positionY: 0.0, easing: selectedKeyframeEasing)
                                } else {
                                    project.clips[selectedClipIndex].transform.offsetX = 0.0
                                    project.clips[selectedClipIndex].transform.offsetY = 0.0
                                }
                                syncPreviewStateWithPlayhead()
                            }) {
                                Image(systemName: "circle.grid.cross.fill")
                                    .font(.system(size: 10))
                                    .foregroundColor(.skyAccent)
                                    .frame(width: 28, height: 28)
                                    .background(Color.skyAccent.opacity(0.15))
                                    .clipShape(Circle())
                            }

                            Button(action: {
                                recordUndo()
                                if clip.hasKeyframes() {
                                    project.clips[selectedClipIndex].addOrUpdateKeyframe(at: clipLocalMs, positionX: animTransform.offsetX + 10.0, easing: selectedKeyframeEasing)
                                } else {
                                    project.clips[selectedClipIndex].transform.offsetX += 10.0
                                }
                                syncPreviewStateWithPlayhead()
                            }) {
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 12, weight: .black))
                                    .foregroundColor(.textPrimary)
                                    .frame(width: 38, height: 28)
                                    .background(Color.elevatedSurface)
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                            }
                        }

                        // DOWN
                        Button(action: {
                            recordUndo()
                            if clip.hasKeyframes() {
                                project.clips[selectedClipIndex].addOrUpdateKeyframe(at: clipLocalMs, positionY: animTransform.offsetY + 10.0, easing: selectedKeyframeEasing)
                            } else {
                                project.clips[selectedClipIndex].transform.offsetY += 10.0
                            }
                            syncPreviewStateWithPlayhead()
                        }) {
                            Image(systemName: "chevron.down")
                                .font(.system(size: 12, weight: .black))
                                .foregroundColor(.textPrimary)
                                .frame(width: 38, height: 28)
                                .background(Color.elevatedSurface)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Touch & Drag Canvas")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(.textPrimary)
                        Text("Pan or pinch-to-zoom directly on the preview monitor, or use the D-pad arrows to nudge by 10pt.")
                            .font(.system(size: 9.5))
                            .foregroundColor(.textTertiary)
                            .lineLimit(3)
                    }
                }
            }

            Divider().background(Color.borderHairline)

            // 4. Rotation & Flip Controls
            HStack(spacing: 10) {
                Button(action: {
                    recordUndo()
                    if clip.hasKeyframes() {
                        let cur = clip.evaluatedTransform(at: clipLocalMs)
                        let newRot = (cur.rotationDegrees + 90.0).truncatingRemainder(dividingBy: 360.0)
                        project.clips[selectedClipIndex].addOrUpdateKeyframe(at: clipLocalMs, rotationDegrees: newRot, easing: selectedKeyframeEasing)
                    } else {
                        project.clips[selectedClipIndex].transform.rotation = clip.transform.rotation.next
                    }
                    syncPreviewStateWithPlayhead()
                    ProjectStorageManager.shared.saveProject(project)
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
                    syncPreviewStateWithPlayhead()
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
                    syncPreviewStateWithPlayhead()
                }) {
                    Label(clip.transform.flipV ? "Flipped V" : "Flip V", systemImage: "arrow.up.and.down.righttriangle.up.righttriangle.down")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(clip.transform.flipV ? .emeraldAccent : .textSecondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(clip.transform.flipV ? Color.emeraldAccent.opacity(0.15) : Color.elevatedSurface)
                        .clipShape(Capsule())
                }

                Button(action: {
                    recordUndo()
                    if clip.hasKeyframes() {
                        project.clips[selectedClipIndex].addOrUpdateKeyframe(
                            at: clipLocalMs,
                            positionX: 0.0,
                            positionY: 0.0,
                            scale: 1.0,
                            rotationDegrees: 0.0,
                            opacity: 1.0,
                            easing: selectedKeyframeEasing
                        )
                    } else {
                        project.clips[selectedClipIndex].transform = .identity
                    }
                    syncPreviewStateWithPlayhead()
                    ProjectStorageManager.shared.saveProject(project)
                }) {
                    Text("Reset All")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.textTertiary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color.elevatedSurface)
                        .clipShape(Capsule())
                }
            }

            Divider().background(Color.borderHairline)

            // 5. Opacity Control
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("OPACITY")
                        .font(.system(size: 10, weight: .heavy))
                        .foregroundColor(.textTertiary)
                    Spacer()
                    Text("\(Int(round(animTransform.opacity * 100)))%")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundColor(.amberAccent)
                }

                Slider(
                    value: Binding(
                        get: { animTransform.opacity },
                        set: { newOpacity in
                            if clip.hasKeyframes() {
                                project.clips[selectedClipIndex].addOrUpdateKeyframe(at: clipLocalMs, opacity: newOpacity, easing: selectedKeyframeEasing)
                            } else {
                                project.clips[selectedClipIndex].transform.opacity = newOpacity
                            }
                            syncPreviewStateWithPlayhead()
                        }
                    ),
                    in: 0.0...1.0,
                    step: 0.02
                )
                .accentColor(.amberAccent)
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
        playerModel.periodicTickHandler = { curMs in
            self.updatePlayheadFromPlayback(sourceMs: curMs)
        }
        playerModel.onDisplayFrame = { currentSourceSec in
            guard self.playerModel.isPlaying else { return }
            guard self.selectedClipIndex < self.project.clips.count else { return }
            let clip = self.project.clips[self.selectedClipIndex]
            let currentSourceMs = currentSourceSec * 1000.0
            let timelineOffset = clip.mapSourceMsToTimelineOffset(currentSourceMs)
            let anim = clip.evaluatedTransform(at: timelineOffset)
            let animColor = clip.evaluatedColor(at: timelineOffset)
            let rot = clip.hasKeyframes() ? anim.rotationDegrees : Double(clip.transform.rotation.rawValue)
            self.previewState.update(
                scale: anim.scale,
                offsetX: anim.offsetX,
                offsetY: anim.offsetY,
                rotationDegrees: rot,
                opacity: anim.opacity,
                brightness: animColor.brightness,
                contrast: animColor.contrast,
                saturation: animColor.saturation
            )
        }
        playerModel.ensureTimeObserver()

        if let clip = project.clips.first {
            playerModel.player.isMuted = clip.isMuted
            playerModel.setPlaybackBounds(inMs: clip.sourceInPointMs, outMs: clip.sourceOutPointMs)
            playerModel.setup(with: clip.sourceUrl) { [weak playerModel] curMs in
                _ = playerModel
                self.updatePlayheadFromPlayback(sourceMs: curMs)
            }
            if clip.sourceInPointMs > 0 {
                playerModel.seek(to: clip.sourceInPointMs)
            }
        }
        syncPreviewStateWithPlayhead()
    }

    private func syncPreviewStateWithPlayhead() {
        guard let clip = selectedClip else { return }
        let clipStart = project.timelineStartTime(forClipIndex: selectedClipIndex)
        let clipLocalMs = Double(max(0, min(clip.timelineDurationMs, playheadMs - clipStart)))
        let anim = clip.evaluatedTransform(at: clipLocalMs)
        let animColor = clip.evaluatedColor(at: clipLocalMs)
        let rot = clip.hasKeyframes() ? anim.rotationDegrees : Double(clip.transform.rotation.rawValue)
        previewState.update(
            scale: anim.scale,
            offsetX: anim.offsetX,
            offsetY: anim.offsetY,
            rotationDegrees: rot,
            opacity: anim.opacity,
            brightness: animColor.brightness,
            contrast: animColor.contrast,
            saturation: animColor.saturation
        )
    }

    private func updatePlayheadFromPlayback(sourceMs: Int64) {
        guard let clip = selectedClip else { return }

        // Hard boundary clamp: if player reaches or passes trimmed out-point, advance immediately!
        if sourceMs >= clip.sourceOutPointMs - 25 {
            self.advanceToNextClipAndContinue()
            return
        }

        // Hard boundary clamp: if player is playing before trimmed in-point, seek to in-point
        if sourceMs < clip.sourceInPointMs - 40 {
            playerModel.seek(to: clip.sourceInPointMs, preservePlaybackState: true)
            return
        }

        let clipStart = project.timelineStartTime(forClipIndex: selectedClipIndex)
        let timelineOffset = clip.mapSourceMsToTimelineOffset(sourceMs)
        let newPlayhead = clipStart + timelineOffset

        self.playheadMs = newPlayhead
    }

    private func advanceToNextClipAndContinue() {
        guard !isAdvancingClip else { return }
        isAdvancingClip = true

        if selectedClipIndex + 1 < project.clips.count {
            selectedClipIndex += 1
            let nextClip = project.clips[selectedClipIndex]
            let startMs = project.timelineStartTime(forClipIndex: selectedClipIndex)
            playheadMs = startMs

            // Pre-seed preview state for next clip at time 0 so there is no single-frame glitch or jump
            let anim = nextClip.evaluatedTransform(at: Double(0))
            let animColor = nextClip.evaluatedColor(at: Double(0))
            self.previewState.update(
                scale: anim.scale,
                offsetX: anim.offsetX,
                offsetY: anim.offsetY,
                rotationDegrees: nextClip.hasKeyframes() ? anim.rotationDegrees : Double(nextClip.transform.rotation.rawValue),
                opacity: anim.opacity,
                brightness: animColor.brightness,
                contrast: animColor.contrast,
                saturation: animColor.saturation
            )

            playerModel.player.isMuted = nextClip.isMuted
            playerModel.setPlaybackBounds(inMs: nextClip.sourceInPointMs, outMs: nextClip.sourceOutPointMs)
            let speed = Float(nextClip.speedConfig.speedMultiplier)
            playerModel.transitionTo(
                url: nextClip.sourceUrl,
                startMs: nextClip.sourceInPointMs,
                inMs: nextClip.sourceInPointMs,
                outMs: nextClip.sourceOutPointMs,
                playRate: speed,
                autoPlay: true
            ) {
                self.isAdvancingClip = false
            }
        } else {
            // End of entire project timeline reached
            playerModel.pause()
            playheadMs = project.totalTimelineDurationMs
            isAdvancingClip = false
        }
    }

    private func syncPlayheadToPlayer(preservePlayback: Bool = false) {
        guard let clip = selectedClip else { return }
        let clipStart = project.timelineStartTime(forClipIndex: selectedClipIndex)
        let offsetMs = max(0, min(clip.timelineDurationMs, playheadMs - clipStart))
        let sourceMs = max(clip.sourceInPointMs, min(clip.sourceOutPointMs, clip.mapTimelineOffsetToSourceMs(offsetMs)))

        playerModel.player.isMuted = clip.isMuted
        playerModel.setPlaybackBounds(inMs: clip.sourceInPointMs, outMs: clip.sourceOutPointMs)

        let isCurrentUrl = (playerModel.player.currentItem?.asset as? AVURLAsset)?.url == clip.sourceUrl
        if !isCurrentUrl {
            let speed = Float(clip.speedConfig.speedMultiplier)
            playerModel.transitionTo(
                url: clip.sourceUrl,
                startMs: sourceMs,
                inMs: clip.sourceInPointMs,
                outMs: clip.sourceOutPointMs,
                playRate: speed,
                autoPlay: preservePlayback
            )
        } else {
            playerModel.seek(to: sourceMs, preservePlaybackState: preservePlayback)
        }
        syncPreviewStateWithPlayhead()
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
        selectedKeyframeId = nil
        if project.clips.isEmpty {
            selectedClipIndex = 0
            playheadMs = 0
            playerModel.pause()
            playerModel.cleanup()
        } else {
            selectedClipIndex = max(0, min(project.clips.count - 1, selectedClipIndex))
            let clipStart = project.timelineStartTime(forClipIndex: selectedClipIndex)
            playheadMs = clipStart
            syncPlayheadToPlayer(preservePlayback: false)
        }
        syncPreviewStateWithPlayhead()
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

    private func startProjectExport(config: ProjectExportConfig) {
        isExporting = true
        exportProgress = 0.0
        exportStatusMessage = "Initializing render pipeline..."

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
                        self.playheadMs = self.project.timelineStartTime(forClipIndex: self.selectedClipIndex)
                        ProjectStorageManager.shared.saveProject(self.project)
                        self.playerModel.ensureTimeObserver()
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
                    self.playheadMs = self.project.timelineStartTime(forClipIndex: self.selectedClipIndex)
                    ProjectStorageManager.shared.saveProject(self.project)
                    self.playerModel.ensureTimeObserver()
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

// MARK: - Native Real Audio Waveform Strip (LibreCuts Architecture)
struct ClipAudioWaveformView: View {
    let clip: EditorClip
    let width: CGFloat
    let isSelected: Bool

    @State private var waveformData: [Float] = []

    var body: some View {
        HStack(spacing: 2) {
            if clip.isMuted {
                HStack(spacing: 4) {
                    Rectangle()
                        .fill(Color.textTertiary.opacity(0.35))
                        .frame(height: 1)
                    Text("MUTED")
                        .font(.system(size: 7.5, weight: .heavy, design: .monospaced))
                        .foregroundColor(.textTertiary)
                    Rectangle()
                        .fill(Color.textTertiary.opacity(0.35))
                        .frame(height: 1)
                }
            } else if waveformData.isEmpty {
                // Loading / extracting shimmer
                HStack(spacing: 2) {
                    let barCount = max(6, Int(width / 5.0))
                    ForEach(0..<barCount, id: \.self) { _ in
                        RoundedRectangle(cornerRadius: 1)
                            .fill(Color.emeraldAccent.opacity(0.25))
                            .frame(width: 2, height: 4)
                    }
                }
            } else {
                // Render real waveform bars mapped to the trimmed range
                let barCount = max(6, Int(width / 4.0))
                let totalDur = max(1.0, Double(clip.sourceDurationMs))
                let inRatio = Double(clip.sourceInPointMs) / totalDur
                let outRatio = Double(clip.sourceOutPointMs) / totalDur
                let spanRatio = max(0.001, outRatio - inRatio)

                ForEach(0..<barCount, id: \.self) { i in
                    let fraction = Double(i) / Double(max(1, barCount - 1))
                    let clipFraction = inRatio + (fraction * spanRatio)
                    let sampleIndex = min(waveformData.count - 1, max(0, Int(clipFraction * Double(waveformData.count))))
                    let rawAmp = waveformData[sampleIndex]
                    let scaledAmp = Double(rawAmp) * min(2.0, max(0.0, clip.volume))
                    let barHeight = max(2.5, min(18.0, 3.0 + (scaledAmp * 15.0)))

                    RoundedRectangle(cornerRadius: 1)
                        .fill(isSelected ? Color.emeraldAccent : Color.emeraldAccent.opacity(0.75))
                        .frame(width: 2, height: CGFloat(barHeight))
                }
            }
        }
        .frame(height: 20)
        .onAppear {
            loadWaveform()
        }
        .onChange(of: clip.sourceUrl) { _ in
            loadWaveform()
        }
    }

    private func loadWaveform() {
        AudioWaveformExtractor.shared.extractWaveform(for: clip.sourceUrl, targetSamples: 300) { amps in
            self.waveformData = amps
        }
    }
}

// MARK: - Dynamic Adaptive Time Ruler View (LibreCuts TimeRulerView)
struct DynamicTimeRulerView: View {
    let durationMs: Int64
    let pointsPerSecond: CGFloat
    let width: CGFloat
    let onSeek: (Int64) -> Void

    var body: some View {
        let msPerPoint = 1000.0 / max(1.0, Double(pointsPerSecond))
        // Target ~75 points between major labeled ticks
        let targetMs = Int64(round(75.0 * msPerPoint))

        let stepMs: Int64 = {
            switch targetMs {
            case ...120: return 100
            case ...300: return 200
            case ...700: return 500
            case ...1500: return 1000
            case ...3500: return 2000
            case ...7500: return 5000
            case ...15000: return 10000
            case ...45000: return 30000
            case ...90000: return 60000
            case ...180000: return 120000
            case ...450000: return 300000
            default: return 600000
            }
        }()

        let minorStepMs = max(20, stepMs / 5)
        let totalTicks = max(1, Int(durationMs / minorStepMs) + 2)

        ZStack(alignment: .topLeading) {
            // Tick marks & timecode labels
            ForEach(0..<totalTicks, id: \.self) { i in
                let tickMs = Int64(i) * minorStepMs
                let x = CGFloat(tickMs) / 1000.0 * pointsPerSecond
                let isMajor = (tickMs % stepMs == 0)

                if isMajor {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(formatTickLabel(tickMs, stepMs: stepMs))
                            .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                            .foregroundColor(Color.textSecondary)
                        Rectangle()
                            .fill(Color.borderHairlineBright)
                            .frame(width: 1.5, height: 7)
                    }
                    .offset(x: x)
                } else {
                    Rectangle()
                        .fill(Color.borderHairline.opacity(0.6))
                        .frame(width: 1, height: 4)
                        .offset(x: x, y: 15)
                }
            }

            // Interactive top gesture overlay spanning full width and height
            Color.white.opacity(0.001)
                .frame(width: width, height: 26)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { val in
                            let seekMs = Int64(max(0, min(Double(durationMs), Double(val.location.x) / Double(pointsPerSecond) * 1000.0)))
                            onSeek(seekMs)
                        }
                )
        }
        .frame(width: width, height: 26, alignment: .topLeading)
    }

    private func formatTickLabel(_ ms: Int64, stepMs: Int64) -> String {
        let totalSec = Double(ms) / 1000.0
        let m = Int(totalSec) / 60
        let s = Int(totalSec) % 60
        if stepMs < 1000 {
            let tenths = Int((totalSec.truncatingRemainder(dividingBy: 1.0)) * 10)
            return String(format: "%02d:%02d.%d", m, s, tenths)
        } else {
            return String(format: "%02d:%02d", m, s)
        }
    }
}

// MARK: - Playhead Triangle Pointer
struct TrianglePointer: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

// MARK: - Export Settings Modal Sheet
struct ExportSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss

    let project: VideoProject
    let aspectRatio: AspectRatioPreset
    let onStartExport: (ProjectExportConfig) -> Void

    @State private var selectedResolution: ExportResolutionPreset = .res1080p
    @State private var selectedFps: ExportFrameRate = .fps30
    @State private var selectedCodec: EditorCodec = .h264
    @State private var selectedQuality: ExportQuality = .high
    @State private var saveToCameraRoll: Bool = true

    private var currentConfig: ProjectExportConfig {
        ProjectExportConfig(
            resolutionPreset: selectedResolution,
            aspectRatio: aspectRatio,
            frameRate: selectedFps,
            codec: selectedCodec,
            quality: selectedQuality,
            saveToCameraRoll: saveToCameraRoll
        )
    }

    private var validation: (isValid: Bool, error: String?) {
        currentConfig.validate()
    }

    private var estimatedFileSizeMB: Double {
        let totalSec = Double(project.totalTimelineDurationMs) / 1000.0
        let bitrateMbps = currentConfig.bitrateMbps
        return (totalSec * bitrateMbps) / 8.0
    }

    var body: some View {
        NavigationView {
            ZStack {
                Color.voidCanvas.ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        // 1. Resolution Selection (720p, 1080p, 4K)
                        VStack(alignment: .leading, spacing: 8) {
                            Text("RESOLUTION")
                                .font(.system(size: 11, weight: .heavy))
                                .foregroundColor(.textSecondary)

                            HStack(spacing: 8) {
                                ForEach(ExportResolutionPreset.allCases) { res in
                                    let isSel = selectedResolution == res
                                    Button(action: { selectedResolution = res }) {
                                        VStack(spacing: 3) {
                                            Text(res.shortLabel)
                                                .font(.system(size: 13, weight: .bold))
                                            let dims = res.dimensions(for: aspectRatio)
                                            Text("\(dims.width)x\(dims.height)")
                                                .font(.system(size: 9.5, design: .monospaced))
                                                .foregroundColor(isSel ? .white.opacity(0.85) : .textTertiary)
                                        }
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 10)
                                        .background(isSel ? Color.brandAccent : Color.surfaceCard)
                                        .foregroundColor(isSel ? .white : .textPrimary)
                                        .clipShape(RoundedRectangle(cornerRadius: 10))
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 10)
                                                .stroke(isSel ? Color.brandAccent : Color.borderHairline, lineWidth: 1)
                                        )
                                    }
                                }
                            }
                        }

                        // 2. Frame Rate (24, 30, 60 FPS)
                        VStack(alignment: .leading, spacing: 8) {
                            Text("FRAME RATE")
                                .font(.system(size: 11, weight: .heavy))
                                .foregroundColor(.textSecondary)

                            HStack(spacing: 8) {
                                ForEach(ExportFrameRate.allCases) { fps in
                                    let isSel = selectedFps == fps
                                    Button(action: { selectedFps = fps }) {
                                        Text("\(fps.rawValue) FPS")
                                            .font(.system(size: 12, weight: .bold))
                                            .frame(maxWidth: .infinity)
                                            .padding(.vertical, 10)
                                            .background(isSel ? Color.brandAccent : Color.surfaceCard)
                                            .foregroundColor(isSel ? .white : .textPrimary)
                                            .clipShape(RoundedRectangle(cornerRadius: 10))
                                            .overlay(
                                                RoundedRectangle(cornerRadius: 10)
                                                    .stroke(isSel ? Color.brandAccent : Color.borderHairline, lineWidth: 1)
                                            )
                                    }
                                }
                            }
                        }

                        // 3. Video Codec (H.264, HEVC)
                        VStack(alignment: .leading, spacing: 8) {
                            Text("ENCODING CODEC")
                                .font(.system(size: 11, weight: .heavy))
                                .foregroundColor(.textSecondary)

                            HStack(spacing: 8) {
                                ForEach(EditorCodec.allCases) { codec in
                                    let isSel = selectedCodec == codec
                                    Button(action: { selectedCodec = codec }) {
                                        VStack(spacing: 2) {
                                            Text(codec.shortLabel)
                                                .font(.system(size: 12.5, weight: .bold))
                                            Text(codec == .h264 ? "Universal" : "Smaller Size")
                                                .font(.system(size: 9))
                                                .foregroundColor(isSel ? .white.opacity(0.85) : .textTertiary)
                                        }
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 8)
                                        .background(isSel ? Color.brandAccent : Color.surfaceCard)
                                        .foregroundColor(isSel ? .white : .textPrimary)
                                        .clipShape(RoundedRectangle(cornerRadius: 10))
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 10)
                                                .stroke(isSel ? Color.brandAccent : Color.borderHairline, lineWidth: 1)
                                        )
                                    }
                                }
                            }
                        }

                        // 4. Export Quality / Bitrate
                        VStack(alignment: .leading, spacing: 8) {
                            Text("QUALITY & BITRATE")
                                .font(.system(size: 11, weight: .heavy))
                                .foregroundColor(.textSecondary)

                            Picker("Quality", selection: $selectedQuality) {
                                ForEach(ExportQuality.allCases) { q in
                                    Text(q.rawValue).tag(q)
                                }
                            }
                            .pickerStyle(SegmentedPickerStyle())
                        }

                        // 5. Save to Camera Roll
                        Toggle(isOn: $saveToCameraRoll) {
                            HStack(spacing: 8) {
                                Image(systemName: "photo.on.rectangle")
                                    .foregroundColor(.brandAccent)
                                Text("Save Video to Photos Camera Roll")
                                    .font(.system(size: 13, weight: .semibold))
                            }
                        }
                        .padding(.vertical, 4)

                        // 6. Output Specifications Summary Card
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("EXPORT SPECIFICATIONS")
                                    .font(.system(size: 10, weight: .heavy))
                                    .foregroundColor(.textTertiary)
                                Spacer()
                                Text(aspectRatio.badgeText)
                                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                                    .foregroundColor(.skyAccent)
                            }

                            Divider().background(Color.borderHairline)

                            HStack {
                                Text("Dimensions:")
                                    .font(.system(size: 12))
                                    .foregroundColor(.textSecondary)
                                Spacer()
                                Text("\(currentConfig.targetWidth) × \(currentConfig.targetHeight) px")
                                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                                    .foregroundColor(.textPrimary)
                            }

                            HStack {
                                Text("Target Bitrate:")
                                    .font(.system(size: 12))
                                    .foregroundColor(.textSecondary)
                                Spacer()
                                Text("\(Int(currentConfig.bitrateMbps)) Mbps")
                                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                                    .foregroundColor(.textPrimary)
                            }

                            HStack {
                                Text("Estimated Size:")
                                    .font(.system(size: 12))
                                    .foregroundColor(.textSecondary)
                                Spacer()
                                Text(String(format: "~%.1f MB", max(0.5, estimatedFileSizeMB)))
                                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                                    .foregroundColor(.amberAccent)
                            }

                            if let err = validation.error {
                                Text(err)
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundColor(.red)
                                    .padding(.top, 4)
                            }
                        }
                        .padding(14)
                        .background(Color.surfaceCard)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(Color.borderHairline, lineWidth: 1)
                        )

                        // Start Export CTA Button
                        Button(action: {
                            onStartExport(currentConfig)
                        }) {
                            HStack(spacing: 6) {
                                Image(systemName: "arrow.up.circle.fill")
                                    .font(.system(size: 14, weight: .bold))
                                Text("Start Export")
                                    .font(.system(size: 14, weight: .heavy))
                            }
                            .frame(maxWidth: .infinity)
                            .frame(height: 48)
                            .background(validation.isValid ? AnyView(LinearGradient.brandGradient) : AnyView(Color.surfaceCard))
                            .foregroundColor(validation.isValid ? .white : .textTertiary)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                        }
                        .disabled(!validation.isValid)
                        .padding(.top, 8)
                    }
                    .padding(18)
                }
            }
            .navigationTitle("Export Video")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundColor(.textSecondary)
                }
            }
        }
    }
}

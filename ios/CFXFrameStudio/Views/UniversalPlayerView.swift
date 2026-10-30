import SwiftUI
import AVKit
import PhotosUI
import UniformTypeIdentifiers

// MARK: - Native AVPlayer Hosting Layer
struct UniversalVideoPlayerRepresentable: UIViewRepresentable {
    let player: AVPlayer?
    let aspectMode: PlayerAspectRatioMode

    func makeUIView(context: Context) -> PlayerUIView {
        let view = PlayerUIView()
        view.backgroundColor = .black
        return view
    }

    func updateUIView(_ uiView: PlayerUIView, context: Context) {
        uiView.playerLayer.player = player

        switch aspectMode {
        case .fit:
            uiView.playerLayer.videoGravity = .resizeAspect
        case .fill:
            uiView.playerLayer.videoGravity = .resizeAspectFill
        case .ratio16_9, .ratio4_3, .ratio21_9, .original:
            uiView.playerLayer.videoGravity = .resizeAspect
        }
    }

    class PlayerUIView: UIView {
        override class var layerClass: AnyClass {
            AVPlayerLayer.self
        }

        var playerLayer: AVPlayerLayer {
            layer as! AVPlayerLayer
        }
    }
}

// MARK: - Document Picker for Files
struct PlayerDocumentPicker: UIViewControllerRepresentable {
    var onPick: (URL) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let types: [UTType] = UTType.supportedVideoImportTypes
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: true)
        picker.delegate = context.coordinator
        picker.allowsMultipleSelection = false
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onPick: onPick)
    }

    class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: (URL) -> Void
        init(onPick: @escaping (URL) -> Void) {
            self.onPick = onPick
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first else { return }
            onPick(url)
        }
    }
}

// MARK: - Main Universal VLC Pro Player View
struct UniversalPlayerView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var engine = UniversalPlayerEngine()

    // Initial URL if opened directly from Downloader/Trimmer
    var initialMediaUrl: URL? = nil

    // UI Overlay state
    @State private var showControls: Bool = true
    @State private var controlsTimer: Task<Void, Never>? = nil
    @State private var showInspector: Bool = false
    @State private var showDocPicker: Bool = false
    @State private var photoItem: PhotosPickerItem? = nil

    // Gesture State
    @State private var activeGestureType: ActiveGestureType? = nil
    @State private var gestureValue: Float = 0.0
    @State private var scrubDeltaSeconds: Double = 0.0
    @State private var scrubInitialTime: Double = 0.0
    @State private var showSkipRippleLeft: Bool = false
    @State private var showSkipRippleRight: Bool = false

    // Recent Files
    @State private var recentFiles: [URL] = []

    // Copy Timecode Toast
    @State private var showCopiedToast: Bool = false
    @State private var copiedTimecodeString: String = ""

    enum ActiveGestureType {
        case brightness
        case volume
        case scrub
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color.black.ignoresSafeArea()

                if engine.currentSourceUrl != nil {
                    // Active Video Presentation
                    playerContent(size: proxy.size)
                } else {
                    // Media Empty / Selector State
                    emptyStatePicker
                }
            }
        }
        .navigationBarBackButtonHidden(true)
        .navigationBarHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .statusBarHidden(!showControls && engine.currentSourceUrl != nil)
        .ignoresSafeArea()
        .sheet(isPresented: $showInspector) {
            mediaInspectorSheet
        }
        .sheet(isPresented: $showDocPicker) {
            PlayerDocumentPicker { pickedUrl in
                Task {
                    await engine.loadMedia(url: pickedUrl)
                    loadRecentFiles()
                }
            }
        }
        .onChange(of: photoItem) { newItem in
            guard let item = newItem else { return }
            Task {
                if let movie = try? await item.loadTransferable(type: MovieTransferable.self) {
                    await engine.loadMedia(url: movie.url)
                    loadRecentFiles()
                }
            }
        }
        .task {
            loadRecentFiles()
            if let initial = initialMediaUrl {
                await engine.loadMedia(url: initial)
            }
        }
    }

    // MARK: - Video Layer & Gestures

    @ViewBuilder
    private func playerContent(size: CGSize) -> some View {
        ZStack {
            // 1. Native Player Layer
            UniversalVideoPlayerRepresentable(player: engine.player, aspectMode: engine.aspectRatioMode)
                .scaleEffect(engine.zoomScale)
                .offset(engine.panOffset)
                .frame(width: size.width, height: size.height)
                .clipped()

            // 2. Gesture Handling Overlay
            if !engine.isControlsLocked {
                gestureDetector(size: size)
            }

            // 3. Gesture Feedback HUDs
            gestureFeedbackHUD(size: size)

            // 4. Double-Tap Chevrons
            rippleFeedbackOverlay

            // 5. On-Screen Buffering / Status
            if engine.isBuffering || engine.statusMessage != nil {
                loadingOverlay
            }

            // 6. Player Control Overlays (Top, Bottom, Lock)
            if showControls || engine.isControlsLocked {
                controlsOverlay
            }

            // 7. Floating Copied Toast
            if showCopiedToast {
                VStack {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.emeraldAccent)
                            .font(.system(size: 16, weight: .bold))
                        Text("Timecode Copied: \(copiedTimecodeString)")
                            .font(.system(size: 13, weight: .bold, design: .monospaced))
                            .foregroundColor(.white)
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                    .background(.ultraThinMaterial)
                    .cornerRadius(20)
                    .shadow(color: .black.opacity(0.4), radius: 10, y: 5)
                    .padding(.top, 70)
                    Spacer()
                }
                .transition(.move(edge: .top).combined(with: .opacity))
            }

            // 8. Resumed Playback Banner
            if engine.hasResumedPlayback, let saved = engine.lastSavedPosition {
                VStack {
                    HStack(spacing: 10) {
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundColor(.amberAccent)

                        VStack(alignment: .leading, spacing: 2) {
                            Text("Resumed Playback")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundColor(.white)
                            Text("Continuing from \(formatTime(saved))")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(.gray)
                        }

                        Spacer()

                        Button("Start Over") {
                            engine.seek(to: 0.0)
                            if let url = engine.currentSourceUrl {
                                engine.clearSavedPlaybackPosition(for: url)
                            }
                            withAnimation(.spring()) {
                                engine.hasResumedPlayback = false
                            }
                        }
                        .font(.system(size: 11, weight: .bold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Color.white.opacity(0.18))
                        .foregroundColor(.white)
                        .cornerRadius(6)

                        Button {
                            withAnimation(.easeOut) {
                                engine.hasResumedPlayback = false
                            }
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundColor(.gray)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.ultraThinMaterial)
                    .cornerRadius(14)
                    .padding(.horizontal, 20)
                    .padding(.top, 65)
                    Spacer()
                }
                .transition(.move(edge: .top).combined(with: .opacity))
                .onAppear {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 6.0) {
                        withAnimation(.easeOut(duration: 0.4)) {
                            engine.hasResumedPlayback = false
                        }
                    }
                }
            }
        }
    }

    // MARK: - Gesture Detection (Left/Right/Horizontal)

    @ViewBuilder
    private func gestureDetector(size: CGSize) -> some View {
        HStack(spacing: 0) {
            // Left Half: Screen Brightness
            Color.clear
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 10)
                        .onChanged { val in
                            handleVerticalDrag(val: val, isLeftHalf: true, screenHeight: size.height)
                        }
                        .onEnded { _ in
                            endGesture()
                        }
                )
                .simultaneousGesture(
                    TapGesture(count: 2).onEnded {
                        triggerDoubleTapSkip(forward: false)
                    }
                )
                .simultaneousGesture(
                    TapGesture(count: 1).onEnded {
                        toggleControls()
                    }
                )

            // Right Half: Volume Boost
            Color.clear
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 10)
                        .onChanged { val in
                            handleVerticalDrag(val: val, isLeftHalf: false, screenHeight: size.height)
                        }
                        .onEnded { _ in
                            endGesture()
                        }
                )
                .simultaneousGesture(
                    TapGesture(count: 2).onEnded {
                        triggerDoubleTapSkip(forward: true)
                    }
                )
                .simultaneousGesture(
                    TapGesture(count: 1).onEnded {
                        toggleControls()
                    }
                )
        }
        .gesture(
            // Horizontal Scrub Seek
            DragGesture(minimumDistance: 25)
                .onChanged { val in
                    handleHorizontalScrub(val: val, screenWidth: size.width)
                }
                .onEnded { _ in
                    endHorizontalScrub()
                }
        )
        .gesture(
            // Two-Finger Pinch Zoom
            MagnificationGesture()
                .onChanged { scale in
                    engine.zoomScale = max(0.5, min(scale, 4.0))
                }
        )
    }

    private func handleVerticalDrag(val: DragGesture.Value, isLeftHalf: Bool, screenHeight: CGFloat) {
        let isHorizontal = abs(val.translation.width) > abs(val.translation.height) * 1.3
        if isHorizontal && activeGestureType == nil {
            return
        }

        let dragDelta = Float(-val.translation.height / screenHeight)

        if isLeftHalf {
            activeGestureType = .brightness
            let target = max(0.0, min(engine.brightness + dragDelta * 0.05, 1.0))
            engine.setBrightness(target)
            gestureValue = target
        } else {
            activeGestureType = .volume
            let target = max(0.0, min(engine.volume + dragDelta * 0.08, 2.0))
            engine.setVolume(target)
            gestureValue = target
        }
    }

    private func handleHorizontalScrub(val: DragGesture.Value, screenWidth: CGFloat) {
        let isHorizontal = abs(val.translation.width) > abs(val.translation.height)
        guard isHorizontal else { return }

        if activeGestureType != .scrub {
            activeGestureType = .scrub
            scrubInitialTime = engine.currentTime
        }

        let fraction = val.translation.width / screenWidth
        let scrubDuration = min(engine.duration, 120.0) // Up to 2 mins seek range per swipe
        scrubDeltaSeconds = Double(fraction) * scrubDuration
    }

    private func endHorizontalScrub() {
        if activeGestureType == .scrub {
            let target = max(0.0, min(scrubInitialTime + scrubDeltaSeconds, engine.duration))
            engine.seek(to: target)
            activeGestureType = nil
            scrubDeltaSeconds = 0.0
        }
    }

    private func endGesture() {
        withAnimation(.easeOut(duration: 0.3)) {
            activeGestureType = nil
        }
    }

    private func triggerDoubleTapSkip(forward: Bool) {
        if forward {
            engine.seekRelative(seconds: 10)
            withAnimation(.easeInOut(duration: 0.2)) { showSkipRippleRight = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                withAnimation(.easeOut(duration: 0.3)) { showSkipRippleRight = false }
            }
        } else {
            engine.seekRelative(seconds: -10)
            withAnimation(.easeInOut(duration: 0.2)) { showSkipRippleLeft = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                withAnimation(.easeOut(duration: 0.3)) { showSkipRippleLeft = false }
            }
        }
        restartControlsTimer()
    }

    private func toggleControls() {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            showControls.toggle()
        }
        if showControls {
            restartControlsTimer()
        }
    }

    private func restartControlsTimer() {
        controlsTimer?.cancel()
        controlsTimer = Task {
            try? await Task.sleep(nanoseconds: 4_500_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.4)) {
                showControls = false
            }
        }
    }

    // MARK: - HUD Overlays

    @ViewBuilder
    private func gestureFeedbackHUD(size: CGSize) -> some View {
        Group {
            // Brightness HUD (Left Edge)
            if activeGestureType == .brightness {
                HStack {
                    VStack(spacing: 8) {
                        Image(systemName: "sun.max.fill")
                            .font(.system(size: 20, weight: .bold))
                            .foregroundColor(.white)
                        GeometryReader { g in
                            ZStack(alignment: .bottom) {
                                Capsule().fill(Color.white.opacity(0.2))
                                Capsule().fill(Color.white)
                                    .frame(height: g.size.height * CGFloat(gestureValue))
                            }
                        }
                        .frame(width: 6, height: 120)
                        Text("\(Int(gestureValue * 100))%")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundColor(.white)
                    }
                    .padding(12)
                    .background(.ultraThinMaterial)
                    .cornerRadius(16)
                    .padding(.leading, 24)
                    Spacer()
                }
                .transition(.opacity)
            }

            // Volume HUD (Right Edge, 200% VLC Boost)
            if activeGestureType == .volume {
                HStack {
                    Spacer()
                    VStack(spacing: 8) {
                        Image(systemName: gestureValue > 1.0 ? "speaker.wave.3.fill" : (gestureValue > 0 ? "speaker.wave.2.fill" : "speaker.slash.fill"))
                            .font(.system(size: 20, weight: .bold))
                            .foregroundColor(gestureValue > 1.0 ? Color(hex: "FF8800") : .white)
                        GeometryReader { g in
                            ZStack(alignment: .bottom) {
                                Capsule().fill(Color.white.opacity(0.2))
                                Capsule().fill(gestureValue > 1.0 ? Color(hex: "FF8800") : Color.brandAccent)
                                    .frame(height: g.size.height * CGFloat(min(gestureValue, 2.0) / 2.0))
                            }
                        }
                        .frame(width: 6, height: 120)
                        Text(gestureValue > 1.0 ? "BOOST \(Int(gestureValue * 100))%" : "\(Int(gestureValue * 100))%")
                            .font(.system(size: 10, weight: .black, design: .monospaced))
                            .foregroundColor(gestureValue > 1.0 ? Color(hex: "FF8800") : .white)
                    }
                    .padding(12)
                    .background(.ultraThinMaterial)
                    .cornerRadius(16)
                    .padding(.trailing, 24)
                }
                .transition(.opacity)
            }

            // Scrub Seek Central Pill
            if activeGestureType == .scrub {
                let target = max(0.0, min(scrubInitialTime + scrubDeltaSeconds, engine.duration))
                VStack(spacing: 6) {
                    HStack(spacing: 8) {
                        Image(systemName: scrubDeltaSeconds >= 0 ? "goforward" : "gobackward")
                            .font(.system(size: 20, weight: .bold))
                            .foregroundColor(.brandAccent)
                        Text(String(format: "%@%02d:%02d", scrubDeltaSeconds >= 0 ? "+" : "-", Int(abs(scrubDeltaSeconds)) / 60, Int(abs(scrubDeltaSeconds)) % 60))
                            .font(.system(size: 22, weight: .heavy, design: .monospaced))
                            .foregroundColor(.white)
                    }
                    Text(String(format: "%02d:%02d / %02d:%02d", Int(target) / 60, Int(target) % 60, Int(engine.duration) / 60, Int(engine.duration) % 60))
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                        .foregroundColor(.gray)
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 16)
                .background(.ultraThinMaterial)
                .cornerRadius(20)
                .shadow(color: .black.opacity(0.6), radius: 20, x: 0, y: 10)
                .transition(.scale.combined(with: .opacity))
            }
        }
    }

    // MARK: - Double Tap Skip Ripples

    @ViewBuilder
    private var rippleFeedbackOverlay: some View {
        HStack {
            if showSkipRippleLeft {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left")
                    Image(systemName: "chevron.left")
                    Text("10s")
                        .font(.system(size: 14, weight: .bold))
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
                .background(Color.black.opacity(0.65))
                .foregroundColor(.white)
                .clipShape(Capsule())
                .padding(.leading, 40)
            }
            Spacer()
            if showSkipRippleRight {
                HStack(spacing: 4) {
                    Text("10s")
                        .font(.system(size: 14, weight: .bold))
                    Image(systemName: "chevron.right")
                    Image(systemName: "chevron.right")
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
                .background(Color.black.opacity(0.65))
                .foregroundColor(.white)
                .clipShape(Capsule())
                .padding(.trailing, 40)
            }
        }
    }

    // MARK: - Loading Overlay

    @ViewBuilder
    private var loadingOverlay: some View {
        VStack(spacing: 12) {
            ProgressView()
                .scaleEffect(1.4)
                .tint(.brandAccent)
            if let msg = engine.statusMessage {
                Text(msg)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(.ultraThinMaterial)
                    .cornerRadius(12)
            }
        }
    }

    // MARK: - Controls Overlay (Top / Center / Bottom)

    @ViewBuilder
    private var controlsOverlay: some View {
        ZStack {
            // 1. Top Bar
            VStack {
                topControlsBar
                Spacer()
            }

            // 2. Center Playback Transport (Floating in middle)
            if !engine.isControlsLocked {
                centerPlaybackControls
            }

            // 3. Bottom Bar (Scrubber + Tool Pills)
            if !engine.isControlsLocked {
                VStack {
                    Spacer()
                    bottomControlsBar
                }
            }
        }
        .transition(.opacity)
    }

    // MARK: - Top Controls Bar

    @ViewBuilder
    private var topControlsBar: some View {
        HStack(spacing: 12) {
            // Dismiss Button
            Button {
                engine.cleanUp()
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(.white)
                    .frame(width: 38, height: 38)
                    .background(.ultraThinMaterial)
                    .clipShape(Circle())
            }

            // Title & Codec Tag
            VStack(alignment: .leading, spacing: 2) {
                Text(engine.metadata.title.isEmpty ? "VLC Pro Player" : engine.metadata.title)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(.white)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    if !engine.metadata.container.isEmpty {
                        badgeTag(engine.metadata.container, color: .brandAccent)
                    }
                    if !engine.metadata.videoCodec.isEmpty {
                        badgeTag(engine.metadata.videoCodec, color: .skyAccent)
                    }
                    if !engine.metadata.audioCodec.isEmpty {
                        badgeTag(engine.metadata.audioCodec, color: .amberAccent)
                    }
                }
            }

            Spacer()

            if !engine.isControlsLocked {
                // Aspect Ratio Menu
                Menu {
                    ForEach(PlayerAspectRatioMode.allCases) { mode in
                        Button {
                            engine.aspectRatioMode = mode
                        } label: {
                            Label(mode.rawValue, systemImage: mode.iconName)
                        }
                    }
                } label: {
                    Image(systemName: engine.aspectRatioMode.iconName)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(width: 38, height: 38)
                        .background(.ultraThinMaterial)
                        .clipShape(Circle())
                }

                // Inspector Sheet Button
                Button {
                    showInspector = true
                } label: {
                    Image(systemName: "info.circle")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(width: 38, height: 38)
                        .background(.ultraThinMaterial)
                        .clipShape(Circle())
                }
            }

            // Screen Lock Button
            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                    engine.isControlsLocked.toggle()
                    if engine.isControlsLocked {
                        showControls = false
                    }
                }
            } label: {
                Image(systemName: engine.isControlsLocked ? "lock.fill" : "lock.open")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(engine.isControlsLocked ? .amberAccent : .white)
                    .frame(width: 38, height: 38)
                    .background(.ultraThinMaterial)
                    .clipShape(Circle())
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 12)
        .background(
            LinearGradient(colors: [Color.black.opacity(0.85), Color.clear], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
        )
    }

    // MARK: - Center Playback Controls

    @ViewBuilder
    private var centerPlaybackControls: some View {
        HStack(spacing: 28) {
            // Frame Step Back
            Button {
                engine.stepFrame(forward: false)
                restartControlsTimer()
            } label: {
                Image(systemName: "chevron.left.2")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(.white)
                    .frame(width: 44, height: 44)
                    .background(.ultraThinMaterial)
                    .clipShape(Circle())
            }

            // 10s Skip Back
            Button {
                engine.seekRelative(seconds: -10)
                restartControlsTimer()
            } label: {
                Image(systemName: "gobackward.10")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(width: 50, height: 50)
                    .background(.ultraThinMaterial)
                    .clipShape(Circle())
            }

            // Play / Pause (Large Tactile Hero Button)
            Button {
                engine.togglePlayPause()
                restartControlsTimer()
            } label: {
                ZStack {
                    Circle()
                        .fill(LinearGradient.brandGradient)
                        .frame(width: 68, height: 68)
                        .shadow(color: .brandAccent.opacity(0.5), radius: 14)
                    Image(systemName: engine.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 28, weight: .heavy))
                        .foregroundColor(.white)
                        .offset(x: engine.isPlaying ? 0 : 3)
                }
            }

            // 10s Skip Forward
            Button {
                engine.seekRelative(seconds: 10)
                restartControlsTimer()
            } label: {
                Image(systemName: "goforward.10")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(width: 50, height: 50)
                    .background(.ultraThinMaterial)
                    .clipShape(Circle())
            }

            // Frame Step Forward
            Button {
                engine.stepFrame(forward: true)
                restartControlsTimer()
            } label: {
                Image(systemName: "chevron.right.2")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(.white)
                    .frame(width: 44, height: 44)
                    .background(.ultraThinMaterial)
                    .clipShape(Circle())
            }
        }
    }

    private func badgeTag(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .heavy, design: .monospaced))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.2))
            .foregroundColor(color)
            .cornerRadius(4)
    }

    // MARK: - Bottom Controls Bar

    @ViewBuilder
    private var bottomControlsBar: some View {
        VStack(spacing: 8) {
            // Row 1: Scrubber with Timecode Badges on Both Ends
            HStack(spacing: 12) {
                // Current Timecode (Tap to copy!)
                Button(action: copyCurrentTimecode) {
                    HStack(spacing: 4) {
                        Text(formatTime(engine.currentTime))
                            .font(.system(size: 12, weight: .bold, design: .monospaced))
                            .foregroundColor(.white)
                        Image(systemName: showCopiedToast ? "checkmark.circle.fill" : "doc.on.doc")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(showCopiedToast ? .emeraldAccent : .skyAccent)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.ultraThinMaterial)
                    .cornerRadius(8)
                }

                // Smooth Scrubber Slider Track
                GeometryReader { sliderGeo in
                    ZStack(alignment: .leading) {
                        // Background track
                        Capsule()
                            .fill(Color.white.opacity(0.2))
                            .frame(height: 5)

                        // A-B Loop Segment Highlight
                        if let a = engine.loopPointA, engine.duration > 0 {
                            let aPos = CGFloat(a / engine.duration) * sliderGeo.size.width
                            let bPos = engine.loopPointB.map { CGFloat($0 / engine.duration) * sliderGeo.size.width } ?? sliderGeo.size.width
                            Capsule()
                                .fill(Color.amberAccent.opacity(0.6))
                                .frame(width: max(2, bPos - aPos), height: 5)
                                .offset(x: aPos)
                        }

                        // Progress track
                        Capsule()
                            .fill(Color.brandAccent)
                            .frame(width: engine.duration > 0 ? sliderGeo.size.width * CGFloat(engine.currentTime / engine.duration) : 0, height: 5)

                        // Glowing Draggable Thumb
                        Circle()
                            .fill(Color.white)
                            .frame(width: 14, height: 14)
                            .shadow(color: .black.opacity(0.5), radius: 3)
                            .offset(x: engine.duration > 0 ? (sliderGeo.size.width * CGFloat(engine.currentTime / engine.duration)) - 7 : -7)
                    }
                    .frame(height: 20)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { val in
                                let fraction = max(0.0, min(Double(val.location.x / sliderGeo.size.width), 1.0))
                                engine.seek(to: fraction * engine.duration)
                                restartControlsTimer()
                            }
                    )
                }
                .frame(height: 20)

                // Remaining Timecode
                if engine.duration > 0 {
                    Text("-" + formatTime(max(0, engine.duration - engine.currentTime)))
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .foregroundColor(.gray)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 4)
                        .background(.ultraThinMaterial)
                        .cornerRadius(8)
                }
            }

            // Row 2: Compact Secondary Tool Pills
            HStack(spacing: 12) {
                // Playback Speed Menu
                Menu {
                    ForEach([0.25, 0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0, 3.0], id: \.self) { rate in
                        Button {
                            engine.setPlaybackRate(Float(rate))
                        } label: {
                            HStack {
                                Text("\(rate, specifier: "%.2f")x")
                                if engine.playbackRate == Float(rate) {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    Text("\(engine.playbackRate, specifier: "%.2f")x")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(engine.playbackRate != 1.0 ? Color.brandAccent : Color.white.opacity(0.15))
                        .foregroundColor(.white)
                        .cornerRadius(8)
                }

                // A-B Loop Toggle
                Button {
                    if engine.loopPointA == nil {
                        engine.setPointA()
                    } else if engine.loopPointB == nil {
                        engine.setPointB()
                    } else {
                        engine.clearABLoop()
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "repeat")
                            .font(.system(size: 11, weight: .bold))
                        if engine.isLoopingAB {
                            Text("A-B Active")
                                .font(.system(size: 11, weight: .heavy))
                        } else if engine.loopPointA != nil {
                            Text("Set B")
                                .font(.system(size: 11, weight: .heavy))
                        } else {
                            Text("A-B")
                                .font(.system(size: 11, weight: .heavy))
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(engine.isLoopingAB ? Color.amberAccent : (engine.loopPointA != nil ? Color.amberAccent.opacity(0.3) : Color.white.opacity(0.15)))
                    .foregroundColor(engine.isLoopingAB ? .black : .white)
                    .cornerRadius(8)
                }

                // Sleep Timer Menu
                Menu {
                    ForEach(PlayerSleepTimer.allCases) { timer in
                        Button {
                            engine.setSleepTimer(timer)
                        } label: {
                            HStack {
                                Text(timer.label)
                                if engine.sleepTimer == timer {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "moon.fill")
                            .font(.system(size: 11))
                        if engine.sleepTimerRemainingSeconds > 0 {
                            Text(String(format: "%02d:%02d", engine.sleepTimerRemainingSeconds / 60, engine.sleepTimerRemainingSeconds % 60))
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                        } else {
                            Text("Sleep")
                                .font(.system(size: 11, weight: .semibold))
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(engine.sleepTimer != .off ? Color.skyAccent : Color.white.opacity(0.15))
                    .foregroundColor(.white)
                    .cornerRadius(8)
                }

                // Copy Timecode Button
                Button(action: copyCurrentTimecode) {
                    HStack(spacing: 4) {
                        Image(systemName: showCopiedToast ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 11, weight: .bold))
                        Text(showCopiedToast ? "Copied" : "Copy Time")
                            .font(.system(size: 11, weight: .bold))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(showCopiedToast ? Color.emeraldAccent : Color.white.opacity(0.15))
                    .foregroundColor(showCopiedToast ? .black : .white)
                    .cornerRadius(8)
                }

                Spacer()
            }
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 16)
        .background(
            LinearGradient(colors: [Color.clear, Color.black.opacity(0.85)], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
        )
    }

    // MARK: - Empty State File Selector

    @ViewBuilder
    private var emptyStatePicker: some View {
        VStack(spacing: 24) {
            // Header Bar
            HStack {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(.white)
                        .frame(width: 38, height: 38)
                        .background(Color.white.opacity(0.1))
                        .clipShape(Circle())
                }
                Spacer()
                Text("Universal VLC Player")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundColor(.white)
                Spacer()
                Color.clear.frame(width: 38, height: 38)
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)

            Spacer()

            // Big VLC-style Cone Icon & Title
            VStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(
                            RadialGradient(
                                colors: [Color(hex: "FF8800").opacity(0.4), Color.clear],
                                center: .center,
                                startRadius: 10,
                                endRadius: 80
                            )
                        )
                        .frame(width: 140, height: 140)

                    Image(systemName: "play.tv.fill")
                        .font(.system(size: 64, weight: .light))
                        .foregroundColor(Color(hex: "FF8800"))
                }

                Text("Play Any Video Without Remuxing")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundColor(.white)

                Text("Supports MKV, AVI, WebM, MP4, MOV, FLV, TS\nwith DTS, AC3, Dolby & 200% Volume Boost")
                    .font(.system(size: 13))
                    .foregroundColor(.gray)
                    .multilineTextAlignment(.center)
            }

            // Action Buttons
            VStack(spacing: 12) {
                // Open from Files
                Button {
                    showDocPicker = true
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "folder.fill")
                            .font(.system(size: 18, weight: .bold))
                        Text("Open from Files / iCloud")
                            .font(.system(size: 15, weight: .bold))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Color(hex: "FF8800"))
                    .foregroundColor(.black)
                    .cornerRadius(14)
                }

                // Pick from Photos
                PhotosPicker(selection: $photoItem, matching: .videos) {
                    HStack(spacing: 12) {
                        Image(systemName: "photo.on.rectangle.angled")
                            .font(.system(size: 18, weight: .bold))
                        Text("Pick from Photos Library")
                            .font(.system(size: 15, weight: .bold))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Color.white.opacity(0.12))
                    .foregroundColor(.white)
                    .cornerRadius(14)
                }
            }
            .padding(.horizontal, 32)

            // Recent Files Carousel
            if !recentFiles.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("RECENT VIDEOS")
                        .font(.system(size: 11, weight: .heavy, design: .monospaced))
                        .foregroundColor(.gray)
                        .padding(.horizontal, 24)

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 12) {
                            ForEach(recentFiles, id: \.self) { url in
                                Button {
                                    Task {
                                        await engine.loadMedia(url: url)
                                    }
                                } label: {
                                    VStack(alignment: .leading, spacing: 6) {
                                        ZStack(alignment: .bottomLeading) {
                                            RoundedRectangle(cornerRadius: 10)
                                                .fill(Color.white.opacity(0.08))
                                                .frame(width: 130, height: 80)
                                            Image(systemName: "play.circle.fill")
                                                .font(.system(size: 28))
                                                .foregroundColor(Color(hex: "FF8800"))
                                                .frame(maxWidth: .infinity, maxHeight: .infinity)

                                            if let pos = engine.getSavedPlaybackPosition(for: url) {
                                                HStack(spacing: 3) {
                                                    Image(systemName: "clock.arrow.circlepath")
                                                        .font(.system(size: 8, weight: .bold))
                                                    Text(formatTime(pos))
                                                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                                                }
                                                .padding(.horizontal, 6)
                                                .padding(.vertical, 2)
                                                .background(Color.amberAccent.opacity(0.85))
                                                .foregroundColor(.black)
                                                .cornerRadius(4)
                                                .padding(6)
                                            }
                                        }
                                        Text(url.lastPathComponent)
                                            .font(.system(size: 11, weight: .semibold))
                                            .foregroundColor(.white)
                                            .lineLimit(1)
                                            .frame(width: 130, alignment: .leading)
                                    }
                                }
                            }
                        }
                        .padding(.horizontal, 24)
                    }
                }
            }

            Spacer()
        }
    }

    // MARK: - Media Inspector Sheet

    @ViewBuilder
    private var mediaInspectorSheet: some View {
        NavigationStack {
            ZStack {
                Color.voidCanvas.ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 16) {
                        inspectorCard(title: "CONTAINER & FORMAT") {
                            inspectorRow("File Name", value: engine.metadata.title)
                            inspectorRow("Container", value: engine.metadata.container)
                            inspectorRow("File Size", value: engine.metadata.fileSizeFormatted)
                            inspectorRow("Bitrate", value: "\(engine.metadata.bitrateKbps) kbps")
                            inspectorRow("Duration", value: formatTime(engine.duration))
                        }

                        inspectorCard(title: "VIDEO STREAM") {
                            inspectorRow("Codec", value: engine.metadata.videoCodec.isEmpty ? "Direct / Apple H.264" : engine.metadata.videoCodec)
                            inspectorRow("Resolution", value: "\(engine.metadata.width) x \(engine.metadata.height)")
                            inspectorRow("Frame Rate", value: String(format: "%.2f fps", engine.metadata.frameRate))
                        }

                        inspectorCard(title: "AUDIO STREAM") {
                            inspectorRow("Codec", value: engine.metadata.audioCodec.isEmpty ? "AAC" : engine.metadata.audioCodec)
                            inspectorRow("Channels", value: "\(engine.metadata.audioChannels) Channels")
                            inspectorRow("Sample Rate", value: "\(engine.metadata.audioSampleRate) Hz")
                            inspectorRow("Volume Boost", value: "\(Int(engine.volume * 100))%")
                        }
                    }
                    .padding(20)
                }
            }
            .navigationTitle("Media Inspector")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        showInspector = false
                    }
                    .foregroundColor(.brandAccent)
                }
            }
        }
    }

    private func inspectorCard<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 11, weight: .heavy, design: .monospaced))
                .foregroundColor(.brandAccent)
            VStack(spacing: 8) {
                content()
            }
            .padding(14)
            .background(Color.white.opacity(0.06))
            .cornerRadius(12)
        }
    }

    private func inspectorRow(_ label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 13))
                .foregroundColor(.gray)
            Spacer()
            Text(value)
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundColor(.white)
        }
    }

    // MARK: - Helpers

    private func copyCurrentTimecode() {
        let precise = formatPreciseTimecode(engine.currentTime)
        UIPasteboard.general.string = precise
        copiedTimecodeString = precise
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
            showCopiedToast = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            withAnimation(.easeOut(duration: 0.3)) {
                showCopiedToast = false
            }
        }
    }

    private func formatPreciseTimecode(_ seconds: Double) -> String {
        guard !seconds.isNaN && !seconds.isInfinite && seconds >= 0 else { return "00:00:00.000" }
        let total = Int(seconds)
        let hrs = total / 3600
        let mins = (total % 3600) / 60
        let secs = total % 60
        let millis = Int((seconds.truncatingRemainder(dividingBy: 1.0)) * 1000)
        return String(format: "%02d:%02d:%02d.%03d", hrs, mins, secs, millis)
    }

    private func formatTime(_ seconds: Double) -> String {
        guard !seconds.isNaN && !seconds.isInfinite else { return "00:00" }
        let total = Int(seconds)
        let hrs = total / 3600
        let mins = (total % 3600) / 60
        let secs = total % 60
        if hrs > 0 {
            return String(format: "%d:%02d:%02d", hrs, mins, secs)
        } else {
            return String(format: "%02d:%02d", mins, secs)
        }
    }

    private func loadRecentFiles() {
        var files: [URL] = []
        // Gather files from app documents and downloads folder
        let fileManager = FileManager.default
        if let docs = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first {
            if let items = try? fileManager.contentsOfDirectory(at: docs, includingPropertiesForKeys: [.contentModificationDateKey], options: .skipsHiddenFiles) {
                let videoExtensions: Set<String> = ["mp4", "mov", "m4v", "mkv", "avi", "webm", "flv", "ts"]
                let sorted = items.filter { videoExtensions.contains($0.pathExtension.lowercased()) }
                    .sorted { (u1, u2) -> Bool in
                        let d1 = (try? u1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date.distantPast
                        let d2 = (try? u2.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date.distantPast
                        return d1 > d2
                    }
                files.append(contentsOf: sorted.prefix(8))
            }
        }
        self.recentFiles = files
    }
}

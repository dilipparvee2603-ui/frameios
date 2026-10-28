import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

private enum CornerType {
    case topLeft, topRight, bottomLeft, bottomRight
}

struct ImageCropperView: View {
    @Environment(\.dismiss) private var dismiss

    // Image state
    @State private var sourceImage: UIImage? = nil
    @State private var selectedPhotoItem: PhotosPickerItem? = nil
    @State private var showFilePicker: Bool = false

    // Transform & Crop state
    @State private var selectedRatio: CropRatio = .free
    @State private var rotationDegrees: Int = 0
    @State private var isFlipped: Bool = false
    @State private var selectedFormat: CropFormat = .png

    // Interactive Crop Box & Zoom state
    @State private var cropUnitRect: CGRect = CGRect(x: 0, y: 0, width: 1.0, height: 1.0)
    @State private var dragStartUnitRect: CGRect? = nil
    @State private var zoomScale: CGFloat = 1.0
    @State private var baseZoomScale: CGFloat = 1.0

    // Export state
    @State private var isCropping: Bool = false
    @State private var exportedFileUrl: URL? = nil
    @State private var showShareSheet: Bool = false
    @State private var alertMessage: String? = nil
    @State private var showAlert: Bool = false

    var body: some View {
        ZStack {
            Color.voidCanvas.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 16) {
                    headerBar

                    if let img = sourceImage {
                        imageCanvasSection(for: img)
                        ratioSelectorSection(for: img)
                        transformControlsSection(for: img)
                        formatSelectorSection
                        cropActionButton(for: img)

                        if exportedFileUrl != nil {
                            shareSheetButton
                        }

                        Spacer(minLength: 24)
                    } else {
                        emptyImportSection
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
            }
        }
        .navigationBarBackButtonHidden(true)
        .onChange(of: selectedPhotoItem) { newItem in
            Task {
                if let item = newItem {
                    await loadFromPhotos(item: item)
                }
            }
        }
        .fileImporter(
            isPresented: $showFilePicker,
            allowedContentTypes: [.image, .png, .jpeg, UTType(filenameExtension: "heic") ?? .image, UTType(filenameExtension: "webp") ?? .image],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first {
                    loadFromFiles(url: url)
                }
            case .failure(let error):
                alertMessage = "File import error: \(error.localizedDescription)"
                showAlert = true
            }
        }
        .sheet(isPresented: $showShareSheet) {
            if let outUrl = exportedFileUrl {
                ShareActivityView(activityItems: [outUrl])
            }
        }
        .alert(isPresented: $showAlert) {
            Alert(
                title: Text("CFX Image Cropper"),
                message: Text(alertMessage ?? ""),
                dismissButton: .default(Text("OK"))
            )
        }
    }

    // MARK: - Subviews

    @ViewBuilder
    private var headerBar: some View {
        HStack {
            Button(action: { dismiss() }) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(.textPrimary)
                    .frame(width: 36, height: 36)
                    .background(Color.surfaceCard)
                    .clipShape(Circle())
            }

            Text("IMAGE CROPPER STUDIO")
                .font(.system(size: 15, weight: .bold))
                .foregroundColor(.textPrimary)

            Spacer()

            HStack(spacing: 8) {
                PhotosPicker(selection: $selectedPhotoItem, matching: .images) {
                    Image(systemName: "photo.on.rectangle.angled")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(.amberAccent)
                        .frame(width: 36, height: 36)
                        .background(Color.surfaceCard)
                        .clipShape(Circle())
                }

                Button(action: { showFilePicker = true }) {
                    Image(systemName: "folder.fill")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(.amberAccent)
                        .frame(width: 36, height: 36)
                        .background(Color.surfaceCard)
                        .clipShape(Circle())
                }
            }
        }
    }

    @ViewBuilder
    private var emptyImportSection: some View {
        VStack(spacing: 14) {
            // Import from Photos
            PhotosPicker(selection: $selectedPhotoItem, matching: .images) {
                GlassCard(cornerRadius: 18, padding: 22) {
                    HStack(spacing: 16) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 12)
                                .fill(Color.amberAccent.opacity(0.15))
                                .frame(width: 48, height: 48)
                            Image(systemName: "photo.on.rectangle.angled")
                                .font(.system(size: 22, weight: .bold))
                                .foregroundColor(.amberAccent)
                        }

                        VStack(alignment: .leading, spacing: 3) {
                            Text("Import from Camera Roll")
                                .font(.system(size: 15, weight: .bold))
                                .foregroundColor(.textPrimary)
                            Text("High-res photos from your library")
                                .font(.system(size: 12))
                                .foregroundColor(.textMuted)
                        }

                        Spacer()

                        Image(systemName: "chevron.right")
                            .foregroundColor(.textTertiary)
                    }
                }
            }

            // Import from Files
            Button(action: { showFilePicker = true }) {
                GlassCard(cornerRadius: 18, padding: 22) {
                    HStack(spacing: 16) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 12)
                                .fill(Color.emeraldAccent.opacity(0.15))
                                .frame(width: 48, height: 48)
                            Image(systemName: "folder.fill")
                                .font(.system(size: 22, weight: .bold))
                                .foregroundColor(.emeraldAccent)
                        }

                        VStack(alignment: .leading, spacing: 3) {
                            Text("Import from Files App")
                                .font(.system(size: 15, weight: .bold))
                                .foregroundColor(.textPrimary)
                            Text("PNG, JPG, HEIC, WebP documents")
                                .font(.system(size: 12))
                                .foregroundColor(.textMuted)
                        }

                        Spacer()

                        Image(systemName: "chevron.right")
                            .foregroundColor(.textTertiary)
                    }
                }
            }

            // Pro Features Card
            GlassCard(cornerRadius: 18, padding: 18) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 8) {
                        Image(systemName: "sparkles")
                            .foregroundColor(.amberAccent)
                            .font(.system(size: 14, weight: .bold))
                        Text("PRO STUDIO FEATURES")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(.textMuted)
                            .tracking(1.0)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        featureRow(icon: "crop", title: "Adjustable Crop Frame", desc: "Drag frame to reposition & drag corner handles to resize")
                        featureRow(icon: "magnifyingglass", title: "Pinch & Slider Zoom", desc: "Zoom up to 4.0x for precision cropping of fine details")
                        featureRow(icon: "aspectratio", title: "Social Aspect Ratios", desc: "1:1 Square, 4:5 Portrait, 16:9 YouTube, 9:16 Reels/TikTok")
                        featureRow(icon: "rotate.right", title: "Transform & Orient", desc: "90° lossless rotation and horizontal mirroring")
                        featureRow(icon: "arrow.down.doc", title: "Dual Export Engine", desc: "Lossless PNG & 100% JPG with direct save & Files sheet")
                    }
                }
            }
        }
        .padding(.top, 10)
    }

    @ViewBuilder
    private func featureRow(icon: String, title: String, desc: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.amberAccent)
                .frame(width: 20)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.textPrimary)
                Text(desc)
                    .font(.system(size: 11))
                    .foregroundColor(.textMuted)
            }
        }
    }

    @ViewBuilder
    private func imageCanvasSection(for img: UIImage) -> some View {
        let eff = effectiveDimensions(for: img)
        let nativeW = max(1, Int(cropUnitRect.width * eff.width))
        let nativeH = max(1, Int(cropUnitRect.height * eff.height))

        VStack(spacing: 8) {
            ZStack(alignment: .topTrailing) {
                GeometryReader { geo in
                    let containerSize = geo.size
                    canvasContent(containerSize: containerSize, image: img, effectiveSize: eff)
                }
                .frame(maxWidth: .infinity)
                .aspectRatio(1.0, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(Color.borderHairline, lineWidth: 1)
                )

                resolutionBadge(nativeW: nativeW, nativeH: nativeH)
                    .padding(10)
            }

            zoomControlsBar
        }
    }

    @ViewBuilder
    private func canvasContent(containerSize: CGSize, image: UIImage, effectiveSize: CGSize) -> some View {
        let effW = effectiveSize.width
        let effH = effectiveSize.height

        if effW > 0, effH > 0 {
            let imgAspect = effW / effH
            let containerAspect = containerSize.width / containerSize.height

            let fitW: CGFloat = imgAspect > containerAspect ? containerSize.width : containerSize.height * imgAspect
            let fitH: CGFloat = imgAspect > containerAspect ? containerSize.width / imgAspect : containerSize.height

            let originX = (containerSize.width - fitW) / 2.0
            let originY = (containerSize.height - fitH) / 2.0

            let boxX = originX + cropUnitRect.origin.x * fitW
            let boxY = originY + cropUnitRect.origin.y * fitH
            let boxW = max(10, cropUnitRect.size.width * fitW)
            let boxH = max(10, cropUnitRect.size.height * fitH)

            ZStack {
                Color.black

                // Fitted Image with rotation, flip and zoom
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .rotationEffect(.degrees(Double(rotationDegrees)))
                    .scaleEffect(x: (isFlipped ? -1 : 1) * zoomScale, y: zoomScale)
                    .frame(width: fitW, height: fitH)
                    .position(x: containerSize.width / 2.0, y: containerSize.height / 2.0)

                // 4 Surrounding Dark Scrims (dimming outside crop box)
                scrimView(containerSize: containerSize, boxX: boxX, boxY: boxY, boxW: boxW, boxH: boxH)

                // Center Box with grid, move icon and drag gesture
                centerBoxView(boxX: boxX, boxY: boxY, boxW: boxW, boxH: boxH, fitW: fitW, fitH: fitH)

                // 4 Corner Handles with 44x44 touch targets
                cornerHandlesLayer(boxX: boxX, boxY: boxY, boxW: boxW, boxH: boxH, fitW: fitW, fitH: fitH, effW: effW, effH: effH)
            }
            .gesture(
                MagnificationGesture()
                    .onChanged { val in
                        zoomScale = clampVal(baseZoomScale * val, 1.0, 4.0)
                    }
                    .onEnded { _ in
                        baseZoomScale = zoomScale
                    }
            )
        }
    }

    @ViewBuilder
    private func scrimView(containerSize: CGSize, boxX: CGFloat, boxY: CGFloat, boxW: CGFloat, boxH: CGFloat) -> some View {
        let scrimColor = Color.black.opacity(0.55)
        ZStack {
            // Top scrim
            if boxY > 0 {
                scrimColor
                    .frame(width: containerSize.width, height: boxY)
                    .position(x: containerSize.width / 2.0, y: boxY / 2.0)
            }
            // Bottom scrim
            let bottomH = max(0, containerSize.height - (boxY + boxH))
            if bottomH > 0 {
                scrimColor
                    .frame(width: containerSize.width, height: bottomH)
                    .position(x: containerSize.width / 2.0, y: (boxY + boxH) + bottomH / 2.0)
            }
            // Left scrim
            if boxX > 0 {
                scrimColor
                    .frame(width: boxX, height: boxH)
                    .position(x: boxX / 2.0, y: boxY + boxH / 2.0)
            }
            // Right scrim
            let rightW = max(0, containerSize.width - (boxX + boxW))
            if rightW > 0 {
                scrimColor
                    .frame(width: rightW, height: boxH)
                    .position(x: (boxX + boxW) + rightW / 2.0, y: boxY + boxH / 2.0)
            }
        }
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private func centerBoxView(boxX: CGFloat, boxY: CGFloat, boxW: CGFloat, boxH: CGFloat, fitW: CGFloat, fitH: CGFloat) -> some View {
        ZStack {
            // Transparent touch target for dragging the entire box
            Color.white.opacity(0.001)
                .frame(width: boxW, height: boxH)

            // Amber border
            Rectangle()
                .stroke(Color.amberAccent, lineWidth: 1.5)
                .frame(width: boxW, height: boxH)

            // Subtle Rule-of-Thirds Grid
            VStack {
                Spacer()
                Divider().background(Color.white.opacity(0.25))
                Spacer()
                Divider().background(Color.white.opacity(0.25))
                Spacer()
            }
            .frame(width: boxW, height: boxH)

            HStack {
                Spacer()
                Divider().background(Color.white.opacity(0.25))
                Spacer()
                Divider().background(Color.white.opacity(0.25))
                Spacer()
            }
            .frame(width: boxW, height: boxH)

            // Move glyph in center
            Image(systemName: "arrow.up.and.down.and.arrow.left.and.right")
                .font(.system(size: 16, weight: .bold))
                .foregroundColor(.white.opacity(0.45))
        }
        .position(x: boxX + boxW / 2.0, y: boxY + boxH / 2.0)
        .gesture(
            DragGesture(minimumDistance: 1)
                .onChanged { val in
                    if dragStartUnitRect == nil {
                        dragStartUnitRect = cropUnitRect
                    }
                    guard let start = dragStartUnitRect else { return }
                    let deltaX = val.translation.width / fitW
                    let deltaY = val.translation.height / fitH
                    let newX = clampVal(start.origin.x + deltaX, 0, 1.0 - start.width)
                    let newY = clampVal(start.origin.y + deltaY, 0, 1.0 - start.height)
                    cropUnitRect = CGRect(x: newX, y: newY, width: start.width, height: start.height)
                }
                .onEnded { _ in
                    dragStartUnitRect = nil
                }
        )
    }

    @ViewBuilder
    private func cornerHandlesLayer(boxX: CGFloat, boxY: CGFloat, boxW: CGFloat, boxH: CGFloat, fitW: CGFloat, fitH: CGFloat, effW: CGFloat, effH: CGFloat) -> some View {
        ZStack {
            cornerHandleView(type: .topLeft, x: boxX, y: boxY, fitW: fitW, fitH: fitH, effW: effW, effH: effH)
            cornerHandleView(type: .topRight, x: boxX + boxW, y: boxY, fitW: fitW, fitH: fitH, effW: effW, effH: effH)
            cornerHandleView(type: .bottomLeft, x: boxX, y: boxY + boxH, fitW: fitW, fitH: fitH, effW: effW, effH: effH)
            cornerHandleView(type: .bottomRight, x: boxX + boxW, y: boxY + boxH, fitW: fitW, fitH: fitH, effW: effW, effH: effH)
        }
    }

    @ViewBuilder
    private func cornerHandleView(type: CornerType, x: CGFloat, y: CGFloat, fitW: CGFloat, fitH: CGFloat, effW: CGFloat, effH: CGFloat) -> some View {
        ZStack {
            Circle()
                .fill(Color.white)
                .frame(width: 14, height: 14)
                .overlay(Circle().stroke(Color.amberAccent, lineWidth: 2.5))
                .shadow(color: Color.black.opacity(0.6), radius: 3, x: 0, y: 1)
        }
        .frame(width: 44, height: 44)
        .contentShape(Rectangle())
        .position(x: x, y: y)
        .gesture(
            DragGesture(minimumDistance: 1)
                .onChanged { val in
                    handleCornerDrag(corner: type, translation: val.translation, fitW: fitW, fitH: fitH, effectiveW: effW, effectiveH: effH)
                }
                .onEnded { _ in
                    dragStartUnitRect = nil
                }
        )
    }

    @ViewBuilder
    private func resolutionBadge(nativeW: Int, nativeH: Int) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(Color.emeraldAccent)
                .frame(width: 6, height: 6)

            Text("\(nativeW) × \(nativeH) px")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundColor(.emeraldAccent)

            Text("• \(selectedRatio.rawValue)")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.textMuted)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.surfaceCard.opacity(0.92))
        .clipShape(Capsule())
        .overlay(
            Capsule()
                .stroke(Color.borderHairline, lineWidth: 1)
        )
    }

    @ViewBuilder
    private var zoomControlsBar: some View {
        GlassCard(cornerRadius: 12, padding: 8) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.amberAccent)
                    .font(.system(size: 11, weight: .bold))

                Text(String(format: "%.1fx", zoomScale))
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundColor(.textPrimary)
                    .frame(width: 32, alignment: .leading)

                Slider(value: $zoomScale, in: 1.0...4.0, step: 0.1)
                    .accentColor(.amberAccent)

                Button(action: {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        zoomScale = 1.0
                        baseZoomScale = 1.0
                        if let img = sourceImage {
                            let eff = effectiveDimensions(for: img)
                            cropUnitRect = ImageCropEngine.computeDefaultUnitRect(imageSize: eff, ratio: selectedRatio)
                        }
                    }
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.counterclockwise")
                            .font(.system(size: 10, weight: .bold))
                        Text("Reset")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundColor(.textMuted)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.elevatedSurface)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }
            }
        }
    }

    @ViewBuilder
    private func ratioSelectorSection(for img: UIImage) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("ASPECT RATIO")
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(.textMuted)
                .tracking(1.0)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(CropRatio.allCases) { ratio in
                        Button(action: {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                selectedRatio = ratio
                                let eff = effectiveDimensions(for: img)
                                cropUnitRect = ImageCropEngine.computeDefaultUnitRect(imageSize: eff, ratio: ratio)
                            }
                        }) {
                            VStack(spacing: 3) {
                                Text(ratio.rawValue)
                                    .font(.system(size: 13, weight: .bold))
                                    .foregroundColor(selectedRatio == ratio ? .gradientStart : .textPrimary)

                                Text(ratio.subtitle)
                                    .font(.system(size: 9))
                                    .foregroundColor(selectedRatio == ratio ? .gradientStart.opacity(0.8) : .textMuted)
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(selectedRatio == ratio ? Color.brandAccent.opacity(0.25) : Color.elevatedSurface)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                            .overlay(
                                RoundedRectangle(cornerRadius: 10)
                                    .stroke(selectedRatio == ratio ? Color.brandAccent : Color.borderHairline, lineWidth: 1)
                            )
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func transformControlsSection(for img: UIImage) -> some View {
        HStack(spacing: 12) {
            // Rotate 90°
            Button(action: {
                withAnimation(.easeInOut(duration: 0.2)) {
                    rotationDegrees = (rotationDegrees + 90) % 360
                    let eff = effectiveDimensions(for: img)
                    cropUnitRect = ImageCropEngine.computeDefaultUnitRect(imageSize: eff, ratio: selectedRatio)
                }
            }) {
                HStack(spacing: 6) {
                    Image(systemName: "rotate.right")
                        .font(.system(size: 13, weight: .bold))
                    Text("Rotate 90°")
                        .font(.system(size: 12, weight: .semibold))
                }
                .foregroundColor(.textPrimary)
                .frame(maxWidth: .infinity)
                .frame(height: 38)
                .background(Color.elevatedSurface)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.borderHairline, lineWidth: 1)
                )
            }

            // Flip Horizontal
            Button(action: {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isFlipped.toggle()
                }
            }) {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.left.and.right.righttriangle.left.righttriangle.right")
                        .font(.system(size: 13, weight: .bold))
                    Text("Flip")
                        .font(.system(size: 12, weight: .semibold))
                }
                .foregroundColor(.textPrimary)
                .frame(maxWidth: .infinity)
                .frame(height: 38)
                .background(Color.elevatedSurface)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.borderHairline, lineWidth: 1)
                )
            }

            // Reset
            Button(action: {
                withAnimation(.easeInOut(duration: 0.2)) {
                    rotationDegrees = 0
                    isFlipped = false
                    zoomScale = 1.0
                    baseZoomScale = 1.0
                    selectedRatio = .free
                    let eff = effectiveDimensions(for: img)
                    cropUnitRect = ImageCropEngine.computeDefaultUnitRect(imageSize: eff, ratio: .free)
                }
            }) {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 13, weight: .bold))
                    Text("Reset")
                        .font(.system(size: 12, weight: .semibold))
                }
                .foregroundColor(.textMuted)
                .frame(maxWidth: .infinity)
                .frame(height: 38)
                .background(Color.elevatedSurface)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.borderHairline, lineWidth: 1)
                )
            }
        }
    }

    @ViewBuilder
    private var formatSelectorSection: some View {
        GlassCard(cornerRadius: 14, padding: 12) {
            HStack {
                Text("Output Format")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.textPrimary)

                Spacer()

                HStack(spacing: 8) {
                    ForEach(CropFormat.allCases) { fmt in
                        Button(action: { selectedFormat = fmt }) {
                            Text(fmt.rawValue)
                                .font(.system(size: 11, weight: .bold))
                                .foregroundColor(selectedFormat == fmt ? .amberAccent : .textMuted)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(selectedFormat == fmt ? Color.amberAccent.opacity(0.18) : Color.surfaceCard)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8)
                                        .stroke(selectedFormat == fmt ? Color.amberAccent : Color.borderHairline, lineWidth: 1)
                                )
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func cropActionButton(for img: UIImage) -> some View {
        Button(action: {
            cropAndSave(image: img)
        }) {
            HStack(spacing: 8) {
                if isCropping {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
                        .scaleEffect(0.9)
                    Text("Cropping & Saving...")
                        .font(.system(size: 14, weight: .bold))
                } else {
                    Image(systemName: "crop")
                        .font(.system(size: 15, weight: .bold))
                    Text("Save Cropped Image (\(selectedRatio.rawValue))")
                        .font(.system(size: 14, weight: .bold))
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 48)
            .background(LinearGradient.brandGradient)
            .foregroundColor(.white)
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .disabled(isCropping)
    }

    @ViewBuilder
    private var shareSheetButton: some View {
        Button(action: { showShareSheet = true }) {
            HStack(spacing: 8) {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 14, weight: .bold))
                Text("Share / Save Cropped Image to Files")
                    .font(.system(size: 13, weight: .bold))
            }
            .frame(maxWidth: .infinity)
            .frame(height: 44)
            .background(Color.elevatedSurface)
            .foregroundColor(.amberAccent)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.amberAccent.opacity(0.4), lineWidth: 1)
            )
        }
    }

    // MARK: - Logic & Gestures

    private func clampVal(_ value: CGFloat, _ minVal: CGFloat, _ maxVal: CGFloat) -> CGFloat {
        return min(max(value, minVal), maxVal)
    }

    private func effectiveDimensions(for img: UIImage) -> CGSize {
        let isRotated90 = (rotationDegrees / 90) % 2 != 0
        let w = isRotated90 ? img.size.height : img.size.width
        let h = isRotated90 ? img.size.width : img.size.height
        return CGSize(width: max(1, w), height: max(1, h))
    }

    private func handleCornerDrag(corner: CornerType, translation: CGSize, fitW: CGFloat, fitH: CGFloat, effectiveW: CGFloat, effectiveH: CGFloat) {
        if dragStartUnitRect == nil {
            dragStartUnitRect = cropUnitRect
        }
        guard let start = dragStartUnitRect else { return }

        let deltaX = translation.width / fitW
        let deltaY = translation.height / fitH

        let targetAspect: CGFloat? = selectedRatio.dimensions.map { $0.0 / $0.1 }
        let k: CGFloat = targetAspect != nil ? ((effectiveW / effectiveH) / targetAspect!) : 1.0

        switch corner {
        case .bottomRight:
            if targetAspect == nil {
                let newW = clampVal(start.width + deltaX, 0.12, 1.0 - start.origin.x)
                let newH = clampVal(start.height + deltaY, 0.12, 1.0 - start.origin.y)
                cropUnitRect = CGRect(x: start.origin.x, y: start.origin.y, width: newW, height: newH)
            } else {
                var newW = clampVal(start.width + deltaX, 0.12, 1.0 - start.origin.x)
                var newH = newW * k
                if start.origin.y + newH > 1.0 {
                    newH = 1.0 - start.origin.y
                    newW = newH / k
                }
                if newW >= 0.12 && newH >= 0.12 {
                    cropUnitRect = CGRect(x: start.origin.x, y: start.origin.y, width: newW, height: newH)
                }
            }

        case .topLeft:
            if targetAspect == nil {
                let newX = clampVal(start.origin.x + deltaX, 0, start.maxX - 0.12)
                let newY = clampVal(start.origin.y + deltaY, 0, start.maxY - 0.12)
                cropUnitRect = CGRect(x: newX, y: newY, width: start.maxX - newX, height: start.maxY - newY)
            } else {
                var newW = clampVal(start.width - deltaX, 0.12, start.maxX)
                var newH = newW * k
                if newH > start.maxY {
                    newH = start.maxY
                    newW = newH / k
                }
                let newX = start.maxX - newW
                let newY = start.maxY - newH
                if newX >= 0 && newY >= 0 && newW >= 0.12 && newH >= 0.12 {
                    cropUnitRect = CGRect(x: newX, y: newY, width: newW, height: newH)
                }
            }

        case .topRight:
            if targetAspect == nil {
                let newW = clampVal(start.width + deltaX, 0.12, 1.0 - start.origin.x)
                let newY = clampVal(start.origin.y + deltaY, 0, start.maxY - 0.12)
                cropUnitRect = CGRect(x: start.origin.x, y: newY, width: newW, height: start.maxY - newY)
            } else {
                var newW = clampVal(start.width + deltaX, 0.12, 1.0 - start.origin.x)
                var newH = newW * k
                if newH > start.maxY {
                    newH = start.maxY
                    newW = newH / k
                }
                let newY = start.maxY - newH
                if newY >= 0 && newW >= 0.12 && newH >= 0.12 {
                    cropUnitRect = CGRect(x: start.origin.x, y: newY, width: newW, height: newH)
                }
            }

        case .bottomLeft:
            if targetAspect == nil {
                let newX = clampVal(start.origin.x + deltaX, 0, start.maxX - 0.12)
                let newH = clampVal(start.height + deltaY, 0.12, 1.0 - start.origin.y)
                cropUnitRect = CGRect(x: newX, y: start.origin.y, width: start.maxX - newX, height: newH)
            } else {
                var newW = clampVal(start.width - deltaX, 0.12, start.maxX)
                var newH = newW * k
                if start.origin.y + newH > 1.0 {
                    newH = 1.0 - start.origin.y
                    newW = newH / k
                }
                let newX = start.maxX - newW
                if newX >= 0 && newW >= 0.12 && newH >= 0.12 {
                    cropUnitRect = CGRect(x: newX, y: start.origin.y, width: newW, height: newH)
                }
            }
        }
    }

    private func loadFromPhotos(item: PhotosPickerItem) async {
        do {
            if let data = try await item.loadTransferable(type: Data.self),
               let loaded = UIImage(data: data) {
                await MainActor.run {
                    self.sourceImage = loaded
                    self.rotationDegrees = 0
                    self.isFlipped = false
                    self.zoomScale = 1.0
                    self.baseZoomScale = 1.0
                    self.exportedFileUrl = nil
                    let eff = self.effectiveDimensions(for: loaded)
                    self.cropUnitRect = ImageCropEngine.computeDefaultUnitRect(imageSize: eff, ratio: self.selectedRatio)
                }
            }
        } catch {
            await MainActor.run {
                self.alertMessage = "Failed to load photo: \(error.localizedDescription)"
                self.showAlert = true
            }
        }
    }

    private func loadFromFiles(url: URL) {
        let isScoped = url.startAccessingSecurityScopedResource()
        defer {
            if isScoped { url.stopAccessingSecurityScopedResource() }
        }

        do {
            let data = try Data(contentsOf: url)
            if let loaded = UIImage(data: data) {
                self.sourceImage = loaded
                self.rotationDegrees = 0
                self.isFlipped = false
                self.zoomScale = 1.0
                self.baseZoomScale = 1.0
                self.exportedFileUrl = nil
                let eff = self.effectiveDimensions(for: loaded)
                self.cropUnitRect = ImageCropEngine.computeDefaultUnitRect(imageSize: eff, ratio: self.selectedRatio)
            } else {
                self.alertMessage = "Unable to decode image from selected file."
                self.showAlert = true
            }
        } catch {
            self.alertMessage = "Failed to read file: \(error.localizedDescription)"
            self.showAlert = true
        }
    }

    private func cropAndSave(image: UIImage) {
        guard !isCropping else { return }
        isCropping = true

        Task {
            do {
                let eff = effectiveDimensions(for: image)
                let pixelX = clampVal(cropUnitRect.origin.x * eff.width, 0, eff.width - 1)
                let pixelY = clampVal(cropUnitRect.origin.y * eff.height, 0, eff.height - 1)
                let pixelW = clampVal(cropUnitRect.size.width * eff.width, 1, eff.width - pixelX)
                let pixelH = clampVal(cropUnitRect.size.height * eff.height, 1, eff.height - pixelY)

                let finalCropRect = CGRect(x: pixelX, y: pixelY, width: pixelW, height: pixelH).integral

                guard let cropped = ImageCropEngine.cropImage(
                    image,
                    to: finalCropRect,
                    rotationDegrees: rotationDegrees,
                    isFlipped: isFlipped
                ) else {
                    throw NSError(domain: "ImageCropper", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to perform crop operation."])
                }

                // Save to temp file for sharing / files app
                let tempUrl = try ImageCropEngine.saveToTempFile(image: cropped, format: selectedFormat)

                // Attempt to save to Camera Roll
                var savedToPhotos = false
                do {
                    _ = try await ImageCropEngine.saveToPhotos(image: cropped, format: selectedFormat)
                    savedToPhotos = true
                } catch {
                    savedToPhotos = false
                }

                await MainActor.run {
                    self.isCropping = false
                    self.exportedFileUrl = tempUrl

                    if savedToPhotos {
                        self.alertMessage = "✓ Cropped image (\(Int(finalCropRect.width)) × \(Int(finalCropRect.height)) px) saved to Camera Roll!"
                        self.showAlert = true
                    } else {
                        // Automatically open Save to Files / Share Sheet!
                        self.showShareSheet = true
                    }
                }
            } catch {
                await MainActor.run {
                    self.isCropping = false
                    self.alertMessage = "Crop error: \(error.localizedDescription)"
                    self.showAlert = true
                }
            }
        }
    }
}

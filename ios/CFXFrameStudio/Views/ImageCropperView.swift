import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

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
                        ratioSelectorSection
                        transformControlsSection
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
                        featureRow(icon: "crop", title: "Lossless Pixel Cropping", desc: "No quality loss, preserves original native resolution")
                        featureRow(icon: "aspectratio", title: "Social Aspect Ratios", desc: "1:1 Square, 4:5 Portrait, 16:9 YouTube, 9:16 Reels/TikTok")
                        featureRow(icon: "rotate.right", title: "Transform & Orient", desc: "90° lossless rotation and horizontal mirroring")
                        featureRow(icon: "arrow.down.doc", title: "Dual Export Engine", desc: "PNG lossless & JPG with auto-save to Camera Roll & Files")
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
        let (cropW, cropH) = activeOutputDimensions(for: img)

        VStack(spacing: 8) {
            ZStack(alignment: .topTrailing) {
                // Image Display Canvas with aspect fit
                GeometryReader { geo in
                    let canvasSize = geo.size
                    ZStack {
                        Color.black

                        Image(uiImage: img)
                            .resizable()
                            .scaledToFit()
                            .rotationEffect(.degrees(Double(rotationDegrees)))
                            .scaleEffect(x: isFlipped ? -1 : 1, y: 1)
                            .frame(maxWidth: canvasSize.width, maxHeight: canvasSize.height)

                        // Crop overlay bounding box
                        cropOverlayView(containerSize: canvasSize, imageSize: img.size)
                    }
                    .frame(width: canvasSize.width, height: canvasSize.height)
                }
                .frame(maxWidth: .infinity)
                .aspectRatio(1.0, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(Color.borderHairline, lineWidth: 1)
                )

                // Top Resolution Badge
                HStack(spacing: 6) {
                    Circle()
                        .fill(Color.emeraldAccent)
                        .frame(width: 6, height: 6)

                    Text("\(cropW) × \(cropH) px")
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
                .padding(10)
            }
        }
    }

    @ViewBuilder
    private func cropOverlayView(containerSize: CGSize, imageSize: CGSize) -> some View {
        let isRotated90 = (rotationDegrees / 90) % 2 != 0
        let effectiveW = isRotated90 ? imageSize.height : imageSize.width
        let effectiveH = isRotated90 ? imageSize.width : imageSize.height

        if effectiveW > 0, effectiveH > 0 {
            let imgAspect = effectiveW / effectiveH
            let containerAspect = containerSize.width / containerSize.height

            // Calculate actual rendered rect of the fitted image inside container
            let fitW: CGFloat
            let fitH: CGFloat
            if imgAspect > containerAspect {
                fitW = containerSize.width
                fitH = containerSize.width / imgAspect
            } else {
                fitH = containerSize.height
                fitW = containerSize.height * imgAspect
            }

            // Calculate crop box rect inside the fitted image
            let cropRect = ImageCropEngine.computeCropRect(imageSize: CGSize(width: effectiveW, height: effectiveH), ratio: selectedRatio)
            let scaleX = fitW / effectiveW
            let scaleY = fitH / effectiveH

            let boxW = cropRect.width * scaleX
            let boxH = cropRect.height * scaleY

            if selectedRatio != .free {
                ZStack {
                    // Outer border of crop region
                    Rectangle()
                        .stroke(Color.amberAccent, lineWidth: 1.5)
                        .frame(width: boxW, height: boxH)

                    // Subtle Rule-of-Thirds Grid
                    VStack {
                        Spacer()
                        Divider().background(Color.white.opacity(0.2))
                        Spacer()
                        Divider().background(Color.white.opacity(0.2))
                        Spacer()
                    }
                    .frame(width: boxW, height: boxH)

                    HStack {
                        Spacer()
                        Divider().background(Color.white.opacity(0.2))
                        Spacer()
                        Divider().background(Color.white.opacity(0.2))
                        Spacer()
                    }
                    .frame(width: boxW, height: boxH)
                }
            }
        }
    }

    @ViewBuilder
    private var ratioSelectorSection: some View {
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
    private var transformControlsSection: some View {
        HStack(spacing: 12) {
            // Rotate 90°
            Button(action: {
                withAnimation(.easeInOut(duration: 0.2)) {
                    rotationDegrees = (rotationDegrees + 90) % 360
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
                    selectedRatio = .free
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

    // MARK: - Logic Helpers

    private func activeOutputDimensions(for img: UIImage) -> (Int, Int) {
        let isRotated90 = (rotationDegrees / 90) % 2 != 0
        let w = isRotated90 ? img.size.height : img.size.width
        let h = isRotated90 ? img.size.width : img.size.height
        let rect = ImageCropEngine.computeCropRect(imageSize: CGSize(width: w, height: h), ratio: selectedRatio)
        return (Int(rect.width), Int(rect.height))
    }

    private func loadFromPhotos(item: PhotosPickerItem) async {
        do {
            if let data = try await item.loadTransferable(type: Data.self),
               let loaded = UIImage(data: data) {
                await MainActor.run {
                    self.sourceImage = loaded
                    self.rotationDegrees = 0
                    self.isFlipped = false
                    self.exportedFileUrl = nil
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
                self.exportedFileUrl = nil
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
                // If rotated or flipped, first transform the image before computing crop rect
                let isRotated90 = (rotationDegrees / 90) % 2 != 0
                let effectiveW = isRotated90 ? image.size.height : image.size.width
                let effectiveH = isRotated90 ? image.size.width : image.size.height

                let cropRect = ImageCropEngine.computeCropRect(
                    imageSize: CGSize(width: effectiveW, height: effectiveH),
                    ratio: selectedRatio
                )

                guard let cropped = ImageCropEngine.cropImage(
                    image,
                    to: cropRect,
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
                    // Photos rejected or permission issue: fallback to Share Sheet / Files
                    savedToPhotos = false
                }

                await MainActor.run {
                    self.isCropping = false
                    self.exportedFileUrl = tempUrl

                    if savedToPhotos {
                        self.alertMessage = "✓ Cropped image (\(Int(cropRect.width)) × \(Int(cropRect.height)) px) saved to Camera Roll!"
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

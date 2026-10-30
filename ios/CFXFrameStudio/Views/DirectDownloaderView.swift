import SwiftUI
import AVFoundation

struct DirectDownloaderView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var engine = DirectDownloadEngine()
    @StateObject private var ytEngine = YouTubeDownloadEngine()
    @StateObject private var igEngine = InstagramDownloadEngine()
    @StateObject private var twitterEngine = TwitterDownloadEngine()
    @StateObject private var tiktokEngine = TikTokDownloadEngine()
    @ObservedObject private var notificationManager = NotificationManager.shared

    @State private var inputUrl: String = ""
    @State private var showShareSheet: Bool = false
    @State private var recentDownloads: [URL] = []
    @State private var showSettingsModal: Bool = false
    @State private var selectedQualityId: String = ""
    @State private var selectedCarouselIndex: Int = 0
    @State private var selectedTwitterIndex: Int = 0
    @State private var selectedTikTokIndex: Int = 0
    @State private var isRemuxingDownloadedFile: Bool = false
    @State private var remuxProgress: Double = 0.0

    private var isYouTubeLink: Bool {
        YouTubeDownloadEngine.isYouTubeUrl(inputUrl)
    }

    private var isInstagramLink: Bool {
        InstagramDownloadEngine.isInstagramUrl(inputUrl)
    }

    private var isTwitterLink: Bool {
        TwitterDownloadEngine.isTwitterUrl(inputUrl)
    }

    private var isTikTokLink: Bool {
        TikTokDownloadEngine.isTikTokUrl(inputUrl)
    }

    private var instagramGradient: LinearGradient {
        LinearGradient(
            colors: [Color(hex: "833AB4"), Color(hex: "FD1D1D"), Color(hex: "F77737")],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private var twitterGradient: LinearGradient {
        LinearGradient(
            colors: [Color(hex: "1D9BF0"), Color(hex: "0C71B0")],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private var tiktokGradient: LinearGradient {
        LinearGradient(
            colors: [Color(hex: "00F2FE"), Color(hex: "4FACFE"), Color(hex: "FE0979")],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    var body: some View {
        ZStack {
            Color.voidCanvas.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 16) {
                    headerBar
                    inputCard

                    // YouTube Fetching Indicator
                    if ytEngine.isFetching {
                        ytFetchingCard
                    }

                    // Instagram Fetching Indicator
                    if igEngine.isFetching {
                        igFetchingCard
                    }

                    // TikTok Fetching Indicator
                    if tiktokEngine.isFetching {
                        tiktokFetchingCard
                    }

                    // Twitter Fetching Indicator
                    if twitterEngine.isFetching {
                        twitterFetchingCard
                    }

                    // YouTube Qualities Card
                    if let ytInfo = ytEngine.videoInfo, !engine.isDownloading, engine.downloadedFileUrl == nil {
                        ytQualitiesCard(info: ytInfo)
                            .transition(.opacity.combined(with: .scale(scale: 0.98)))
                    }

                    // Instagram Media Card (Reels, Posts, Carousels, Stories)
                    if let igInfo = igEngine.postInfo, !engine.isDownloading, engine.downloadedFileUrl == nil {
                        igMediaCard(info: igInfo)
                            .transition(.opacity.combined(with: .scale(scale: 0.98)))
                    }

                    // TikTok Media Card (HD Video, Audio, Photo Slides)
                    if let ttInfo = tiktokEngine.postInfo, !engine.isDownloading, engine.downloadedFileUrl == nil {
                        tiktokMediaCard(info: ttInfo)
                            .transition(.opacity.combined(with: .scale(scale: 0.98)))
                    }

                    // Twitter / X Media Card (Videos, GIFs, Photos)
                    if let twInfo = twitterEngine.tweetInfo, !engine.isDownloading, engine.downloadedFileUrl == nil {
                        twitterMediaCard(info: twInfo)
                            .transition(.opacity.combined(with: .scale(scale: 0.98)))
                    }

                    // Download Progress Card
                    if engine.isDownloading {
                        downloadProgressCard
                    }

                    // Result & Inspection Card
                    if let fileUrl = engine.downloadedFileUrl, let inspection = engine.mediaInspection {
                        downloadResultCard(fileUrl: fileUrl, inspection: inspection)
                    }

                    // Error Banner
                    if let error = engine.errorMessage ?? ytEngine.errorMessage ?? igEngine.errorMessage ?? twitterEngine.errorMessage ?? tiktokEngine.errorMessage {
                        errorBanner(error: error)
                    }

                    // Recent Local Downloads
                    if !recentDownloads.isEmpty {
                        recentDownloadsSection
                    }

                    Spacer(minLength: 24)
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
            }
        }
        .navigationBarBackButtonHidden(true)
        .onAppear {
            refreshRecentDownloads()
            notificationManager.setup()
            notificationManager.requestAuthorization()
        }
        .onChange(of: engine.downloadedFileUrl) { newUrl in
            if newUrl != nil {
                refreshRecentDownloads()
                if !engine.savedToPhotos {
                    showShareSheet = true
                }
            }
        }
        .sheet(isPresented: $showShareSheet) {
            if let url = engine.downloadedFileUrl {
                ShareActivityView(activityItems: [url])
            }
        }
        .sheet(isPresented: $showSettingsModal) {
            SettingsView()
                .onDisappear {
                    refreshRecentDownloads()
                }
        }
    }

    // MARK: - Header Bar
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

            VStack(alignment: .leading, spacing: 2) {
                Text("UNIVERSAL DOWNLOADER")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(.textPrimary)

                Text("Direct • YouTube • Instagram • TikTok • X / Twitter")
                    .font(.system(size: 10))
                    .foregroundColor(.textMuted)
            }

            Spacer()

            HStack(spacing: 8) {
                Button(action: {
                    notificationManager.requestAuthorization { granted in
                        if !granted {
                            if let settingsUrl = URL(string: UIApplication.openSettingsURLString) {
                                UIApplication.shared.open(settingsUrl)
                            }
                        }
                    }
                }) {
                    Image(systemName: notificationManager.isAuthorized ? "bell.fill" : "bell.slash")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(notificationManager.isAuthorized ? .emeraldAccent : .textMuted)
                        .frame(width: 36, height: 36)
                        .background(Color.surfaceCard)
                        .clipShape(Circle())
                }

                Button(action: { pasteFromClipboard() }) {
                    Image(systemName: "doc.on.clipboard")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(.skyAccent)
                        .frame(width: 36, height: 36)
                        .background(Color.surfaceCard)
                        .clipShape(Circle())
                }

                Button(action: { showSettingsModal = true }) {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(.textSecondary)
                        .frame(width: 36, height: 36)
                        .background(Color.surfaceCard)
                        .clipShape(Circle())
                }
            }
        }
    }

    // MARK: - Input Card
    @ViewBuilder
    private var inputCard: some View {
        GlassCard(cornerRadius: 18, padding: 16) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 8) {
                    if isTikTokLink {
                        Image(systemName: "music.note.tv.fill")
                            .foregroundColor(.skyAccent)
                            .font(.system(size: 14, weight: .bold))

                        Text("TIKTOK LINK DETECTED")
                            .font(.system(size: 11, weight: .heavy))
                            .foregroundStyle(tiktokGradient)
                            .tracking(0.8)
                    } else if isTwitterLink {
                        Image(systemName: "bubble.left.and.bubble.right.fill")
                            .foregroundColor(.skyAccent)
                            .font(.system(size: 14, weight: .bold))

                        Text("X / TWITTER LINK DETECTED")
                            .font(.system(size: 11, weight: .heavy))
                            .foregroundStyle(twitterGradient)
                            .tracking(0.8)
                    } else if isInstagramLink {
                        Image(systemName: "play.square.stack.fill")
                            .foregroundColor(.pinkAccent)
                            .font(.system(size: 14, weight: .bold))

                        Text("INSTAGRAM LINK DETECTED")
                            .font(.system(size: 11, weight: .heavy))
                            .foregroundStyle(instagramGradient)
                            .tracking(0.8)
                    } else if isYouTubeLink {
                        Image(systemName: "play.rectangle.fill")
                            .foregroundColor(.brandAccent)
                            .font(.system(size: 14, weight: .bold))

                        Text("YOUTUBE LINK DETECTED")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(.gradientStart)
                            .tracking(1.0)
                    } else {
                        Image(systemName: "link.badge.plus")
                            .foregroundColor(.skyAccent)
                            .font(.system(size: 14, weight: .bold))

                        Text("DIRECT MEDIA, TIKTOK, TWITTER OR INSTA LINK")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(.textMuted)
                            .tracking(1.0)
                    }

                    Spacer()
                }

                HStack(spacing: 8) {
                    TextField("https://... (TikTok, Twitter/X, Instagram, YouTube, S3)", text: $inputUrl)
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundColor(.textPrimary)
                        .textInputAutocapitalization(.never)
                        .disableAutocorrection(true)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(Color.elevatedSurface)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(
                                    isTikTokLink ? Color(hex: "00F2FE").opacity(0.6) :
                                    (isTwitterLink ? Color(hex: "1D9BF0").opacity(0.6) :
                                    (isInstagramLink ? Color.pinkAccent.opacity(0.5) :
                                    (isYouTubeLink ? Color.brandAccent.opacity(0.4) : Color.borderHairline))),
                                    lineWidth: 1
                                )
                        )

                    if !inputUrl.isEmpty {
                        Button(action: {
                            inputUrl = ""
                            ytEngine.videoInfo = nil
                            ytEngine.errorMessage = nil
                            igEngine.postInfo = nil
                            igEngine.errorMessage = nil
                            twitterEngine.tweetInfo = nil
                            twitterEngine.errorMessage = nil
                            tiktokEngine.postInfo = nil
                            tiktokEngine.errorMessage = nil
                        }) {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 16))
                                .foregroundColor(.textTertiary)
                        }
                    }
                }

                HStack(spacing: 10) {
                    Button(action: { pasteFromClipboard() }) {
                        HStack(spacing: 6) {
                            Image(systemName: "doc.on.clipboard")
                                .font(.system(size: 12, weight: .bold))
                            Text("Paste")
                                .font(.system(size: 12, weight: .semibold))
                        }
                        .foregroundColor(.skyAccent)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color.skyAccent.opacity(0.15))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }

                    Spacer()

                    if isTikTokLink {
                        Button(action: {
                            engine.reset()
                            selectedTikTokIndex = 0
                            Task {
                                await tiktokEngine.fetchMedia(for: inputUrl)
                            }
                        }) {
                            HStack(spacing: 6) {
                                Image(systemName: "music.note.tv.fill")
                                    .font(.system(size: 14, weight: .bold))
                                Text("Fetch TikTok Media")
                                    .font(.system(size: 13, weight: .bold))
                            }
                            .foregroundColor(.white)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .background(tiktokGradient)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                            .shadow(color: Color(hex: "FE0979").opacity(0.3), radius: 8, y: 3)
                        }
                        .disabled(tiktokEngine.isFetching)
                    } else if isTwitterLink {
                        Button(action: {
                            engine.reset()
                            selectedTwitterIndex = 0
                            Task {
                                await twitterEngine.fetchMedia(for: inputUrl)
                            }
                        }) {
                            HStack(spacing: 6) {
                                Image(systemName: "bubble.left.and.bubble.right.fill")
                                    .font(.system(size: 14, weight: .bold))
                                Text("Fetch Tweet Media")
                                    .font(.system(size: 13, weight: .bold))
                            }
                            .foregroundColor(.white)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .background(twitterGradient)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                            .shadow(color: Color(hex: "1D9BF0").opacity(0.3), radius: 8, y: 3)
                        }
                        .disabled(twitterEngine.isFetching)
                    } else if isInstagramLink {
                        Button(action: {
                            engine.reset()
                            selectedCarouselIndex = 0
                            Task {
                                await igEngine.fetchMedia(for: inputUrl)
                            }
                        }) {
                            HStack(spacing: 6) {
                                Image(systemName: "sparkles.tv")
                                    .font(.system(size: 14, weight: .bold))
                                Text("Fetch Insta Media")
                                    .font(.system(size: 13, weight: .bold))
                            }
                            .foregroundColor(.white)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .background(instagramGradient)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                            .shadow(color: Color(hex: "FD1D1D").opacity(0.3), radius: 8, y: 3)
                        }
                        .disabled(igEngine.isFetching)
                    } else if isYouTubeLink {
                        Button(action: {
                            engine.reset()
                            Task {
                                await ytEngine.fetchQualities(for: inputUrl)
                            }
                        }) {
                            HStack(spacing: 6) {
                                Image(systemName: "list.bullet.circle.fill")
                                    .font(.system(size: 14, weight: .bold))
                                Text("Fetch Qualities")
                                    .font(.system(size: 13, weight: .bold))
                            }
                            .foregroundColor(.white)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .background(LinearGradient.brandGradient)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                        }
                        .disabled(ytEngine.isFetching)
                    } else {
                        Button(action: {
                            engine.startDownload(urlString: inputUrl)
                        }) {
                            HStack(spacing: 6) {
                                Image(systemName: "arrow.down.circle.fill")
                                    .font(.system(size: 14, weight: .bold))
                                Text("Start Download")
                                    .font(.system(size: 13, weight: .bold))
                            }
                            .foregroundColor(.white)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .background(LinearGradient.brandGradient)
                            .opacity(inputUrl.isEmpty ? 0.4 : 1.0)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                        }
                        .disabled(inputUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || engine.isDownloading)
                    }
                }
            }
        }
    }

    // MARK: - Instagram Fetching Indicator Card
    @ViewBuilder
    private var igFetchingCard: some View {
        GlassCard(cornerRadius: 16, padding: 16) {
            HStack(spacing: 12) {
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle(tint: .pinkAccent))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Extracting Instagram Media...")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(.textPrimary)
                    Text("Resolving direct CDN stream & metadata...")
                        .font(.system(size: 11))
                        .foregroundColor(.textMuted)
                }
                Spacer()
            }
        }
    }

    // MARK: - Instagram Media Card
    @ViewBuilder
    private func igMediaCard(info: InstagramPostInfo) -> some View {
        GlassCard(cornerRadius: 18, padding: 16) {
            VStack(alignment: .leading, spacing: 14) {
                // Header (Author & Kind)
                HStack(alignment: .top, spacing: 12) {
                    ZStack {
                        Circle()
                            .fill(instagramGradient)
                            .frame(width: 44, height: 44)

                        Image(systemName: info.kind.badgeIcon)
                            .font(.system(size: 20, weight: .bold))
                            .foregroundColor(.white)
                    }

                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(info.author)
                                .font(.system(size: 14, weight: .bold))
                                .foregroundColor(.textPrimary)
                                .lineLimit(1)

                            Image(systemName: "checkmark.seal.fill")
                                .font(.system(size: 11))
                                .foregroundColor(.skyAccent)
                        }

                        HStack(spacing: 6) {
                            Text(info.kind.rawValue.uppercased())
                                .font(.system(size: 8.5, weight: .heavy))
                                .foregroundColor(.pinkAccent)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.pinkAccent.opacity(0.14))
                                .clipShape(Capsule())

                            if info.items.count > 1 {
                                Text("\(info.items.count) ITEMS")
                                    .font(.system(size: 8.5, weight: .heavy))
                                    .foregroundColor(.amberAccent)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.amberAccent.opacity(0.14))
                                    .clipShape(Capsule())
                            }
                        }
                    }

                    Spacer()
                }

                // Caption snippet
                if !info.caption.isEmpty {
                    Text(info.caption)
                        .font(.system(size: 12))
                        .foregroundColor(.textSecondary)
                        .lineLimit(3)
                        .padding(.vertical, 2)
                }

                Divider().background(Color.borderHairline)

                // Multi-Item Carousel Selector
                if info.items.count > 1 {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("SELECT CAROUSEL SLIDE")
                            .font(.system(size: 9.5, weight: .heavy))
                            .foregroundColor(.textTertiary)
                            .tracking(0.8)

                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(0..<info.items.count, id: \.self) { index in
                                    let item = info.items[index]
                                    Button(action: {
                                        withAnimation(.easeInOut(duration: 0.15)) {
                                            selectedCarouselIndex = index
                                        }
                                    }) {
                                        HStack(spacing: 6) {
                                            Image(systemName: item.type.systemIcon)
                                                .font(.system(size: 10, weight: .bold))

                                            Text("Slide \(index + 1)")
                                                .font(.system(size: 11, weight: .bold))
                                        }
                                        .foregroundColor(selectedCarouselIndex == index ? .white : .textSecondary)
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 7)
                                        .background(selectedCarouselIndex == index ? AnyView(instagramGradient) : AnyView(Color.elevatedSurface))
                                        .clipShape(Capsule())
                                        .overlay(
                                            Capsule().stroke(Color.borderHairline, lineWidth: 1)
                                        )
                                    }
                                }
                            }
                        }
                    }
                }

                // Active Item Preview / Details
                let activeIndex = min(selectedCarouselIndex, max(0, info.items.count - 1))
                if activeIndex < info.items.count {
                    let activeItem = info.items[activeIndex]

                    HStack(spacing: 12) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(Color.elevatedSurface)
                                .frame(width: 50, height: 50)

                            Image(systemName: activeItem.type.systemIcon)
                                .font(.system(size: 22, weight: .bold))
                                .foregroundColor(activeItem.type == .video ? .skyAccent : .pinkAccent)
                        }

                        VStack(alignment: .leading, spacing: 3) {
                            Text(activeItem.displayLabel)
                                .font(.system(size: 13, weight: .bold))
                                .foregroundColor(.textPrimary)

                            Text(activeItem.type == .video ? "Lossless H.264 MP4 with Audio" : "High-Resolution JPEG")
                                .font(.system(size: 11))
                                .foregroundColor(.emeraldAccent)
                        }

                        Spacer()
                    }
                    .padding(10)
                    .background(Color.elevatedSurface.opacity(0.6))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                    // Download Buttons
                    VStack(spacing: 8) {
                        // 1. Download Selected Item
                        Button(action: {
                            withAnimation(.easeInOut(duration: 0.25)) {
                                engine.startDownload(urlString: activeItem.downloadUrl, customFilename: activeItem.filename)
                            }
                        }) {
                            HStack(spacing: 8) {
                                Image(systemName: "arrow.down.circle.fill")
                                    .font(.system(size: 15, weight: .bold))

                                Text(activeItem.type == .video ? "Download Reel ➔ Camera Roll" : "Download Photo ➔ Camera Roll")
                                    .font(.system(size: 13.5, weight: .bold))
                            }
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .frame(height: 44)
                            .background(instagramGradient)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .shadow(color: Color(hex: "FD1D1D").opacity(0.3), radius: 8, y: 3)
                        }
                        .disabled(engine.isDownloading || igEngine.isBatchDownloading)

                        // 2. Download All Items (If Carousel)
                        if info.items.count > 1 {
                            Button(action: {
                                Task {
                                    await igEngine.downloadAllItems(items: info.items, with: engine)
                                }
                            }) {
                                HStack(spacing: 8) {
                                    if igEngine.isBatchDownloading {
                                        ProgressView()
                                            .progressViewStyle(CircularProgressViewStyle(tint: .emeraldAccent))
                                            .scaleEffect(0.8)
                                        Text(igEngine.batchStatusMessage)
                                            .font(.system(size: 12.5, weight: .bold))
                                            .foregroundColor(.emeraldAccent)
                                    } else {
                                        Image(systemName: "square.and.arrow.down.on.square.fill")
                                            .font(.system(size: 13, weight: .bold))
                                        Text("Download All \(info.items.count) Items to Photos")
                                            .font(.system(size: 13, weight: .bold))
                                    }
                                }
                                .foregroundColor(.emeraldAccent)
                                .frame(maxWidth: .infinity)
                                .frame(height: 42)
                                .background(Color.emeraldAccent.opacity(0.14))
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .stroke(Color.emeraldAccent.opacity(0.3), lineWidth: 1)
                                )
                            }
                            .disabled(engine.isDownloading || igEngine.isBatchDownloading)
                        }
                    }
                }
            }
        }
    }

    // MARK: - TikTok Fetching Indicator Card
    @ViewBuilder
    private var tiktokFetchingCard: some View {
        GlassCard(cornerRadius: 16, padding: 16) {
            HStack(spacing: 12) {
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle(tint: .skyAccent))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Extracting TikTok Media...")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(.textPrimary)
                    Text("Resolving watermark-free CDN stream & original audio...")
                        .font(.system(size: 11))
                        .foregroundColor(.textMuted)
                }
                Spacer()
            }
        }
    }

    // MARK: - Twitter Fetching Indicator Card
    @ViewBuilder
    private var twitterFetchingCard: some View {
        GlassCard(cornerRadius: 16, padding: 16) {
            HStack(spacing: 12) {
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle(tint: .skyAccent))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Extracting X / Twitter Media...")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(.textPrimary)
                    Text("Parsing tweet payload & high-resolution media...")
                        .font(.system(size: 11))
                        .foregroundColor(.textMuted)
                }
                Spacer()
            }
        }
    }

    // MARK: - TikTok Media Card
    @ViewBuilder
    private func tiktokMediaCard(info: TikTokPostInfo) -> some View {
        GlassCard(cornerRadius: 18, padding: 16) {
            VStack(alignment: .leading, spacing: 14) {
                // Header (Author & Platform Badge)
                HStack(alignment: .top, spacing: 12) {
                    ZStack {
                        Circle()
                            .fill(tiktokGradient)
                            .frame(width: 44, height: 44)

                        Image(systemName: "music.note.tv.fill")
                            .font(.system(size: 19, weight: .bold))
                            .foregroundColor(.white)
                    }

                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(info.authorName)
                                .font(.system(size: 14, weight: .bold))
                                .foregroundColor(.textPrimary)
                                .lineLimit(1)

                            Image(systemName: "checkmark.seal.fill")
                                .font(.system(size: 11))
                                .foregroundColor(.skyAccent)
                        }

                        HStack(spacing: 6) {
                            Text(info.authorHandle)
                                .font(.system(size: 11))
                                .foregroundColor(.textSecondary)

                            Text("TIKTOK")
                                .font(.system(size: 8.5, weight: .heavy))
                                .foregroundColor(.skyAccent)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.skyAccent.opacity(0.14))
                                .clipShape(Capsule())

                            let photoCount = info.items.filter { $0.type == .photo }.count
                            if photoCount > 1 {
                                Text("\(photoCount) SLIDES")
                                    .font(.system(size: 8.5, weight: .heavy))
                                    .foregroundColor(.amberAccent)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.amberAccent.opacity(0.14))
                                    .clipShape(Capsule())
                            }
                        }
                    }

                    Spacer()
                }

                // Caption snippet
                if !info.caption.isEmpty {
                    Text(info.caption)
                        .font(.system(size: 12))
                        .foregroundColor(.textSecondary)
                        .lineLimit(3)
                        .padding(.vertical, 2)
                }

                // Music Title if present
                if let music = info.musicTitle, !music.isEmpty {
                    HStack(spacing: 6) {
                        Image(systemName: "music.note")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(.pinkAccent)
                        Text(music)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.pinkAccent)
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.pinkAccent.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }

                Divider().background(Color.borderHairline)

                // Multi-Slide Selector (if slideshow)
                let photoItems = info.items.filter { $0.type == .photo }
                if photoItems.count > 1 {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("SELECT PHOTO SLIDE")
                            .font(.system(size: 9.5, weight: .heavy))
                            .foregroundColor(.textTertiary)
                            .tracking(0.8)

                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(0..<photoItems.count, id: \.self) { index in
                                    Button(action: {
                                        withAnimation(.easeInOut(duration: 0.15)) {
                                            selectedTikTokIndex = index
                                        }
                                    }) {
                                        HStack(spacing: 6) {
                                            Image(systemName: "photo.fill")
                                                .font(.system(size: 10, weight: .bold))

                                            Text("Slide \(index + 1)")
                                                .font(.system(size: 11, weight: .bold))
                                        }
                                        .foregroundColor(selectedTikTokIndex == index ? .white : .textSecondary)
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 7)
                                        .background(selectedTikTokIndex == index ? AnyView(tiktokGradient) : AnyView(Color.elevatedSurface))
                                        .clipShape(Capsule())
                                        .overlay(
                                            Capsule().stroke(Color.borderHairline, lineWidth: 1)
                                        )
                                    }
                                }
                            }
                        }
                    }
                }

                // Main Video Item (if exists)
                if let videoItem = info.items.first(where: { $0.type == .video }) {
                    VStack(spacing: 8) {
                        HStack(spacing: 12) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(Color.elevatedSurface)
                                    .frame(width: 48, height: 48)

                                Image(systemName: "play.circle.fill")
                                    .font(.system(size: 22, weight: .bold))
                                    .foregroundColor(.skyAccent)
                            }

                            VStack(alignment: .leading, spacing: 3) {
                                Text(videoItem.displayLabel)
                                    .font(.system(size: 13, weight: .bold))
                                    .foregroundColor(.textPrimary)

                                Text("Clean 1080p Stream • Zero Watermark")
                                    .font(.system(size: 11))
                                    .foregroundColor(.emeraldAccent)
                            }

                            Spacer()
                        }
                        .padding(10)
                        .background(Color.elevatedSurface.opacity(0.6))
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                        Button(action: {
                            withAnimation(.easeInOut(duration: 0.25)) {
                                engine.startDownload(urlString: videoItem.downloadUrl, customFilename: videoItem.filename)
                            }
                        }) {
                            HStack(spacing: 8) {
                                Image(systemName: "arrow.down.circle.fill")
                                    .font(.system(size: 15, weight: .bold))

                                Text("Download HD Video ➔ Camera Roll")
                                    .font(.system(size: 13.5, weight: .bold))
                            }
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .frame(height: 44)
                            .background(tiktokGradient)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .shadow(color: Color(hex: "FE0979").opacity(0.3), radius: 8, y: 3)
                        }
                        .disabled(engine.isDownloading || tiktokEngine.isBatchDownloading)
                    }
                }

                // Photo Item (if slideshow)
                if !photoItems.isEmpty {
                    let activeIndex = min(selectedTikTokIndex, max(0, photoItems.count - 1))
                    let activePhoto = photoItems[activeIndex]

                    VStack(spacing: 8) {
                        Button(action: {
                            withAnimation(.easeInOut(duration: 0.25)) {
                                engine.startDownload(urlString: activePhoto.downloadUrl, customFilename: activePhoto.filename)
                            }
                        }) {
                            HStack(spacing: 8) {
                                Image(systemName: "photo.fill")
                                    .font(.system(size: 14, weight: .bold))

                                Text("Save Slide \(activeIndex + 1) ➔ Camera Roll")
                                    .font(.system(size: 13, weight: .bold))
                            }
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .frame(height: 42)
                            .background(tiktokGradient)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                        .disabled(engine.isDownloading || tiktokEngine.isBatchDownloading)

                        if photoItems.count > 1 {
                            Button(action: {
                                Task {
                                    await tiktokEngine.downloadAllItems(items: photoItems, with: engine)
                                }
                            }) {
                                HStack(spacing: 8) {
                                    if tiktokEngine.isBatchDownloading {
                                        ProgressView()
                                            .progressViewStyle(CircularProgressViewStyle(tint: .emeraldAccent))
                                            .scaleEffect(0.8)
                                        Text(tiktokEngine.batchStatusMessage)
                                            .font(.system(size: 12.5, weight: .bold))
                                            .foregroundColor(.emeraldAccent)
                                    } else {
                                        Image(systemName: "square.and.arrow.down.on.square.fill")
                                            .font(.system(size: 13, weight: .bold))
                                        Text("Download All \(photoItems.count) Slides to Photos")
                                            .font(.system(size: 13, weight: .bold))
                                    }
                                }
                                .foregroundColor(.emeraldAccent)
                                .frame(maxWidth: .infinity)
                                .frame(height: 42)
                                .background(Color.emeraldAccent.opacity(0.14))
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .stroke(Color.emeraldAccent.opacity(0.3), lineWidth: 1)
                                )
                            }
                            .disabled(engine.isDownloading || tiktokEngine.isBatchDownloading)
                        }
                    }
                }

                // Audio Item (MP3)
                if let audioItem = info.items.first(where: { $0.type == .audio }) {
                    Button(action: {
                        withAnimation(.easeInOut(duration: 0.25)) {
                            engine.startDownload(urlString: audioItem.downloadUrl, customFilename: audioItem.filename)
                        }
                    }) {
                        HStack(spacing: 8) {
                            Image(systemName: "music.note")
                                .font(.system(size: 13, weight: .bold))

                            Text("Extract Audio (MP3)")
                                .font(.system(size: 12.5, weight: .bold))
                        }
                        .foregroundColor(.skyAccent)
                        .frame(maxWidth: .infinity)
                        .frame(height: 38)
                        .background(Color.skyAccent.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .stroke(Color.skyAccent.opacity(0.25), lineWidth: 1)
                        )
                    }
                    .disabled(engine.isDownloading || tiktokEngine.isBatchDownloading)
                }
            }
        }
    }

    // MARK: - Twitter / X Media Card
    @ViewBuilder
    private func twitterMediaCard(info: TweetInfo) -> some View {
        GlassCard(cornerRadius: 18, padding: 16) {
            VStack(alignment: .leading, spacing: 14) {
                // Header (Author & Kind)
                HStack(alignment: .top, spacing: 12) {
                    ZStack {
                        Circle()
                            .fill(twitterGradient)
                            .frame(width: 44, height: 44)

                        Image(systemName: "bubble.left.and.bubble.right.fill")
                            .font(.system(size: 19, weight: .bold))
                            .foregroundColor(.white)
                    }

                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(info.authorName)
                                .font(.system(size: 14, weight: .bold))
                                .foregroundColor(.textPrimary)
                                .lineLimit(1)

                            Image(systemName: "checkmark.seal.fill")
                                .font(.system(size: 11))
                                .foregroundColor(.skyAccent)
                        }

                        HStack(spacing: 6) {
                            Text(info.authorHandle)
                                .font(.system(size: 11))
                                .foregroundColor(.textSecondary)

                            Text("X / TWITTER")
                                .font(.system(size: 8.5, weight: .heavy))
                                .foregroundColor(.skyAccent)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.skyAccent.opacity(0.14))
                                .clipShape(Capsule())

                            if info.items.count > 1 {
                                Text("\(info.items.count) MEDIA")
                                    .font(.system(size: 8.5, weight: .heavy))
                                    .foregroundColor(.amberAccent)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.amberAccent.opacity(0.14))
                                    .clipShape(Capsule())
                            }
                        }
                    }

                    Spacer()

                    // Metrics
                    if let likes = info.likes, likes > 0 {
                        HStack(spacing: 4) {
                            Image(systemName: "heart.fill")
                                .font(.system(size: 10))
                                .foregroundColor(.pinkAccent)
                            Text("\(likes)")
                                .font(.system(size: 10.5, weight: .semibold))
                                .foregroundColor(.textSecondary)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.elevatedSurface)
                        .clipShape(Capsule())
                    }
                }

                // Tweet text
                if !info.text.isEmpty {
                    Text(info.text)
                        .font(.system(size: 12))
                        .foregroundColor(.textSecondary)
                        .lineLimit(4)
                        .padding(.vertical, 2)
                }

                Divider().background(Color.borderHairline)

                // Multi-Item Selector
                if info.items.count > 1 {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("SELECT MEDIA ITEM")
                            .font(.system(size: 9.5, weight: .heavy))
                            .foregroundColor(.textTertiary)
                            .tracking(0.8)

                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(0..<info.items.count, id: \.self) { index in
                                    let item = info.items[index]
                                    Button(action: {
                                        withAnimation(.easeInOut(duration: 0.15)) {
                                            selectedTwitterIndex = index
                                        }
                                    }) {
                                        HStack(spacing: 6) {
                                            Image(systemName: item.type.systemIcon)
                                                .font(.system(size: 10, weight: .bold))

                                            Text("Item \(index + 1)")
                                                .font(.system(size: 11, weight: .bold))
                                        }
                                        .foregroundColor(selectedTwitterIndex == index ? .white : .textSecondary)
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 7)
                                        .background(selectedTwitterIndex == index ? AnyView(twitterGradient) : AnyView(Color.elevatedSurface))
                                        .clipShape(Capsule())
                                        .overlay(
                                            Capsule().stroke(Color.borderHairline, lineWidth: 1)
                                        )
                                    }
                                }
                            }
                        }
                    }
                }

                // Active Item Preview / Details
                let activeIndex = min(selectedTwitterIndex, max(0, info.items.count - 1))
                if activeIndex < info.items.count {
                    let activeItem = info.items[activeIndex]

                    HStack(spacing: 12) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(Color.elevatedSurface)
                                .frame(width: 48, height: 48)

                            Image(systemName: activeItem.type.systemIcon)
                                .font(.system(size: 22, weight: .bold))
                                .foregroundColor(activeItem.type == .photo ? .pinkAccent : .skyAccent)
                        }

                        VStack(alignment: .leading, spacing: 3) {
                            Text(activeItem.displayLabel)
                                .font(.system(size: 13, weight: .bold))
                                .foregroundColor(.textPrimary)

                            Text(activeItem.type == .video ? "Original High-Definition MP4" : (activeItem.type == .gif ? "Looping MP4 Animation" : "Full-Resolution Image"))
                                .font(.system(size: 11))
                                .foregroundColor(.emeraldAccent)
                        }

                        Spacer()
                    }
                    .padding(10)
                    .background(Color.elevatedSurface.opacity(0.6))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                    // Action buttons
                    VStack(spacing: 8) {
                        Button(action: {
                            withAnimation(.easeInOut(duration: 0.25)) {
                                engine.startDownload(urlString: activeItem.downloadUrl, customFilename: activeItem.filename)
                            }
                        }) {
                            HStack(spacing: 8) {
                                Image(systemName: "arrow.down.circle.fill")
                                    .font(.system(size: 15, weight: .bold))

                                Text(activeItem.type == .photo ? "Save Photo ➔ Camera Roll" : "Download Video ➔ Camera Roll")
                                    .font(.system(size: 13.5, weight: .bold))
                            }
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .frame(height: 44)
                            .background(twitterGradient)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .shadow(color: Color(hex: "1D9BF0").opacity(0.3), radius: 8, y: 3)
                        }
                        .disabled(engine.isDownloading || twitterEngine.isBatchDownloading)

                        // Batch Save if multi-items
                        if info.items.count > 1 {
                            Button(action: {
                                Task {
                                    await twitterEngine.downloadAllItems(items: info.items, with: engine)
                                }
                            }) {
                                HStack(spacing: 8) {
                                    if twitterEngine.isBatchDownloading {
                                        ProgressView()
                                            .progressViewStyle(CircularProgressViewStyle(tint: .emeraldAccent))
                                            .scaleEffect(0.8)
                                        Text(twitterEngine.batchStatusMessage)
                                            .font(.system(size: 12.5, weight: .bold))
                                            .foregroundColor(.emeraldAccent)
                                    } else {
                                        Image(systemName: "square.and.arrow.down.on.square.fill")
                                            .font(.system(size: 13, weight: .bold))
                                        Text("Download All \(info.items.count) Items to Photos")
                                            .font(.system(size: 13, weight: .bold))
                                    }
                                }
                                .foregroundColor(.emeraldAccent)
                                .frame(maxWidth: .infinity)
                                .frame(height: 42)
                                .background(Color.emeraldAccent.opacity(0.14))
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .stroke(Color.emeraldAccent.opacity(0.3), lineWidth: 1)
                                )
                            }
                            .disabled(engine.isDownloading || twitterEngine.isBatchDownloading)
                        }
                    }
                }
            }
        }
    }

    // MARK: - YouTube Fetching Indicator Card
    @ViewBuilder
    private var ytFetchingCard: some View {
        GlassCard(cornerRadius: 16, padding: 16) {
            HStack(spacing: 12) {
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle(tint: .brandAccent))
                Text("Analyzing YouTube stream resolutions & codecs...")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.textPrimary)
                Spacer()
            }
        }
    }

    private func currentSelectedQuality(info: YouTubeVideoInfo) -> YouTubeQualityOption {
        if let match = info.qualities.first(where: { $0.id == selectedQualityId }) {
            return match
        }
        return info.qualities.first ?? YouTubeQualityOption(
            id: "fallback", label: "Auto (Best Quality)", resolution: 1080, format: "MP4",
            videoCodec: "H.264", audioCodec: "AAC", downloadUrl: "", audioUrl: nil,
            approximateBytes: nil, isCameraRollCompatible: true
        )
    }

    // MARK: - YouTube Qualities Card
    @ViewBuilder
    private func ytQualitiesCard(info: YouTubeVideoInfo) -> some View {
        let currentOption = currentSelectedQuality(info: info)

        GlassCard(cornerRadius: 18, padding: 16) {
            VStack(alignment: .leading, spacing: 14) {
                // Video Header
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "play.rectangle.fill")
                        .font(.system(size: 28))
                        .foregroundColor(.brandAccent)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(info.title)
                            .font(.system(size: 13, weight: .bold))
                            .foregroundColor(.textPrimary)
                            .lineLimit(2)

                        HStack(spacing: 8) {
                            Text(info.author)
                                .font(.system(size: 11))
                                .foregroundColor(.textMuted)

                            if info.durationSec > 0 {
                                Text("• \(info.durationSec / 60):\(String(format: "%02d", info.durationSec % 60))")
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundColor(.textTertiary)
                            }
                        }
                    }
                }

                Divider().background(Color.borderHairline)

                Text("SELECT RESOLUTION / QUALITY")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.textMuted)
                    .tracking(1.0)

                // Dropdown Menu Selector
                Menu {
                    ForEach(info.qualities) { option in
                        Button(action: {
                            selectedQualityId = option.id
                        }) {
                            HStack {
                                Text(option.label)
                                if option.isCameraRollCompatible {
                                    Image(systemName: "checkmark.circle.fill")
                                } else {
                                    Image(systemName: "folder.fill")
                                }
                                if !option.displaySize.isEmpty {
                                    Text("(\(option.displaySize))")
                                }
                            }
                        }
                    }
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 6) {
                                Text(currentOption.label)
                                    .font(.system(size: 13, weight: .bold))
                                    .foregroundColor(.textPrimary)

                                if currentOption.isCameraRollCompatible {
                                    HStack(spacing: 3) {
                                        Image(systemName: "checkmark.circle.fill")
                                            .font(.system(size: 9))
                                        Text("Camera Roll")
                                            .font(.system(size: 9, weight: .bold))
                                    }
                                    .foregroundColor(.emeraldAccent)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.emeraldAccent.opacity(0.12))
                                    .clipShape(Capsule())
                                } else {
                                    HStack(spacing: 3) {
                                        Image(systemName: "folder.fill")
                                            .font(.system(size: 9))
                                        Text("CFX Files")
                                            .font(.system(size: 9, weight: .bold))
                                    }
                                    .foregroundColor(.amberAccent)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.amberAccent.opacity(0.12))
                                    .clipShape(Capsule())
                                }
                            }

                            HStack(spacing: 8) {
                                Text("\(currentOption.format) • \(currentOption.videoCodec)")
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundColor(.textTertiary)

                                if !currentOption.displaySize.isEmpty {
                                    Text("• \(currentOption.displaySize)")
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundColor(.textMuted)
                                }
                            }
                        }

                        Spacer()

                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.skyAccent)
                            .padding(8)
                            .background(Color.voidCanvas.opacity(0.6))
                            .clipShape(Circle())
                    }
                    .padding(12)
                    .background(Color.elevatedSurface)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color.borderHairline, lineWidth: 1)
                    )
                }

                // Download Button for Selected Quality
                Button(action: {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        engine.startYouTubeDownload(option: currentOption, videoTitle: info.title)
                    }
                }) {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.system(size: 15, weight: .bold))
                        Text("Download \(currentOption.resolution > 0 ? "\(currentOption.resolution)p" : currentOption.format)")
                            .font(.system(size: 14, weight: .bold))
                    }
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
                    .background(LinearGradient.brandGradient)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .disabled(engine.isDownloading)
            }
        }
    }

    // MARK: - Download Progress Card
    @ViewBuilder
    private var downloadProgressCard: some View {
        GlassCard(cornerRadius: 16, padding: 16) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    HStack(spacing: 8) {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: .skyAccent))
                            .scaleEffect(0.8)
                        Text(engine.statusMessage.isEmpty ? "Downloading Media..." : engine.statusMessage)
                            .font(.system(size: 13, weight: .bold))
                            .foregroundColor(.textPrimary)
                    }

                    Spacer()

                    Text("\(Int(engine.progress * 100))%")
                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                        .foregroundColor(.skyAccent)
                }

                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.elevatedSurface)
                            .frame(height: 6)

                        RoundedRectangle(cornerRadius: 4)
                            .fill(LinearGradient(colors: [Color.skyAccent, Color.brandAccent], startPoint: .leading, endPoint: .trailing))
                            .frame(width: max(0, geo.size.width * CGFloat(engine.progress)), height: 6)
                    }
                }
                .frame(height: 6)

                HStack {
                    Text("\(formatBytes(engine.bytesWritten)) / \(formatBytes(engine.totalBytes))")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.textMuted)

                    Spacer()

                    Text("\(String(format: "%.1f", engine.downloadSpeedMBs)) MB/s")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundColor(.emeraldAccent)
                }

                Button(action: { engine.cancelDownload() }) {
                    Text("Cancel Download")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.textMuted)
                        .frame(maxWidth: .infinity)
                        .frame(height: 32)
                        .background(Color.elevatedSurface)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }
        }
    }

    // MARK: - Download Result Card
    @ViewBuilder
    private func downloadResultCard(fileUrl: URL, inspection: MediaInspection) -> some View {
        GlassCard(cornerRadius: 18, padding: 16) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.emeraldAccent)
                        .font(.system(size: 18))

                    VStack(alignment: .leading, spacing: 2) {
                        Text(fileUrl.lastPathComponent)
                            .font(.system(size: 14, weight: .bold))
                            .foregroundColor(.textPrimary)
                            .lineLimit(1)

                        Text(engine.savedToPhotos
                             ? "✓ Saved to Photos Library & CFX Studio Files"
                             : "Saved to On My iPhone > CFX Studio")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(engine.savedToPhotos ? .emeraldAccent : .amberAccent)
                    }
                    Spacer()
                }

                if !engine.savedToPhotos, let reason = inspection.incompatibilityReason {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "info.circle.fill")
                            .foregroundColor(.amberAccent)
                            .font(.system(size: 12))
                            .padding(.top, 1)

                        Text(reason)
                            .font(.system(size: 11))
                            .foregroundColor(.textMuted)
                    }
                    .padding(8)
                    .background(Color.amberAccent.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("MEDIA CODECS & CONTAINER")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.textTertiary)
                        .tracking(1.0)

                    HStack(spacing: 6) {
                        codecChip(title: "Container", value: inspection.container, color: .skyAccent)
                        if inspection.isVideo {
                            codecChip(title: "Video", value: inspection.videoCodec, color: .emeraldAccent)
                            codecChip(title: "Audio", value: inspection.audioCodec, color: .amberAccent)
                        } else {
                            codecChip(title: "Resolution", value: "\(inspection.width)×\(inspection.height)", color: .emeraldAccent)
                        }
                    }
                }

                Divider().background(Color.borderHairline)

                VStack(spacing: 8) {
                    if (!inspection.isPhotosCompatible && inspection.isVideo) || MKVRemuxEngine.shared.isMatroska(url: fileUrl) {
                        Button(action: { remuxDownloadedMKV(url: fileUrl) }) {
                            HStack(spacing: 8) {
                                if isRemuxingDownloadedFile {
                                    ProgressView()
                                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                        .scaleEffect(0.8)
                                    Text("Optimizing for iOS... \(Int(remuxProgress * 100))%")
                                        .font(.system(size: 13, weight: .bold))
                                } else {
                                    Image(systemName: "bolt.fill")
                                        .font(.system(size: 13, weight: .bold))
                                    Text("⚡ Optimize for iOS & Save to Photos")
                                        .font(.system(size: 13, weight: .bold))
                                }
                            }
                            .frame(maxWidth: .infinity)
                            .frame(height: 42)
                            .background(LinearGradient.brandGradient)
                            .foregroundColor(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                        }
                        .disabled(isRemuxingDownloadedFile)
                    }

                    Button(action: { showShareSheet = true }) {
                        HStack(spacing: 8) {
                            Image(systemName: "square.and.arrow.up")
                                .font(.system(size: 14, weight: .bold))
                            Text("Share / Save to Files")
                                .font(.system(size: 13, weight: .bold))
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 42)
                        .background(Color.elevatedSurface)
                        .foregroundColor(.skyAccent)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(Color.skyAccent.opacity(0.3), lineWidth: 1)
                        )
                    }

                    HStack(spacing: 8) {
                        if inspection.isVideo {
                            NavigationLink(destination: VideoTrimmerView()) {
                                toolPipelineButton(icon: "scissors", label: "Trimmer")
                            }

                            NavigationLink(destination: FrameExporterView()) {
                                toolPipelineButton(icon: "photo.stack", label: "Exporter")
                            }

                            NavigationLink(destination: VideoConverterView()) {
                                toolPipelineButton(icon: "arrow.triangle.2.circlepath", label: "Converter")
                            }
                        } else {
                            NavigationLink(destination: ImageCropperView()) {
                                toolPipelineButton(icon: "crop", label: "Open Cropper")
                            }
                        }
                    }

                    Button(action: {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            engine.reset()
                        }
                    }) {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.counterclockwise")
                                .font(.system(size: 11, weight: .semibold))
                            Text("Download Another Video / Format")
                                .font(.system(size: 12, weight: .semibold))
                        }
                        .foregroundColor(.skyAccent)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 4)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func codecChip(title: String, value: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Text(title + ":")
                .font(.system(size: 10))
                .foregroundColor(.textMuted)
            Text(value)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundColor(color)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.surfaceCard)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.borderHairline, lineWidth: 1)
        )
    }

    @ViewBuilder
    private func toolPipelineButton(icon: String, label: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .bold))
            Text(label)
                .font(.system(size: 11, weight: .bold))
        }
        .foregroundColor(.textPrimary)
        .frame(maxWidth: .infinity)
        .frame(height: 36)
        .background(Color.elevatedSurface)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.borderHairline, lineWidth: 1)
        )
    }

    @ViewBuilder
    private func errorBanner(error: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.brandVibrant)
                .font(.system(size: 14))

            Text(error)
                .font(.system(size: 12))
                .foregroundColor(.textPrimary)

            Spacer()
        }
        .padding(12)
        .background(Color.brandAccent.opacity(0.15))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.brandAccent.opacity(0.3), lineWidth: 1)
        )
    }

    // MARK: - Recent Local Downloads Section
    @ViewBuilder
    private var recentDownloadsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("CFX STUDIO STORAGE (ON MY IPHONE)")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.textMuted)
                    .tracking(1.0)
                Spacer()
                Text("\(recentDownloads.count) files")
                    .font(.system(size: 11))
                    .foregroundColor(.textTertiary)
            }

            VStack(spacing: 6) {
                ForEach(recentDownloads.prefix(5), id: \.self) { url in
                    recentFileRow(url: url)
                }
            }
        }
        .padding(.top, 8)
    }

    @ViewBuilder
    private func recentFileRow(url: URL) -> some View {
        GlassCard(cornerRadius: 12, padding: 10) {
            HStack(spacing: 10) {
                let isVid = ["mp4", "mov", "mkv", "webm", "m4v"].contains(url.pathExtension.lowercased())
                Image(systemName: isVid ? "video.fill" : "photo.fill")
                    .font(.system(size: 14))
                    .foregroundColor(isVid ? .skyAccent : .amberAccent)
                    .frame(width: 24)

                VStack(alignment: .leading, spacing: 2) {
                    Text(url.lastPathComponent)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.textPrimary)
                        .lineLimit(1)

                    if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
                       let size = attrs[.size] as? Int64 {
                        Text(formatBytes(size))
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(.textMuted)
                    }
                }

                Spacer()

                Button(action: {
                    engine.downloadedFileUrl = url
                    showShareSheet = true
                }) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 12))
                        .foregroundColor(.skyAccent)
                        .padding(6)
                        .background(Color.elevatedSurface)
                        .clipShape(Circle())
                }
            }
        }
    }

    // MARK: - Helpers
    private func pasteFromClipboard() {
        if let clip = UIPasteboard.general.string {
            inputUrl = clip.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private func formatBytes(_ bytes: Int64) -> String {
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

    private func remuxDownloadedMKV(url: URL) {
        guard !isRemuxingDownloadedFile else { return }
        isRemuxingDownloadedFile = true
        remuxProgress = 0.0
        Task {
            do {
                let mp4Url = try await MKVRemuxEngine.shared.remuxToMP4(sourceUrl: url) { progress, _ in
                    Task { @MainActor in
                        self.remuxProgress = progress
                    }
                }
                let saved = await engine.saveVideoToPhotos(url: mp4Url)
                await MainActor.run {
                    self.isRemuxingDownloadedFile = false
                    if saved {
                        self.engine.savedToPhotos = true
                    }
                }
            } catch {
                await MainActor.run {
                    self.isRemuxingDownloadedFile = false
                }
            }
        }
    }

    private func refreshRecentDownloads() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        if let files = try? FileManager.default.contentsOfDirectory(at: docs, includingPropertiesForKeys: [.contentModificationDateKey], options: .skipsHiddenFiles) {
            recentDownloads = files.sorted {
                let d1 = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date.distantPast
                let d2 = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date.distantPast
                return d1 > d2
            }
        }
    }
}

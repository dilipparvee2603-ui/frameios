import SwiftUI

struct ProjectGalleryView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var projects: [VideoProject] = []
    @State private var showCreateModal: Bool = false
    @State private var newProjectTitle: String = "My Project"
    @State private var selectedAspectRatio: AspectRatioPreset = .ratio9x16

    var body: some View {
        ZStack {
            Color.voidCanvas.ignoresSafeArea()

            VStack(spacing: 16) {
                // Header Bar
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
                        Text("PRO VIDEO EDITOR")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundColor(.textPrimary)

                        Text("Multi-Clip Timeline • Precision Slow-Mo • 4K Export")
                            .font(.system(size: 10))
                            .foregroundColor(.textMuted)
                    }

                    Spacer()

                    Button(action: {
                        newProjectTitle = "Project \(projects.count + 1)"
                        showCreateModal = true
                    }) {
                        HStack(spacing: 5) {
                            Image(systemName: "plus.circle.fill")
                                .font(.system(size: 13, weight: .bold))
                            Text("New Project")
                                .font(.system(size: 12, weight: .bold))
                        }
                        .foregroundColor(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(LinearGradient.brandGradient)
                        .clipShape(Capsule())
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)

                if projects.isEmpty {
                    emptyState
                } else {
                    projectsList
                }
            }
        }
        .navigationBarBackButtonHidden(true)
        .onAppear {
            refreshProjects()
        }
        .sheet(isPresented: $showCreateModal) {
            createProjectSheet
        }
    }

    // MARK: - Empty State
    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 16) {
            Spacer()

            ZStack {
                Circle()
                    .fill(Color.surfaceCard)
                    .frame(width: 80, height: 80)
                Image(systemName: "film.stack.fill")
                    .font(.system(size: 36))
                    .foregroundColor(.brandAccent)
            }

            Text("No Editing Projects Yet")
                .font(.system(size: 17, weight: .bold))
                .foregroundColor(.textPrimary)

            Text("Create your first multi-clip timeline project with precision optical-flow slow-mo and color grading.")
                .font(.system(size: 13))
                .foregroundColor(.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

            Button(action: {
                newProjectTitle = "Project 1"
                showCreateModal = true
            }) {
                HStack(spacing: 8) {
                    Image(systemName: "plus")
                        .font(.system(size: 14, weight: .bold))
                    Text("Create New Project")
                        .font(.system(size: 14, weight: .bold))
                }
                .foregroundColor(.white)
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .background(LinearGradient.brandGradient)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .padding(.top, 8)

            Spacer()
        }
    }

    // MARK: - Projects List
    @ViewBuilder
    private var projectsList: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                ForEach(projects) { project in
                    NavigationLink(destination: VideoEditorView(existingProject: project)) {
                        projectCard(project: project)
                    }
                    .buttonStyle(PlainButtonStyle())
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
    }

    @ViewBuilder
    private func projectCard(project: VideoProject) -> some View {
        GlassCard(cornerRadius: 16, padding: 14) {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.elevatedSurface)
                        .frame(width: 52, height: 52)
                    Image(systemName: "video.fill")
                        .font(.system(size: 20))
                        .foregroundColor(.brandAccent)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(project.title)
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(.textPrimary)

                    HStack(spacing: 8) {
                        Text(project.canvasAspectRatio.badgeText)
                            .font(.system(size: 9, weight: .heavy))
                            .foregroundColor(.skyAccent)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.skyAccent.opacity(0.14))
                            .clipShape(Capsule())

                        Text("\(project.clips.count) CLIPS")
                            .font(.system(size: 9, weight: .heavy))
                            .foregroundColor(.emeraldAccent)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.emeraldAccent.opacity(0.14))
                            .clipShape(Capsule())

                        Text(formatDuration(project.totalTimelineDurationMs))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.textTertiary)
                    }
                }

                Spacer()

                Menu {
                    Button(action: {
                        _ = ProjectStorageManager.shared.duplicateProject(project)
                        refreshProjects()
                    }) {
                        Label("Duplicate Project", systemImage: "plus.square.on.square")
                    }

                    Button(role: .destructive, action: {
                        ProjectStorageManager.shared.deleteProject(id: project.id)
                        refreshProjects()
                    }) {
                        Label("Delete Project", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 16))
                        .foregroundColor(.textTertiary)
                        .frame(width: 32, height: 32)
                }
            }
        }
    }

    // MARK: - Create Project Sheet
    @ViewBuilder
    private var createProjectSheet: some View {
        ZStack {
            Color.voidCanvas.ignoresSafeArea()

            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Text("NEW PROJECT")
                        .font(.system(size: 15, weight: .heavy))
                        .foregroundColor(.textPrimary)
                    Spacer()
                    Button("Cancel") { showCreateModal = false }
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(.textTertiary)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Project Name")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.textSecondary)
                    TextField("Project Name", text: $newProjectTitle)
                        .font(.system(size: 14))
                        .foregroundColor(.textPrimary)
                        .padding(12)
                        .background(Color.elevatedSurface)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Aspect Ratio Canvas")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.textSecondary)

                    Picker("Aspect Ratio", selection: $selectedAspectRatio) {
                        ForEach(AspectRatioPreset.allCases) { preset in
                            Text(preset.rawValue).tag(preset)
                        }
                    }
                    .pickerStyle(WheelPickerStyle())
                    .frame(height: 120)
                }

                Spacer()

                Button(action: {
                    let newProj = VideoProject(
                        title: newProjectTitle.isEmpty ? "My Project" : newProjectTitle,
                        canvasAspectRatio: selectedAspectRatio
                    )
                    ProjectStorageManager.shared.saveProject(newProj)
                    refreshProjects()
                    showCreateModal = false
                }) {
                    Text("Create Project")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 48)
                        .background(LinearGradient.brandGradient)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
            }
            .padding(20)
        }
    }

    private func refreshProjects() {
        projects = ProjectStorageManager.shared.listProjects()
    }

    private func formatDuration(_ ms: Int64) -> String {
        let totalSec = Double(max(0, ms)) / 1000.0
        let m = Int(totalSec) / 60
        let s = Int(totalSec) % 60
        return String(format: "%02d:%02d", m, s)
    }
}

import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers
import ZulipCoreBindings

/// Zulip's rules for a display name, checked before asking the server so the
/// editor can say what is wrong while the user types.
enum ProfileName {
    /// Zulip counts Unicode code points (`UserProfile.MIN_NAME_LENGTH` and
    /// `MAX_NAME_LENGTH`).
    static let minimumLength = 2
    static let maximumLength = 100
    /// Characters that would break mention and Markdown syntax.
    static let forbiddenCharacters: Set<Character> = ["*", "`", "\\", ">", "\"", "@"]

    /// Why Zulip would refuse `name` (already trimmed); nil when it would accept it.
    static func problem(with name: String) -> String? {
        let length = name.unicodeScalars.count
        if length < minimumLength {
            return "Enter a name of at least \(minimumLength) characters."
        }
        if length > maximumLength {
            return "A name can be up to \(maximumLength) characters."
        }
        if let character = name.first(where: forbiddenCharacters.contains) {
            return "A name cannot contain \(character)."
        }
        if name.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) {
            return "A name cannot contain control characters."
        }
        // "Name|12" reads as the `@**Name|12**` mention syntax.
        if let bar = name.lastIndex(of: "|") {
            let suffix = name[name.index(after: bar)...]
            if !suffix.isEmpty, suffix.allSatisfy(\.isASCII), suffix.allSatisfy(\.isNumber) {
                return "A name cannot end in “|” followed by digits."
            }
        }
        return nil
    }
}

/// Turns a picture the user chose into one Zulip accepts as an avatar.
enum AvatarImagePreparation {
    /// Zulip keeps a 500 px avatar at most; a little more stays sharp after its
    /// own scaling.
    static let side = 1_000

    /// Reads the chosen picture, crops it to its centre square (the part Zulip
    /// keeps), scales it to at most `side` pixels and writes it to a temporary
    /// file: JPEG when it has no transparency, PNG otherwise. A format Zulip
    /// cannot read, such as HEIC, becomes one it can, and a large photo no
    /// longer exceeds the server's upload limit. Nil when the file is not a
    /// picture.
    nonisolated static func prepare(_ source: URL) async -> URL? {
        let side = Self.side
        return await Task.detached(priority: .userInitiated) { () -> URL? in
            let accessed = source.startAccessingSecurityScopedResource()
            defer {
                if accessed {
                    source.stopAccessingSecurityScopedResource()
                }
            }
            guard let imageSource = CGImageSourceCreateWithURL(source as CFURL, nil),
                  let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil)
                      as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Int,
                  let height = properties[kCGImagePropertyPixelHeight] as? Int,
                  width > 0,
                  height > 0
            else {
                return nil
            }
            // Decoded so that the shorter side, which the square keeps, lands
            // at `side`; a smaller picture keeps its own size.
            let longer = max(width, height)
            let shorter = min(width, height)
            let decodeSize = min(
                longer,
                Int((Double(side) * Double(longer) / Double(shorter)).rounded(.up))
            )
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: decodeSize,
                kCGImageSourceShouldCacheImmediately: true,
            ]
            guard let image = CGImageSourceCreateThumbnailAtIndex(
                imageSource,
                0,
                options as CFDictionary
            ) else {
                return nil
            }
            let square = min(image.width, image.height)
            let crop = CGRect(
                x: (image.width - square) / 2,
                y: (image.height - square) / 2,
                width: square,
                height: square
            )
            guard let cropped = image.cropping(to: crop) else {
                return nil
            }
            let opaque: [CGImageAlphaInfo] = [.none, .noneSkipFirst, .noneSkipLast]
            let hasAlpha = !opaque.contains(cropped.alphaInfo)
            let type = hasAlpha ? UTType.png : UTType.jpeg
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("ZulipMacAvatars", isDirectory: true)
            try? FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            let target = directory
                .appendingPathComponent("avatar-\(UUID().uuidString)")
                .appendingPathExtension(hasAlpha ? "png" : "jpg")
            guard let destination = CGImageDestinationCreateWithURL(
                target as CFURL,
                type.identifier as CFString,
                1,
                nil
            ) else {
                return nil
            }
            let imageProperties: [CFString: Any] = hasAlpha
                ? [:]
                : [kCGImageDestinationLossyCompressionQuality: 0.9]
            CGImageDestinationAddImage(destination, cropped, imageProperties as CFDictionary)
            guard CGImageDestinationFinalize(destination) else {
                try? FileManager.default.removeItem(at: target)
                return nil
            }
            return target
        }.value
    }

    /// Deletes a prepared picture once it is no longer needed, off the main actor.
    nonisolated static func discard(_ file: URL) {
        Task.detached(priority: .utility) {
            try? FileManager.default.removeItem(at: file)
        }
    }
}

/// Changes the user's own photo and name. Both are saved together on Save and
/// show everywhere once the server accepts them.
struct ProfileEditor: View {
    let session: LiveSessionViewModel
    let dismiss: () -> Void

    private static let photoSize: CGFloat = 72

    @State private var name: String
    /// The chosen picture, prepared for upload and not yet handed to the session.
    @State private var photoFile: URL?
    @State private var photoPreview: NSImage?
    @State private var isPreparingPhoto = false
    @State private var isChoosingPhoto = false
    @State private var photoProblem: String?
    @FocusState private var isNameFocused: Bool

    init(session: LiveSessionViewModel, dismiss: @escaping () -> Void) {
        self.session = session
        self.dismiss = dismiss
        _name = State(initialValue: session.ownFullName)
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var nameProblem: String? {
        ProfileName.problem(with: trimmedName)
    }

    private var changesName: Bool {
        trimmedName != session.ownFullName
    }

    private var isSaving: Bool {
        session.profileSaveState == .saving
    }

    private var canSave: Bool {
        (changesName || photoFile != nil)
            && (!changesName || nameProblem == nil)
            && !isSaving
            && !isPreparingPhoto
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.large) {
            Text("Edit profile")
                .font(AppTheme.Typography.title)

            HStack(spacing: AppTheme.Spacing.large) {
                photo

                VStack(alignment: .leading, spacing: AppTheme.Spacing.extraSmall) {
                    Button(photoFile == nil ? "Choose Photo…" : "Choose Another Photo…") {
                        isChoosingPhoto = true
                    }
                    .disabled(isSaving || isPreparingPhoto)
                    Text("The centre of the picture is shown in a circle.")
                        .font(AppTheme.Typography.caption)
                        .foregroundStyle(AppTheme.Colors.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                    if let photoProblem {
                        Text(photoProblem)
                            .font(AppTheme.Typography.caption)
                            .foregroundStyle(AppTheme.Colors.destructive)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            VStack(alignment: .leading, spacing: AppTheme.Spacing.extraSmall) {
                Text("Name")
                    .font(AppTheme.Typography.label)
                    .foregroundStyle(AppTheme.Colors.secondaryText)
                TextField("Your name", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .focused($isNameFocused)
                    .disabled(isSaving)
                    .onSubmit(submit)
                if changesName, let nameProblem {
                    Text(nameProblem)
                        .font(AppTheme.Typography.caption)
                        .foregroundStyle(AppTheme.Colors.destructive)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if case let .failed(message) = session.profileSaveState {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(AppTheme.Typography.caption)
                    .foregroundStyle(AppTheme.Colors.destructive)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                if isSaving {
                    ProgressView()
                        .controlSize(.small)
                }
                Button("Cancel") {
                    session.resetProfileSave()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                .disabled(isSaving)
                Button("Save", action: submit)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
            }
        }
        .padding(28)
        .frame(width: 420)
        .interactiveDismissDisabled(isSaving)
        .fileImporter(isPresented: $isChoosingPhoto, allowedContentTypes: [.image]) { result in
            if case let .success(url) = result {
                choosePhoto(url)
            }
        }
        .onAppear {
            session.resetProfileSave()
            isNameFocused = true
        }
        .onChange(of: session.profileSaveState) {
            switch session.profileSaveState {
            case .saved:
                session.resetProfileSave()
                dismiss()
            case .failed:
                // A photo that was handed over is gone; show the current one again.
                if photoFile == nil {
                    photoPreview = nil
                }
            case .idle, .saving:
                break
            }
        }
        .onDisappear {
            if let photoFile {
                AvatarImagePreparation.discard(photoFile)
            }
        }
    }

    @ViewBuilder
    private var photo: some View {
        ZStack {
            if let photoPreview {
                Image(nsImage: photoPreview)
                    .resizable()
                    .scaledToFill()
                    .frame(width: Self.photoSize, height: Self.photoSize)
                    .clipShape(Circle())
            } else {
                AvatarImage(
                    initials: session.sidebarSnapshot?.currentUserInitials ?? "?",
                    remoteURL: session.sidebarSnapshot?.currentUserAvatarURL,
                    size: Self.photoSize,
                    mediaLocalURLs: session.mediaLocalURLs,
                    requestMedia: session.loadMedia
                )
            }
            if isPreparingPhoto {
                Circle()
                    .fill(AppTheme.Colors.canvas.opacity(0.6))
                    .frame(width: Self.photoSize, height: Self.photoSize)
                ProgressView()
                    .controlSize(.small)
            }
        }
        .frame(width: Self.photoSize, height: Self.photoSize)
        .accessibilityElement()
        .accessibilityLabel(photoFile == nil ? "Your photo" : "Your new photo")
    }

    private func choosePhoto(_ url: URL) {
        photoProblem = nil
        isPreparingPhoto = true
        Task {
            let prepared = await AvatarImagePreparation.prepare(url)
            isPreparingPhoto = false
            guard let prepared else {
                photoProblem = "This file is not a picture Zulip Mac can read."
                return
            }
            if let previous = photoFile {
                AvatarImagePreparation.discard(previous)
            }
            photoFile = prepared
            photoPreview = await NativeImageDecoder.load(prepared, maxPixelSize: 240).image
        }
    }

    private func submit() {
        guard canSave else {
            return
        }
        let file = photoFile
        // From here the session owns the picture and deletes it when done.
        photoFile = nil
        session.saveProfile(
            fullName: changesName ? trimmedName : nil,
            avatarFile: file
        )
    }
}

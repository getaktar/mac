import AVFoundation
import AVKit
import SwiftUI
import UniformTypeIdentifiers

/// A video or audio file in a bucket, played from its link without being
/// downloaded first. Nothing is loaded until Play is clicked; until then
/// its thumbnail stands in.
struct MediaPreview: View {
    let filename: String
    let poster: NSImage?
    /// The link to play from, asked for on Play: a presigned one where
    /// possible, so private buckets work too.
    let url: () async -> URL?

    @State private var player: AVPlayer?
    @State private var isLoading = false
    @State private var failed = false

    /// Whether AVFoundation can play this kind of file (MP4, MOV, M4V, MP3,
    /// M4A, WAV and the like, but not MKV or WebM).
    static func canPlay(filename: String) -> Bool {
        let ext = (filename as NSString).pathExtension
        guard !ext.isEmpty, let type = UTType(filenameExtension: ext),
              type.conforms(to: .audiovisualContent) else { return false }
        return AVURLAsset.audiovisualTypes().contains { $0.rawValue == type.identifier }
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.9)
            if let player {
                PlayerView(player: player)
            } else {
                if let poster {
                    Image(nsImage: poster)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else {
                    Image(systemName: FileKindIcon.symbolName(for: filename))
                        .font(.system(size: 44))
                        .foregroundStyle(.white.opacity(0.5))
                }
                if failed {
                    Label("Preview unavailable", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(.regularMaterial, in: Capsule())
                } else if isLoading {
                    ProgressView()
                } else {
                    Button(action: play) {
                        Image(systemName: "play.circle.fill")
                            .font(.system(size: 54))
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, .black.opacity(0.45))
                            .shadow(radius: 6)
                    }
                    .buttonStyle(.plain)
                    .help("Play")
                }
            }
        }
        .onDisappear { player?.pause() }
    }

    private func play() {
        isLoading = true
        Task {
            defer { isLoading = false }
            guard let url = await url() else {
                failed = true
                return
            }
            let player = AVPlayer(url: url)
            self.player = player
            player.play()
        }
    }
}

/// AppKit's own player view (the one QuickTime Player uses). SwiftUI's
/// `VideoPlayer` crashes on macOS while setting itself up, so it isn't used.
private struct PlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .inline
        view.showsFullScreenToggleButton = true
        view.player = player
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
    }

    static func dismantleNSView(_ view: AVPlayerView, coordinator: ()) {
        view.player?.pause()
        view.player = nil
    }
}

import AVKit
import SwiftUI

#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

struct PlayerBar: View {
    @ObservedObject var playback: PlaybackController
    let openNowPlaying: (() -> Void)?
    let usesSystemGlassContainer: Bool

    @State private var isSeeking = false
    @State private var pendingSeekTime = 0.0
    @State private var isVolumeVisible = false

    init(
        playback: PlaybackController,
        usesSystemGlassContainer: Bool = false,
        openNowPlaying: (() -> Void)? = nil
    ) {
        self.playback = playback
        self.usesSystemGlassContainer = usesSystemGlassContainer
        self.openNowPlaying = openNowPlaying
    }

    @ViewBuilder
    var body: some View {
        if usesSystemGlassContainer {
            playerContent
                .padding(.horizontal, 8)
                .zIndex(2)
        } else {
            Group {
                if #available(macOS 26.0, iOS 26.0, *) {
                    playerContent
                        .glassEffect(.regular.interactive(), in: Capsule())
                } else {
                    playerContent
                        .background(.ultraThinMaterial, in: Capsule())
                }
            }
            .frame(height: 52)
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
            .background(alignment: .bottom) {
                LinearGradient(
                    colors: [
                        platformWindowBackground.opacity(0),
                        platformWindowBackground.opacity(0.22)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 44)
                .padding(.bottom, -8)
                .allowsHitTesting(false)
            }
            .zIndex(2)
        }
    }

    private var playerContent: some View {
        GeometryReader { geometry in
            if geometry.size.width <= 520, openNowPlaying != nil {
                compactPlayerContent
            } else {
                desktopPlayerContent(isCompact: geometry.size.width <= 700)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 52)
    }

    private func desktopPlayerContent(isCompact: Bool) -> some View {
        HStack(spacing: 10) {
            songInfoSection(isCompact: isCompact)
                .frame(width: isCompact ? 52 : 200, height: 52)

            progressSection
                .frame(maxWidth: .infinity)
                .frame(height: 52)

            playbackOptionsSection
                .frame(width: 42, height: 52)
        }
    }

    private var compactPlayerContent: some View {
        HStack(spacing: 8) {
            Button(action: { openNowPlaying?() }) {
                HStack(spacing: 10) {
                    AlbumArtworkView(
                        url: playback.currentSong?.artworkURL,
                        cornerRadius: 6
                    )
                    .frame(width: 36, height: 36)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(playback.currentSong?.title ?? "")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.primary)
                            .lineLimit(1)

                        Text(playback.currentSong?.artist ?? "")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityLabel("Now Playing")

            if playback.isBuffering {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 36, height: 36)
            } else {
                PlayerBarIconButton(
                    action: playback.togglePlayback,
                    accessibilityLabel: playback.isPlaying ? "Pause" : "Play"
                ) {
                    Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 18))
                        .contentTransition(.symbolEffect(.replace))
                }
                .frame(width: 36, height: 36)
            }

            PlayerBarIconButton(
                action: playback.playNext,
                accessibilityLabel: "Next"
            ) {
                Image(systemName: "forward.fill")
                    .font(.system(size: 14))
            }
            .frame(width: 36, height: 36)
            .disabled(!playback.canGoNext)
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func songInfoSection(isCompact: Bool) -> some View {
        if let openNowPlaying {
            Button(action: openNowPlaying) {
                songInfoContent(isCompact: isCompact)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Now Playing")
        } else {
            songInfoContent(isCompact: isCompact)
        }
    }

    private func songInfoContent(isCompact: Bool) -> some View {
        HStack(spacing: 8) {
            AlbumArtworkView(
                url: playback.currentSong?.artworkURL,
                cornerRadius: 6
            )
            .frame(width: 32, height: 32)

            if !isCompact {
                VStack(alignment: .leading, spacing: 4) {
                    Text(playback.currentSong?.title ?? "")
                        .font(.system(size: 13))
                        .lineLimit(1)

                    Text(playback.currentSong?.artist ?? "")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(width: 140, height: 29, alignment: .leading)
            }
        }
        .padding(.leading, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    private var progressSection: some View {
        ZStack(alignment: .top) {
            PlayerProgressLane(
                elapsedTime: displayedElapsedTime,
                duration: playback.duration,
                canSeek: playback.duration > 0,
                isLoading: playback.isBuffering,
                onScrub: { time in
                    pendingSeekTime = time
                    isSeeking = true
                },
                onCommit: { time in
                    pendingSeekTime = time
                    playback.seek(to: time)
                    isSeeking = false
                }
            )
            .padding(.top, 18)
            .zIndex(1)

            progressActionButtons
                .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var progressActionButtons: some View {
        HStack(spacing: 6) {
            AirPlayRoutePicker()
                .frame(width: 28, height: 28)
                .disabled(playback.currentSong == nil)

            PlayerBarIconButton(
                action: playback.toggleShuffle,
                isSelected: playback.isShuffling,
                accessibilityLabel: "Shuffle"
            ) {
                Image(systemName: "shuffle")
                    .font(.system(size: 16))
                    .foregroundStyle(playback.isShuffling ? YoruneStyle.accent : Color.primary)
            }

            PlayerBarIconButton(
                action: playback.playPrevious,
                accessibilityLabel: "Previous"
            ) {
                Image(systemName: "backward.fill")
                    .font(.system(size: 13))
            }
            .disabled(!playback.canGoPrevious)

            PlayerBarIconButton(
                action: playback.togglePlayback,
                accessibilityLabel: playback.isPlaying ? "Pause" : "Play"
            ) {
                Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 20))
                    .contentTransition(.symbolEffect(.replace))
            }
            .disabled(playback.currentSong == nil)

            PlayerBarIconButton(
                action: playback.playNext,
                accessibilityLabel: "Next"
            ) {
                Image(systemName: "forward.fill")
                    .font(.system(size: 13))
            }
            .disabled(!playback.canGoNext)

            PlayerBarIconButton(
                action: playback.cycleRepeatMode,
                isSelected: playback.repeatMode != .off,
                accessibilityLabel: "Repeat"
            ) {
                Image(systemName: repeatSymbol)
                    .font(.system(size: 16))
                    .foregroundStyle(
                        playback.repeatMode == .off
                            ? Color.primary
                            : YoruneStyle.accent
                    )
                    .contentTransition(.symbolEffect(.replace))
            }

            PlayerBarIconButton(
                action: {
                    withAnimation(YoruneStyle.quickAnimation) {
                        isVolumeVisible.toggle()
                    }
                },
                accessibilityLabel: "Volume"
            ) {
                Image(systemName: volumeSymbol)
                    .font(.system(size: 15))
                    .contentTransition(.symbolEffect(.replace))
            }
            .popover(isPresented: $isVolumeVisible, arrowEdge: .bottom) {
                PlayerVolumePopover(playback: playback)
            }
        }
    }

    private var playbackOptionsSection: some View {
        HStack {
            PlayerBarIconButton(
                action: playback.toggleQueueInspector,
                isSelected: playback.isQueuePresented,
                accessibilityLabel: "Queue"
            ) {
                Image(systemName: "list.bullet")
                    .font(.system(size: 16))
                    .foregroundStyle(
                        playback.isQueuePresented
                            ? YoruneStyle.accent
                            : Color.primary
                    )
            }
        }
        .padding(.trailing, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
    }

    private var displayedElapsedTime: Double {
        isSeeking ? pendingSeekTime : playback.elapsedTime
    }

    private var volumeSymbol: String {
        switch playback.volume {
        case 0:
            "speaker.slash.fill"
        case ..<0.34:
            "speaker.wave.1.fill"
        case ..<0.67:
            "speaker.wave.2.fill"
        default:
            "speaker.wave.3.fill"
        }
    }

    private var repeatSymbol: String {
        playback.repeatMode == .one ? "repeat.1" : "repeat"
    }

    private var platformWindowBackground: Color {
        #if os(macOS)
        Color(nsColor: .windowBackgroundColor)
        #elseif os(iOS)
        Color(uiColor: .systemBackground)
        #endif
    }
}

private struct PlayerProgressLane: View {
    let elapsedTime: Double
    let duration: Double
    let canSeek: Bool
    let isLoading: Bool
    let onScrub: (Double) -> Void
    let onCommit: (Double) -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var isDragging = false
    @State private var isHovering = false

    private var fraction: CGFloat {
        guard duration > 0 else { return 0 }
        return CGFloat(min(max(elapsedTime / duration, 0), 1))
    }

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Text(formatTime(elapsedTime))
                Spacer(minLength: 8)
                Text("-\(formatTime(max(0, duration - elapsedTime)))")
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .monospacedDigit()
            .lineLimit(1)
            .frame(height: 12)

            progressBar
        }
        .frame(height: 30)
        .accessibilityElement()
        .accessibilityLabel(Text("Playback Position"))
        .accessibilityValue(
            Text("\(formatTime(elapsedTime)) / \(formatTime(duration))")
        )
        .accessibilityAdjustableAction { direction in
            guard canSeek else { return }
            let step = max(5, duration * 0.02)
            switch direction {
            case .increment:
                let target = min(duration, elapsedTime + step)
                onScrub(target)
                onCommit(target)
            case .decrement:
                let target = max(0, elapsedTime - step)
                onScrub(target)
                onCommit(target)
            @unknown default:
                break
            }
        }
    }

    private var progressBar: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let thumbSize: CGFloat = isDragging ? 14 : (isHovering ? 12 : 10)

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(trackColor)
                    .frame(height: 4)

                Capsule()
                    .fill(isLoading ? Color.secondary : YoruneStyle.accent)
                    .frame(width: width * fraction, height: 4)

                Circle()
                    .fill(isLoading ? Color.secondary : YoruneStyle.accent)
                    .frame(width: thumbSize, height: thumbSize)
                    .offset(
                        x: min(
                            max(0, width * fraction - thumbSize / 2),
                            max(0, width - thumbSize)
                        )
                    )
                    .opacity(canSeek ? 1 : 0)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard canSeek, width > 0 else { return }
                        isDragging = true
                        onScrub(progressTime(x: value.location.x, width: width))
                    }
                    .onEnded { value in
                        defer { isDragging = false }
                        guard canSeek, width > 0 else { return }
                        let target = progressTime(x: value.location.x, width: width)
                        onScrub(target)
                        onCommit(target)
                    }
            )
            .onHover { hovering in
                isHovering = hovering
            }
        }
        .frame(height: 12)
    }

    private var trackColor: Color {
        let opacity = isHovering || isDragging ? 0.28 : 0.18
        return colorScheme == .dark
            ? .white.opacity(opacity)
            : .black.opacity(opacity)
    }

    private func progressTime(x: CGFloat, width: CGFloat) -> Double {
        let clampedX = min(max(x, 0), width)
        return duration * Double(clampedX / width)
    }

    private func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0:00" }
        let totalSeconds = Int(seconds.rounded(.down))
        return "\(totalSeconds / 60):\(String(format: "%02d", totalSeconds % 60))"
    }
}

private struct PlayerBarIconButton<Icon: View>: View {
    let action: () -> Void
    var isSelected = false
    let accessibilityLabel: LocalizedStringKey
    @ViewBuilder let icon: () -> Icon

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Label {
                Text(accessibilityLabel)
            } icon: {
                icon()
                    .frame(width: 28, height: 28)
                    .background {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(backgroundColor)
                    }
                    .contentShape(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                    )
            }
            .labelStyle(.iconOnly)
        }
        .buttonStyle(PlayerBarIconButtonStyle())
        .frame(width: 28, height: 28)
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityLabel(Text(accessibilityLabel))
        .opacity(isEnabled ? 1 : 0.38)
        .onHover { hovering in
            withAnimation(YoruneStyle.quickAnimation) {
                isHovering = hovering
            }
        }
    }

    private var backgroundColor: Color {
        let baseColor: Color = colorScheme == .dark ? .white : .black
        if isHovering, isEnabled {
            return baseColor.opacity(0.08)
        }
        if isSelected {
            return baseColor.opacity(0.06)
        }
        return .clear
    }
}

private struct PlayerBarIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .opacity(configuration.isPressed ? 0.72 : 1)
            .animation(YoruneStyle.quickAnimation, value: configuration.isPressed)
    }
}

private struct PlayerVolumePopover: View {
    @ObservedObject var playback: PlaybackController

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "speaker.fill")
                .foregroundStyle(.secondary)

#if os(iOS)
            IOSSystemVolumeSlider(tint: .label)
                .frame(height: 24)
                .accessibilityLabel("Volume")
#else
            Slider(
                value: Binding(
                    get: { playback.volume },
                    set: playback.setVolume
                ),
                in: 0 ... 1
            )
            .accessibilityLabel("Volume")
#endif

            Image(systemName: "speaker.wave.3.fill")
                .foregroundStyle(.secondary)
        }
        .controlSize(.small)
        .padding(12)
        .frame(width: 220)
    }
}

#if os(macOS)
struct AirPlayRoutePicker: NSViewRepresentable {
    func makeNSView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.setRoutePickerButtonColor(.labelColor, for: .normal)
        view.setRoutePickerButtonColor(.labelColor, for: .normalHighlighted)
        let accent = NSColor(srgbRed: 1, green: 0, blue: 0.337, alpha: 1)
        view.setRoutePickerButtonColor(accent, for: .active)
        view.setRoutePickerButtonColor(accent, for: .activeHighlighted)
        view.setAccessibilityLabel(String(localized: "AirPlay"))
        return view
    }

    func updateNSView(_ nsView: AVRoutePickerView, context: Context) {}
}
#elseif os(iOS)
struct AirPlayRoutePicker: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.prioritizesVideoDevices = false
        view.tintColor = .label
        view.activeTintColor = UIColor(red: 1, green: 0, blue: 0.337, alpha: 1)
        view.accessibilityLabel = String(localized: "AirPlay")
        return view
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}
#endif

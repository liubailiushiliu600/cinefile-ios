import SwiftUI
import UIKit
import MobileVLCKit

/// Full-screen player: VLC renders into a plain UIView, everything on top of
/// it (transport bar, seek strip, track menus, gestures, auto-hide) is drawn here.
///
/// Gestures (iPad-native, no visible buttons needed):
///   * horizontal drag — scrub, 120–900 s of film per screen width
///   * vertical drag on the left half — screen brightness
///   * vertical drag on the right half — player volume
/// A single tap toggles the chrome. The drag layer sits *under* the chrome, so
/// the seek slider and the buttons always win when they are on screen.
struct PlayerScreen: View {
    let url: URL
    let title: String
    var subtitle: String = ""
    /// Entry identity for resume playback; empty disables progress memory.
    var progressKey: String = ""

    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var vm = VLCPlayer()

    @State private var showChrome = true
    @State private var hideTask: Task<Void, Never>?
    @State private var seekPreview: Float?

    // Resume
    @State private var resumeAt: Double = 0
    @State private var showResumeToast = false
    @State private var resumeTask: Task<Void, Never>?
    @State private var lastSavedTime: Double = -1

    // Gestures
    private enum DragMode: Equatable { case seek, volume, brightness }
    @State private var dragMode: DragMode?
    @State private var dragStartTime: Double = 0
    @State private var dragSeekTarget: Double = 0
    @State private var dragStartVolume: Double = 0
    @State private var dragStartBrightness: Double = 0.5
    @State private var hud: HUDState?

    private struct HUDState: Equatable {
        let icon: String
        let text: String
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black.ignoresSafeArea()

                VLCVideoSurface(player: vm.player)
                    .ignoresSafeArea()

                gestureLayer(size: geo.size)

                if let message = vm.errorText {
                    errorOverlay(message)
                }

                if let hud {
                    hudView(hud)
                        .transition(.opacity)
                }

                if showResumeToast {
                    resumeToast
                        .transition(.move(edge: .top).combined(with: .opacity))
                }

                if showChrome {
                    chrome
                        .transition(.opacity)
                }
            }
        }
        .statusBarHidden(true)
        .onAppear { start() }
        .onDisappear {
            persistProgress(force: true)
            PlaybackActivity.shared.end()
            hideTask?.cancel()
            resumeTask?.cancel()
            vm.stop()
        }
        .onChange(of: vm.currentTime) { value in
            guard !progressKey.isEmpty else { return }
            guard abs(value - lastSavedTime) >= 5 else { return }
            lastSavedTime = value
            persistProgress()
        }
        .onChange(of: vm.isEnded) { ended in
            if ended { persistProgress(force: true) }
        }
        .onChange(of: scenePhase) { phase in
            if phase != .active { persistProgress(force: true) }
        }
    }

    // MARK: - Lifecycle

    private func start() {
        PlaybackActivity.shared.begin()

        // Resume where the last session stopped, but not inside the credits.
        if let saved = PlaybackProgressStore.shared.progress(for: progressKey),
           !saved.finished,
           saved.position >= 10,
           saved.duration <= 0 || saved.position < saved.duration - 30 {
            resumeAt = saved.position
        }

        vm.open(url, startAt: resumeAt)
        scheduleHide()

        if resumeAt > 0 {
            withAnimation(.easeOut(duration: 0.2)) { showResumeToast = true }
            resumeTask?.cancel()
            resumeTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 6_000_000_000)
                guard !Task.isCancelled else { return }
                withAnimation(.easeOut(duration: 0.2)) { showResumeToast = false }
            }
        }
    }

    private func persistProgress(force: Bool = false) {
        guard !progressKey.isEmpty else { return }
        let duration = vm.duration
        if vm.isEnded, duration > 0 {
            PlaybackProgressStore.shared.record(key: progressKey, position: duration, duration: duration)
        } else if vm.currentTime > 0 {
            PlaybackProgressStore.shared.record(
                key: progressKey,
                position: vm.currentTime,
                duration: duration
            )
        } else {
            return
        }
        if force { PlaybackProgressStore.shared.flush() }
    }

    private func restartFromBeginning() {
        PlaybackProgressStore.shared.clear(key: progressKey)
        vm.seek(to: 0)
        resumeAt = 0
        lastSavedTime = -1
        withAnimation(.easeOut(duration: 0.2)) { showResumeToast = false }
        resumeTask?.cancel()
    }

    // MARK: - Gestures

    private func gestureLayer(size: CGSize) -> some View {
        Color.clear
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.easeOut(duration: 0.15)) {
                    showChrome.toggle()
                }
                scheduleHide()
            }
            .gesture(
                DragGesture(minimumDistance: 14)
                    .onChanged { value in handleDrag(value, size: size) }
                    .onEnded { value in endDrag(value, size: size) }
            )
    }

    private func handleDrag(_ value: DragGesture.Value, size: CGSize) {
        if dragMode == nil {
            hideTask?.cancel()
            if abs(value.translation.width) > abs(value.translation.height) {
                dragMode = .seek
                dragStartTime = vm.currentTime
                dragSeekTarget = vm.currentTime
                vm.beginSeeking()
            } else if value.startLocation.x > size.width / 2 {
                dragMode = .volume
                dragStartVolume = Double(vm.volume)
            } else {
                dragMode = .brightness
                dragStartBrightness = Double(Self.currentBrightness() ?? 0.5)
            }
        }

        guard let mode = dragMode else { return }

        switch mode {
        case .seek:
            guard size.width > 0 else { return }
            // 10 minutes per screen width for a feature film, 90 s for a clip.
            let span = min(max(vm.duration * 0.6, 90), 600)
            let target = clamp(dragStartTime + Double(value.translation.width / size.width) * span)
            dragSeekTarget = target
            seekPreview = vm.duration > 0 ? Float(target / vm.duration) : nil
            setHUD(
                HUDState(
                    icon: "goforward",
                    text: "\(Self.clock(target)) / \(Self.clock(vm.duration))"
                )
            )

        case .volume:
            guard size.height > 0 else { return }
            let level = min(max(dragStartVolume + Double(-value.translation.height / size.height) * 160, 0), 200)
            vm.setVolume(Int32(level))
            setHUD(
                HUDState(
                    icon: level <= 1 ? "speaker.slash.fill" : "speaker.wave.2.fill",
                    text: "音量 \(Int(level))%"
                )
            )

        case .brightness:
            guard size.height > 0 else { return }
            let level = min(max(dragStartBrightness + Double(-value.translation.height / size.height), 0.02), 1)
            Self.setBrightness(level)
            setHUD(
                HUDState(
                    icon: "sun.max.fill",
                    text: "亮度 \(Int((level * 100).rounded()))%"
                )
            )
        }
    }

    private func endDrag(_ value: DragGesture.Value, size: CGSize) {
        if dragMode == .seek {
            vm.seek(to: dragSeekTarget)
            vm.endSeeking(vm.duration > 0 ? Float(dragSeekTarget / max(vm.duration, 1)) : 0)
            seekPreview = nil
            persistProgress(force: true)
        }
        dragMode = nil
        setHUD(nil)
        scheduleHide()
    }

    private func clamp(_ seconds: Double) -> Double {
        var target = max(0, seconds)
        if vm.duration > 0 { target = min(target, vm.duration) }
        return target
    }

    private func setHUD(_ state: HUDState?) {
        withAnimation(.easeOut(duration: 0.12)) { hud = state }
    }

    private func hudView(_ state: HUDState) -> some View {
        HStack(spacing: 10) {
            Image(systemName: state.icon)
                .font(.system(size: 18, weight: .medium))
                .foregroundColor(CF.accent)
            Text(state.text)
                .font(CF.mono(CF.fontBody, weight: .medium))
                .foregroundColor(CF.text1)
        }
        .padding(.horizontal, 18)
        .frame(height: 52)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color.black.opacity(0.72))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(CF.lineStrong, lineWidth: 1)
        )
        .allowsHitTesting(false)
    }

    private static func screen() -> UIScreen? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first?.screen
    }

    private static func currentBrightness() -> CGFloat? {
        screen()?.brightness
    }

    private static func setBrightness(_ value: Double) {
        screen()?.brightness = CGFloat(min(max(value, 0), 1))
    }

    // MARK: - Chrome

    private var chrome: some View {
        VStack(spacing: 0) {
            topBar
            Spacer(minLength: 0)
            bottomBar
        }
        .background(
            VStack(spacing: 0) {
                LinearGradient(
                    colors: [Color.black.opacity(0.72), Color.black.opacity(0)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 150)
                Spacer(minLength: 0)
                LinearGradient(
                    colors: [Color.black.opacity(0), Color.black.opacity(0.82)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 230)
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)
        )
    }

    private var topBar: some View {
        HStack(spacing: 14) {
            Button {
                dismiss()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 13, weight: .semibold))
                    Text("返回片库")
                        .font(CF.ui(CF.fontBody, weight: .medium))
                }
                .foregroundColor(CF.text1)
                .padding(.horizontal, 14)
                .frame(height: 38)
                .background(Capsule().fill(Color.black.opacity(0.45)))
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(CF.ui(CF.fontBody, weight: .medium))
                    .foregroundColor(CF.text1)
                    .lineLimit(1)
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(CF.mono(CF.fontCaption))
                        .foregroundColor(CF.text3)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 24)
        .padding(.top, 18)
    }

    private var resumeToast: some View {
        VStack {
            HStack(spacing: 12) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(CF.accent)
                Text("已从 \(Self.clock(resumeAt)) 继续播放")
                    .font(CF.ui(CF.fontSmall, weight: .medium))
                    .foregroundColor(CF.text1)
                Button {
                    restartFromBeginning()
                } label: {
                    Text("从头播放")
                        .font(CF.ui(CF.fontSmall, weight: .medium))
                        .foregroundColor(CF.textOnAccent)
                        .padding(.horizontal, 10)
                        .frame(height: 28)
                        .background(RoundedRectangle(cornerRadius: 7).fill(CF.accent))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14)
            .frame(height: 48)
            .background(
                RoundedRectangle(cornerRadius: 12).fill(Color.black.opacity(0.76))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12).stroke(CF.lineStrong, lineWidth: 1)
            )
            .padding(.top, 74)

            Spacer(minLength: 0)
        }
    }

    private var bottomBar: some View {
        VStack(spacing: 12) {
            seekBar
            controlRow
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 22)
    }

    private var seekBar: some View {
        HStack(spacing: 12) {
            Text(Self.clock(seekPreview.map { Double($0) * vm.duration } ?? vm.currentTime))
                .font(CF.mono(CF.fontCaption))
                .foregroundColor(CF.text2)
                .frame(width: 62, alignment: .trailing)

            Slider(
                value: Binding(
                    get: { seekPreview ?? vm.position },
                    set: { seekPreview = $0 }
                ),
                in: 0...1,
                onEditingChanged: { editing in
                    if editing {
                        vm.beginSeeking()
                    } else {
                        vm.endSeeking(seekPreview ?? vm.position)
                        seekPreview = nil
                        scheduleHide()
                    }
                }
            )
            .tint(CF.accent)

            Text(Self.clock(vm.duration))
                .font(CF.mono(CF.fontCaption))
                .foregroundColor(CF.text2)
                .frame(width: 62, alignment: .leading)
        }
    }

    private var controlRow: some View {
        HStack(spacing: 16) {
            Button {
                vm.togglePlay()
                scheduleHide()
            } label: {
                Image(systemName: vm.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundColor(CF.textOnAccent)
                    .frame(width: 46, height: 46)
                    .background(Circle().fill(CF.accent))
            }
            .buttonStyle(.plain)

            Button {
                vm.skip(-10)
                scheduleHide()
            } label: {
                Text("-10s")
                    .font(CF.mono(CF.fontSmall, weight: .medium))
                    .foregroundColor(CF.text1)
                    .padding(.horizontal, 10)
                    .frame(height: 32)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.10)))
            }
            .buttonStyle(.plain)

            Button {
                vm.skip(10)
                scheduleHide()
            } label: {
                Text("+10s")
                    .font(CF.mono(CF.fontSmall, weight: .medium))
                    .foregroundColor(CF.text1)
                    .padding(.horizontal, 10)
                    .frame(height: 32)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.10)))
            }
            .buttonStyle(.plain)

            Spacer(minLength: 8)

            // Volume
            Button {
                vm.toggleMute()
                scheduleHide()
            } label: {
                Image(systemName: vm.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.system(size: 15))
                    .foregroundColor(CF.text2)
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)

            Slider(
                value: Binding(
                    get: { Double(vm.volume) },
                    set: { vm.setVolume(Int32($0)) }
                ),
                in: 0...200
            )
            .tint(CF.text2)
            .frame(width: 92)

            // Subtitles
            Menu {
                Button {
                    vm.selectSubtitle(-1)
                } label: {
                    Label("关闭字幕", systemImage: vm.currentSubtitle < 0 ? "checkmark" : "captions.bubble")
                }
                ForEach(vm.subtitleTracks) { track in
                    Button {
                        vm.selectSubtitle(track.id)
                    } label: {
                        if vm.currentSubtitle == track.id {
                            Label(track.name, systemImage: "checkmark")
                        } else {
                            Text(track.name)
                        }
                    }
                }
            } label: {
                Image(systemName: "captions.bubble")
                    .font(.system(size: 16))
                    .foregroundColor(vm.subtitleTracks.isEmpty ? CF.text3 : CF.text1)
                    .frame(width: 34, height: 34)
            }

            // Audio tracks
            Menu {
                ForEach(vm.audioTracks) { track in
                    Button {
                        vm.selectAudio(track.id)
                    } label: {
                        if vm.currentAudio == track.id {
                            Label(track.name, systemImage: "checkmark")
                        } else {
                            Text(track.name)
                        }
                    }
                }
            } label: {
                Image(systemName: "waveform")
                    .font(.system(size: 16))
                    .foregroundColor(vm.audioTracks.isEmpty ? CF.text3 : CF.text1)
                    .frame(width: 34, height: 34)
            }
        }
    }

    private func errorOverlay(_ message: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 40, weight: .light))
                .foregroundColor(CF.danger)
            Text("播放失败")
                .font(CF.ui(20, weight: .semibold))
                .foregroundColor(CF.text1)
            Text(message)
                .font(CF.ui(CF.fontBody))
                .foregroundColor(CF.text2)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            Button("返回片库") { dismiss() }
                .buttonStyle(CFButtonStyle(primary: true))
                .padding(.top, 6)
        }
        .padding(32)
        .background(RoundedRectangle(cornerRadius: CF.radius).fill(CF.bg2))
    }

    // MARK: - Auto-hide

    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_800_000_000)
            guard !Task.isCancelled else { return }
            if vm.isPlaying && seekPreview == nil && hud == nil {
                withAnimation(.easeOut(duration: 0.2)) {
                    showChrome = false
                }
            }
        }
    }

    private static func clock(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "00:00" }
        let total = Int(seconds)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%02d:%02d", minutes, secs)
    }
}

/// The drawable VLC renders into.
struct VLCVideoSurface: UIViewRepresentable {
    let player: VLCMediaPlayer

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .black
        view.isUserInteractionEnabled = false
        player.drawable = view
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        if (player.drawable as? UIView) !== uiView {
            player.drawable = uiView
        }
    }
}

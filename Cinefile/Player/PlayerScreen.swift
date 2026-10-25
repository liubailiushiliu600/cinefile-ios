import SwiftUI
import MobileVLCKit

/// Full-screen player: VLC renders into a plain UIView, everything on top of
/// it (transport bar, seek strip, track menus, auto-hide) is drawn here.
struct PlayerScreen: View {
    let entry: Entry

    @Environment(\.dismiss) private var dismiss
    @StateObject private var vm = VLCPlayer()

    @State private var showChrome = true
    @State private var hideTask: Task<Void, Never>?
    @State private var seekPreview: Float?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VLCVideoSurface(player: vm.player)
                .ignoresSafeArea()

            if let message = vm.errorText {
                errorOverlay(message)
            }

            if showChrome {
                chrome
                    .transition(.opacity)
            }
        }
        .statusBarHidden(true)
        .onAppear {
            vm.open(entry.url)
            scheduleHide()
        }
        .onDisappear {
            hideTask?.cancel()
            vm.stop()
        }
        .onTapGesture {
            withAnimation(.easeOut(duration: 0.15)) {
                showChrome.toggle()
            }
            scheduleHide()
        }
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
                Text(entry.name)
                    .font(CF.ui(CF.fontBody, weight: .medium))
                    .foregroundColor(CF.text1)
                    .lineLimit(1)
                Text(entry.displaySize)
                    .font(CF.mono(CF.fontCaption))
                    .foregroundColor(CF.text3)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 24)
        .padding(.top, 18)
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
            if vm.isPlaying && seekPreview == nil {
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

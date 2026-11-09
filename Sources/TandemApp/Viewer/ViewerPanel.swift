import SwiftUI
import TandemCore

/// The viewer and its transport bar.
struct ViewerPanel: View {
    let model: EditorModel
    let actions: EditorActions
    @State private var viewerZoom: CGFloat = 1

    var body: some View {
        VStack(spacing: 0) {
            ViewerRepresentable(model: model, zoom: $viewerZoom)
                .overlay(alignment: .bottomLeading) { WalkthroughCard(model: model) }
                // The viewer runs to the top of the window, so the margin
                // over the picture is where it moves the window from.
                .overlay(alignment: .top) { WindowDragArea().frame(height: CanvasGeometry.margin) }
            TransportBar(model: model, actions: actions, zoom: $viewerZoom)
        }
        .background(Theme.viewer.color)
    }
}

struct ViewerRepresentable: NSViewRepresentable {
    let model: EditorModel
    /// The transport bar's zoom menu and the viewer's pinch and wheel both
    /// change it.
    @Binding var zoom: CGFloat

    func makeNSView(context: Context) -> ViewerView {
        let view = ViewerView(model: model)
        let binding = $zoom
        view.onZoomChange = { value in
            DispatchQueue.main.async { if binding.wrappedValue != value { binding.wrappedValue = value } }
        }
        return view
    }

    func updateNSView(_ view: ViewerView, context: Context) {
        guard abs(view.zoom - zoom) > 0.0001 else { return }
        if zoom == 1 { view.zoomToFit() } else { view.setZoom(zoom) }
    }
}

/// Timecode, transport buttons, proxy and fit, as in the design.
struct TransportBar: View {
    let model: EditorModel
    let actions: EditorActions
    @Binding var zoom: CGFloat

    var body: some View {
        let playback = model.playback
        HStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(Timecode.string(playback.time, rate: model.frameRate))
                    .font(.system(size: 19, weight: .light).monospacedDigit())
                    .foregroundStyle(Theme.text.color)
                Text("/ " + Timecode.string(model.project.duration, rate: model.frameRate))
                    .font(.ui(12).monospacedDigit())
                    .foregroundStyle(Theme.textFainter.color)
                // A J or L shuttle away from the chosen speed.
                if playback.isPlaying && playback.rate != playback.speed {
                    Text(PlaybackController.label(playback.rate))
                        .font(.ui(11, .semibold))
                        .foregroundStyle(Theme.amber.color)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 18) {
                TransportIcon(name: "backward.end.fill", help: Shortcuts.help("Previous edit", .previousEdit), shortcut: .previousEdit) { actions.perform(.previousEdit) }
                Button {
                    actions.perform(.playPause)
                } label: {
                    Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Theme.onAmber.color)
                        .offset(x: playback.isPlaying ? 0 : 1)
                        .frame(width: 32, height: 32)
                        .background(Circle().fill(Theme.text.color))
                }
                .buttonStyle(.plain)
                // The playback speed lives on the play button: a badge
                // when it isn't 1×, and the speeds on a right-click.
                .overlay(alignment: .topLeading) { SpeedBadge(playback: playback) }
                .contextMenu { SpeedPicker(playback: playback) }
                .tip(Shortcuts.help("Play or pause", .playPause) + ". J, K and L shuttle backwards, stop and forwards.")
                .shortcutHint(.playPause, edge: .top)
                TransportIcon(name: "forward.end.fill", help: Shortcuts.help("Next edit", .nextEdit), shortcut: .nextEdit) { actions.perform(.nextEdit) }
            }

            HStack(spacing: 12) {
                Button {
                    model.showSafeMargins.toggle()
                } label: {
                    Image(systemName: "viewfinder")
                        .font(.system(size: 12))
                        .foregroundStyle(model.showSafeMargins ? Theme.text.color : Theme.textMuted.color)
                }
                .buttonStyle(.plain)
                .tip(Shortcuts.help("Safe margins: show the title-safe and action-safe areas", .toggleSafeMargins))
                .shortcutHint(.toggleSafeMargins, edge: .top)
                ToggleText(title: "Proxy", on: playback.useProxies, help: Shortcuts.help("Proxies: play from 1080p copies where they're ready; off plays the original files", .toggleProxy), shortcut: .toggleProxy, hintEdge: .top) {
                    playback.useProxies.toggle()
                }
                Menu {
                    Button("25%") { zoom = 0.25 }
                    Button("50%") { zoom = 0.5 }
                    Button("Fit") { zoom = 1 }
                    Button("150%") { zoom = 1.5 }
                    Button("200%") { zoom = 2 }
                    Button("400%") { zoom = 4 }
                } label: {
                    Text(zoom == 1 ? "Fit" : "\(Int(zoom * 100))%")
                        .font(.ui(11.5))
                        .foregroundStyle(Theme.textMuted.color)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .overlay(RoundedRectangle(cornerRadius: 5).stroke(Theme.controlBorder.color, lineWidth: 1))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .tip("Viewer zoom, relative to fitting the frame. Pinch, or scroll with ⌘ or ⌥, to zoom about the pointer; scroll to move around; double-click the picture to fit.")
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, 16)
        .frame(height: Theme.Metrics.transportHeight)
        .overlay(alignment: .top) { Rectangle().fill(Theme.borderSubtle.color).frame(height: 1) }
    }
}

/// The speeds Space and the play button can play at, as a checked list.
private struct SpeedPicker: View {
    let playback: PlaybackController

    var body: some View {
        Picker("Playback speed", selection: Binding(get: { playback.speed }, set: { playback.setSpeed($0) })) {
            ForEach(PlaybackController.speeds, id: \.self) { speed in
                Text(PlaybackController.label(speed)).tag(speed)
            }
        }
        .pickerStyle(.inline)
    }
}

/// The chosen speed on the play button's corner, always showing (1× too),
/// so it's plain where the speed is set: a click opens the speeds. A
/// right-click on the play button opens them as well.
private struct SpeedBadge: View {
    let playback: PlaybackController

    var body: some View {
        Menu {
            SpeedPicker(playback: playback)
        } label: {
            Text(PlaybackController.label(playback.speed))
                .font(.ui(9.5, .semibold).monospacedDigit())
                // Quieter at 1×, so it's there without competing with the
                // play button until a speed is chosen.
                .foregroundStyle(playback.speed == 1 ? Theme.textMuted.color : Theme.text.color)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(Capsule().fill(Theme.tabSelected.color))
                .overlay(Capsule().stroke(Theme.controlBorder.color, lineWidth: 1))
                .contentShape(Capsule())
        }
        // The plain button style keeps the capsule; the borderless menu
        // style draws only the label's text.
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .tip("Playback speed for Space and the play button. The sound keeps its pitch.")
        // Starts just inside the play button's right edge and grows
        // rightwards, so 0.75× doesn't cover the play symbol; low enough to
        // stay clear of the bar's top edge.
        .offset(x: 22, y: -3)
    }
}

private struct TransportIcon: View {
    let name: String
    let help: String
    var shortcut: EditorCommand? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: name)
                .font(.system(size: 13))
                .foregroundStyle(Theme.textMuted.color)
                .frame(width: 26, height: 24)
                .hoverBackground(Theme.tabSelected.color, cornerRadius: 5)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .tip(help)
        // Over the button: under it is the timeline's own toolbar.
        .shortcutHint(shortcut, edge: .top)
    }
}

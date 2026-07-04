import AppKit
import SwiftUI

private enum WindowPreviewPanelLayout {
    static let cornerRadius: CGFloat = 18
    static let effectMargin: CGFloat = 8
}

@MainActor
final class WindowPreviewPanel {
    private let panel: NSPanel
    private let hostingView: NSHostingView<WindowPreviewGroupView>

    init() {
        hostingView = NSHostingView(
            rootView: WindowPreviewGroupView(
                previewGroup: nil,
                thumbnailSize: .zero,
                onPreviewSelected: { _ in },
                onPreviewClosed: { _ in },
                onPreviewMinimized: { _ in }
            )
        )
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 220),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        panel.contentView = hostingView
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = false
    }

    func show(
        _ previewGroup: WindowPreviewGroup,
        above dockFrame: CGRect?,
        near mouseLocation: NSPoint,
        onPreviewSelected: @escaping (WindowPreview) -> Void,
        onPreviewClosed: @escaping (WindowPreview) -> Void,
        onPreviewMinimized: @escaping (WindowPreview) -> Void
    ) {
        let panelSize = size(for: previewGroup)
        let thumbnailSize = thumbnailSize(for: previewGroup)
        hostingView.rootView = WindowPreviewGroupView(
            previewGroup: previewGroup,
            thumbnailSize: thumbnailSize,
            onPreviewSelected: onPreviewSelected,
            onPreviewClosed: onPreviewClosed,
            onPreviewMinimized: onPreviewMinimized
        )

        panel.setContentSize(panelSize)
        panel.setFrameOrigin(origin(for: panelSize, above: dockFrame, near: mouseLocation))
        panel.orderFrontRegardless()
    }

    func hide() {
        panel.orderOut(nil)
    }

    var isVisible: Bool {
        panel.isVisible
    }

    func contains(_ point: NSPoint) -> Bool {
        panel.isVisible && panel.frame.insetBy(dx: -8, dy: -8).contains(point)
    }

    private func size(for previewGroup: WindowPreviewGroup) -> CGSize {
        let count = previewGroup.previews.count
        let columns = min(max(count, 1), 4)
        let rows = Int(ceil(Double(count) / Double(columns)))
        let thumbnailSize = thumbnailSize(for: previewGroup)
        let horizontalPadding: CGFloat = 24
        let verticalPadding: CGFloat = 54
        let spacing: CGFloat = 12

        return CGSize(
            width: CGFloat(columns) * thumbnailSize.width + CGFloat(columns - 1) * spacing + horizontalPadding + WindowPreviewPanelLayout.effectMargin * 2,
            height: CGFloat(rows) * (thumbnailSize.height + 24) + CGFloat(rows - 1) * spacing + verticalPadding + WindowPreviewPanelLayout.effectMargin * 2
        )
    }

    private func thumbnailSize(for previewGroup: WindowPreviewGroup) -> CGSize {
        let largestWindow = previewGroup.previews.max { left, right in
            left.windowBounds.width * left.windowBounds.height < right.windowBounds.width * right.windowBounds.height
        }
        let largestSize = largestWindow?.windowBounds.size ?? CGSize(width: 320, height: 200)
        let maximumSize = CGSize(width: 240, height: 150)
        let scale = min(maximumSize.width / largestSize.width, maximumSize.height / largestSize.height, 1)

        return CGSize(
            width: max(160, largestSize.width * scale),
            height: max(100, largestSize.height * scale)
        )
    }

    private func origin(for panelSize: CGSize, above dockFrame: CGRect?, near mouseLocation: NSPoint) -> NSPoint {
        let anchor = dockFrame.map { NSPoint(x: $0.midX, y: $0.maxY) } ?? mouseLocation
        let screen = NSScreen.screens.first(where: { NSMouseInRect(anchor, $0.frame, false) }) ?? NSScreen.main
        let visibleFrame = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let padding: CGFloat = 12

        var origin = NSPoint(
            x: anchor.x - panelSize.width / 2,
            y: anchor.y + 14
        )

        if origin.y + panelSize.height > visibleFrame.maxY {
            let fallbackY = (dockFrame?.minY ?? mouseLocation.y) - panelSize.height - 14
            origin.y = fallbackY
        }

        origin.x = min(max(origin.x, visibleFrame.minX + padding), visibleFrame.maxX - panelSize.width - padding)
        origin.y = min(max(origin.y, visibleFrame.minY + padding), visibleFrame.maxY - panelSize.height - padding)

        return origin
    }
}

private struct WindowPreviewGroupView: View {
    let previewGroup: WindowPreviewGroup?
    let thumbnailSize: CGSize
    let onPreviewSelected: (WindowPreview) -> Void
    let onPreviewClosed: (WindowPreview) -> Void
    let onPreviewMinimized: (WindowPreview) -> Void

    private var columns: [GridItem] {
        let count = previewGroup?.previews.count ?? 1
        return Array(repeating: GridItem(.fixed(thumbnailSize.width), spacing: 12), count: min(max(count, 1), 4))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let previewGroup {
                Text(previewGroup.applicationName)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)

                LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                    ForEach(previewGroup.previews) { preview in
                        WindowPreviewTile(
                            preview: preview,
                            thumbnailSize: thumbnailSize,
                            onPreviewSelected: onPreviewSelected,
                            onPreviewClosed: onPreviewClosed,
                            onPreviewMinimized: onPreviewMinimized
                        )
                    }
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: WindowPreviewPanelLayout.cornerRadius, style: .continuous)
                .fill(.regularMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: WindowPreviewPanelLayout.cornerRadius, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color.cyan.opacity(0.18),
                                    Color.indigo.opacity(0.12),
                                    Color.white.opacity(0.06)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: WindowPreviewPanelLayout.cornerRadius, style: .continuous)
                .strokeBorder(.white.opacity(0.28), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: WindowPreviewPanelLayout.cornerRadius, style: .continuous))
        .padding(WindowPreviewPanelLayout.effectMargin)
    }
}

private struct WindowPreviewTile: View {
    let preview: WindowPreview
    let thumbnailSize: CGSize
    let onPreviewSelected: (WindowPreview) -> Void
    let onPreviewClosed: (WindowPreview) -> Void
    let onPreviewMinimized: (WindowPreview) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topLeading) {
                Button {
                    onPreviewSelected(preview)
                } label: {
                    ZStack {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(.black.opacity(0.22))

                        Image(nsImage: preview.image)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .padding(.top, 4)
                            .padding([.horizontal, .bottom], 3)
                            .frame(width: thumbnailSize.width, height: thumbnailSize.height)
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .frame(width: thumbnailSize.width, height: thumbnailSize.height)
                    .compositingGroup()
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .strokeBorder(.white.opacity(0.22), lineWidth: 1)
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .shadow(color: .black.opacity(0.22), radius: 8, x: 0, y: 4)
                }
                .buttonStyle(.plain)

                WindowControlButtons(
                    onClose: { onPreviewClosed(preview) },
                    onMinimize: { onPreviewMinimized(preview) }
                )
                .padding(6)
            }

            Button {
                onPreviewSelected(preview)
            } label: {
                Text(preview.title)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(width: thumbnailSize.width, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }
}

private struct WindowControlButtons: View {
    let onClose: () -> Void
    let onMinimize: () -> Void

    var body: some View {
        HStack(spacing: 7) {
            WindowControlButton(
                color: Color(red: 1.0, green: 0.36, blue: 0.31),
                symbolName: "xmark",
                accessibilityLabel: "Close",
                action: onClose
            )
            WindowControlButton(
                color: Color(red: 1.0, green: 0.75, blue: 0.22),
                symbolName: "minus",
                accessibilityLabel: "Minimize",
                action: onMinimize
            )
        }
        .padding(5)
        .background(.black.opacity(0.22), in: Capsule())
    }
}

private struct WindowControlButton: View {
    let color: Color
    let symbolName: String
    let accessibilityLabel: String
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(color)
                    .frame(width: 14, height: 14)
                    .overlay(
                        Circle()
                            .stroke(.black.opacity(0.16), lineWidth: 0.5)
                    )

                Image(systemName: symbolName)
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.black.opacity(0.58))
                    .opacity(isHovering ? 1 : 0)
            }
            .scaleEffect(isHovering ? 1.22 : 1)
            .animation(.snappy(duration: 0.14), value: isHovering)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
        .onHover { isHovering = $0 }
    }
}

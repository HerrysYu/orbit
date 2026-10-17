import SwiftUI

// What you attached to a message you sent, shown above its bubble: a photo grid (tap to view full screen), file
// chips and link previews.

struct SentAttachments: View {
    @Environment(AppModel.self) private var model
    @Namespace private var zoom
    var clientId: String
    var attachments: [Attachment]
    @State private var viewing: ViewedImage?

    struct ViewedImage: Identifiable {
        var id: Int
        var image: CGImage
    }

    var body: some View {
        let images = attachments.enumerated().compactMap { index, attachment -> (Int, CGImage)? in
            guard attachment.kind == .image, let cg = image(index, attachment) else { return nil }
            return (index, cg)
        }
        let missingImages = attachments.enumerated().filter { $0.element.kind == .image && image($0.offset, $0.element) == nil }
        VStack(alignment: .trailing, spacing: Space.xs) {
            if !images.isEmpty {
                PhotoGrid(images: images) { index, cg in viewing = ViewedImage(id: index, image: cg) }
                    .environment(\.zoomNamespace, zoom)
            }
            ForEach(missingImages, id: \.offset) { _, attachment in
                AttachmentChip(symbol: "photo", title: attachment.name ?? "照片", subtitle: "图片")
            }
            ForEach(Array(attachments.enumerated()).filter { $0.element.kind == .file }, id: \.offset) { _, attachment in
                AttachmentChip(symbol: "doc.fill", title: attachment.name ?? "文件", subtitle: fileSubtitle(attachment))
            }
            ForEach(Array(attachments.enumerated()).filter { $0.element.kind == .link }, id: \.offset) { _, attachment in
                SentLinkPreview(url: attachment.url ?? "")
            }
        }
        .fullScreenCover(item: $viewing) { viewed in
            ImageViewer(image: viewed.image)
                .navigationTransition(.zoom(sourceID: viewed.id, in: zoom))
        }
    }

    private func image(_ index: Int, _ attachment: Attachment) -> CGImage? {
        if let cg = model.attachmentCache.image(clientId: clientId, index: index) { return cg }
        if let b64 = attachment.dataB64, let data = Data(base64Encoded: b64) { return ImageTools.cgImage(from: data) }
        return nil
    }

    private func fileSubtitle(_ attachment: Attachment) -> String {
        let size = attachment.dataB64.map { Fmt.bytes($0.count * 3 / 4) }
        let ext = (attachment.name as NSString?)?.pathExtension.uppercased()
        let parts = [ext?.isEmpty == false ? ext : nil, size].compactMap { $0 }
        return parts.isEmpty ? "文件" : parts.joined(separator: " · ")
    }
}

extension EnvironmentValues {
    @Entry var zoomNamespace: Namespace.ID?
}

private struct PhotoGrid: View {
    @Environment(\.zoomNamespace) private var zoom
    var images: [(Int, CGImage)]
    var onTap: (Int, CGImage) -> Void

    var body: some View {
        let columns = images.count == 1 ? 1 : 2
        let side: CGFloat = images.count == 1 ? 220 : 116
        let shape = RoundedRectangle(cornerRadius: Radius.bubble, style: .continuous)
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(side), spacing: 4), count: columns), spacing: 4) {
            ForEach(images, id: \.0) { index, cg in
                Button { onTap(index, cg) } label: {
                    Image(decorative: cg, scale: 1)
                        .resizable()
                        .scaledToFill()
                        .frame(width: side, height: images.count == 1 ? min(280, side * CGFloat(cg.height) / CGFloat(max(cg.width, 1))) : side)
                        .clipped()
                        .contentShape(.rect)
                }
                .buttonStyle(.pressable)
                .modifier(ZoomSource(id: index, namespace: zoom))
                .accessibilityLabel("照片，轻点查看大图")
            }
        }
        .clipShape(shape)
        .overlay { shape.strokeBorder(Color.hairline, lineWidth: 0.5) }
        .fixedSize()
    }
}

private struct ZoomSource: ViewModifier {
    var id: Int
    var namespace: Namespace.ID?

    func body(content: Content) -> some View {
        if let namespace { content.matchedTransitionSource(id: id, in: namespace) } else { content }
    }
}

/// Full-screen photo with pinch-to-zoom and drag-down-to-dismiss. It sits on black like every photo viewer, so
/// its controls are white on a material instead of design tokens.
private struct ImageViewer: View {
    @Environment(\.dismiss) private var dismiss
    var image: CGImage
    @State private var scale: CGFloat = 1
    @State private var drag: CGSize = .zero

    var body: some View {
        let progress = min(1, abs(drag.height) / 300)
        ZStack {
            Color.black.opacity(1 - progress * 0.7).ignoresSafeArea()
            Image(decorative: image, scale: 1)
                .resizable()
                .scaledToFit()
                .scaleEffect(scale * (1 - progress * 0.2))
                .offset(drag)
                .gesture(MagnifyGesture()
                    .onChanged { scale = max(1, $0.magnification) }
                    .onEnded { _ in withAnimation(Motion.standard) { scale = 1 } })
                .simultaneousGesture(DragGesture()
                    .onChanged { if scale == 1 { drag = $0.translation } }
                    .onEnded { value in
                        if abs(value.predictedEndTranslation.height) > 220 { dismiss() }
                        else { withAnimation(Motion.momentum) { drag = .zero } }
                    })
                .accessibilityLabel("照片")
        }
        .overlay(alignment: .topTrailing) {
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(.ultraThinMaterial, in: .circle)
            }
            .buttonStyle(.pressable)
            .padding(Space.l)
            .accessibilityLabel("关闭")
        }
    }
}

/// A file (or a photo whose bytes are gone) as a small chip.
struct AttachmentChip: View {
    var symbol: String
    var title: String
    var subtitle: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(Color.inkSecondary)
                .frame(width: 36, height: 36)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(.subheadline, weight: .medium)).foregroundStyle(Color.ink).lineLimit(1)
                Text(subtitle).font(.caption).foregroundStyle(Color.inkSecondary).lineLimit(1)
            }
        }
        .padding(.leading, 6)
        .padding(.trailing, 14)
        .padding(.vertical, 6)
        .frame(maxWidth: 260, alignment: .leading)
        .background(Color.surface, in: .rect(cornerRadius: Radius.bubble - 4, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: Radius.bubble - 4, style: .continuous).strokeBorder(Color.hairline, lineWidth: 0.5) }
        .accessibilityElement(children: .combine)
    }
}

private struct SentLinkPreview: View {
    @Environment(\.openURL) private var openURL
    var url: String

    var body: some View {
        let parsed = URL(string: url)
        Button {
            if let parsed { openURL(parsed) }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "safari")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(Color.inkSecondary)
                    .frame(width: 36, height: 36)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(parsed?.host() ?? url).font(.system(.subheadline, weight: .medium)).foregroundStyle(Color.ink).lineLimit(1)
                    Text(url).font(.caption).foregroundStyle(Color.inkSecondary).lineLimit(1).truncationMode(.middle)
                }
            }
            .padding(.leading, 6)
            .padding(.trailing, 14)
            .padding(.vertical, 6)
            .frame(maxWidth: 260, alignment: .leading)
            .background(Color.surface, in: .rect(cornerRadius: Radius.bubble - 4, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: Radius.bubble - 4, style: .continuous).strokeBorder(Color.hairline, lineWidth: 0.5) }
        }
        .buttonStyle(.pressable)
        .accessibilityHint("在浏览器中打开")
    }
}

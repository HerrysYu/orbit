#if DEBUG
import CoreGraphics
import Foundation

/// Sample content for screenshots (`-OPADraftItems YES`). Debug builds only.
enum ChatDebug {
    /// `-OPAChatOffline YES`: turns the running demo into "a paired Mac that is offline" (in memory only), so the
    /// real offline behavior can be looked at: the header pill, the status line and the composer
    /// placeholder. `-OPAChatDeliveryDemo YES` adds a queued message ("待发送") and one that did not arrive ("没有送达").
    @MainActor
    static func goOffline(_ model: AppModel, withMessages: Bool) async {
        let host = #"{"hostId":"debug","hostPub":"","hostName":"演示 Mac","lan":[],"pairedAt":0}"#
        model.pairedHost = try? JSONDecoder().decode(PairedHost.self, from: Data(host.utf8))
        model.isDemo = false
        model.lastSeenOnlineAt = Date().addingTimeInterval(-120)
        model.connection = .hostOffline
        guard withMessages else { return }
        try? await Task.sleep(for: .milliseconds(600))
        model.send(text: "做完发我一份 PDF", attachments: [])
        let failed = model.send(text: "另外记得报销截止是 25 号", attachments: [])
        model.setDelivery(failed, .failed("演示：Mac 没有接受这条消息"))
    }

    /// `-OPAChatGhostReplies YES`: replies with nothing to read, as old data and old Mac versions left them: an empty
    /// one, a blank one, an empty "主动" one, a "主动" one of line breaks, and one that is still streaming but has only
    /// line breaks (so the waiting row shows after the thread). Then a real "主动" reply, which must keep its tag.
    /// The ghosts must not show at all, byline included. Four seconds later the streaming one gets its first words,
    /// behind blank lines: they take the waiting row's place, and the blank lines do not show.
    @MainActor
    static func addGhostReplies(_ model: AppModel) {
        let now = Clock.nowMs
        let ghosts: [(text: String, proactive: Bool)] = [("", false), ("  \n", false), ("", true), ("\n\n", true)]
        for (i, ghost) in ghosts.enumerated() {
            let message = AssistantMessage(id: "ghost-\(i)", text: ghost.text, proactive: ghost.proactive, interrupted: false,
                                           streaming: false, ts: now + Int64(i))
            model.timelineStore.upsert(.assistant(message), order: model.nextLocalOrder())
        }
        let real = AssistantMessage(id: "ghost-real", text: "我看了一下今天的日程，下午三点有一个会。", proactive: true, interrupted: false,
                                    streaming: false, ts: now + 10)
        model.timelineStore.upsert(.assistant(real), order: model.nextLocalOrder())
        model.beginStreaming(id: "ghost-stream", proactive: false, text: "\n")
        Task {
            try? await Task.sleep(for: .seconds(4))
            model.appendStreamDelta(id: "ghost-stream", text: "\n\n收到，我来看一下。\n")
        }
    }

    /// `-OPAChatImageCards YES`: cards whose pictures come in every shape the Mac can send, to look at `CardImage`
    /// and its placeholders: an inline `data:` URL (wide, tall, square), a web address, a leftover local path and a
    /// broken `data:` URL. The cards go to the end of the thread. With `-OPAChatImageCardsWarm YES` the inline pictures
    /// are decoded first, so the cards draw them in their very first frame, as when scrolling back to a card.
    @MainActor
    static func addImageCards(_ model: AppModel) async {
        let wide = samplePictureURL(width: 1200, height: 700, rgb: [0.98, 0.74, 0.45, 0.35, 0.55, 0.85])
        let tall = samplePictureURL(width: 600, height: 1300, rgb: [0.55, 0.85, 0.65, 0.20, 0.40, 0.55])
        let square = samplePictureURL(width: 400, height: 400, rgb: [0.95, 0.60, 0.65, 0.45, 0.30, 0.70])
        let web = "https://picsum.photos/seed/orbit/800/600"
        let localPath = "/Users/herry/Desktop/截图 2026-10-16.png"
        let broken = "data:image/jpeg;base64,this-is-not-base64!"
        if UserDefaults.standard.bool(forKey: "OPAChatImageCardsWarm") {
            for picture in [wide, tall, square] { _ = await CardImageStore.load(picture) }
        }
        let now = Clock.nowMs
        let cards: [Card] = [
            Card(id: "card-img-gallery", component: "image_gallery", props: ["title": "图片的各种来源", "images": [
                ["url": .string(wide), "caption": "本地截图（data URL，横图）"],
                ["url": .string(tall), "caption": "data URL，竖图（居中裁切）"],
                ["url": .string(web), "caption": "https 图片"],
            ]], ts: now),
            Card(id: "card-img-gallery-bad", component: "image_gallery", props: ["title": "显示不出来的图片", "images": [
                ["url": .string(localPath), "caption": "残留的本地路径"],
                ["url": .string(broken), "caption": "损坏的 data URL"],
                ["caption": "没有地址"],
            ]], ts: now),
            Card(id: "card-img-link", component: "link_preview", props: [
                "url": "https://www.apple.com/newsroom/", "title": "带 data URL 配图的链接", "siteName": "apple.com",
                "description": "配图是 Mac 转成 data URL 发来的。", "imageUrl": .string(wide)], ts: now + 1),
            Card(id: "card-img-link-tall", component: "link_preview", props: [
                "url": "https://www.apple.com/newsroom/", "title": "竖图配图（居中裁切）", "siteName": "apple.com",
                "description": "手机截图这样的竖图，卡片下面的文字不能被盖住。", "imageUrl": .string(tall)], ts: now + 2),
            Card(id: "card-img-link-local", component: "link_preview", props: [
                "url": "https://www.apple.com/newsroom/", "title": "配图是本地路径的链接", "siteName": "apple.com",
                "description": "显示占位框，不撑乱布局。", "imageUrl": .string(localPath)], ts: now + 3),
            Card(id: "card-img-order", component: "order_card", props: [
                "merchant": "和府捞面（望京店）", "imageUrl": .string(square),
                "items": [["name": "草本汤牛肉面", "qty": 1, "price": 39]], "total": 39, "currency": "CNY", "status": "draft"], ts: now + 4),
            Card(id: "card-img-video", component: "video", props: [
                "url": "https://example.com/video.m3u8", "title": "封面是 data URL 的视频", "posterUrl": .string(wide)], ts: now + 5),
            Card(id: "card-img-compare", component: "comparison", props: ["title": "缩略图的几种来源", "items": [
                ["id": "a", "title": "data URL", "price": "¥100", "imageUrl": .string(square)],
                ["id": "b", "title": "本地路径", "price": "¥200", "imageUrl": .string(localPath)],
                ["id": "c", "title": "https", "price": "¥300", "imageUrl": .string(web)],
            ]], ts: now + 6),
        ]
        for card in cards {
            model.timelineStore.upsert(.card(card), order: model.nextLocalOrder())
        }
    }

    /// A gradient picture with a white mark near the top left corner (so the crop and the orientation show), as a
    /// `data:image/jpeg;base64,…` string.
    private static func samplePictureURL(width: Int, height: Int, rgb: [CGFloat]) -> String {
        let space = CGColorSpaceCreateDeviceRGB()
        let top = CGColor(red: rgb[0], green: rgb[1], blue: rgb[2], alpha: 1)
        let bottom = CGColor(red: rgb[3], green: rgb[4], blue: rgb[5], alpha: 1)
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let gradient = CGGradient(colorsSpace: space, colors: [top, bottom] as CFArray, locations: [0, 1]) else { return "" }
        context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: CGFloat(height)), end: CGPoint(x: CGFloat(width), y: 0), options: [])
        let mark = CGFloat(min(width, height)) / 5
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.9))
        context.fillEllipse(in: CGRect(x: mark / 2, y: CGFloat(height) - mark * 1.5, width: mark, height: mark))
        context.fill(CGRect(x: 0, y: CGFloat(height) / 2 - 2, width: CGFloat(width), height: 4))
        guard let image = context.makeImage(), let data = ImageTools.jpeg(image, quality: 0.8) else { return "" }
        return "data:image/jpeg;base64," + data.base64EncodedString()
    }

    /// Two photo-like gradients and a PDF-looking file, as in the attachment board.
    static func sampleDraftItems() -> [DraftItem] {
        var items: [DraftItem] = []
        let gradients: [[CGFloat]] = [[0.95, 0.89, 0.81, 0.89, 0.73, 0.56], [0.92, 0.82, 0.76, 0.78, 0.58, 0.47]]
        for rgb in gradients {
            if let data = gradientJPEG(rgb), let item = DraftItem.image(from: data) { items.append(item) }
        }
        items.append(DraftItem(content: .file(name: "9月发票.pdf", mime: "application/pdf", data: Data(count: 412_000))))
        return items
    }

    /// `rgb` = top r, g, b followed by bottom r, g, b.
    private static func gradientJPEG(_ rgb: [CGFloat]) -> Data? {
        let side = 400
        let space = CGColorSpaceCreateDeviceRGB()
        let top = CGColor(red: rgb[0], green: rgb[1], blue: rgb[2], alpha: 1)
        let bottom = CGColor(red: rgb[3], green: rgb[4], blue: rgb[5], alpha: 1)
        guard let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let gradient = CGGradient(colorsSpace: space, colors: [top, bottom] as CFArray, locations: [0, 1]) else { return nil }
        context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: CGFloat(side)), end: CGPoint(x: CGFloat(side), y: 0), options: [])
        guard let image = context.makeImage() else { return nil }
        return ImageTools.jpeg(image, quality: 0.8)
    }
}
#endif

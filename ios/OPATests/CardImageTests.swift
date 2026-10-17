import SwiftUI
import UIKit
import XCTest
@testable import OPA

/// Pictures in cards: the `data:` URLs the Mac sends for local screenshots, how they are told apart from web
/// addresses and other strings, how they are decoded, and the cache in front of the decoder.
@MainActor
final class CardImageTests: XCTestCase {
    // MARK: Fixtures

    /// A real picture of the given pixel size, encoded as PNG.
    private func png(width: Int, height: Int) -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format)
        return renderer.pngData { context in
            UIColor.orange.setFill()
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
    }

    private func dataURL(_ data: Data, header: String = "image/png;base64") -> String {
        "data:\(header),\(data.base64EncodedString())"
    }

    private func pixelSize(_ image: UIImage?) -> (width: Int, height: Int)? {
        guard let cg = image?.cgImage else { return nil }
        return (cg.width, cg.height)
    }

    // MARK: A valid data URL

    func testAValidDataURLGivesItsBytesAndAPicture() {
        let bytes = png(width: 4, height: 3)
        let url = dataURL(bytes)
        XCTAssertEqual(CardImageCodec.bytes(ofDataURL: url), bytes)
        let size = pixelSize(CardImageCodec.image(fromDataURL: url))
        XCTAssertEqual(size?.width, 4)
        XCTAssertEqual(size?.height, 3)
    }

    func testCommonSpellingsOfADataURLAreAccepted() {
        let bytes = png(width: 40, height: 30)
        let plain = bytes.base64EncodedString()
        let wrapped = bytes.base64EncodedString(options: [.lineLength76Characters, .endLineWithLineFeed])
        XCTAssertTrue(wrapped.contains("\n"), "the fixture should really be wrapped")

        XCTAssertEqual(CardImageCodec.bytes(ofDataURL: "DATA:IMAGE/JPEG;BASE64,\(plain)"), bytes)
        XCTAssertEqual(CardImageCodec.bytes(ofDataURL: "data:image/jpeg;charset=utf-8;base64,\(plain)"), bytes)
        XCTAssertEqual(CardImageCodec.bytes(ofDataURL: "data:;base64,\(plain)"), bytes)
        XCTAssertEqual(CardImageCodec.bytes(ofDataURL: "  \ndata:image/png;base64,\(plain)"), bytes)
        XCTAssertEqual(CardImageCodec.bytes(ofDataURL: "data:image/png;base64,\(wrapped)"), bytes)
    }

    func testABigPictureIsShrunkAndASmallOneIsNotEnlarged() {
        let big = pixelSize(CardImageCodec.image(from: png(width: 3000, height: 1000)))
        XCTAssertEqual(big?.width, CardImageCodec.maxPixel)
        let height = big?.height ?? 0
        XCTAssertTrue((682...683).contains(height), "the aspect ratio should survive, got \(height)")

        let small = pixelSize(CardImageCodec.image(from: png(width: 30, height: 20)))
        XCTAssertEqual(small?.width, 30)
        XCTAssertEqual(small?.height, 20)
    }

    // MARK: A data URL with a broken payload

    func testBase64ThatIsNotBase64IsRejected() {
        XCTAssertNil(CardImageCodec.bytes(ofDataURL: "data:image/jpeg;base64,@@@ not base64 @@@"))
        XCTAssertNil(CardImageCodec.bytes(ofDataURL: "data:image/jpeg;base64,%%%%"))
        XCTAssertNil(CardImageCodec.image(fromDataURL: "data:image/jpeg;base64,@@@ not base64 @@@"))
    }

    func testAnEmptyPayloadIsRejected() {
        XCTAssertNil(CardImageCodec.bytes(ofDataURL: "data:image/jpeg;base64,"))
        XCTAssertNil(CardImageCodec.bytes(ofDataURL: "data:image/jpeg;base64,  \n "))
        XCTAssertNil(CardImageCodec.image(fromDataURL: "data:image/jpeg;base64,"))
    }

    func testValidBase64ThatIsNotAPictureGivesBytesButNoPicture() {
        let url = "data:image/png;base64,\(Data("hello".utf8).base64EncodedString())"
        XCTAssertEqual(CardImageCodec.bytes(ofDataURL: url), Data("hello".utf8))
        XCTAssertNil(CardImageCodec.image(fromDataURL: url))
        guard case .failed = CardImageCodec.result(forDataURL: url) else { return XCTFail("should be a failed result") }
    }

    // MARK: Strings that are not data URLs

    func testStringsThatAreNotBase64DataURLsAreRejected() {
        let payload = png(width: 4, height: 4).base64EncodedString()
        for raw in [
            "",
            "   ",
            "/Users/me/Desktop/screenshot.png",
            "file:///Users/me/Desktop/screenshot.png",
            "https://example.com/a.png",
            "data",
            "data:",
            "data:image/png",                          // no comma
            "data:image/png,\(payload)",               // not marked base64
            "data:image/png;base64;charset=utf-8,\(payload)",
            "image/png;base64,\(payload)",             // no scheme
        ] {
            XCTAssertNil(CardImageCodec.bytes(ofDataURL: raw), "should not read bytes from: \(raw.prefix(40))")
            XCTAssertNil(CardImageCodec.image(fromDataURL: raw), "should not read a picture from: \(raw.prefix(40))")
        }
    }

    // MARK: Telling the kinds of string apart

    func testSourceKinds() {
        XCTAssertEqual(CardImageSource(nil), .unusable)
        XCTAssertEqual(CardImageSource(""), .unusable)
        XCTAssertEqual(CardImageSource("   "), .unusable)
        XCTAssertEqual(CardImageSource("/Users/me/Desktop/screenshot.png"), .unusable)
        XCTAssertEqual(CardImageSource("file:///Users/me/Desktop/screenshot.png"), .unusable)
        XCTAssertEqual(CardImageSource("screenshot.png"), .unusable)
        XCTAssertEqual(CardImageSource("https://"), .unusable)

        XCTAssertEqual(CardImageSource("https://example.com/a.jpg"), .remote(URL(string: "https://example.com/a.jpg")!))
        XCTAssertEqual(CardImageSource("  HTTPS://example.com/a.jpg \n"), .remote(URL(string: "HTTPS://example.com/a.jpg")!))
        XCTAssertEqual(CardImageSource("http://example.com/a.jpg"), .remote(URL(string: "http://example.com/a.jpg")!))

        let inline = "data:image/jpeg;base64,/9j/4AAQ"
        XCTAssertEqual(CardImageSource(inline), .embedded(inline))
        XCTAssertEqual(CardImageSource(" \(inline)"), .embedded(" \(inline)"))
        XCTAssertEqual(CardImageSource("DATA:image/jpeg;base64,/9j/4AAQ"), .embedded("DATA:image/jpeg;base64,/9j/4AAQ"))
    }

    func testABlankPictureStringMeansNoPicture() {
        XCTAssertEqual(JSONValue.string("https://example.com/a.jpg").pictureString, "https://example.com/a.jpg")
        XCTAssertEqual(JSONValue.string("/tmp/a.png").pictureString, "/tmp/a.png")   // still "a picture": it gets the placeholder
        XCTAssertNil(JSONValue.string("").pictureString)
        XCTAssertNil(JSONValue.string(" \n").pictureString)
        XCTAssertNil(JSONValue.number(3).pictureString)
        XCTAssertNil(JSONValue.null.pictureString)
    }

    // MARK: The frame

    /// The frame of a card picture must not depend on what is inside it: a picture (wide or tall, it is cropped),
    /// one that is still loading, one that does not decode, a leftover path, no string at all.
    func testEveryStateOfAPictureHasTheSameFrame() async {
        let wide = dataURL(png(width: 400, height: 100))
        let tall = dataURL(png(width: 100, height: 400))
        let loading = dataURL(png(width: 50, height: 50))   // valid, but never decoded in this test
        let broken = "data:image/png;base64,@@@@"
        for picture in [wide, tall, broken] { _ = await CardImageStore.load(picture) }

        let sources: [(String, String?)] = [
            ("wide picture", wide), ("tall picture", tall), ("still loading", loading), ("broken data URL", broken),
            ("local path", "/Users/me/shot.png"), ("blank", ""), ("no string", nil),
        ]
        for (name, source) in sources {
            let size = renderedSize(CardImage(source: source, ratio: 4.0 / 3.0).frame(width: 300))
            XCTAssertEqual(size?.width ?? 0, 300, accuracy: 1, name)
            XCTAssertEqual(size?.height ?? 0, 225, accuracy: 1, name)
        }
        // A thumbnail keeps its square, with or without a picture.
        for source in [tall, "nope"] {
            let size = renderedSize(CardImage(source: source, ratio: 1).frame(width: 44, height: 44))
            XCTAssertEqual(size?.width ?? 0, 44, accuracy: 1)
            XCTAssertEqual(size?.height ?? 0, 44, accuracy: 1)
        }
    }

    private func renderedSize(_ view: some View) -> CGSize? {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        return renderer.uiImage?.size
    }

    // MARK: The cache

    func testTheStoreDecodesOnceAndRemembersThePicture() async {
        let url = dataURL(png(width: 8, height: 6))
        XCTAssertNil(CardImageStore.cached(for: url))

        guard case .picture(let first) = await CardImageStore.load(url) else { return XCTFail("should decode the picture") }
        XCTAssertEqual(first.cgImage?.width, 8)
        guard case .picture(let remembered)? = CardImageStore.cached(for: url) else { return XCTFail("should be cached") }
        XCTAssertTrue(first === remembered)

        guard case .picture(let again) = await CardImageStore.load(url) else { return XCTFail("should still be there") }
        XCTAssertTrue(first === again, "a second load must hand back the cached picture, not decode again")
    }

    func testTheStoreRemembersThatAStringDoesNotDecode() async {
        let url = "data:image/png;base64,@@@@"
        guard case .failed = await CardImageStore.load(url) else { return XCTFail("should fail") }
        guard case .failed? = CardImageStore.cached(for: url) else { return XCTFail("the failure should be cached") }
    }

    func testTwoRequestsForTheSamePictureShareOneDecode() async {
        let url = dataURL(png(width: 9, height: 9))
        async let a = CardImageStore.load(url)
        async let b = CardImageStore.load(url)
        let (first, second) = await (a, b)
        guard case .picture(let x) = first, case .picture(let y) = second else { return XCTFail("both should decode") }
        XCTAssertTrue(x === y)
    }
}

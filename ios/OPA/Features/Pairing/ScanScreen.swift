import PhotosUI
import SwiftUI

/// The scan page: a full-screen camera picture drawn by SwiftUI (frames come from `CameraEngine`, never from an
/// `AVCaptureVideoPreviewLayer`), a viewfinder, and a glass bar with the two other ways in (paste a link, read a
/// screenshot from the photo library). The page is always dark, like any camera.
///
/// The camera runs only while this page is on screen and the app is active. No camera (the Simulator), a denied
/// permission, a restriction or a failed session each replace the viewfinder with a short explanation; paste and
/// photo keep working in every case.
struct ScanScreen: View {
    let flow: PairingFlow

    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var photo: PhotosPickerItem?
    @State private var decoding = false
    @State private var pastePresented = false

    private var scanner: QRScanner { flow.scanner }

    var body: some View {
        ZStack {
            CameraFeed(scanner: scanner)
            VStack(spacing: 0) {
                topBar
                ScrollView {
                    VStack(spacing: 0) {
                        column
                        // At accessibility text sizes the bar would cover half the page: it scrolls with the content.
                        if typeSize.isAccessibilitySize { bottomBar }
                    }
                }
                .scrollBounceBehavior(.basedOnSize)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if !typeSize.isAccessibilitySize { bottomBar }
        }
        .preferredColorScheme(.dark)
        .animation(MotionAware(reduce: reduceMotion).snappy, value: flow.recognizedHostName)
        .animation(MotionAware(reduce: reduceMotion).snappy, value: flow.hint)
        .sensoryFeedback(.success, trigger: flow.recognitionCount)
        .task { await scanner.start() }
        .onDisappear { scanner.stop() }
        .onChange(of: scenePhase) { _, phase in
            // Off while the app is not in front (also while a system prompt is up); back on when it returns, which also
            // picks up a permission the user just switched on in Settings.
            if phase == .active {
                if flow.recognizedHostName == nil { Task { await scanner.start() } }
            } else {
                scanner.stop(keepFrame: flow.recognizedHostName != nil)
            }
        }
        .onChange(of: photo) { _, item in
            guard let item else { return }
            Task { await readQRCode(in: item) }
        }
        .sheet(isPresented: $pastePresented) {
            PasteLinkSheet { flow.submit(link: $0) }
        }
    }

    // MARK: Pieces

    private var topBar: some View {
        HStack {
            GlassCircleButton(systemImage: "xmark", accessibilityLabel: "关闭") { flow.scannerPresented = false }
            Spacer(minLength: 0)
            Text("连接 Mac")
                .font(.headline)
                .foregroundStyle(CameraInk.primary)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 0)
            Color.clear.frame(width: 44, height: 44)
        }
        .padding(.horizontal, Space.l)
        .padding(.top, 4)
    }

    private var column: some View {
        VStack(spacing: 0) {
            VStack(spacing: 6) {
                Text("扫描 Mac 上的二维码")
                    .font(.system(.title3, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)
                commandLine
            }
            .multilineTextAlignment(.center)
            .padding(.top, 40)

            stageArea
                .padding(.top, 48)

            statusLine
                .padding(.top, 34)
        }
        .padding(.horizontal, 30)
        .padding(.bottom, Space.xl)
        .frame(maxWidth: .infinity)
        .foregroundStyle(CameraInk.primary)
    }

    /// "在 Mac 终端运行 opa pair" with the command set in a chip.
    private var commandLine: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) { Text("在 Mac 终端运行"); commandChip }
            VStack(spacing: 6) { Text("在 Mac 终端运行"); commandChip }
        }
        .pairingFont(14.5, relativeTo: .subheadline)
        .foregroundStyle(CameraInk.secondary)
    }

    private var commandChip: some View {
        Text("opa pair")
            .font(.system(.footnote, design: .monospaced))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.white.opacity(0.14), in: .rect(cornerRadius: 6, style: .continuous))
    }

    /// The viewfinder, or the reason there is none.
    @ViewBuilder
    private var stageArea: some View {
        switch scanner.availability {
        case .starting, .running:
            Viewfinder()
        case .denied:
            CameraPanel(title: "需要相机权限",
                        message: "允许 Orbit 使用相机，才能扫描 Mac 上的二维码。也可以用下面的“粘贴链接”或“从相册识别”。",
                        action: ("去设置开启相机", openSettings))
        case .restricted:
            CameraPanel(title: "相机被限制了",
                        message: "这台设备限制了相机的使用（屏幕使用时间或设备管理）。可以用下面的“粘贴链接”或“从相册识别”完成配对。",
                        action: nil)
        case .noCamera:
            CameraPanel(title: "这台设备没有可用的相机",
                        message: noCameraMessage,
                        action: nil)
        case .failed:
            CameraPanel(title: "相机暂时打不开",
                        message: "稍后再试，或者用下面的“粘贴链接”或“从相册识别”。",
                        action: ("重新打开相机", { Task { await scanner.start() } }))
        }
    }

    private var noCameraMessage: String {
        #if targetEnvironment(simulator)
        "模拟器没有相机。用下面的“粘贴链接”或“从相册识别”继续。"
        #else
        "用下面的“粘贴链接”或“从相册识别”完成配对。"
        #endif
    }

    /// "识别到 …" after a valid code, or what is wrong with the one in view.
    @ViewBuilder
    private var statusLine: some View {
        if let name = flow.recognizedHostName {
            Label {
                Text("识别到 \(name)")
            } icon: {
                Image(systemName: "checkmark").fontWeight(.bold)
            }
            .pairingFont(14, relativeTo: .subheadline)
            .foregroundStyle(CameraInk.primary.opacity(0.9))
            .multilineTextAlignment(.center)
            .transition(.opacity)
        } else if let hint = flow.hint {
            Label {
                Text(hint.text)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
            }
            .pairingFont(14, relativeTo: .subheadline)
            .foregroundStyle(CameraInk.primary.opacity(0.9))
            .multilineTextAlignment(.center)
            .transition(.opacity)
        }
    }

    private var bottomBar: some View {
        let isDecoding = decoding   // read here: the picker's label closure is not main-actor isolated
        let paste = Button { pastePresented = true } label: {
            Label("粘贴链接", systemImage: "doc.on.clipboard")
        }
        let library = PhotosPicker(selection: $photo, matching: .images) {
            if isDecoding {
                ProgressView().tint(CameraInk.primary)
            } else {
                Label("从相册识别", systemImage: "photo")
            }
        }
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: Space.s) { paste; library }
            VStack(spacing: Space.s) { paste; library }
        }
        .buttonStyle(ScanBarButtonStyle())
        .padding(Space.s)
        .orbitGlass(in: .rect(cornerRadius: 30, style: .continuous))
        .padding(.horizontal, Space.m)
        .padding(.bottom, Space.s)
    }

    // MARK: Actions

    private func openSettings() {
        if let url = URL(string: "app-settings:") { openURL(url) }
    }

    @MainActor
    private func readQRCode(in item: PhotosPickerItem) async {
        decoding = true
        defer { decoding = false; photo = nil }
        let data = try? await item.loadTransferable(type: Data.self)
        await flow.scanned(imageData: data)
    }
}

// MARK: - Camera picture

/// Fixed colors of the camera page: it is dark whatever the system setting is.
private enum CameraInk {
    static let primary = Color(red: 1, green: 0.992, blue: 0.976)
    static let secondary = Color(red: 1, green: 0.992, blue: 0.976).opacity(0.78)
}

/// The camera picture behind everything. Its own view so that only this body re-runs for every new frame.
private struct CameraFeed: View {
    let scanner: QRScanner

    var body: some View {
        GeometryReader { geo in
            ZStack {
                EllipseGlow(stops: [.init(color: Color(hex: "#3A332D") ?? .gray, location: 0),
                                    .init(color: Color(hex: "#141210") ?? .black, location: 0.75),
                                    .init(color: Color(hex: "#141210") ?? .black, location: 1)],
                            center: UnitPoint(x: 0.5, y: 0.42), radiusX: 0.8, radiusY: 0.6)
                if let frame = scanner.frame {
                    Image(decorative: frame, scale: 1)
                        .resizable()
                        .scaledToFill()
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
                        .overlay { Color.black.opacity(0.18) }
                        .overlay(alignment: .top) { fade(from: .top).frame(height: 300) }
                        .overlay(alignment: .bottom) { fade(from: .bottom).frame(height: 240) }
                }
            }
        }
        .background(Color.black)
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }

    /// A dark fade at the top / bottom edge keeps the text and the glass bar readable on a bright picture.
    private func fade(from edge: VerticalEdge) -> some View {
        LinearGradient(colors: [.black.opacity(0.55), .clear],
                       startPoint: edge == .top ? .top : .bottom, endPoint: edge == .top ? .bottom : .top)
    }
}

// MARK: - Viewfinder and panels

/// Four corner brackets around a 240 pt square (46 pt arms, 26 pt outer radius, 4 pt line).
private struct Viewfinder: View {
    var body: some View {
        ViewfinderCorners()
            .stroke(CameraInk.primary, style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
            .frame(width: 240, height: 240)
            .accessibilityElement()
            .accessibilityLabel("取景框")
            .accessibilityHint("把 Mac 上的二维码放进框里")
    }
}

private struct ViewfinderCorners: Shape {
    var arm: CGFloat = 46
    var radius: CGFloat = 26

    func path(in rect: CGRect) -> Path {
        var path = Path()
        func corner(_ start: CGPoint, _ vertex: CGPoint, _ end: CGPoint) {
            path.move(to: start)
            path.addArc(tangent1End: vertex, tangent2End: end, radius: radius)
            path.addLine(to: end)
        }
        corner(CGPoint(x: rect.minX, y: rect.minY + arm), CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.minX + arm, y: rect.minY))
        corner(CGPoint(x: rect.maxX - arm, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY + arm))
        corner(CGPoint(x: rect.maxX, y: rect.maxY - arm), CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.maxX - arm, y: rect.maxY))
        corner(CGPoint(x: rect.minX + arm, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY - arm))
        return path
    }
}

/// Where the viewfinder would be, when the camera cannot be used: what is wrong and what to do about it.
private struct CameraPanel: View {
    var title: String
    var message: String
    var action: (title: String, run: () -> Void)?

    var body: some View {
        VStack(spacing: Space.m) {
            Image(systemName: "camera.fill")
                .pairingFont(26, weight: .medium)
                .foregroundStyle(CameraInk.secondary)
                .accessibilityHidden(true)
            Text(title)
                .font(.system(.headline, weight: .semibold))
                .multilineTextAlignment(.center)
            Text(message)
                .font(.subheadline)
                .lineSpacing(2)
                .foregroundStyle(CameraInk.secondary)
                .multilineTextAlignment(.center)
            if let action {
                Button(action.title, action: action.run)
                    .buttonStyle(.orbit(.primary, size: .small))
                    .padding(.top, Space.xs)
            }
        }
        .padding(Space.xl)
        .frame(maxWidth: 340)
        .background(Color.white.opacity(0.08), in: .rect(cornerRadius: Radius.card, style: .continuous))
        .accessibilityElement(children: .contain)
    }
}

// MARK: - Glass bar buttons

/// The two buttons in the glass bar: a pale capsule that darkens when pressed.
private struct ScanBarButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        BarButtonBody(configuration: configuration)
    }

    private struct BarButtonBody: View {
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        let configuration: ButtonStyleConfiguration

        var body: some View {
            configuration.label
                .font(.system(.subheadline, weight: .semibold))
                .foregroundStyle(CameraInk.primary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, minHeight: 48)
                .background(Color.white.opacity(configuration.isPressed ? 0.22 : 0.12), in: .capsule)
                .contentShape(.capsule)
                .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
                .animation(MotionAware(reduce: reduceMotion).press, value: configuration.isPressed)
        }
    }
}

import SwiftUI
import UIKit

struct CameraScreen: View {
    @State private var model = CameraModel()
    @State private var previewView: PreviewView?

    var body: some View {
        @Bindable var model = model
        GeometryReader { geometry in
            let frame = previewFrame(in: geometry.size)
            ZStack {
                Color.black
                CameraPreview(session: model.session) { view in
                    previewView = view
                }
                .frame(width: frame.width, height: frame.height)
                .position(x: frame.midX, y: frame.midY)
                .gesture(previewGesture)

                if let placement = model.overlayPlacement, let sprite = model.sprite {
                    Image(decorative: sprite, scale: 1)
                        .resizable()
                        .frame(width: placement.pixelRadius * 2, height: placement.pixelRadius * 2)
                        .rotationEffect(.radians(placement.rotation))
                        .position(x: frame.minX + placement.center.x, y: frame.minY + placement.center.y)
                        .allowsHitTesting(false)
                }

                if let guide = model.moonGuide {
                    MoonGuideMarker(guide: guide)
                        .position(x: frame.minX + guide.anchor.x, y: frame.minY + guide.anchor.y)
                        .allowsHitTesting(false)
                }

                if let meteringPoint = model.meteringPoint {
                    RoundedRectangle(cornerRadius: 2)
                        .stroke(.yellow, lineWidth: 1.5)
                        .frame(width: 72, height: 72)
                        .position(x: frame.minX + meteringPoint.x, y: frame.minY + meteringPoint.y)
                        .allowsHitTesting(false)
                }

                VStack {
                    HStack {
                        Text("\(model.phaseName)  \(zoomText)")
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(.black.opacity(0.45), in: Capsule())
                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 12)

                    if let statusMessage = model.statusMessage {
                        Text(statusMessage)
                            .font(.footnote)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(.black.opacity(0.55), in: Capsule())
                    }

                    if let horizonMessage = model.horizonMessage {
                        Text(horizonMessage)
                            .font(.footnote)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(.black.opacity(0.55), in: Capsule())
                    }

                    Spacer()

                    if model.isCalibrating {
                        Text("拖动月盘，盖住真实的月亮")
                            .font(.footnote)
                        Text(model.calibrationReadout)
                            .font(.footnote.monospacedDigit())
                    }

                    controls(model)
                        .padding(.horizontal, 20)
                        .padding(.bottom, 18)
                }
                .foregroundStyle(.white)
            }
            .onAppear {
                UIDevice.current.beginGeneratingDeviceOrientationNotifications()
                model.start()
                publishFrame(frame)
            }
            .onChange(of: frame) { _, newFrame in
                publishFrame(newFrame)
            }
            .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in
                publishFrame(previewFrame(in: geometry.size))
            }
        }
        .background(.black)
        .ignoresSafeArea()
        .statusBarHidden()
        .fullScreenCover(isPresented: $model.showResult) {
            if let image = model.capturedImage {
                CaptureResultView(
                    image: image,
                    message: model.saveMessage,
                    onSave: { model.saveCapturedPhoto() },
                    onRetake: { model.retake() }
                )
            }
        }
        .onDisappear { model.stop() }
    }

    private var zoomText: String {
        if abs(model.displayZoom - model.displayZoom.rounded()) < 0.05 {
            return String(format: "%.0f×", model.displayZoom)
        }
        return String(format: "%.1f×", model.displayZoom)
    }

    @ViewBuilder
    private func controls(_ model: CameraModel) -> some View {
        @Bindable var model = model
        @Bindable var alignment = model.alignment
        VStack(spacing: 14) {
            HStack {
                Text("曝光")
                    .font(.caption)
                Slider(value: $model.exposureBias, in: model.exposureRange)
                    .onChange(of: model.exposureBias) { _, value in
                        model.setExposureBias(value)
                    }
            }
            HStack(spacing: 12) {
                iconToggle(
                    image: "BelowHorizon",
                    label: "地平线遮住月亮",
                    isOn: !alignment.drawMoonBelowHorizon
                ) {
                    alignment.drawMoonBelowHorizon.toggle()
                    model.refreshDisplayedMoon()
                }
                iconToggle(
                    image: "MoonPhase",
                    label: "月相模拟",
                    isOn: alignment.simulateMoonPhase
                ) {
                    alignment.simulateMoonPhase.toggle()
                    model.refreshDisplayedMoon()
                }
                Spacer()
            }
            HStack(spacing: 18) {
                zoomButton(0.5)
                zoomButton(1)
                zoomButton(2)
                Spacer()
                if model.isCalibrating {
                    Button("重置") { model.resetAlignment() }
                    Button("完成") { model.finishCalibration() }
                } else {
                    Button("校正") { model.beginCalibration() }
                }
            }
            .font(.subheadline.weight(.semibold))
            Button {
                model.shutter()
            } label: {
                Circle()
                    .strokeBorder(.white, lineWidth: 4)
                    .background(Circle().fill(.white.opacity(0.9)))
                    .frame(width: 72, height: 72)
            }
            .buttonStyle(.plain)
        }
    }

    private func iconToggle(image: String, label: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(image)
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: 28, height: 28)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
                .foregroundStyle(isOn ? Color.yellow : Color.white.opacity(0.72))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityValue(isOn ? "开" : "关")
    }

    private func zoomButton(_ zoom: Double) -> some View {
        let selected = abs(model.displayZoom - zoom) < 0.12
        return Button {
            model.setDisplayZoom(zoom)
        } label: {
            Text(zoom < 1 ? "0.5" : String(format: "%.0f", zoom))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(selected ? .yellow.opacity(0.9) : .white.opacity(0.16), in: Capsule())
                .foregroundStyle(selected ? .black : .white)
        }
        .buttonStyle(.plain)
    }

    private var previewGesture: some Gesture {
        SimultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    guard model.isCalibrating else { return }
                    model.dragCalibration(to: value.location)
                }
                .onEnded { value in
                    if model.isCalibrating {
                        model.endCalibration(at: value.location)
                    } else if hypot(value.translation.width, value.translation.height) < 12, let previewView {
                        model.focus(at: value.location, in: previewView)
                    }
                },
            MagnificationGesture()
                .onChanged { scale in
                    guard !model.isCalibrating else { return }
                    model.updatePinch(scale)
                }
                .onEnded { _ in
                    model.endPinch()
                }
        )
    }

    private func publishFrame(_ frame: CGRect) {
        modelPreviewSize = frame.size
        modelScreenOrientation = currentOrientation
        model.updatePreview(size: frame.size, orientation: currentOrientation)
    }

    private var currentOrientation: ScreenOrientation {
        let orientation = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first?
            .effectiveGeometry.interfaceOrientation ?? .portrait
        switch orientation {
        case .landscapeLeft: return .landscapeLeft
        case .landscapeRight: return .landscapeRight
        case .portraitUpsideDown: return .upsideDown
        default: return .portrait
        }
    }

    private func previewFrame(in size: CGSize) -> CGRect {
        let landscape = size.width > size.height
        let aspect = landscape ? 4.0 / 3.0 : 3.0 / 4.0
        let fitted = CGSize(
            width: min(size.width, size.height * aspect),
            height: min(size.height, size.width / aspect)
        )
        let width = fitted.height * aspect > size.width ? size.width : fitted.height * aspect
        let height = width / aspect
        return CGRect(
            x: (size.width - width) / 2,
            y: (size.height - height) / 2,
            width: width,
            height: height
        )
    }

    @State private var modelPreviewSize: CGSize = .zero
    @State private var modelScreenOrientation: ScreenOrientation = .portrait
}

private struct MoonGuideMarker: View {
    var guide: MoonGuide

    var body: some View {
        let degrees = Int(guide.separationDegrees.rounded())
        ZStack {
            Chevron()
                .fill(.white)
                .overlay(Chevron().stroke(.yellow, lineWidth: 1.5))
                .frame(width: 28, height: 22)
                .shadow(color: .black.opacity(0.85), radius: 2, y: 1)
                .rotationEffect(.radians(guide.rotation))
            Text("\(degrees)°")
                .font(.caption2.monospacedDigit().weight(.bold))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.9), radius: 2, y: 1)
                .offset(labelOffset)
        }
        .frame(width: 88, height: 88)
    }

    private var labelOffset: CGSize {
        let distance: CGFloat = 32
        return CGSize(
            width: -sin(guide.rotation) * distance,
            height: cos(guide.rotation) * distance
        )
    }
}

private struct Chevron: Shape {
    func path(in rect: CGRect) -> Path {
        let inset = rect.insetBy(dx: 1, dy: 1)
        let width = inset.width
        let height = inset.height
        var path = Path()
        path.move(to: CGPoint(x: inset.minX + width * 0.5, y: inset.minY))
        path.addLine(to: CGPoint(x: inset.maxX, y: inset.maxY))
        path.addLine(to: CGPoint(x: inset.minX + width * 0.5, y: inset.minY + height * 0.62))
        path.addLine(to: CGPoint(x: inset.minX, y: inset.maxY))
        path.closeSubpath()
        return path
    }
}

import SwiftUI

struct CaptureResultView: View {
    var model: CameraModel

    @State private var didChoose = false

    var body: some View {
        GeometryReader { geometry in
            let imageSize = model.resultPixelSize
            let display = fittedRect(imageSize: imageSize, in: geometry.size)
            let displayed = model.isAdjustingCapture
                ? (model.capturedBaseImage ?? model.capturedImage)
                : (model.capturedImage ?? model.capturedBaseImage)
            ZStack {
                Color.black
                if let displayed {
                    Image(uiImage: displayed)
                        .resizable()
                        .frame(width: display.width, height: display.height)
                        .position(x: display.midX, y: display.midY)
                }
                if model.isAdjustingCapture,
                   let sprite = model.resultSprite,
                   let placement = model.resultPlacement,
                   imageSize.width > 1,
                   display.width > 1 {
                    let scale = display.width / imageSize.width
                    MoonDiskOverlay(sprite: sprite, placement: placement, showsTint: model.alignment.simulateAtmosphere)
                        .scaleEffect(scale)
                        .position(
                            x: display.minX + placement.center.x * scale,
                            y: display.minY + placement.center.y * scale
                        )
                        .allowsHitTesting(false)
                }
            }
            .contentShape(Rectangle())
            .gesture(drag(in: display, imageSize: imageSize))
            .overlay(alignment: .top) { toggles }
            .overlay(alignment: .bottom) { actions }
        }
        .background(.black)
        .foregroundStyle(.white)
    }

    private var toggles: some View {
        HStack(spacing: 12) {
            iconToggle(image: "MoonPhase", label: "月相模拟", isOn: model.alignment.simulateMoonPhase) {
                model.setResultMoonPhase(!model.alignment.simulateMoonPhase)
            }
            iconToggle(image: "Atmosphere", label: "大气颜色", isOn: model.alignment.simulateAtmosphere) {
                model.setResultAtmosphere(!model.alignment.simulateAtmosphere)
            }
            Button("重置") { model.resetResultAlignment() }
                .font(.subheadline.weight(.semibold))
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
    }

    private var actions: some View {
        HStack(spacing: 28) {
            Button("丢弃") { choose(model.discardCapturedPhoto) }
            Button("保存") { choose(model.saveCapturedPhoto) }
        }
        .font(.headline)
        .buttonStyle(.borderedProminent)
        .disabled(didChoose || model.isAdjustingCapture || !model.resultReady)
        .padding(.bottom, 28)
    }

    private func drag(in display: CGRect, imageSize: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { value in
                guard let point = imagePoint(value.location, display: display, imageSize: imageSize) else { return }
                if !model.isAdjustingCapture {
                    model.beginCaptureDrag()
                }
                model.updateCaptureDrag(to: point)
            }
            .onEnded { value in
                guard model.isAdjustingCapture else { return }
                let point = imagePoint(value.location, display: display, imageSize: imageSize)
                    ?? model.resultPlacement?.center
                    ?? .zero
                model.endCaptureDrag(at: point)
            }
    }

    private func imagePoint(_ location: CGPoint, display: CGRect, imageSize: CGSize) -> CGPoint? {
        guard display.width > 1, display.height > 1, imageSize.width > 1, imageSize.height > 1 else { return nil }
        guard display.contains(location) else { return nil }
        return CGPoint(
            x: (location.x - display.minX) / display.width * imageSize.width,
            y: (location.y - display.minY) / display.height * imageSize.height
        )
    }

    private func fittedRect(imageSize: CGSize, in container: CGSize) -> CGRect {
        guard imageSize.width > 1, imageSize.height > 1, container.width > 1, container.height > 1 else {
            return CGRect(origin: .zero, size: container)
        }
        let scale = min(container.width / imageSize.width, container.height / imageSize.height)
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return CGRect(
            x: (container.width - size.width) / 2,
            y: (container.height - size.height) / 2,
            width: size.width,
            height: size.height
        )
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

    private func choose(_ action: () -> Void) {
        guard !didChoose else { return }
        didChoose = true
        action()
    }
}

import SwiftUI

struct CaptureResultView: View {
    let image: UIImage
    let onSave: () -> Void
    let onDiscard: () -> Void

    @State private var didChoose = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
            VStack {
                Spacer()
                HStack(spacing: 28) {
                    Button("丢弃") { choose(onDiscard) }
                    Button("保存") { choose(onSave) }
                }
                .font(.headline)
                .buttonStyle(.borderedProminent)
                .disabled(didChoose)
                .padding(.bottom, 28)
            }
        }
        .foregroundStyle(.white)
    }

    private func choose(_ action: () -> Void) {
        guard !didChoose else { return }
        didChoose = true
        action()
    }
}

import SwiftUI

struct CaptureResultView: View {
    let image: UIImage
    let message: String?
    let onSave: () -> Void
    let onRetake: () -> Void

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
            VStack {
                Spacer()
                if let message {
                    Text(message)
                        .font(.footnote)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(.black.opacity(0.55), in: Capsule())
                }
                HStack(spacing: 28) {
                    Button("重拍", action: onRetake)
                    Button("保存", action: onSave)
                }
                .font(.headline)
                .buttonStyle(.borderedProminent)
                .padding(.bottom, 28)
            }
        }
        .foregroundStyle(.white)
    }
}

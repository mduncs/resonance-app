import SwiftUI

struct LoadingView: View {
    var message: String = "Loading..."
    var style: LoadingStyle = .spinner

    enum LoadingStyle {
        case spinner
        case progress(Double)
        case indeterminate
    }

    var body: some View {
        VStack(spacing: 16) {
            switch style {
            case .spinner:
                ProgressView()
                    .scaleEffect(1.5)

            case .progress(let value):
                ProgressView(value: value)
                    .frame(width: 200)

            case .indeterminate:
                ProgressView()
                    .progressViewStyle(.linear)
                    .frame(width: 200)
            }

            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct LoadingOverlay: View {
    var isLoading: Bool
    var message: String = "Loading..."

    var body: some View {
        if isLoading {
            ZStack {
                Color.black.opacity(0.3)
                    .ignoresSafeArea()

                VStack(spacing: 16) {
                    ProgressView()
                        .scaleEffect(1.5)

                    Text(message)
                        .font(.subheadline)
                        .foregroundStyle(.white)
                }
                .padding(24)
                .background(.ultraThinMaterial)
                .cornerRadius(12)
            }
        }
    }
}

struct ShimmerView: View {
    @State private var isAnimating = false

    var body: some View {
        Rectangle()
            .fill(.quaternary)
            .overlay {
                GeometryReader { geometry in
                    Rectangle()
                        .fill(
                            LinearGradient(
                                colors: [.clear, .white.opacity(0.3), .clear],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: geometry.size.width / 2)
                        .offset(x: isAnimating ? geometry.size.width * 1.5 : -geometry.size.width / 2)
                }
            }
            .clipped()
            .onAppear {
                withAnimation(.linear(duration: 1.5).repeatForever(autoreverses: false)) {
                    isAnimating = true
                }
            }
    }
}

struct SkeletonRow: View {
    var body: some View {
        HStack(spacing: 12) {
            ShimmerView()
                .frame(width: 50, height: 50)
                .cornerRadius(6)

            VStack(alignment: .leading, spacing: 8) {
                ShimmerView()
                    .frame(width: 150, height: 14)
                    .cornerRadius(4)

                ShimmerView()
                    .frame(width: 100, height: 12)
                    .cornerRadius(4)
            }

            Spacer()
        }
        .padding(.vertical, 4)
    }
}

struct SkeletonGrid: View {
    let count: Int

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 140))], spacing: 16) {
            ForEach(0..<count, id: \.self) { _ in
                VStack(alignment: .leading, spacing: 8) {
                    ShimmerView()
                        .aspectRatio(1, contentMode: .fit)
                        .cornerRadius(6)

                    ShimmerView()
                        .frame(height: 14)
                        .cornerRadius(4)

                    ShimmerView()
                        .frame(width: 80, height: 12)
                        .cornerRadius(4)
                }
            }
        }
    }
}

#Preview {
    VStack(spacing: 40) {
        LoadingView(message: "Loading library...")

        VStack(spacing: 0) {
            SkeletonRow()
            SkeletonRow()
            SkeletonRow()
        }
        .padding()

        SkeletonGrid(count: 4)
            .padding()
    }
}

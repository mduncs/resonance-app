import SwiftUI

/// A 5-star rating picker that supports 0-5 ratings.
/// Rating 0 clears the rating.
struct RatingView: View {
    let rating: Int?
    let onRate: (Int) -> Void
    var size: CGFloat = 16
    var spacing: CGFloat = 2

    var body: some View {
        HStack(spacing: spacing) {
            ForEach(1...5, id: \.self) { star in
                Image(systemName: starImage(for: star))
                    .font(.system(size: size))
                    .foregroundStyle(starColor(for: star))
                    .onTapGesture {
                        // Tapping current rating clears it (sets to 0)
                        if rating == star {
                            onRate(0)
                        } else {
                            onRate(star)
                        }
                    }
            }
        }
    }

    private func starImage(for star: Int) -> String {
        guard let rating, rating >= star else {
            return "star"
        }
        return "star.fill"
    }

    private func starColor(for star: Int) -> Color {
        guard let rating, rating >= star else {
            return .secondary
        }
        return .yellow
    }
}

/// Compact rating display for use in rows - shows filled stars only when rated
struct RatingIndicator: View {
    let rating: Int?
    var size: CGFloat = 10

    var body: some View {
        if let rating, rating > 0 {
            HStack(spacing: 1) {
                ForEach(1...rating, id: \.self) { _ in
                    Image(systemName: "star.fill")
                        .font(.system(size: size))
                        .foregroundStyle(.yellow)
                }
            }
        }
    }
}

/// Menu-based rating picker for context menus
struct RatingPicker: View {
    let currentRating: Int?
    let onRate: (Int) -> Void

    var body: some View {
        Menu {
            ForEach(0...5, id: \.self) { rating in
                Button {
                    onRate(rating)
                } label: {
                    HStack {
                        if rating == 0 {
                            Text("No Rating")
                        } else {
                            Text(String(repeating: "\u{2605}", count: rating))
                        }
                        if currentRating == rating || (rating == 0 && currentRating == nil) {
                            Spacer()
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            Label {
                HStack {
                    Text("Rating")
                    if let rating = currentRating, rating > 0 {
                        Text("(\(String(repeating: "\u{2605}", count: rating)))")
                            .foregroundStyle(.secondary)
                    }
                }
            } icon: {
                Image(systemName: currentRating != nil && currentRating! > 0 ? "star.fill" : "star")
            }
        }
    }
}

#Preview("RatingView") {
    VStack(spacing: 20) {
        RatingView(rating: nil, onRate: { _ in })
        RatingView(rating: 3, onRate: { _ in })
        RatingView(rating: 5, onRate: { _ in })

        Divider()

        HStack {
            Text("Song Title")
            Spacer()
            RatingIndicator(rating: 4)
        }
        .padding()

        HStack {
            Text("Unrated Song")
            Spacer()
            RatingIndicator(rating: nil)
        }
        .padding()
    }
    .padding()
    .frame(width: 300)
}

#Preview("RatingPicker") {
    VStack {
        RatingPicker(currentRating: nil, onRate: { _ in })
        RatingPicker(currentRating: 3, onRate: { _ in })
    }
    .padding()
}

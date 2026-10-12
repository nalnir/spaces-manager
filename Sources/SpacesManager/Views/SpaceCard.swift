import SwiftUI

struct RowDragPreview: View {
    let row: SpaceRow

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Text(row.emoji)
                Circle().fill(Color(hex: row.accentHex)).frame(width: 14, height: 14)
                Text(row.name).font(.headline)
                Text("\(row.spaces.count) spaces").font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                ForEach(row.spaces.prefix(4)) { space in
                    SpaceCard(space: space, isSelected: false, isKeyboardFocused: false)
                        .scaleEffect(0.5, anchor: .topLeading)
                        .frame(width: 80, height: 51, alignment: .topLeading)
                }
            }
        }
        .padding(12)
        .frame(width: 420, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8).stroke(.white.opacity(0.35), lineWidth: 1)
        }
    }
}

struct SpaceCard: View {
    let space: SpaceRecord
    let isSelected: Bool
    let isKeyboardFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .topLeading) {
                if let thumbnail = space.thumbnail {
                    Image(decorative: thumbnail, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    LinearGradient(
                        colors: [Color(hex: "263C34"), Color(hex: "111C1A")],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    Image(systemName: space.kind.icon)
                        .font(.title2)
                        .foregroundStyle(.white.opacity(0.78))
                        .padding(12)
                }
            }
            .frame(height: 68)
            .clipped()
            HStack {
                Text(space.name).lineLimit(1)
                Spacer(minLength: 4)
            }
            .font(.caption.weight(.medium))
            .padding(7)
        }
        .frame(width: 160)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .stroke(
                    isKeyboardFocused ? Color(hex: "73BCEB") : (isSelected ? Color.white : .white.opacity(0.18)),
                    lineWidth: isKeyboardFocused || isSelected ? 2 : 1
                )
        }
    }
}

enum ColorPalette {
    static let values = [
        "EF6A6A", "F39A4E", "E8C75F", "B9D76B", "75C98D",
        "56C5A8", "57C8D5", "73BCEB", "7897E8", "9D83DC",
        "C77BD7", "E899AE", "C77764", "AE9275", "858C98",
        "F4A5A5", "F5C287", "E5DC86", "9BCF89", "85D4C7",
    ]
}

extension Color {
    init(hex: String) {
        let value = UInt64(hex.trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16) ?? 0
        self.init(
            .sRGB,
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255,
            opacity: 1
        )
    }
}
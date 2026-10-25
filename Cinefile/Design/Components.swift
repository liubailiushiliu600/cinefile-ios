import SwiftUI

/// Bordered button used across the shell (design tokens: 34pt height, 8pt radius).
struct CFButtonStyle: ButtonStyle {
    var primary: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(CF.ui(13, weight: .medium))
            .foregroundColor(primary ? CF.textOnAccent : CF.text2)
            .padding(.horizontal, 12)
            .frame(minHeight: 34)
            .background(
                RoundedRectangle(cornerRadius: CF.radiusSmall)
                    .fill(primary ? CF.accent : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: CF.radiusSmall)
                    .stroke(primary ? CF.accent : CF.line, lineWidth: 1)
            )
            .opacity(configuration.isPressed ? 0.75 : 1.0)
    }
}

/// Centered empty state with an optional action.
struct EmptyStateView: View {
    let systemImage: String
    let title: String
    let message: String
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: systemImage)
                .font(.system(size: 44, weight: .light))
                .foregroundColor(CF.text3)
            Text(title)
                .font(CF.ui(17, weight: .semibold))
                .foregroundColor(CF.text1)
            Text(message)
                .font(CF.ui(13))
                .foregroundColor(CF.text3)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(CFButtonStyle(primary: true))
                    .padding(.top, 6)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}

/// Small pill badge ("已看", "★ 9", "4K").
struct CFBadge: View {
    let text: String
    var color: Color = CF.text2
    var filled: Bool = false

    var body: some View {
        Text(text)
            .font(CF.mono(10, weight: .medium))
            .foregroundColor(filled ? CF.textOnAccent : color)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(filled ? color : Color.black.opacity(0.55))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(filled ? Color.clear : CF.lineStrong, lineWidth: 1)
            )
    }
}

/// Section header used inside panels.
struct PanelHeader: View {
    let title: String
    var subtitle: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(CF.ui(20, weight: .semibold))
                .foregroundColor(CF.text1)
            if let subtitle {
                Text(subtitle)
                    .font(CF.ui(12))
                    .foregroundColor(CF.text3)
            }
        }
    }
}

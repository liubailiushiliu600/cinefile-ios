import SwiftUI

/// Bordered button used across the shell (design tokens: 34pt height, 8pt radius).
struct CFButtonStyle: ButtonStyle {
    var primary: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(CF.ui(CF.fontBody, weight: .medium))
            .foregroundColor(primary ? CF.textOnAccent : CF.text2)
            .padding(.horizontal, 14)
            .frame(minHeight: 40)
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
        VStack(spacing: 16) {
            Image(systemName: systemImage)
                .font(.system(size: 52, weight: .light))
                .foregroundColor(CF.text3)
            Text(title)
                .font(CF.ui(20, weight: .semibold))
                .foregroundColor(CF.text1)
            Text(message)
                .font(CF.ui(CF.fontBody))
                .foregroundColor(CF.text3)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(CFButtonStyle(primary: true))
                    .padding(.top, 8)
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
            .font(CF.mono(11, weight: .medium))
            .foregroundColor(filled ? CF.textOnAccent : color)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
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
                .font(CF.ui(22, weight: .semibold))
                .foregroundColor(CF.text1)
            if let subtitle {
                Text(subtitle)
                    .font(CF.ui(14))
                    .foregroundColor(CF.text3)
            }
        }
    }
}

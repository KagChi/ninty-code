import SwiftUI
import NintyCore

/// opencode v2 permission dock: raised shell + footer tray with Deny / Allow always / Allow once.
struct PermissionDock: View {
    let request: PermissionRequest
    let onReply: (PermissionReply) -> Void

    var body: some View {
        VStack(spacing: 4) {
            // Shell body
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Theme.warning)
                        .font(.system(size: 13))
                    Text("Permission required")
                        .font(Theme.sansMedium)
                        .foregroundStyle(Theme.textBase)
                }
                preview
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassEffect(.regular.tint(Theme.layer01.opacity(0.5)), in: .rect(cornerRadius: Theme.radiusXL))

            // Footer tray
            HStack(spacing: 8) {
                Spacer()
                Button("Deny") { onReply(.reject) }
                    .buttonStyle(DockButtonStyle(variant: .ghost))
                    .keyboardShortcut(.cancelAction)
                Button("Allow always") { onReply(.always) }
                    .buttonStyle(DockButtonStyle(variant: .secondary))
                Button("Allow once") { onReply(.once) }
                    .buttonStyle(DockButtonStyle(variant: .primary))
                    .keyboardShortcut(.defaultAction)
            }
            .padding(8)
            .glassEffect(.regular.tint(Theme.bgBase.opacity(0.5)), in: .rect(cornerRadius: Theme.radiusXL))
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: 800)
    }

    @ViewBuilder
    private var preview: some View {
        if request.tool == "edit",
           let oldString = request.arguments["oldString"]?.stringValue,
           let newString = request.arguments["newString"]?.stringValue {
            DiffView(diff: (
                path: request.arguments["path"]?.stringValue ?? "",
                removed: oldString.components(separatedBy: .newlines),
                added: newString.components(separatedBy: .newlines)
            ))
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                Text(request.preview)
                    .font(Theme.caption)
                    .foregroundStyle(Theme.textMuted)
                    .textSelection(.enabled)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
            }
            .background(Theme.bgDeep, in: .rect(cornerRadius: Theme.radiusSmall))
            .overlay(RoundedRectangle(cornerRadius: Theme.radiusSmall).stroke(Theme.borderBase, lineWidth: 0.5))
        }
    }
}

struct DockButtonStyle: ButtonStyle {
    enum Variant { case ghost, secondary, primary }
    let variant: Variant

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.smallMedium)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .foregroundStyle(foreground)
            .background(background, in: .rect(cornerRadius: Theme.radiusSmall))
            .opacity(configuration.isPressed ? 0.8 : 1)
    }

    private var foreground: Color {
        switch variant {
        case .ghost: return Theme.textMuted
        case .secondary: return Theme.textBase
        case .primary: return .white
        }
    }

    private var background: Color {
        switch variant {
        case .ghost: return .clear
        case .secondary: return Theme.layer03
        case .primary: return Theme.accent
        }
    }
}

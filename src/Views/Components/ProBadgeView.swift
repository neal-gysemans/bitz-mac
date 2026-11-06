import SwiftUI

/// A compact neon-accented badge indicating a Pro-tier exclusive feature.
public struct ProBadgeView: View {
    public init() {}

    public var body: some View {
        Text("PRO")
            .font(.system(size: 9, weight: .bold, design: .monospaced))
            .foregroundStyle(Color.cyan)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                Capsule()
                    .fill(Color.cyan.opacity(0.15))
            )
            .overlay(
                Capsule()
                    .stroke(Color.cyan.opacity(0.4), lineWidth: 1)
            )
    }
}

// MARK: - Pro Feature Gate Modifier

public struct ProFeatureGateModifier: ViewModifier {
    public let feature: BitzFeature
    public let licensingService: any LicensingServiceProtocol
    public var onUpgradeRequested: (() -> Void)?

    @State private var showingPopover: Bool = false

    public func body(content: Content) -> some View {
        if licensingService.isFeatureUnlocked(feature) {
            content
        } else {
            HStack(spacing: 6) {
                content
                    .opacity(0.6)

                Button {
                    showingPopover = true
                } label: {
                    ProBadgeView()
                }
                .buttonStyle(.plain)
                .help("View Pro features")
                .accessibilityLabel("View Pro Features")
                .popover(isPresented: $showingPopover) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Image(systemName: "lock.fill")
                                .foregroundColor(.cyan)
                            Text(feature.title)
                                .font(.headline)
                        }

                        Text(feature.description)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        Divider()

                        HStack {
                            Spacer()
                            Button("View Bitz Pro Perks") {
                                showingPopover = false
                                onUpgradeRequested?()
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.cyan)
                            .controlSize(.small)
                        }
                    }
                    .padding(14)
                    .frame(width: 260)
                }
            }
        }
    }
}

public extension View {
    /// Decorates a view with a Pro badge and informative popover if the feature is locked.
    func proFeatureGated(
        _ feature: BitzFeature,
        licensingService: any LicensingServiceProtocol,
        onUpgradeRequested: (() -> Void)? = nil
    ) -> some View {
        modifier(
            ProFeatureGateModifier(
                feature: feature,
                licensingService: licensingService,
                onUpgradeRequested: onUpgradeRequested
            )
        )
    }
}

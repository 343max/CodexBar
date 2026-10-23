import Foundation

public enum ChatboxProviderDescriptor {
    public static let descriptor = Self.spec.makeDescriptor()
    public static let spec = PluginProviderSpec(
        id: .chatbox,
        displayName: "Chatbox AI",
        sessionLabel: "Plan",
        weeklyLabel: "Top-up credits",
        dashboardURL: "https://chatboxai.app",
        color: .init(hex: 0x228BE6),
        confetti: [0x228BE6, 0xA9C2FF],
        noDataMessage: "No cost history data.",
        history: .unavailable,
        burnDownWidgetSelectable: false,
        environmentKey: "CHATBOX_LICENSE_KEY",
        menuBarMetrics: .init(supported: [.automatic, .primary, .secondary]),
        apiKeyField: .init(
            id: "chatbox-license-key",
            title: "API key",
            subtitle: "Stored in the CodexBar config file."),
        showsAPIDetail: true,
        availability: .configuredKey)
}

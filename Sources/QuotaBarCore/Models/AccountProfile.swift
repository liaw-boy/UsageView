import Foundation

public struct AccountProfile: Identifiable, Codable, Sendable {
    public let id: String
    public let provider: ProviderID
    public var name: String
    public var email: String?
    public var orgName: String?
    public var plan: String?
    public var colorTag: String
    public var rawPayload: String
    public var isActive: Bool
    public var createdAt: Date
    public var lastUsedAt: Date

    public init(
        id: String = UUID().uuidString,
        provider: ProviderID,
        name: String,
        email: String? = nil,
        orgName: String? = nil,
        plan: String? = nil,
        colorTag: String = "#4A90E2",
        rawPayload: String,
        isActive: Bool = false,
        createdAt: Date = Date(),
        lastUsedAt: Date = Date()
    ) {
        self.id = id
        self.provider = provider
        self.name = name
        self.email = email
        self.orgName = orgName
        self.plan = plan
        self.colorTag = colorTag
        self.rawPayload = rawPayload
        self.isActive = isActive
        self.createdAt = createdAt
        self.lastUsedAt = lastUsedAt
    }

    public var displayTitle: String {
        if !name.isEmpty && name != "預設帳號" {
            return name
        }
        if let email, !email.isEmpty {
            return email
        }
        return "\(provider.displayName) 帳號"
    }

    public var shortId: String {
        String(id.prefix(6))
    }
}

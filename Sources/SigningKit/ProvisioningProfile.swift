import Foundation
import CryptoKit

/// A parsed `.mobileprovision` provisioning profile.
///
/// The file is a CMS (PKCS#7) blob whose payload is a plain-text XML property
/// list. We extract that plist range directly (no shelling out to `security`),
/// which keeps parsing pure and unit-testable.
public struct ProvisioningProfile {
    public enum ProfileType: Equatable {
        case development, adHoc, appStore, enterprise, unknown
    }

    public var name: String
    public var teamIdentifier: String
    public var applicationIdentifier: String
    public var developerCertificateSHA1s: [String]
    public var type: ProfileType
    public var expirationDate: Date?
    public var provisionedDeviceCount: Int
    /// UDIDs the profile is provisioned for (empty for App Store / enterprise profiles).
    public var provisionedDevices: [String]
    /// The profile's `Entitlements` dictionary (used to build the codesign entitlements file).
    public var entitlements: [String: Any]

    public var isExpired: Bool {
        guard let expirationDate else { return true }
        return expirationDate < Date()
    }

    public enum ParseError: Error, LocalizedError {
        case plistNotFound
        case malformed

        public var errorDescription: String? {
            switch self {
            case .plistNotFound: return "Could not find a property list inside the provisioning profile."
            case .malformed:     return "The provisioning profile is malformed."
            }
        }
    }

    public static func parse(data: Data) throws -> ProvisioningProfile {
        let plistData = try extractPlist(from: data)

        guard let root = try PropertyListSerialization
                .propertyList(from: plistData, format: nil) as? [String: Any] else {
            throw ParseError.malformed
        }

        let name = root["Name"] as? String ?? ""
        let team = (root["TeamIdentifier"] as? [String])?.first ?? ""
        let entitlements = root["Entitlements"] as? [String: Any] ?? [:]
        let appID = entitlements["application-identifier"] as? String ?? ""
        let getTaskAllow = entitlements["get-task-allow"] as? Bool ?? false
        let provisionsAllDevices = root["ProvisionsAllDevices"] as? Bool ?? false
        let devices = root["ProvisionedDevices"] as? [String] ?? []
        let expiration = root["ExpirationDate"] as? Date

        let certs = (root["DeveloperCertificates"] as? [Data] ?? []).map { sha1Hex($0) }

        let type: ProfileType
        if provisionsAllDevices {
            type = .enterprise
        } else if getTaskAllow {
            type = .development
        } else if !devices.isEmpty {
            type = .adHoc
        } else {
            type = .appStore
        }

        return ProvisioningProfile(
            name: name,
            teamIdentifier: team,
            applicationIdentifier: appID,
            developerCertificateSHA1s: certs,
            type: type,
            expirationDate: expiration,
            provisionedDeviceCount: devices.count,
            provisionedDevices: devices,
            entitlements: entitlements
        )
    }

    /// Locates the `<plist …>…</plist>` payload within the CMS container.
    private static func extractPlist(from data: Data) throws -> Data {
        let open = Data("<plist".utf8)
        let close = Data("</plist>".utf8)
        guard let start = data.range(of: open)?.lowerBound,
              let end = data.range(of: close, in: start..<data.endIndex)?.upperBound else {
            throw ParseError.plistNotFound
        }
        return data.subdata(in: start..<end)
    }

    private static func sha1Hex(_ data: Data) -> String {
        Insecure.SHA1.hash(data: data)
            .map { String(format: "%02X", $0) }
            .joined()
    }
}

import CovaCore
import Foundation

@MainActor
public final class CovaPlayer {
    public let assetOrigin: URL

    public init(assetOrigin: URL = CovaEnvironment.apiBaseURL) {
        self.assetOrigin = assetOrigin
    }
}

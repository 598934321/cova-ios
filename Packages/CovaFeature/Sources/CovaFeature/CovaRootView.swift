import CovaUI
import SwiftUI

public struct CovaRootView: View {
    private let themeMode: CovaThemeMode

    public init(themeMode: CovaThemeMode = .system) {
        self.themeMode = themeMode
    }

    public var body: some View {
        Text(appDisplayName)
            .preferredColorScheme(themeMode.colorScheme)
    }

    private var appDisplayName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? ""
    }
}

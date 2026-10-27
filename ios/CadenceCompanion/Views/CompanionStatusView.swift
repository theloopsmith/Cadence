import SwiftUI

public struct CompanionStatusView: View {
    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Cadence Companion — Meta Gen 3 AI Glasses")
                .font(.title2.bold())
            Text("Status: Connected • WearState: Worn • Audio Route: .playAndRecord")
                .font(.subheadline)
        }
        .padding()
    }
}

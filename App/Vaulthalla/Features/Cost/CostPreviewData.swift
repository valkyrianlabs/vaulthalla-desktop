#if DEBUG
import Foundation
import VHContract
import VHTransport

/// PREVIEW DATA, DEBUG only: price budgets, cost alerts and spend for the preview nodes.
nonisolated enum CostPreviewData: PreviewFeature {
    static func answer(_ command: WsCommand, _ payload: some Sendable, from transport: PreviewTransport)
        throws(WsError) -> Any?
    {
        nil
    }
}
#endif

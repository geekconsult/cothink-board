import Foundation

enum InspectorVisibility: String, CaseIterable {
    case automatic
    case shown
    case hidden

    func isVisible(hasSelection: Bool) -> Bool {
        switch self {
        case .automatic: return hasSelection
        case .shown: return true
        case .hidden: return false
        }
    }

    func toggled(hasSelection: Bool) -> InspectorVisibility {
        isVisible(hasSelection: hasSelection) ? .hidden : .shown
    }
}

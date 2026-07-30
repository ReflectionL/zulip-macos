import ZulipCoreBindings

enum ConversationLoadState: Equatable, Sendable {
    case loading(title: String, subtitle: String)
    case empty(title: String, subtitle: String, message: String)
    case failure(title: String, subtitle: String, message: String)
    case offline(ConversationPage)
    case loaded(ConversationPage)

    var title: String {
        switch self {
        case let .loading(title, _),
             let .empty(title, _, _),
             let .failure(title, _, _):
            title
        case let .offline(page),
             let .loaded(page):
            page.title
        }
    }

    var subtitle: String {
        switch self {
        case let .loading(_, subtitle),
             let .empty(_, subtitle, _),
             let .failure(_, subtitle, _):
            subtitle
        case let .offline(page),
             let .loaded(page):
            page.subtitle
        }
    }
}

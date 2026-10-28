import Foundation
import OpenArcModel

// Plan C30: FakeEngine's model of Chromium's Autofill data (tests and UI development). Submitting
// an address or card form offers to save it (`FakeTab.simulateAddressSubmission`,
// `simulateCardSubmission`); saved entries come back as dropdown rows on the next form
// (`FakeTab.simulateAutofillFieldFocus`). Chromium's rules kept in miniature: nothing is offered
// off the record, an entry already saved is not offered again, and a site whose new-address offers
// were declined `FakeAutofillStore.maximumStrikes` times is not asked again (the card equivalent
// counts per card).

/// An address as a form submits it.
public struct FakeAddress: Hashable, Sendable {
    public var name: String
    public var street: String
    public var city: String
    public var postalCode: String
    public var country: String
    public var email: String
    public var phone: String

    public init(
        name: String, street: String, city: String, postalCode: String, country: String = "US",
        email: String = "", phone: String = ""
    ) {
        self.name = name
        self.street = street
        self.city = city
        self.postalCode = postalCode
        self.country = country
        self.email = email
        self.phone = phone
    }

    /// Envelope style, like the engine's summary.
    var summary: String {
        [name, street, "\(city) \(postalCode)".trimmingCharacters(in: .whitespaces), country]
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    /// The same person: a submission with other values for a saved name is an update (the fake's
    /// stand-in for Chromium's profile comparison).
    func isSameEntry(as other: FakeAddress) -> Bool {
        name == other.name
    }
}

/// A payment card as a form submits it.
public struct FakeCard: Hashable, Sendable {
    public var number: String
    public var expirationMonth: Int
    public var expirationYear: Int
    public var cardholderName: String
    public var securityCode: String

    public init(number: String, expirationMonth: Int, expirationYear: Int, cardholderName: String = "", securityCode: String = "") {
        self.number = number
        self.expirationMonth = expirationMonth
        self.expirationYear = expirationYear
        self.cardholderName = cardholderName
        self.securityCode = securityCode
    }

    var lastFourDigits: String { String(number.filter(\.isNumber).suffix(4)) }

    /// "MM/YY".
    var expiration: String {
        String(format: "%02d/%02d", expirationMonth, expirationYear % 100)
    }

    /// The network from the number's first digit (enough for the fake).
    var network: String {
        switch number.first {
        case "4": "Visa"
        case "5": "Mastercard"
        case "3": "American Express"
        default: ""
        }
    }
}

/// Saved addresses and cards per profile, shared by every tab of one FakeEngine.
// @unchecked: every mutable stored property is read and written only under `lock`.
public final class FakeAutofillStore: @unchecked Sendable {
    /// Declined new-address offers per site (or declined offers per card) before the engine stops
    /// asking. Chromium's default limit, inferred.
    public static let maximumStrikes = 3

    private let lock = NSLock()
    private var addresses: [Profile.ID: [FakeAddress]] = [:]
    private var cards: [Profile.ID: [FakeCard]] = [:]
    private var siteStrikes: [String: Int] = [:]
    private var cardStrikes: [String: Int] = [:]

    public init() {}

    public func savedAddresses(profileID: Profile.ID) -> [FakeAddress] { lock.withLock { addresses[profileID] ?? [] } }
    public func savedCards(profileID: Profile.ID) -> [FakeCard] { lock.withLock { cards[profileID] ?? [] } }

    func removeAll(profileID: Profile.ID) {
        lock.withLock {
            addresses[profileID] = nil
            cards[profileID] = nil
        }
    }

    /// What submitting `address` offers: nil (nothing to ask), or the saved entry it would update.
    func addressOffer(_ address: FakeAddress, profileID: Profile.ID, site: String) -> (offer: Bool, original: FakeAddress?) {
        lock.withLock {
            let saved = addresses[profileID] ?? []
            if saved.contains(address) { return (false, nil) }
            if let original = saved.first(where: { $0.isSameEntry(as: address) }) { return (true, original) }
            return ((siteStrikes[site] ?? 0) < Self.maximumStrikes, nil)
        }
    }

    func saveAddress(_ address: FakeAddress, replacing original: FakeAddress?, profileID: Profile.ID, site: String) {
        lock.withLock {
            var saved = addresses[profileID] ?? []
            if let original, let index = saved.firstIndex(of: original) {
                saved[index] = address
            } else {
                saved.append(address)
            }
            addresses[profileID] = saved
            siteStrikes[site] = nil
        }
    }

    func declineAddress(site: String, wasUpdate: Bool) {
        guard !wasUpdate else { return }
        lock.withLock { siteStrikes[site, default: 0] += 1 }
    }

    /// What submitting `card` offers: nil when there is nothing to ask.
    func cardOffer(_ card: FakeCard, profileID: Profile.ID) -> CardSavePrompt.Kind? {
        lock.withLock {
            let key = card.number.filter(\.isNumber)
            if let saved = cards[profileID]?.first(where: { $0.number.filter(\.isNumber) == key }) {
                return saved.securityCode.isEmpty && !card.securityCode.isEmpty ? .securityCodeOnly : nil
            }
            guard (cardStrikes[key] ?? 0) < Self.maximumStrikes else { return nil }
            return card.securityCode.isEmpty ? .card : .cardWithSecurityCode
        }
    }

    func saveCard(_ card: FakeCard, profileID: Profile.ID) {
        lock.withLock {
            let key = card.number.filter(\.isNumber)
            var saved = cards[profileID] ?? []
            if let index = saved.firstIndex(where: { $0.number.filter(\.isNumber) == key }) {
                saved[index] = card
            } else {
                saved.append(card)
            }
            cards[profileID] = saved
            cardStrikes[key] = nil
        }
    }

    func strikeCard(_ card: FakeCard) {
        lock.withLock { cardStrikes[card.number.filter(\.isNumber), default: 0] += 1 }
    }
}

/// The kind of form field a fake dropdown is asked for.
public enum FakeAutofillField: Hashable, Sendable {
    case address
    case card
}

import Contacts
import Foundation
import Testing
@testable import Navi

/// The user's own card, for the address / ZIP fields of their own errands.
@Suite struct UserCardTests {
    @Test func theCardBecomesFormFields() {
        let home = CNMutablePostalAddress()
        home.street = "1000 Olin Way\nBox 42"; home.city = "Needham"; home.state = "MA"; home.postalCode = "02492"; home.country = "USA"
        let work = CNMutablePostalAddress()
        work.street = "1 Work St"; work.city = "Boston"
        let f = UserCard.fields(given: "Liam", family: "Carlin", emails: [(CNLabelWork, "l@work.test"), (CNLabelHome, "l@home.test")],
                                phones: [(CNLabelHome, "555-0100"), (CNLabelPhoneNumberMobile, "555-0199")],
                                addresses: [(CNLabelWork, work), (CNLabelHome, home)])
        #expect(f["name"] == "Liam Carlin" && f["email"] == "l@home.test" && f["phone"] == "555-0199")
        #expect(f["address"] == "1000 Olin Way, Box 42, Needham, MA 02492")
        #expect(f["zip"] == "02492" && f["city"] == "Needham" && f["state"] == "MA")
        #expect(UserCard.fields(given: "", family: "", emails: [], phones: [], addresses: []).isEmpty)
        #expect(UserCard.fields().isEmpty)          // under tests: never the real card
    }
}

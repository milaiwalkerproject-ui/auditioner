import XCTest
@testable import Auditioner

/// An `auditioner://audition/new` request (PLAN U1, U1c) that arrives while a sheet is up waits: the
/// open form is left alone (nothing typed is lost), the router keeps the request, and the Auditions
/// tab presents a fresh form with it once the sheet closes. A newer link replaces a waiting one.
/// Made-up orchestra names.
final class AuditionLinkPresentationTests: XCTestCase {

    private func prefill(_ orchestra: String) -> AuditionPrefill {
        var prefill = AuditionPrefill()
        prefill.orchestra = orchestra
        prefill.position = "Section cello"
        return prefill
    }

    func testNothingPendingMeansNothingToDo() {
        XCTAssertEqual(AuditionLinkPresentation.step(pending: nil, sheetIsUp: false), .nothing)
        XCTAssertEqual(AuditionLinkPresentation.step(pending: nil, sheetIsUp: true), .nothing)
    }

    func testAPendingRequestIsPresentedWhenNothingIsUp() {
        let request: AuditionPrefill = prefill("Example Philharmonic")
        XCTAssertEqual(AuditionLinkPresentation.step(pending: request, sheetIsUp: false), .present(request))
        // A bare auditioner://audition/new (empty prefill) still opens a fresh form.
        XCTAssertEqual(AuditionLinkPresentation.step(pending: AuditionPrefill(), sheetIsUp: false), .present(AuditionPrefill()))
    }

    func testASheetThatIsUpIsLeftAloneAndTheRequestWaits() {
        let request: AuditionPrefill = prefill("Example Philharmonic")
        XCTAssertEqual(AuditionLinkPresentation.step(pending: request, sheetIsUp: true), .waitForSheetToClose,
                       "the open form is never closed under the player")
        // Asking again while the sheet is still up (another onChange) changes nothing either.
        XCTAssertEqual(AuditionLinkPresentation.step(pending: request, sheetIsUp: true), .waitForSheetToClose)
        // After the sheet's onDismiss the same request, still pending, is presented.
        XCTAssertEqual(AuditionLinkPresentation.step(pending: request, sheetIsUp: false), .present(request))
    }

    func testTheRouterIsClearedOnlyByTheFormThatShowsTheRequest() {
        let request: AuditionPrefill = prefill("Example Philharmonic")
        XCTAssertTrue(AuditionLinkPresentation.clearsPending(request, shownPrefill: request))
        XCTAssertFalse(AuditionLinkPresentation.clearsPending(request, shownPrefill: AuditionPrefill()),
                       "a form opened from + does not consume a link that arrived meanwhile")
        XCTAssertFalse(AuditionLinkPresentation.clearsPending(request, shownPrefill: prefill("Other Symphony")),
                       "an earlier link's form does not consume a newer request")
        XCTAssertFalse(AuditionLinkPresentation.clearsPending(nil, shownPrefill: request))
    }

    /// The whole dance with the + form already up: the link waits in the router, untouched, through
    /// every ask while the form is open, and is presented only once the player has closed that form.
    func testAPendingLinkSurvivesUntilTheSheetCloses() {
        let request: AuditionPrefill = prefill("Example Philharmonic")
        let router = AppRouter()
        let catalog = CatalogStore(excerpts: [])
        // The + form is up, with nothing prefilled; the player is typing.
        var sheetIsUp: Bool = true
        let typedInForm: AuditionPrefill = AuditionPrefill()

        // 1. The link arrives: the router holds it; onChange finds a sheet up and leaves it alone.
        DeepLinkRouting.follow(.newAudition(request), router: router, catalog: catalog)
        XCTAssertEqual(router.auditionPrefill, request)
        XCTAssertEqual(AuditionLinkPresentation.step(pending: router.auditionPrefill, sheetIsUp: sheetIsUp), .waitForSheetToClose)
        XCTAssertEqual(router.auditionPrefill, request, "waiting does not touch the request")
        // 2. The open form is not the one that shows the request, so it never clears it.
        XCTAssertFalse(AuditionLinkPresentation.clearsPending(router.auditionPrefill, shownPrefill: typedInForm))
        XCTAssertEqual(AuditionLinkPresentation.step(pending: router.auditionPrefill, sheetIsUp: sheetIsUp), .waitForSheetToClose,
                       "still waiting, however often the tab asks while the form is open")
        XCTAssertEqual(router.auditionPrefill, request)
        // 3. The player taps Cancel (or Add): onDismiss finds the request still there and presents it.
        sheetIsUp = false
        guard case .present(let shown) = AuditionLinkPresentation.step(pending: router.auditionPrefill, sheetIsUp: sheetIsUp) else {
            return XCTFail("expected the waiting request to be presented once the sheet closed")
        }
        XCTAssertEqual(shown, request)
        sheetIsUp = true
        // 4. The form showing the request appears: now, and only now, the router forgets it.
        XCTAssertTrue(AuditionLinkPresentation.clearsPending(router.auditionPrefill, shownPrefill: shown))
        router.auditionPrefill = nil
        // 5. That form closes; onDismiss finds nothing more to do.
        sheetIsUp = false
        XCTAssertEqual(AuditionLinkPresentation.step(pending: router.auditionPrefill, sheetIsUp: sheetIsUp), .nothing)
    }

    /// Two links while a form is open: the newest wins; the earlier one is never presented.
    func testANewerLinkReplacesTheOneWaiting() {
        let first: AuditionPrefill = prefill("Example Philharmonic")
        let second: AuditionPrefill = prefill("Other Symphony")
        let router = AppRouter()
        let catalog = CatalogStore(excerpts: [])

        DeepLinkRouting.follow(.newAudition(first), router: router, catalog: catalog)
        XCTAssertEqual(AuditionLinkPresentation.step(pending: router.auditionPrefill, sheetIsUp: true), .waitForSheetToClose)
        DeepLinkRouting.follow(.newAudition(second), router: router, catalog: catalog)
        XCTAssertEqual(router.auditionPrefill, second, "the newest link replaces the one waiting")
        XCTAssertEqual(AuditionLinkPresentation.step(pending: router.auditionPrefill, sheetIsUp: true), .waitForSheetToClose)

        // The sheet closes: the second link's form is presented, and the first link's would not clear it.
        XCTAssertEqual(AuditionLinkPresentation.step(pending: router.auditionPrefill, sheetIsUp: false), .present(second))
        XCTAssertFalse(AuditionLinkPresentation.clearsPending(router.auditionPrefill, shownPrefill: first))
        XCTAssertTrue(AuditionLinkPresentation.clearsPending(router.auditionPrefill, shownPrefill: second))
    }
}

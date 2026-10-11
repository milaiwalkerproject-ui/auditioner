import XCTest
@testable import Auditioner

/// An `auditioner://audition/new` request (PLAN U1) must survive a sheet that is already up: the
/// Auditions tab closes the sheet first and presents a fresh form, and the router keeps the request
/// until a form has actually shown it. Made-up orchestra names.
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

    func testASheetThatIsUpIsClosedFirstAndTheRequestIsKept() {
        let request: AuditionPrefill = prefill("Example Philharmonic")
        XCTAssertEqual(AuditionLinkPresentation.step(pending: request, sheetIsUp: true), .dismissSheetFirst)
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

    func testTheWholeDanceWithAFormAlreadyUp() {
        // The + form is up; a link arrives.
        let request: AuditionPrefill = prefill("Example Philharmonic")
        var pending: AuditionPrefill? = request
        var sheetIsUp: Bool = true
        var shown: AuditionPrefill = AuditionPrefill()

        // 1. onChange(router.auditionPrefill): close the sheet, keep the request.
        XCTAssertEqual(AuditionLinkPresentation.step(pending: pending, sheetIsUp: sheetIsUp), .dismissSheetFirst)
        sheetIsUp = false
        // 2. onDismiss: present a fresh form with the request.
        guard case .present(let toShow) = AuditionLinkPresentation.step(pending: pending, sheetIsUp: sheetIsUp) else {
            return XCTFail("expected the request to be presented after the sheet closed")
        }
        shown = toShow
        sheetIsUp = true
        // 3. The form appears: now, and only now, the router forgets the request.
        XCTAssertTrue(AuditionLinkPresentation.clearsPending(pending, shownPrefill: shown))
        pending = nil
        // 4. The player taps Cancel or Add; onDismiss finds nothing more to do.
        sheetIsUp = false
        XCTAssertEqual(AuditionLinkPresentation.step(pending: pending, sheetIsUp: sheetIsUp), .nothing)
    }
}

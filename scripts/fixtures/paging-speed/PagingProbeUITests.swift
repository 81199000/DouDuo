import XCTest
final class DouDuoUITests: XCTestCase {
 func testRates() throws {
   for mode in ["standard", "fast", "faster"] {
     let app=XCUIApplication();app.launchEnvironment["PROBE_MODE"]=mode;app.launch()
     let scroll=app.scrollViews["probe-scroll"]
     XCTAssertTrue(scroll.waitForExistence(timeout:10));Thread.sleep(forTimeInterval:1)
     for _ in 0..<3 {
       let from=app.coordinate(withNormalizedOffset:CGVector(dx:0.5,dy:0.8))
       let to=app.coordinate(withNormalizedOffset:CGVector(dx:0.5,dy:0.2))
       from.press(forDuration:0.05,thenDragTo:to,withVelocity:XCUIGestureVelocity(rawValue:900),thenHoldForDuration:0)
       Thread.sleep(forTimeInterval:1.2)
       print("PROBE_RESULT \(mode) \(scroll.value ?? "none") current=\(app.staticTexts["current-id"].label)")
     }
     app.terminate()
   }
 }
}

extension DouDuoUITests {
 func testPagingEdgesAndPreference() throws {
  let app=XCUIApplication();app.launchEnvironment["PROBE_MODE"]="faster";app.launch()
  XCTAssertTrue(app.scrollViews["probe-scroll"].waitForExistence(timeout:10))
  let id=app.staticTexts["current-id"]
  func drag(_ from:CGFloat,_ to:CGFloat,_ hold:Double=0, _ velocity:Double=900) {
   app.coordinate(withNormalizedOffset:CGVector(dx:0.5,dy:from)).press(forDuration:0.05,thenDragTo:app.coordinate(withNormalizedOffset:CGVector(dx:0.5,dy:to)),withVelocity:XCUIGestureVelocity(rawValue:velocity),thenHoldForDuration:hold)
   Thread.sleep(forTimeInterval:0.7)
   print("EDGE id=\(id.label) value=\(app.scrollViews["probe-scroll"].value ?? "none")")
  }
  drag(0.4,0.7,0.2);XCTAssertEqual(id.label,"ID=0","first-page overscroll")
  drag(0.6,0.57,0.3,60);XCTAssertEqual(id.label,"ID=0","short slow drag returns")
  drag(0.8,0.2);XCTAssertEqual(id.label,"ID=1")
  drag(0.2,0.8);XCTAssertEqual(id.label,"ID=0","reverse drag")
  drag(0.8,0.2);XCTAssertEqual(id.label,"ID=1")
  app.buttons["standard"].tap();XCTAssertEqual(id.label,"ID=1","turn off preserves page")
  drag(0.8,0.2);XCTAssertEqual(id.label,"ID=2","standard still works")
  app.buttons["faster"].tap();XCTAssertEqual(id.label,"ID=2","turn on preserves page")
  XCUIDevice.shared.orientation = .landscapeLeft
  Thread.sleep(forTimeInterval:1)
  XCTAssertEqual(id.label,"ID=2","rotation preserves page")
  XCUIDevice.shared.orientation = .portrait
  Thread.sleep(forTimeInterval:1)
  XCTAssertEqual(id.label,"ID=2","rotate back preserves page")
  for _ in 0..<9 { drag(0.8,0.2) }
  XCTAssertEqual(id.label,"ID=9","last-page bound")
  drag(0.8,0.2);XCTAssertEqual(id.label,"ID=9","no overshoot at end")
  let shot=XCTAttachment(screenshot:app.screenshot());shot.name="paging-faster-last-page";shot.lifetime = .keepAlways;add(shot)
  app.buttons["fast"].tap()
  app.terminate();app.launchEnvironment.removeValue(forKey:"PROBE_MODE");app.launch()
  XCTAssertTrue(app.scrollViews["probe-scroll"].waitForExistence(timeout:10))
  drag(0.8,0.2)
  XCTAssertTrue(String(describing:app.scrollViews["probe-scroll"].value).contains("offset=874.0"))
  print("PERSIST_RESULT \(app.scrollViews["probe-scroll"].value ?? "none")")
 }
}


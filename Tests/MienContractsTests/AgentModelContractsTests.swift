import MienContracts
import XCTest

final class AgentModelContractsTests: XCTestCase {
  func testCatalogRequiresUniqueOptionsAndItsCurrentModel() throws {
    let catalog = AgentModelCatalog(
      currentModelID: "gpt-primary",
      options: [
        AgentModelOption(id: "gpt-primary", name: "Primary"),
        AgentModelOption(id: "gpt-fast", name: "Fast"),
      ]
    )

    XCTAssertNoThrow(try catalog.validate())
    XCTAssertTrue(catalog.contains("gpt-fast"))
    XCTAssertEqual(catalog.option(for: "gpt-primary")?.name, "Primary")

    XCTAssertThrowsError(
      try AgentModelCatalog(
        currentModelID: "missing",
        options: catalog.options
      ).validate()
    )
    XCTAssertThrowsError(
      try AgentModelCatalog(
        currentModelID: "gpt-primary",
        options: [catalog.options[0], catalog.options[0]]
      ).validate()
    )
  }
}

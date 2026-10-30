import Testing
@testable import AnsiCore

@Test func replacesExtension() {
    var naming = BatchNaming(existing: [])
    #expect(naming.name(for: "LOGO.ANS", fileExtension: "png") == "LOGO.png")
    #expect(naming.name(for: "README", fileExtension: "gif") == "README.gif")
    #expect(naming.name(for: "pack.v2.ice", fileExtension: "html") == "pack.v2.html")
}

@Test func namesNeverCollide() {
    var naming = BatchNaming(existing: ["B.png", "c 2.PNG", "C.png"])
    #expect(naming.name(for: "A.ANS", fileExtension: "png") == "A.png")
    #expect(naming.name(for: "a.ice", fileExtension: "png") == "a 2.png")
    #expect(naming.name(for: "A.XB", fileExtension: "png") == "A 3.png")
    #expect(naming.name(for: "B.ANS", fileExtension: "png") == "B 2.png")
    #expect(naming.name(for: "c.ans", fileExtension: "png") == "c 3.png")
}

@Test func sanitizesSeparators() {
    var naming = BatchNaming(existing: [])
    #expect(naming.name(for: "a/b:c.ans", fileExtension: "png") == "a_b_c.png")
    #expect(naming.name(for: ".hidden.ans", fileExtension: "png") == "_hidden.png")
    #expect(naming.name(for: ".ans", fileExtension: "png") == "_ans.png")
    #expect(naming.name(for: "", fileExtension: "png") == "Untitled.png")
}

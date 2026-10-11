import Foundation

// A small mutable XML tree for editing MusicXML on the device. Foundation's XMLParser reads the
// file (XMLDocument does not exist on iOS); `serialized()` writes it back with the XML declaration
// and the original DOCTYPE. Element order, unknown elements, comments and processing instructions
// are kept. Attribute order is NOT kept (XMLParser hands attributes over as a dictionary); they are
// written sorted by name, which MusicXML readers do not care about.

/// One attribute of an element.
struct MusicXMLAttribute: Equatable {
    var name: String
    var value: String

    init(name: String, value: String) {
        self.name = name
        self.value = value
    }
}

/// A node of the tree.
enum MusicXMLNode {
    case element(MusicXMLElement)
    case text(String)
    case comment(String)
    case processingInstruction(target: String, data: String?)

    var element: MusicXMLElement? {
        if case .element(let e) = self { return e }
        return nil
    }
}

/// A mutable element: name, attributes, ordered children.
final class MusicXMLElement {
    var name: String
    var attributes: [MusicXMLAttribute]
    var children: [MusicXMLNode]

    init(name: String, attributes: [MusicXMLAttribute] = [], children: [MusicXMLNode] = []) {
        self.name = name
        self.attributes = attributes
        self.children = children
    }

    /// An element with a single text child, e.g. `<step>C</step>`.
    convenience init(name: String, text: String) {
        self.init(name: name, attributes: [], children: [.text(text)])
    }

    // MARK: Attributes

    func attribute(_ name: String) -> String? {
        for attribute in attributes where attribute.name == name {
            return attribute.value
        }
        return nil
    }

    /// Sets (or, with `nil`, removes) an attribute.
    func setAttribute(_ name: String, to value: String?) {
        if let index = attributes.firstIndex(where: { $0.name == name }) {
            if let value = value {
                attributes[index].value = value
            } else {
                attributes.remove(at: index)
            }
        } else if let value = value {
            attributes.append(MusicXMLAttribute(name: name, value: value))
        }
    }

    // MARK: Children

    /// Child elements in order (text, comments and processing instructions skipped).
    var childElements: [MusicXMLElement] {
        var result: [MusicXMLElement] = []
        for child in children {
            if case .element(let e) = child { result.append(e) }
        }
        return result
    }

    func firstChild(named name: String) -> MusicXMLElement? {
        for child in children {
            if case .element(let e) = child, e.name == name { return e }
        }
        return nil
    }

    func children(named name: String) -> [MusicXMLElement] {
        var result: [MusicXMLElement] = []
        for child in children {
            if case .element(let e) = child, e.name == name { result.append(e) }
        }
        return result
    }

    /// All text directly inside this element, joined and trimmed.
    var text: String {
        var buffer = ""
        for child in children {
            if case .text(let t) = child { buffer += t }
        }
        return buffer.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Replaces every child with one text node.
    func setText(_ text: String) {
        children = [.text(text)]
    }

    func append(_ element: MusicXMLElement) {
        children.append(.element(element))
    }

    /// Index of a child element in `children` (identity comparison).
    func index(ofChild element: MusicXMLElement) -> Int? {
        for (index, child) in children.enumerated() {
            if case .element(let e) = child, e === element { return index }
        }
        return nil
    }

    /// Inserts at a position in `children` (clamped).
    func insert(_ element: MusicXMLElement, at index: Int) {
        let clamped = max(0, min(children.count, index))
        children.insert(.element(element), at: clamped)
    }

    /// Inserts right after `reference`; appends when `reference` is not a child. Returns `false` in that case.
    @discardableResult
    func insert(_ element: MusicXMLElement, after reference: MusicXMLElement) -> Bool {
        if let index = index(ofChild: reference) {
            children.insert(.element(element), at: index + 1)
            return true
        }
        children.append(.element(element))
        return false
    }

    /// Inserts right before `reference`; appends when `reference` is not a child. Returns `false` in that case.
    @discardableResult
    func insert(_ element: MusicXMLElement, before reference: MusicXMLElement) -> Bool {
        if let index = index(ofChild: reference) {
            children.insert(.element(element), at: index)
            return true
        }
        children.append(.element(element))
        return false
    }

    /// Removes a child element (identity). Returns `false` when it was not a child.
    @discardableResult
    func remove(_ element: MusicXMLElement) -> Bool {
        guard let index = index(ofChild: element) else { return false }
        children.remove(at: index)
        return true
    }

    func removeChildren(named name: String) {
        children.removeAll { node in
            if case .element(let e) = node, e.name == name { return true }
            return false
        }
    }

    /// Every element below this one, depth first, in document order (this element excluded).
    var descendants: [MusicXMLElement] {
        var result: [MusicXMLElement] = []
        collectDescendants(into: &result)
        return result
    }

    private func collectDescendants(into result: inout [MusicXMLElement]) {
        for child in children {
            if case .element(let e) = child {
                result.append(e)
                e.collectDescendants(into: &result)
            }
        }
    }

    /// A deep copy (new element objects all the way down).
    func deepCopy() -> MusicXMLElement {
        var copiedChildren: [MusicXMLNode] = []
        copiedChildren.reserveCapacity(children.count)
        for child in children {
            switch child {
            case .element(let e):
                copiedChildren.append(.element(e.deepCopy()))
            case .text(let t):
                copiedChildren.append(.text(t))
            case .comment(let c):
                copiedChildren.append(.comment(c))
            case .processingInstruction(let target, let data):
                copiedChildren.append(.processingInstruction(target: target, data: data))
            }
        }
        return MusicXMLElement(name: name, attributes: attributes, children: copiedChildren)
    }

    // MARK: Serialization

    func serialize(into output: inout String) {
        output += "<"
        output += name
        for attribute in attributes {
            output += " "
            output += attribute.name
            output += "=\""
            output += MusicXMLEscaping.escapeAttribute(attribute.value)
            output += "\""
        }
        if children.isEmpty {
            output += "/>"
            return
        }
        output += ">"
        for child in children {
            MusicXMLTree.serialize(node: child, into: &output)
        }
        output += "</"
        output += name
        output += ">"
    }
}

enum MusicXMLEscaping {
    static func escapeText(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.utf8.count)
        for character in text {
            switch character {
            case "&": result += "&amp;"
            case "<": result += "&lt;"
            case ">": result += "&gt;"
            default: result.append(character)
            }
        }
        return result
    }

    static func escapeAttribute(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.utf8.count)
        for character in text {
            switch character {
            case "&": result += "&amp;"
            case "<": result += "&lt;"
            case ">": result += "&gt;"
            case "\"": result += "&quot;"
            default: result.append(character)
            }
        }
        return result
    }
}

enum MusicXMLTreeError: Error, LocalizedError, Equatable {
    case malformed(String)
    case empty

    var errorDescription: String? {
        switch self {
        case .malformed(let detail):
            return String(localized: "This MusicXML file couldn't be read (\(detail)).")
        case .empty:
            return String(localized: "This MusicXML file has no content.")
        }
    }
}

/// A parsed MusicXML document: declaration (always rewritten), DOCTYPE (kept verbatim), root element.
final class MusicXMLTree {
    static let declaration = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>"

    var root: MusicXMLElement
    /// The `<!DOCTYPE ...>` line as found in the file, if any.
    var doctype: String?
    /// Comments and processing instructions that came before the root element.
    var prolog: [MusicXMLNode]
    /// Comments and processing instructions that came after the root element.
    var epilog: [MusicXMLNode]

    init(root: MusicXMLElement, doctype: String? = nil, prolog: [MusicXMLNode] = [], epilog: [MusicXMLNode] = []) {
        self.root = root
        self.doctype = doctype
        self.prolog = prolog
        self.epilog = epilog
    }

    // MARK: Parsing

    static func parse(_ xml: String) throws -> MusicXMLTree {
        let tree = try parse(data: Data(xml.utf8))
        tree.doctype = MusicXMLTree.doctype(in: xml)
        return tree
    }

    static func parse(data: Data) throws -> MusicXMLTree {
        let delegate = MusicXMLTreeParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldProcessNamespaces = false
        parser.shouldResolveExternalEntities = false
        parser.shouldReportNamespacePrefixes = false
        let ok = parser.parse()
        if !ok {
            let detail = parser.parserError?.localizedDescription ?? delegate.firstErrorDescription ?? "unknown error"
            throw MusicXMLTreeError.malformed(detail)
        }
        guard let root = delegate.root else {
            throw MusicXMLTreeError.empty
        }
        let tree = MusicXMLTree(root: root, doctype: nil, prolog: delegate.prolog, epilog: delegate.epilog)
        if let text = String(data: data, encoding: .utf8) {
            tree.doctype = MusicXMLTree.doctype(in: text)
        }
        return tree
    }

    /// The `<!DOCTYPE ...>` declaration before the root element, verbatim (internal subsets included).
    static func doctype(in xml: String) -> String? {
        guard let start = xml.range(of: "<!DOCTYPE") else { return nil }
        // It must come before the root element's start tag.
        let before = xml[xml.startIndex..<start.lowerBound]
        var scan = before.startIndex
        while let lt = before[scan...].firstIndex(of: "<") {
            let next = before.index(after: lt)
            if next < before.endIndex {
                let c = before[next]
                if c == "?" || c == "!" {
                    scan = next
                    continue
                }
                return nil   // an element came first
            }
            break
        }
        var depth = 0
        var index = start.lowerBound
        while index < xml.endIndex {
            let c = xml[index]
            if c == "[" {
                depth += 1
            } else if c == "]" {
                depth = max(0, depth - 1)
            } else if c == ">" && depth == 0 {
                return String(xml[start.lowerBound...index])
            }
            index = xml.index(after: index)
        }
        return nil
    }

    // MARK: Serialization

    func serialized() -> String {
        var output = ""
        output += MusicXMLTree.declaration
        output += "\n"
        if let doctype = doctype, !doctype.isEmpty {
            output += doctype
            output += "\n"
        }
        for node in prolog {
            MusicXMLTree.serialize(node: node, into: &output)
            output += "\n"
        }
        root.serialize(into: &output)
        output += "\n"
        for node in epilog {
            MusicXMLTree.serialize(node: node, into: &output)
            output += "\n"
        }
        return output
    }

    static func serialize(node: MusicXMLNode, into output: inout String) {
        switch node {
        case .element(let e):
            e.serialize(into: &output)
        case .text(let t):
            output += MusicXMLEscaping.escapeText(t)
        case .comment(let c):
            output += "<!--"
            output += c
            output += "-->"
        case .processingInstruction(let target, let data):
            output += "<?"
            output += target
            if let data = data, !data.isEmpty {
                output += " "
                output += data
            }
            output += "?>"
        }
    }

    func deepCopy() -> MusicXMLTree {
        MusicXMLTree(root: root.deepCopy(), doctype: doctype, prolog: prolog, epilog: epilog)
    }
}

// MARK: - XMLParser delegate

/// Builds the tree. Text is buffered and flushed when the next structural event arrives.
private final class MusicXMLTreeParser: NSObject, XMLParserDelegate {
    var root: MusicXMLElement?
    var prolog: [MusicXMLNode] = []
    var epilog: [MusicXMLNode] = []
    var firstErrorDescription: String?

    private var stack: [MusicXMLElement] = []
    private var textBuffer: String = ""
    private var rootClosed = false

    private func flushText() {
        guard !textBuffer.isEmpty else { return }
        if let current = stack.last {
            current.children.append(.text(textBuffer))
        }
        textBuffer = ""
    }

    private func appendOutsideRoot(_ node: MusicXMLNode) {
        if rootClosed {
            epilog.append(node)
        } else {
            prolog.append(node)
        }
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        flushText()
        let sortedAttributes: [MusicXMLAttribute] = attributeDict.keys.sorted().map { key in
            MusicXMLAttribute(name: key, value: attributeDict[key] ?? "")
        }
        let element = MusicXMLElement(name: elementName, attributes: sortedAttributes, children: [])
        if let parent = stack.last {
            parent.children.append(.element(element))
        } else if root == nil {
            root = element
        }
        stack.append(element)
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        flushText()
        if !stack.isEmpty {
            stack.removeLast()
        }
        if stack.isEmpty {
            rootClosed = true
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard !stack.isEmpty else { return }
        textBuffer += string
    }

    func parser(_ parser: XMLParser, foundIgnorableWhitespace whitespaceString: String) {
        guard !stack.isEmpty else { return }
        textBuffer += whitespaceString
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        guard !stack.isEmpty else { return }
        if let text = String(data: CDATABlock, encoding: .utf8) {
            textBuffer += text
        }
    }

    func parser(_ parser: XMLParser, foundComment comment: String) {
        flushText()
        if let current = stack.last {
            current.children.append(.comment(comment))
        } else {
            appendOutsideRoot(.comment(comment))
        }
    }

    func parser(_ parser: XMLParser, foundProcessingInstructionWithTarget target: String, data: String?) {
        flushText()
        let node: MusicXMLNode = .processingInstruction(target: target, data: data)
        if let current = stack.last {
            current.children.append(node)
        } else {
            appendOutsideRoot(node)
        }
    }

    func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) {
        if firstErrorDescription == nil {
            firstErrorDescription = parseError.localizedDescription
        }
    }
}

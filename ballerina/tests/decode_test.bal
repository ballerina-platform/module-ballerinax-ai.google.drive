// Copyright (c) 2026, WSO2 LLC. (http://www.wso2.com).
//
// WSO2 LLC. licenses this file to you under the Apache License,
// Version 2.0 (the "License"); you may not use this file except
// in compliance with the License.
// You may obtain a copy of the License at
//
// http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing,
// software distributed under the License is distributed on an
// "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
// KIND, either express or implied.  See the License for the
// specific language governing permissions and limitations
// under the License.

import ballerina/ai;
import ballerina/test;

// ---- BOM handling ------------------------------------------------------------
// REGRESSION: a leading U+FEFF used to be decoded into the document body, corrupting the
// first CSV header cell / first Markdown heading and polluting every embedding.

@test:Config {}
isolated function testDecodeStripsUtf8Bom() returns error? {
    byte[] withBom = [0xEF, 0xBB, 0xBF, ...("hello".toBytes())];
    string text = check decodeText(withBom, "");
    test:assertEquals(text, "hello", "the UTF-8 BOM must not reach the content");
    test:assertEquals(text.length(), 5, "5 characters, not 6 (a retained BOM counts as one)");
}

@test:Config {}
isolated function testDecodeUtf16LeWithBom() returns error? {
    // "hi" in UTF-16LE, BOM first. Previously a hard failure: not valid UTF-8.
    byte[] utf16le = [0xFF, 0xFE, 0x68, 0x00, 0x69, 0x00];
    test:assertEquals(check decodeText(utf16le, ""), "hi");
}

@test:Config {}
isolated function testDecodeUtf16BeWithBom() returns error? {
    byte[] utf16be = [0xFE, 0xFF, 0x00, 0x68, 0x00, 0x69];
    test:assertEquals(check decodeText(utf16be, ""), "hi");
}

@test:Config {}
isolated function testBomWinsOverDeclaredCharset() returns error? {
    // A BOM is self-describing, so it outranks a contradicting declared charset.
    byte[] utf16le = [0xFF, 0xFE, 0x68, 0x00, 0x69, 0x00];
    test:assertEquals(check decodeText(utf16le, "ISO-8859-1"), "hi");
}

// ---- declared charset --------------------------------------------------------

@test:Config {}
isolated function testDecodeHonoursDeclaredCharset() returns error? {
    // "café" in ISO-8859-1: the trailing 0xE9 is not valid UTF-8 on its own.
    byte[] latin1 = [0x63, 0x61, 0x66, 0xE9];
    test:assertEquals(check decodeText(latin1, "ISO-8859-1"), "café");
}

@test:Config {}
isolated function testDecodeWithoutCharsetIsStrictUtf8() {
    // The same bytes with no declared charset are genuinely undecodable, and must still
    // error rather than silently yielding replacement characters.
    byte[] latin1 = [0x63, 0x61, 0x66, 0xE9];
    test:assertTrue(decodeText(latin1, "") is error, "invalid UTF-8 with no charset is an error");
}

@test:Config {}
isolated function testDecodeUnknownCharsetFallsBackToUtf8() returns error? {
    // A charset this JVM does not know must not break the load; fall back to UTF-8.
    test:assertEquals(check decodeText("plain text".toBytes(), "x-not-a-real-charset"), "plain text");
}

@test:Config {}
isolated function testDecodePlainUtf8Unchanged() returns error? {
    test:assertEquals(check decodeText("héllo wörld".toBytes(), "UTF-8"), "héllo wörld");
}

// ---- charsetFromContentType --------------------------------------------------

@test:Config {}
isolated function testCharsetFromContentType() {
    test:assertEquals(charsetFromContentType("text/plain; charset=UTF-8"), "UTF-8");
    test:assertEquals(charsetFromContentType("text/csv;charset=UTF-16LE"), "UTF-16LE");
    test:assertEquals(charsetFromContentType("text/plain; charset=\"ISO-8859-1\"; foo=bar"),
            "ISO-8859-1", "quotes and trailing parameters are stripped");
    test:assertEquals(charsetFromContentType("text/plain"), "", "no charset parameter yields \"\"");
    test:assertEquals(charsetFromContentType(""), "");
}

@test:Config {}
isolated function testBuildDocumentUsesCharsetFromContentType() returns error? {
    // End to end: this is the shape `fetchAndBuild` passes from `FileContent.mimeType`.
    byte[] latin1 = [0x63, 0x61, 0x66, 0xE9];
    ai:Metadata metadata = {fileName: "notes.txt", mimeType: "text/plain"};
    ai:TextDocument doc = check buildDocument(latin1, TEXT_DOWNLOAD, metadata,
            "text/plain; charset=ISO-8859-1");
    test:assertEquals(doc.content, "café");
}

@test:Config {}
isolated function testBuildDocumentStripsBomFromCsv() returns error? {
    // Excel-exported CSVs almost always carry a UTF-8 BOM; it must not corrupt the header.
    byte[] csv = [0xEF, 0xBB, 0xBF, ...("name,amount\nrent,1200\n".toBytes())];
    ai:Metadata metadata = {fileName: "budget.csv", mimeType: "text/csv"};
    ai:TextDocument doc = check buildDocument(csv, TEXT_DOWNLOAD, metadata, "text/csv");
    test:assertTrue(doc.content.startsWith("name,amount"),
            "the first header cell must be intact: " + doc.content);
}

// ---- HTML rendering ----------------------------------------------------------
// REGRESSION: html/htm classify as plain text, so raw markup and undecoded entities used
// to land in the document body and pollute every embedding.

@test:Config {}
isolated function testHtmlToTextStripsTagsAndDecodesEntities() {
    string rendered = htmlToText("<html><body><h1>Title</h1><p>Body &amp; text</p></body></html>");
    test:assertTrue(rendered.includes("Title"), rendered);
    test:assertTrue(rendered.includes("Body & text"), "entities are resolved: " + rendered);
    test:assertFalse(rendered.includes("<"), "no markup survives: " + rendered);
    test:assertFalse(rendered.includes("&amp;"), "no undecoded entity survives: " + rendered);
}

@test:Config {}
isolated function testHtmlToTextDropsScriptAndStyleBodies() {
    string rendered = htmlToText(
        "<style>.a{color:red}</style><p>Real text</p><script>var x = 1 < 2;</script>");
    test:assertTrue(rendered.includes("Real text"), rendered);
    test:assertFalse(rendered.includes("color:red"), "style bodies are dropped: " + rendered);
    test:assertFalse(rendered.includes("var x"), "script bodies are dropped: " + rendered);
}

@test:Config {}
isolated function testHtmlToTextSeparatesBlocks() {
    // Without a block boundary these two words would run together as "OneTwo".
    string rendered = htmlToText("<p>One</p><p>Two</p>");
    test:assertFalse(rendered.includes("OneTwo"), "block boundaries separate text: " + rendered);
    test:assertTrue(rendered.includes("One") && rendered.includes("Two"), rendered);
}

@test:Config {}
isolated function testHtmlToTextResolvesNumericEntities() {
    string rendered = htmlToText("<p>caf&#233; &#x26; bar</p>");
    test:assertTrue(rendered.includes("café"), rendered);
    test:assertTrue(rendered.includes("&"), rendered);
}

@test:Config {}
isolated function testBuildDocumentHtmlIsRendered() returns error? {
    byte[] html = "<html><body><h1>Report</h1><p>Q3 &amp; Q4</p></body></html>".toBytes();
    ai:Metadata metadata = {fileName: "report.html", mimeType: "text/html"};
    ai:TextDocument doc = check buildDocument(html, TEXT_DOWNLOAD, metadata, "text/html");
    test:assertTrue(doc.content.includes("Report"), doc.content);
    test:assertTrue(doc.content.includes("Q3 & Q4"), doc.content);
    test:assertFalse(doc.content.includes("<h1>"), "raw markup must not reach the body: " + doc.content);
}

@test:Config {}
isolated function testBuildDocumentPlainTextIsNotHtmlRendered() returns error? {
    // A .txt file that happens to contain angle brackets must be preserved verbatim.
    byte[] text = "use <cmd> to run".toBytes();
    ai:Metadata metadata = {fileName: "readme.txt", mimeType: "text/plain"};
    ai:TextDocument doc = check buildDocument(text, TEXT_DOWNLOAD, metadata, "text/plain");
    test:assertEquals(doc.content, "use <cmd> to run", "non-HTML text is never de-tagged");
}

@test:Config {}
isolated function testIsHtml() {
    test:assertTrue(isHtml("text/html", "page.html"));
    test:assertTrue(isHtml("text/html; charset=utf-8", "page"), "parameters do not matter");
    test:assertTrue(isHtml("application/xhtml+xml", "page.xhtml"));
    test:assertTrue(isHtml("", "page.htm"), "the extension decides when there is no MIME type");
    test:assertTrue(isHtml("application/octet-stream", "page.html"), "a generic type falls back");
    test:assertFalse(isHtml("text/plain", "notes.txt"));
    test:assertFalse(isHtml("text/plain", "page.html"), "an explicit non-HTML type wins");
    test:assertFalse(isHtml("", "notes.txt"));
}

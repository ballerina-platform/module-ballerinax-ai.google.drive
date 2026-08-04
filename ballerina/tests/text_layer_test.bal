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

// ---- extractText (native Apache Tika) ----------------------------------------

@test:Config {}
isolated function testExtractTextFromPdfBytes() returns error? {
    string text = check extractText(PDF_BYTES, "sample.pdf", MIME_PDF);
    test:assertTrue(text.includes(PDF_TEXT), text);
}

// ---- extractText: Microsoft Office (POI), one real extraction per format ------

@test:Config {}
isolated function testExtractTextFromDocxBytes() returns error? {
    string text = check extractText(DOCX_BYTES, "office-fixture.docx", MIME_DOCX);
    test:assertTrue(text.includes(DOCX_TEXT), text);
}

@test:Config {}
isolated function testExtractTextFromXlsxBytes() returns error? {
    string text = check extractText(XLSX_BYTES, "office-report.xlsx", MIME_XLSX);
    test:assertTrue(text.includes(XLSX_TEXT), text);
}

@test:Config {}
isolated function testExtractTextFromPptxBytes() returns error? {
    string text = check extractText(PPTX_BYTES, "office-report.pptx", MIME_PPTX);
    test:assertTrue(text.includes(PPTX_TEXT), text);
}

@test:Config {}
isolated function testExtractTextFromXlsBytes() returns error? {
    string text = check extractText(XLS_BYTES, "office-legacy.xls", MIME_XLS);
    test:assertTrue(text.includes(XLS_TEXT), text);
}

@test:Config {}
isolated function testExtractTextFromPptBytes() returns error? {
    string text = check extractText(PPT_BYTES, "office-legacy.ppt", MIME_PPT);
    test:assertTrue(text.includes(PPT_TEXT), text);
}

@test:Config {}
isolated function testExtractTextFromDocBytes() returns error? {
    // `.doc` was advertised in EXTRACTABLE_EXTENSIONS/MIME_TYPES but had no fixture, so POI's
    // HWPF path — distinct from HSSF (.xls) and HSLF (.ppt) — had never been exercised.
    string text = check extractText(DOC_BYTES, "office-legacy.doc", MIME_DOC);
    test:assertTrue(text.includes(DOC_TEXT), text);
}

@test:Config {}
isolated function testExtractTextFromDocWithNoExtension() returns error? {
    string text = check extractText(DOC_BYTES, "Legacy Memo", MIME_DOC);
    test:assertTrue(text.includes(DOC_TEXT), text);
}

// ---- REGRESSION: parser selection follows the MIME type, not the extension ----
// `classify` treats the Drive MIME type as authoritative, so the extractor must too.
// Previously `selectParser` looked only at the file-name suffix, which meant every
// MIME-classified Office/PDF file whose name lacked (or contradicted) the matching
// extension was handed to the wrong parser and always failed.

@test:Config {}
isolated function testExtractTextFromDocxWithNoExtension() returns error? {
    // Renaming a file in the Drive web UI drops the extension; the MIME type still says DOCX.
    string text = check extractText(DOCX_BYTES, "Q3 Report", MIME_DOCX);
    test:assertTrue(text.includes(DOCX_TEXT), text);
}

@test:Config {}
isolated function testExtractTextFromLegacyXlsWithNoExtension() returns error? {
    string text = check extractText(XLS_BYTES, "Legacy Sheet", MIME_XLS);
    test:assertTrue(text.includes(XLS_TEXT), text);
}

@test:Config {}
isolated function testExtractTextFromPdfNamedAsDocx() returns error? {
    // A misnamed file: the extension says OOXML, the MIME type says PDF. The MIME type wins.
    string text = check extractText(PDF_BYTES, "report.docx", MIME_PDF);
    test:assertTrue(text.includes(PDF_TEXT), text);
}

@test:Config {}
isolated function testExtractTextFallsBackToExtensionWithoutMimeType() returns error? {
    // No MIME type at all: the extension is still honoured, as before.
    string text = check extractText(DOCX_BYTES, "office-fixture.docx", "");
    test:assertTrue(text.includes(DOCX_TEXT), text);
}

@test:Config {}
isolated function testExtractTextFallsBackToExtensionForGenericMimeType() returns error? {
    // Drive reports application/octet-stream for blobs it cannot type; fall back to the name.
    string text = check extractText(PPTX_BYTES, "office-report.pptx", "application/octet-stream");
    test:assertTrue(text.includes(PPTX_TEXT), text);
}

@test:Config {}
isolated function testExtractTextIgnoresMimeTypeParameters() returns error? {
    // A MIME type carrying parameters still matches on its base type.
    string text = check extractText(PDF_BYTES, "no-extension", MIME_PDF + "; charset=binary");
    test:assertTrue(text.includes(PDF_TEXT), text);
}

@test:Config {}
isolated function testBuildDocumentExtensionlessDocxExtractsText() returns error? {
    // End to end through buildDocument: this is the shape `classify` produces for an
    // extension-less DOCX, and it previously failed with a PDFBox trailer error.
    ai:Metadata metadata = {fileName: "Q3 Report", mimeType: MIME_DOCX};
    ai:TextDocument doc = check buildDocument(DOCX_BYTES, EXTRACT_DOWNLOAD, metadata);
    test:assertTrue(doc.content.includes(DOCX_TEXT), doc.content);
}

// ---- text-less PDF detection (scanned/image-only AND genuinely blank) ---------

@test:Config {}
isolated function testExtractTextFromScannedPdfErrors() {
    // The scanned fixture parses fine but has no text layer; the extractor must surface
    // a descriptive error rather than silently returning an empty string.
    string|error text = extractText(SCANNED_PDF_BYTES, "scan.pdf", MIME_PDF);
    if text is error {
        test:assertTrue(isTextlessPdfError(text), text.message());
        test:assertTrue(text.message().includes("no extractable text"),
                "the message stays human-readable: " + text.message());
    } else {
        test:assertFail("A scanned (image-only) PDF should surface a descriptive error");
    }
}

@test:Config {}
isolated function testExtractTextFromBlankPdfErrors() {
    // A genuinely blank PDF (empty content stream — no text, no images) yields the same
    // neutral error: the loader cannot tell "scan" from "blank" without OCR, and both are
    // equally unusable as text.
    string|error text = extractText(BLANK_PDF_BYTES, "blank.pdf", MIME_PDF);
    if text is error {
        test:assertTrue(isTextlessPdfError(text), text.message());
    } else {
        test:assertFail("A blank PDF should surface a descriptive error, not an empty document");
    }
}

@test:Config {}
isolated function testBuildDocumentTextlessPdfErrors() {
    ai:Metadata metadata = {fileName: "scan.pdf", mimeType: "application/pdf"};
    ai:TextDocument|ai:Error result = buildDocument(SCANNED_PDF_BYTES, EXTRACT_DOWNLOAD, metadata);
    if result is ai:Error {
        // The reason travels on the CAUSE here: buildDocument wraps the native error.
        test:assertTrue(isTextlessPdfError(result), "The error must be recognisable as text-less PDF");
        test:assertTrue(result.message().includes("no extractable text"), result.message());
    } else {
        test:assertFail("Building a document from a text-less PDF should error, not skip or succeed");
    }
}

@test:Config {}
isolated function testIsTextlessPdfErrorRejectsOtherErrors() {
    test:assertFalse(isTextlessPdfError(error("some unrelated extraction failure")));
    test:assertFalse(isTextlessPdfError(error("Failed to decode text content")));
}

@test:Config {}
isolated function testIsTextlessPdfErrorIgnoresTheMessageText() {
    // REGRESSION: classification used to be `err.message().includes("no extractable text")`,
    // so any unrelated error whose message happened to contain that phrase was silently
    // treated as a skippable text-less PDF. Only the structured `reason` detail counts now.
    error lookalike = error("the archive has no extractable text entries");
    test:assertFalse(isTextlessPdfError(lookalike),
            "a message that merely contains the phrase is not a text-less PDF");
}

@test:Config {}
isolated function testIsTextlessPdfErrorMatchesTheStructuredReason() {
    // Conversely, the reason alone is sufficient — no particular wording required.
    error structured = error("wholly different wording", reason = TEXTLESS_PDF_REASON);
    test:assertTrue(isTextlessPdfError(structured), "the structured reason is what classifies");
    test:assertTrue(isTextlessPdfError(error("wrapped", structured)),
            "and it is found through the cause chain");
}

@test:Config {}
isolated function testTextlessDetectionDoesNotAffectExportLane() returns error? {
    // REGRESSION: the detection lives in the PDF (download+extract) lane only. An exported
    // Google Doc is DECODED, never parsed by PDFBox — so even an EMPTY export builds an
    // (empty) document rather than triggering the text-less-PDF error.
    ai:Metadata metadata = {fileName: "Empty Google Doc", mimeType: GOOGLE_DOC_MIME};
    ai:TextDocument doc = check buildDocument([], WORKSPACE_TEXT, metadata);
    test:assertEquals(doc.content, "", "An empty export decodes to an empty document, not an error");
}

// ---- buildDocument: plain-text / decode path ---------------------------------

@test:Config {}
isolated function testBuildDocumentPlainTextDecode() returns error? {
    byte[] bytes = "hello world".toBytes();
    ai:Metadata metadata = {fileName: "greeting.txt", mimeType: "text/plain", fileSize: 11};
    ai:TextDocument doc = check buildDocument(bytes, TEXT_DOWNLOAD, metadata);
    test:assertEquals(doc.content, "hello world");
    test:assertEquals(doc.metadata?.fileName, "greeting.txt");
    test:assertEquals(doc.metadata?.mimeType, "text/plain");
    test:assertEquals(doc.metadata?.fileSize, <decimal>11);
}

@test:Config {}
isolated function testBuildDocumentWorkspaceTextDecode() returns error? {
    // A Google Doc exported to text/plain is decoded verbatim (same path as a .txt download).
    byte[] bytes = "Exported Google Doc body".toBytes();
    ai:Metadata metadata = {fileName: "My Doc", mimeType: GOOGLE_DOC_MIME};
    ai:TextDocument doc = check buildDocument(bytes, WORKSPACE_TEXT, metadata);
    test:assertEquals(doc.content, "Exported Google Doc body");
    test:assertEquals(doc.metadata?.mimeType, GOOGLE_DOC_MIME, "The ORIGINAL Drive MIME type is retained");
}

@test:Config {}
isolated function testBuildDocumentWorkspaceCsvDecode() returns error? {
    byte[] bytes = "name,amount\nrent,1200\n".toBytes();
    ai:Metadata metadata = {fileName: "Budget", mimeType: GOOGLE_SHEET_MIME};
    ai:TextDocument doc = check buildDocument(bytes, WORKSPACE_CSV, metadata);
    test:assertTrue(doc.content.includes("rent,1200"));
}

@test:Config {}
isolated function testBuildDocumentInvalidUtf8Errors() {
    // 0xFF is not a valid UTF-8 start byte, so decoding a "text" blob fails.
    byte[] invalid = [255, 254, 253];
    ai:Metadata metadata = {fileName: "broken.txt"};
    ai:TextDocument|ai:Error result = buildDocument(invalid, TEXT_DOWNLOAD, metadata);
    if result is ai:Error {
        test:assertTrue(result.message().includes("Failed to decode text"), result.message());
    } else {
        test:assertFail("Invalid UTF-8 text content should surface as an error");
    }
}

// ---- buildDocument: PDF (extractable) path -----------------------------------

@test:Config {}
isolated function testBuildDocumentPdfExtractsText() returns error? {
    ai:Metadata metadata = {fileName: "report.pdf", mimeType: "application/pdf", fileSize: 123};
    ai:TextDocument doc = check buildDocument(PDF_BYTES, EXTRACT_DOWNLOAD, metadata);
    test:assertTrue(doc.content.includes(PDF_TEXT), doc.content);
    test:assertEquals(doc.metadata?.fileName, "report.pdf");
    test:assertEquals(doc.metadata?.mimeType, "application/pdf");
}

@test:Config {}
isolated function testBuildDocumentDocxExtractsText() returns error? {
    // An uploaded .docx goes through the same download+Tika lane as a PDF, but the native
    // extractor selects POI's OOXML parser from the extension.
    ai:Metadata metadata = {
        fileName: "office-fixture.docx",
        mimeType: "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
    };
    ai:TextDocument doc = check buildDocument(DOCX_BYTES, EXTRACT_DOWNLOAD, metadata);
    test:assertTrue(doc.content.includes(DOCX_TEXT), doc.content);
    test:assertEquals(doc.metadata?.fileName, "office-fixture.docx");
}

@test:Config {}
isolated function testBuildDocumentPdfExtractFailureErrors() {
    // Not a PDF: Tika fails to parse, and the error is wrapped with the file name.
    byte[] notAPdf = "this is definitely not a pdf".toBytes();
    ai:Metadata metadata = {fileName: "fake.pdf"};
    ai:TextDocument|ai:Error result = buildDocument(notAPdf, EXTRACT_DOWNLOAD, metadata);
    if result is ai:Error {
        test:assertTrue(result.message().includes("Failed to extract text from 'fake.pdf'"), result.message());
    } else {
        test:assertFail("A non-PDF routed to the extraction path should surface an error");
    }
}

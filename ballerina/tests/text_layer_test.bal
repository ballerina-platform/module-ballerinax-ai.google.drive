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
    string text = check extractText(PDF_BYTES, "sample.pdf");
    test:assertTrue(text.includes(PDF_TEXT), text);
}

// ---- extractText: Microsoft Office (POI), one real extraction per format ------

@test:Config {}
isolated function testExtractTextFromDocxBytes() returns error? {
    string text = check extractText(DOCX_BYTES, "office-fixture.docx");
    test:assertTrue(text.includes(DOCX_TEXT), text);
}

@test:Config {}
isolated function testExtractTextFromXlsxBytes() returns error? {
    string text = check extractText(XLSX_BYTES, "office-report.xlsx");
    test:assertTrue(text.includes(XLSX_TEXT), text);
}

@test:Config {}
isolated function testExtractTextFromPptxBytes() returns error? {
    string text = check extractText(PPTX_BYTES, "office-report.pptx");
    test:assertTrue(text.includes(PPTX_TEXT), text);
}

@test:Config {}
isolated function testExtractTextFromXlsBytes() returns error? {
    string text = check extractText(XLS_BYTES, "office-legacy.xls");
    test:assertTrue(text.includes(XLS_TEXT), text);
}

@test:Config {}
isolated function testExtractTextFromPptBytes() returns error? {
    string text = check extractText(PPT_BYTES, "office-legacy.ppt");
    test:assertTrue(text.includes(PPT_TEXT), text);
}

// ---- text-less PDF detection (scanned/image-only AND genuinely blank) ---------

@test:Config {}
isolated function testExtractTextFromScannedPdfErrors() {
    // The scanned fixture parses fine but has no text layer; the extractor must surface
    // a descriptive error rather than silently returning an empty string.
    string|error text = extractText(SCANNED_PDF_BYTES, "scan.pdf");
    if text is error {
        test:assertTrue(text.message().includes(TEXTLESS_PDF_SENTINEL), text.message());
    } else {
        test:assertFail("A scanned (image-only) PDF should surface a descriptive error");
    }
}

@test:Config {}
isolated function testExtractTextFromBlankPdfErrors() {
    // A genuinely blank PDF (empty content stream — no text, no images) yields the same
    // neutral error: the loader cannot tell "scan" from "blank" without OCR, and both are
    // equally unusable as text.
    string|error text = extractText(BLANK_PDF_BYTES, "blank.pdf");
    if text is error {
        test:assertTrue(text.message().includes(TEXTLESS_PDF_SENTINEL), text.message());
    } else {
        test:assertFail("A blank PDF should surface a descriptive error, not an empty document");
    }
}

@test:Config {}
isolated function testBuildDocumentTextlessPdfErrors() {
    ai:Metadata metadata = {fileName: "scan.pdf", mimeType: "application/pdf"};
    ai:TextDocument|ai:Error result = buildDocument(SCANNED_PDF_BYTES, EXTRACT_DOWNLOAD, metadata);
    if result is ai:Error {
        test:assertTrue(result.message().includes(TEXTLESS_PDF_SENTINEL), result.message());
        test:assertTrue(isTextlessPdfError(result), "The error must be recognisable as text-less PDF");
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

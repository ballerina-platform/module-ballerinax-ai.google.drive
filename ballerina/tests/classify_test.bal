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

import ballerina/test;

// ---- getExtension ------------------------------------------------------------

@test:Config {}
isolated function testGetExtensionBasic() {
    test:assertEquals(getExtension("report.pdf"), "pdf");
    test:assertEquals(getExtension("notes.TXT"), "txt", "Extension is lower-cased");
    test:assertEquals(getExtension("archive.tar.gz"), "gz", "Only the last extension is used");
}

@test:Config {}
isolated function testGetExtensionNoDot() {
    test:assertEquals(getExtension("README"), "", "No dot yields an empty extension");
    test:assertEquals(getExtension("My Google Doc"), "", "A Workspace file has no extension");
}

// ---- classify: ordinary binary files -----------------------------------------

@test:Config {}
isolated function testClassifyPlainTextByExtension() {
    test:assertEquals(classify((), "a.txt"), TEXT_DOWNLOAD);
    test:assertEquals(classify((), "a.md"), TEXT_DOWNLOAD);
    test:assertEquals(classify((), "a.json"), TEXT_DOWNLOAD);
    test:assertEquals(classify((), "a.csv"), TEXT_DOWNLOAD);
    test:assertEquals(classify((), "a.html"), TEXT_DOWNLOAD);
}

@test:Config {}
isolated function testClassifyPlainTextByMimeType() {
    test:assertEquals(classify("text/plain", "noext"), TEXT_DOWNLOAD, "Any text/* MIME is plain text");
    test:assertEquals(classify("application/json", "data"), TEXT_DOWNLOAD);
    // MIME wins even when the extension is unknown.
    test:assertEquals(classify("text/markdown", "weird.bin"), TEXT_DOWNLOAD);
}

@test:Config {}
isolated function testClassifyExtractablePdf() {
    test:assertEquals(classify((), "doc.pdf"), EXTRACT_DOWNLOAD);
    test:assertEquals(classify("application/pdf", "noext"), EXTRACT_DOWNLOAD);
}

@test:Config {}
isolated function testClassifyExtractableOfficeByExtension() {
    // Uploaded Microsoft Office documents are downloaded and extracted via Apache Tika
    // (POI), same as PDFs — all six extensions.
    test:assertEquals(classify((), "a.docx"), EXTRACT_DOWNLOAD);
    test:assertEquals(classify((), "a.pptx"), EXTRACT_DOWNLOAD);
    test:assertEquals(classify((), "a.xlsx"), EXTRACT_DOWNLOAD);
    test:assertEquals(classify((), "a.doc"), EXTRACT_DOWNLOAD);
    test:assertEquals(classify((), "a.ppt"), EXTRACT_DOWNLOAD);
    test:assertEquals(classify((), "a.xls"), EXTRACT_DOWNLOAD);
}

@test:Config {}
isolated function testClassifyExtractableOfficeByMimeType() {
    // Drive reports a real MIME type for uploaded files, so the MIME branch is primary —
    // all six Office MIME types route to the Tika/POI lane even without an extension.
    test:assertEquals(classify("application/msword", "legacy word"), EXTRACT_DOWNLOAD);
    test:assertEquals(classify("application/vnd.openxmlformats-officedocument.wordprocessingml.document",
        "word upload"), EXTRACT_DOWNLOAD);
    test:assertEquals(classify("application/vnd.ms-powerpoint", "legacy slides"), EXTRACT_DOWNLOAD);
    test:assertEquals(classify("application/vnd.openxmlformats-officedocument.presentationml.presentation",
        "slides upload"), EXTRACT_DOWNLOAD);
    test:assertEquals(classify("application/vnd.ms-excel", "legacy sheet"), EXTRACT_DOWNLOAD);
    test:assertEquals(classify("application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
        "sheet upload"), EXTRACT_DOWNLOAD);
}

@test:Config {}
isolated function testGoogleNativesNeverReachThePoiLane() {
    // REGRESSION-CRITICAL lane separation: a Google Doc/Sheet/Slides is a Workspace NATIVE
    // (exported via exportFile), not an uploaded Office file — it must classify to the
    // EXPORT lane even though it is conceptually "a document/spreadsheet/presentation".
    test:assertEquals(classify(GOOGLE_DOC_MIME, "Quarterly Report"), WORKSPACE_TEXT,
        "A Google Doc must export, never route to POI");
    test:assertEquals(classify(GOOGLE_SHEET_MIME, "Budget"), WORKSPACE_CSV,
        "A Google Sheet must export, never route to POI");
    test:assertEquals(classify(GOOGLE_SLIDES_MIME, "Kickoff Deck"), WORKSPACE_TEXT,
        "A Google Slides deck must export, never route to POI");
    // Even a Workspace file whose NAME looks like an Office file stays in the export lane:
    // the google-apps MIME type is checked before any extension fallback.
    test:assertEquals(classify(GOOGLE_DOC_MIME, "report.docx"), WORKSPACE_TEXT,
        "The google-apps MIME type wins over an Office-looking name");
}

@test:Config {}
isolated function testRecognisedMimeWinsOverExtension() {
    // Drive lets a file be renamed without touching its MIME type, so a recognised MIME type
    // must settle the class before the extension is ever consulted. Consulting the extension
    // first would UTF-8 decode these binaries and yield mojibake instead of extracted text.
    test:assertEquals(classify("application/pdf", "notes.txt"), EXTRACT_DOWNLOAD,
        "A PDF renamed to .txt must still be Tika-extracted");
    test:assertEquals(classify("application/vnd.openxmlformats-officedocument.wordprocessingml.document",
            "readme.md"), EXTRACT_DOWNLOAD, "A .docx renamed to .md must still be Tika-extracted");
    // The converse: a text MIME type is not dragged into the Tika lane by an Office-looking name.
    test:assertEquals(classify("text/plain", "report.docx"), TEXT_DOWNLOAD,
        "A text/plain file renamed to .docx must still be decoded");
}

@test:Config {}
isolated function testExtensionFallbackAppliesOnlyToUnknownMime() {
    // A missing or generic MIME type is exactly when the extension is worth trusting.
    test:assertEquals(classify((), "report.pdf"), EXTRACT_DOWNLOAD);
    test:assertEquals(classify("application/octet-stream", "report.pdf"), EXTRACT_DOWNLOAD,
        "A generic MIME type falls through to the extension");
    test:assertEquals(classify("application/octet-stream", "notes.txt"), TEXT_DOWNLOAD);
}

@test:Config {}
isolated function testClassifyUnsupportedBinary() {
    test:assertEquals(classify("image/png", "photo.png"), UNSUPPORTED);
    test:assertEquals(classify("audio/mpeg", "clip.mp3"), UNSUPPORTED);
    test:assertEquals(classify((), "noextension"), UNSUPPORTED);
    test:assertEquals(classify("application/octet-stream", "blob"), UNSUPPORTED);
}

// ---- classify: Google Workspace native files (export routing) ----------------

@test:Config {}
isolated function testClassifyGoogleDocAndSlidesExportAsText() {
    // A Google Doc has no extension and no downloadable bytes; the MIME type routes it to
    // the export-as-text/plain path. Slides behave the same way.
    test:assertEquals(classify(GOOGLE_DOC_MIME, "Quarterly Report"), WORKSPACE_TEXT);
    test:assertEquals(classify(GOOGLE_SLIDES_MIME, "Kickoff Deck"), WORKSPACE_TEXT);
}

@test:Config {}
isolated function testClassifyGoogleSheetExportsAsCsv() {
    test:assertEquals(classify(GOOGLE_SHEET_MIME, "Budget"), WORKSPACE_CSV);
}

@test:Config {}
isolated function testClassifyOtherGoogleAppsTypesUnsupported() {
    // Folders are handled separately by the loader; every other Workspace type (Forms,
    // Drawings, Sites, shortcuts, …) has no supported textual export and is unsupported.
    test:assertEquals(classify(GOOGLE_FOLDER_MIME, "My Folder"), UNSUPPORTED);
    test:assertEquals(classify("application/vnd.google-apps.drawing", "Diagram"), UNSUPPORTED);
    test:assertEquals(classify("application/vnd.google-apps.form", "Survey"), UNSUPPORTED);
}

// ---- export routing helpers --------------------------------------------------

@test:Config {}
isolated function testExportMimeTypeForRouting() {
    test:assertEquals(exportMimeTypeFor(WORKSPACE_TEXT), "text/plain", "Docs/Slides export to plain text");
    test:assertEquals(exportMimeTypeFor(WORKSPACE_CSV), "text/csv", "Sheets export to CSV");
    test:assertTrue(exportMimeTypeFor(EXTRACT_DOWNLOAD) is (), "Binary files are downloaded, not exported");
    test:assertTrue(exportMimeTypeFor(TEXT_DOWNLOAD) is (), "Binary files are downloaded, not exported");
}

@test:Config {}
isolated function testRequiresExport() {
    test:assertTrue(requiresExport(WORKSPACE_TEXT));
    test:assertTrue(requiresExport(WORKSPACE_CSV));
    test:assertFalse(requiresExport(TEXT_DOWNLOAD));
    test:assertFalse(requiresExport(EXTRACT_DOWNLOAD),
        "PDF/Office files are downloaded via getFileContent, never exported");
    test:assertFalse(requiresExport(UNSUPPORTED));
}

@test:Config {}
isolated function testIsSupported() {
    test:assertTrue(isSupported(TEXT_DOWNLOAD));
    test:assertTrue(isSupported(EXTRACT_DOWNLOAD), "PDF and Office files are supported");
    test:assertTrue(isSupported(WORKSPACE_TEXT));
    test:assertTrue(isSupported(WORKSPACE_CSV));
    test:assertFalse(isSupported(UNSUPPORTED));
}

// ---- matchesExtensionFilter --------------------------------------------------

@test:Config {}
isolated function testExtensionFilterEmptyMatchesAll() {
    test:assertTrue(matchesExtensionFilter("a.pdf", ()));
    test:assertTrue(matchesExtensionFilter("a.png", []));
}

@test:Config {}
isolated function testExtensionFilterAllowlist() {
    test:assertTrue(matchesExtensionFilter("a.pdf", ["pdf"]));
    test:assertFalse(matchesExtensionFilter("a.txt", ["pdf"]));
}

@test:Config {}
isolated function testExtensionFilterCaseInsensitiveAndDotTolerant() {
    test:assertTrue(matchesExtensionFilter("A.PDF", ["pdf"]), "File extension compared case-insensitively");
    test:assertTrue(matchesExtensionFilter("a.pdf", [".PDF"]), "Leading dot and case tolerated in the allowlist");
    test:assertTrue(matchesExtensionFilter("a.md", ["pdf", ".md", "TXT"]));
}

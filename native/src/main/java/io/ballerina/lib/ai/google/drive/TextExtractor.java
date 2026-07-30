/*
 * Copyright (c) 2026, WSO2 LLC. (http://www.wso2.com).
 *
 * WSO2 LLC. licenses this file to you under the Apache License,
 * Version 2.0 (the "License"); you may not use this file except
 * in compliance with the License.
 * You may obtain a copy of the License at
 *
 *    http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

package io.ballerina.lib.ai.google.drive;

import io.ballerina.runtime.api.creators.ErrorCreator;
import io.ballerina.runtime.api.creators.TypeCreator;
import io.ballerina.runtime.api.creators.ValueCreator;
import io.ballerina.runtime.api.types.PredefinedTypes;
import io.ballerina.runtime.api.utils.StringUtils;
import io.ballerina.runtime.api.values.BArray;
import io.ballerina.runtime.api.values.BMap;
import io.ballerina.runtime.api.values.BString;
import org.apache.tika.extractor.EmbeddedDocumentExtractor;
import org.apache.tika.metadata.Metadata;
import org.apache.tika.metadata.TikaCoreProperties;
import org.apache.tika.parser.ParseContext;
import org.apache.tika.parser.Parser;
import org.apache.tika.parser.microsoft.OfficeParser;
import org.apache.tika.parser.microsoft.ooxml.OOXMLParser;
import org.apache.tika.parser.pdf.PDFParser;
import org.apache.tika.parser.pdf.PDFParserConfig;
import org.apache.tika.sax.BodyContentHandler;
import org.xml.sax.ContentHandler;

import java.io.ByteArrayInputStream;
import java.io.InputStream;
import java.util.Locale;

/**
 * Extracts plain text from documents using Apache Tika.
 *
 * <p>Supports PDF documents and Microsoft Office files <em>uploaded</em> to Google Drive
 * (.doc/.docx, .ppt/.pptx, .xls/.xlsx): the shipped Tika parser modules are
 * {@code tika-parser-pdf-module} (PDFBox) and {@code tika-parser-microsoft-module} (Apache POI),
 * declared as platform dependencies in {@code Ballerina.toml}. Google Workspace native files
 * (Docs/Sheets/Slides) never reach this method — the loader exports them to text via the Drive
 * connector's {@code exportFile}; only downloaded binary bytes are routed here.
 *
 * <p>This reads straight from the in-memory bytes downloaded from Google Drive via a
 * {@link ByteArrayInputStream}, so no temporary file is ever written.
 *
 * <p>The concrete parser is selected explicitly — from the Drive MIME type first, falling back
 * to the file-name extension only when the MIME type is absent or generic — rather than via
 * {@code AutoDetectParser}. The MIME type is authoritative because that is what the loader's
 * {@code classify} uses to route a file here in the first place: Drive files are routinely
 * renamed without an extension, and Drive's own type detection is the reliable signal. Selecting
 * on the extension alone would hand, say, a DOCX named {@code "Q3 Report"} to
 * {@link PDFParser}. {@code AutoDetectParser} eagerly instantiates every parser
 * registered on the runtime classpath, and in a full Ballerina runtime one of those
 * unrelated parsers fails to initialise against the {@code commons-lang3} version bundled
 * in the runtime ({@code SystemProperties.getUserName(String)} is absent) — a
 * {@code NoSuchMethodError} a platform-dependency {@code commons-lang3} cannot override.
 * Selecting the exact parser we need ({@link PDFParser}, {@link OOXMLParser}, or
 * {@link OfficeParser}) loads only that parser and sidesteps the issue.
 *
 * <p>For the same reason, recursion into <em>embedded</em> objects (thumbnails, OLE objects,
 * attachments) is disabled via a no-op {@link EmbeddedDocumentExtractor}: Office parsers would
 * otherwise route embedded content through {@code AutoDetectParser}'s container detection,
 * which triggers the same {@code commons-lang3} failure. Only the document's own text is
 * needed here, so skipping embedded objects is both a fix and the desired behavior.
 */
public final class TextExtractor {

    // A BodyContentHandler write limit of -1 means "no limit" on extracted content size.
    private static final int UNLIMITED_CONTENT_SIZE = -1;

    // The MIME types Drive reports for the binary formats routed to this extractor. These
    // mirror EXTRACTABLE_MIME_TYPES in utils.bal, which is what admits a file to this lane.
    private static final String MIME_PDF = "application/pdf";
    private static final String MIME_DOCX =
            "application/vnd.openxmlformats-officedocument.wordprocessingml.document";
    private static final String MIME_XLSX =
            "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet";
    private static final String MIME_PPTX =
            "application/vnd.openxmlformats-officedocument.presentationml.presentation";
    private static final String MIME_DOC = "application/msword";
    private static final String MIME_XLS = "application/vnd.ms-excel";
    private static final String MIME_PPT = "application/vnd.ms-powerpoint";

    /**
     * The error message returned for a PDF that parses successfully but yields no text —
     * either a scanned/image-only document or a genuinely blank one. PDFBox extracts only
     * the text layer, so without this check such a PDF would silently produce an EMPTY
     * document. One neutral message covers both cases (the loader cannot know which it is
     * without OCR).
     *
     * <p>This message is for humans only. The Ballerina layer classifies the error by the
     * structured {@code reason} detail field below, never by matching this text — see
     * {@code isTextlessPdfError} in {@code utils.bal}.
     */
    static final String TEXTLESS_PDF_MESSAGE =
            "the PDF contains no extractable text content (it may be a scanned/image-only "
                    + "document or an empty one); OCR is not supported";

    /**
     * The error detail field and value identifying a text-less PDF. The loader matches on
     * this to skip such files in folder listings while surfacing the error for explicitly
     * named ones. Keep in sync with {@code TEXTLESS_PDF_REASON} in {@code utils.bal} — a
     * structured field so rewording {@link #TEXTLESS_PDF_MESSAGE} cannot change behaviour.
     */
    private static final BString ERROR_DETAIL_REASON = StringUtils.fromString("reason");
    private static final BString TEXTLESS_PDF_REASON = StringUtils.fromString("TEXTLESS_PDF");

    private TextExtractor() {
    }

    /**
     * Extracts the textual content of a document held entirely in memory.
     *
     * @param content  the raw file bytes
     * @param fileName the file name, used as a Tika hint and as the parser fallback
     * @param mimeType the Drive MIME type, which selects the parser ({@code ""} when unknown)
     * @return the extracted text as a {@link BString}, or a Ballerina error on failure
     */
    public static Object extractText(BArray content, BString fileName, BString mimeType) {
        byte[] bytes = content.getBytes();
        try (InputStream stream = new ByteArrayInputStream(bytes)) {
            Parser parser = selectParser(fileName.getValue(), mimeType.getValue());
            BodyContentHandler handler = new BodyContentHandler(UNLIMITED_CONTENT_SIZE);
            Metadata metadata = new Metadata();
            metadata.set(TikaCoreProperties.RESOURCE_NAME_KEY, fileName.getValue());
            ParseContext context = new ParseContext();
            context.set(EmbeddedDocumentExtractor.class, SkipEmbeddedExtractor.INSTANCE);
            // OCR is not supported (no Tesseract shipped): disable the PDF parser's OCR
            // fallback explicitly, otherwise it NPEs trying to OCR image-only pages.
            PDFParserConfig pdfConfig = new PDFParserConfig();
            pdfConfig.setOcrStrategy(PDFParserConfig.OCR_STRATEGY.NO_OCR);
            context.set(PDFParserConfig.class, pdfConfig);
            parser.parse(stream, handler, metadata, context);
            String text = handler.toString();
            // A PDF that parses but yields no text is either a scan (pages are images) or a
            // genuinely blank document: PDFBox reads only the text layer, so surface a
            // descriptive error instead of silently returning an empty document.
            if (parser instanceof PDFParser && text.trim().isEmpty()) {
                // Must be an explicitly typed `map<anydata>`: an untyped map makes the
                // Ballerina `error.detail()` lang-lib call fail a runtime type check, and
                // PredefinedTypes.TYPE_ERROR_DETAIL is readonly, so it cannot be populated.
                BMap<BString, Object> detail = ValueCreator.createMapValue(
                        TypeCreator.createMapType(PredefinedTypes.TYPE_ANYDATA));
                detail.put(ERROR_DETAIL_REASON, TEXTLESS_PDF_REASON);
                return ErrorCreator.createError(StringUtils.fromString(TEXTLESS_PDF_MESSAGE), detail);
            }
            return StringUtils.fromString(text);
        } catch (Exception | StackOverflowError | LinkageError e) {
            // Tika/PDFBox/POI throw StackOverflowError on deeply nested or malformed
            // documents, and LinkageError (NoClassDefFoundError) when an optional POI
            // dependency is absent — e.g. an encrypted OOXML file needing commons-codec.
            // Catching only Exception would let those propagate as a Ballerina panic, killing
            // the strand instead of producing a per-file ai:Error. OutOfMemoryError is
            // deliberately NOT caught: the process state is unreliable after one.
            String message = e.getMessage();
            return ErrorCreator.createError(StringUtils.fromString(
                    message != null ? message : e.getClass().getSimpleName()));
        }
    }

    /**
     * Selects the Tika parser for a file, preferring the Drive MIME type and falling back to
     * the file-name extension when the MIME type is absent or not one this extractor handles
     * (e.g. {@code application/octet-stream}). Drive files are commonly renamed without an
     * extension, so the MIME type must win — see the class Javadoc.
     */
    private static Parser selectParser(String fileName, String mimeType) {
        Parser byMimeType = parserForMimeType(mimeType);
        return byMimeType != null ? byMimeType : parserForExtension(fileName);
    }

    /**
     * Returns the parser for a Drive MIME type, or {@code null} when the type is absent,
     * generic, or otherwise not one of the formats routed to this extractor.
     */
    private static Parser parserForMimeType(String mimeType) {
        // Drive can append parameters, e.g. "text/plain; charset=UTF-8"; keep the base type.
        String mime = mimeType.toLowerCase(Locale.ROOT).trim();
        int separator = mime.indexOf(';');
        if (separator >= 0) {
            mime = mime.substring(0, separator).trim();
        }
        if (MIME_DOCX.equals(mime) || MIME_XLSX.equals(mime) || MIME_PPTX.equals(mime)) {
            return new OOXMLParser();
        }
        if (MIME_DOC.equals(mime) || MIME_XLS.equals(mime) || MIME_PPT.equals(mime)) {
            return new OfficeParser();
        }
        if (MIME_PDF.equals(mime)) {
            return new PDFParser();
        }
        return null;
    }

    /**
     * Selects the Tika parser for a file from its extension. OOXML (.docx/.xlsx/.pptx) and
     * legacy OLE2 (.doc/.xls/.ppt) Office formats use POI; everything else this method is
     * called with is a PDF (the caller only routes PDF/Office here), which uses PDFBox.
     */
    private static Parser parserForExtension(String fileName) {
        String name = fileName.toLowerCase(Locale.ROOT);
        if (name.endsWith(".docx") || name.endsWith(".xlsx") || name.endsWith(".pptx")) {
            return new OOXMLParser();
        }
        if (name.endsWith(".doc") || name.endsWith(".xls") || name.endsWith(".ppt")) {
            return new OfficeParser();
        }
        return new PDFParser();
    }

    /**
     * An {@link EmbeddedDocumentExtractor} that skips every embedded object, so parsing never
     * recurses into embedded content (see the class Javadoc for why this matters here).
     */
    private static final class SkipEmbeddedExtractor implements EmbeddedDocumentExtractor {
        static final SkipEmbeddedExtractor INSTANCE = new SkipEmbeddedExtractor();

        @Override
        public boolean shouldParseEmbedded(Metadata metadata) {
            return false;
        }

        @Override
        public void parseEmbedded(InputStream stream, ContentHandler handler, Metadata metadata,
                                  boolean outputHtml) {
            // Intentionally a no-op: embedded objects are not extracted.
        }
    }
}

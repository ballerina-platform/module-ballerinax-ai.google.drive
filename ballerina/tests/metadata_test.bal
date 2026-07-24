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
import ballerina/time;
import ballerinax/googleapis.drive;

// ---- toUtc -------------------------------------------------------------------

@test:Config {}
isolated function testToUtcParsesRfc3339() {
    // Drive reports RFC 3339 timestamps, with and without fractional seconds.
    test:assertTrue(toUtc("2024-01-15T10:30:00Z") is time:Utc, "A plain RFC 3339 timestamp parses");
    test:assertTrue(toUtc("2024-02-20T08:00:00.123Z") is time:Utc, "Fractional seconds parse");
}

@test:Config {}
isolated function testToUtcNilForNilOrUnparseable() {
    test:assertTrue(toUtc(()) is (), "() input yields ()");
    test:assertTrue(toUtc("not-a-timestamp") is (), "Unparseable input yields ()");
}

// ---- buildMetadata (Drive File -> ai:Metadata) -------------------------------

@test:Config {}
isolated function testBuildMetadataFullFile() {
    drive:File file = {
        id: "1AbCdEf",
        name: "report.pdf",
        mimeType: "application/pdf",
        size: 20480,
        createdTime: "2024-01-15T10:30:00.000Z",
        modifiedTime: "2024-02-20T08:00:00.000Z"
    };
    ai:Metadata metadata = buildMetadata(file);
    test:assertEquals(metadata.fileName, "report.pdf");
    test:assertEquals(metadata.mimeType, "application/pdf");
    test:assertEquals(metadata.fileSize, <decimal>20480, "size (int) maps to fileSize (decimal)");
    test:assertTrue(metadata.createdAt !is (), "createdTime maps to createdAt");
    test:assertTrue(metadata.modifiedAt !is (), "modifiedTime maps to modifiedAt");
    test:assertEquals(metadata["fileId"], "1AbCdEf", "the Drive ID is retained as an extra field");
}

@test:Config {}
isolated function testBuildMetadataWorkspaceFileWithoutSize() {
    // Google Workspace files typically report no `size`; it is then left unset.
    drive:File file = {
        id: "1Doc",
        name: "My Google Doc",
        mimeType: GOOGLE_DOC_MIME,
        createdTime: "2024-03-01T00:00:00Z"
    };
    ai:Metadata metadata = buildMetadata(file);
    test:assertEquals(metadata.fileName, "My Google Doc");
    test:assertEquals(metadata.mimeType, GOOGLE_DOC_MIME);
    test:assertTrue(metadata.fileSize is (), "an absent size is left unset");
    test:assertTrue(metadata.createdAt !is ());
    test:assertTrue(metadata.modifiedAt is (), "an absent modifiedTime is left unset");
}

@test:Config {}
isolated function testBuildMetadataDropsUnparseableTimestamp() {
    drive:File file = {id: "x", name: "a.txt", mimeType: "text/plain", createdTime: "bad-date"};
    ai:Metadata metadata = buildMetadata(file);
    test:assertTrue(metadata.createdAt is (), "An unparseable timestamp is dropped, not fatal");
}

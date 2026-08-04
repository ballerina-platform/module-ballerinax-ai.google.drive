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

// A representative Drive ID (opaque; letters, digits, `-`, `_`).
const string ID = "1A2b3C-d4E5f_G6h7I8J9k0";

// ---- driveIdFromUrl: URL shapes ----------------------------------------------

@test:Config {}
isolated function testDriveIdFromFileUrl() returns error? {
    string id = check driveIdFromUrl(string `https://drive.google.com/file/d/${ID}/view?usp=sharing`);
    test:assertEquals(id, ID, "the ID is taken from the /d/<id>/ path segment");
}

@test:Config {}
isolated function testDriveIdFromDocsEditorsUrls() returns error? {
    // Docs, Sheets and Slides all share the `/d/<id>/` shape on docs.google.com.
    test:assertEquals(check driveIdFromUrl(string `https://docs.google.com/document/d/${ID}/edit`), ID);
    test:assertEquals(check driveIdFromUrl(string `https://docs.google.com/spreadsheets/d/${ID}/edit#gid=0`), ID);
    test:assertEquals(check driveIdFromUrl(string `https://docs.google.com/presentation/d/${ID}/edit`), ID);
}

@test:Config {}
isolated function testDriveIdFromFolderUrl() returns error? {
    string id = check driveIdFromUrl(string `https://drive.google.com/drive/folders/${ID}?usp=drive_link`);
    test:assertEquals(id, ID, "the ID is taken from the /folders/<id> path segment");
}

@test:Config {}
isolated function testDriveIdFromOpenIdUrl() returns error? {
    test:assertEquals(check driveIdFromUrl(string `https://drive.google.com/open?id=${ID}`), ID);
    // Also when `id` is not the first query parameter.
    test:assertEquals(check driveIdFromUrl(string `https://drive.google.com/open?usp=x&id=${ID}`), ID);
}

@test:Config {}
isolated function testDriveIdStripsTrailingAndQuery() returns error? {
    // Trailing path segments and query/fragment after the ID are dropped.
    test:assertEquals(check driveIdFromUrl(string `https://drive.google.com/file/d/${ID}/view`), ID);
    test:assertEquals(check driveIdFromUrl(string `  https://drive.google.com/file/d/${ID}/edit  `), ID,
        "surrounding whitespace is trimmed");
}

// ---- driveIdFromUrl: bare IDs pass through -----------------------------------

@test:Config {}
isolated function testDriveIdFromBareId() returns error? {
    // A value that is already an ID (no path/query separators) is returned unchanged, so
    // callers may pass either a URL or an ID into the URL-accepting fields.
    test:assertEquals(check driveIdFromUrl(ID), ID);
}

// ---- driveIdFromUrl: errors --------------------------------------------------

@test:Config {}
isolated function testDriveIdFromUrlErrorsOnUnparseableUrl() {
    // A URL-shaped value with no recognisable ID marker is an error, not a silent passthrough.
    string|ai:Error result = driveIdFromUrl("https://drive.google.com/drive/my-drive");
    test:assertTrue(result is ai:Error, "a URL with no /d/, /folders/ or ?id= yields an error");
}

@test:Config {}
isolated function testDriveIdFromUrlErrorsOnEmpty() {
    test:assertTrue(driveIdFromUrl("") is ai:Error);
    test:assertTrue(driveIdFromUrl("   ") is ai:Error, "whitespace-only is empty");
}

// ---- resolveResourceIds (the loader's URL resolution) ---------------------------

@test:Config {}
isolated function testResolveResourceIdsMixesIdsAndUrls() returns error? {
    // `resourceIds` accepts either form in any order, and each entry resolves to a Drive ID.
    Source src = {
        resourceIds: ["idOne", string `https://drive.google.com/file/d/${ID}/view`, "idTwo"]
    };
    string[] resolved = check resolveResourceIds(src);
    test:assertEquals(resolved, ["idOne", ID, "idTwo"], "entries resolve in order");
}

@test:Config {}
isolated function testResolveResourceIdsMixesFilesAndFolders() returns error? {
    // File and folder URLs resolve identically: `resourceIds` draws no distinction, and which kind
    // of thing an ID names is settled at load time from its Drive MIME type.
    Source src = {
        resourceIds: [
            string `https://drive.google.com/file/d/${ID}/view`,
            string `https://drive.google.com/drive/folders/${ID}`
        ]
    };
    string[] resolved = check resolveResourceIds(src);
    test:assertEquals(resolved, [ID, ID]);
}

@test:Config {}
isolated function testResolveResourceIdsOnReadonlySource() returns error? {
    // The loader stores sources via `cloneReadOnly`, so `resolveResourceIds` must build a fresh
    // mutable array rather than mutating (a clone of) the readonly `resourceIds` — otherwise it
    // panics with "modification not allowed on readonly value".
    readonly & Source src = {
        resourceIds: ["idOne", string `https://drive.google.com/file/d/${ID}/view`]
    };
    string[] resolved = check resolveResourceIds(src);
    test:assertEquals(resolved, ["idOne", ID]);
}

@test:Config {}
isolated function testResolveResourceIdsEmpty() returns error? {
    string[] resolved = check resolveResourceIds({});
    test:assertEquals(resolved, [], "a source with no resourceIds resolves to an empty array");
}

@test:Config {}
isolated function testResolveResourceIdsPropagatesUnparseableUrl() {
    string[]|ai:Error result = resolveResourceIds({resourceIds: ["https://drive.google.com/drive/my-drive"]});
    test:assertTrue(result is ai:Error, "a URL carrying no Drive ID is an error");
}

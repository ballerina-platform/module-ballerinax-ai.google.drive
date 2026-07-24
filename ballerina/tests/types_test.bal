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

// ---- Source defaults ---------------------------------------------------------

@test:Config {}
isolated function testSourceFolderDefaults() {
    Source src = {folderId: "1FolderId"};
    test:assertEquals(src.folderId, "1FolderId");
    test:assertTrue(src.folderUrl is (), "folderUrl defaults to ()");
    test:assertEquals(src.fileIds, [], "fileIds defaults to []");
    test:assertEquals(src.fileUrls, [], "fileUrls defaults to []");
    test:assertFalse(src.recursive, "recursive defaults to false");
    test:assertTrue(src.includeExtensions is (), "includeExtensions defaults to () (all types)");
}

@test:Config {}
isolated function testSourceUrlFields() {
    Source src = {
        folderUrl: "https://drive.google.com/drive/folders/1Fff",
        fileUrls: ["https://drive.google.com/file/d/1Xyz/view"]
    };
    test:assertTrue(src.folderId is (), "folderId defaults to () when folderUrl is used");
    test:assertEquals(src.folderUrl, "https://drive.google.com/drive/folders/1Fff");
    test:assertEquals(src.fileUrls.length(), 1);
}

@test:Config {}
isolated function testSourceFileIdsOnly() {
    Source src = {fileIds: ["1File", "2File"]};
    test:assertTrue(src.folderId is (), "folderId defaults to () when only fileIds are given");
    test:assertEquals(src.fileIds.length(), 2);
}

@test:Config {}
isolated function testSourceExplicitValues() {
    Source src = {
        folderId: "1Specs",
        fileIds: ["1Design"],
        recursive: true,
        includeExtensions: ["pdf", ".md"]
    };
    test:assertEquals(src.folderId, "1Specs");
    test:assertEquals(src.fileIds, ["1Design"]);
    test:assertTrue(src.recursive);
    test:assertEquals(src.includeExtensions, ["pdf", ".md"]);
}

@test:Config {}
isolated function testSourceEmptyLoadsNothing() {
    // A source with neither a folder nor file IDs is valid and simply loads nothing.
    Source src = {};
    test:assertTrue(src.folderId is ());
    test:assertEquals(src.fileIds, []);
}

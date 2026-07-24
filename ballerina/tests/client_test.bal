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

import ballerina/http;
import ballerina/test;
import ballerinax/googleapis.drive;

// ---- newDriveClient construction ---------------------------------------------
// A bearer-token client constructs offline (no token endpoint call). An OAuth2
// refresh-token grant, by contrast, fetches an access token from the token endpoint at
// construction time, so it cannot be exercised offline — that path is covered by the
// integration suite. Here we only assert the OAuth2 config shape type-checks.

@test:Config {}
isolated function testNewDriveClientWithBearerToken() returns error? {
    drive:ConnectionConfig config = {auth: {token: "ya29.test-access-token"}};
    drive:Client _ = check newDriveClient(config);
}

@test:Config {}
isolated function testOAuth2RefreshTokenConfigTypeChecks() {
    // The loader consumes the connector's own ConnectionConfig, so an OAuth2 refresh-token
    // grant is configured exactly as documented. This asserts the shape is accepted (the
    // client is NOT constructed here, as that would contact the token endpoint).
    drive:ConnectionConfig config = {
        auth: {
            clientId: "test-client-id.apps.googleusercontent.com",
            clientSecret: "test-client-secret",
            refreshToken: "test-refresh-token",
            refreshUrl: "https://oauth2.googleapis.com/token",
            scopes: ["https://www.googleapis.com/auth/drive.readonly"]
        }
    };
    test:assertFalse(config.auth is http:BearerTokenConfig, "the configured auth is the OAuth2 grant, not a bearer token");
}

// ---- init --------------------------------------------------------------------

@test:Config {}
isolated function testInitRejectsEmptySources() {
    drive:ConnectionConfig config = {auth: {token: "ya29.test-access-token"}};
    TextDataLoader|error loader = new (config, []);
    test:assertTrue(loader is error, "at least one source is required");
}

@test:Config {}
isolated function testInitConstructsForFolderSource() returns error? {
    // A bearer-token config constructs offline (no token endpoint call at init).
    drive:ConnectionConfig config = {auth: {token: "ya29.test-access-token"}};
    TextDataLoader _ = check new (config, [{folderId: "1FolderId", recursive: true}]);
}

@test:Config {}
isolated function testInitConstructsForFileIdsSource() returns error? {
    drive:ConnectionConfig config = {auth: {token: "ya29.test-access-token"}};
    TextDataLoader _ = check new (config, [{fileIds: ["1File", "2File"]}]);
}

// ---- init: reusing a caller-supplied client -----------------------------------

@test:Config {}
isolated function testInitAcceptsAnExistingClient() returns error? {
    // A caller that already holds a connector client can hand it to the loader instead of a
    // config, so no second HTTP connection pool / OAuth refresh cycle is created. The client
    // is NOT owned by the loader. (A bearer-token client constructs offline.)
    drive:ConnectionConfig config = {auth: {token: "ya29.test-access-token"}};
    drive:Client existingClient = check newDriveClient(config);
    TextDataLoader _ = check new (existingClient, [{folderId: "1FolderId", recursive: true}]);
}

@test:Config {}
isolated function testInitRejectsEmptySourcesWithExistingClient() returns error? {
    // Source validation runs BEFORE the connection is resolved, so it applies equally to the
    // client form, not just the config form.
    drive:ConnectionConfig config = {auth: {token: "ya29.test-access-token"}};
    drive:Client existingClient = check newDriveClient(config);
    TextDataLoader|error loader = new (existingClient, []);
    test:assertTrue(loader is error, "at least one source is required, even with a supplied client");
}

// ---- isNotFoundError ---------------------------------------------------------

@test:Config {}
isolated function testIsNotFoundErrorRecognisesNotFound() {
    test:assertTrue(isNotFoundError(error("File not found: 1BadId")), "'File not found' is recognised");
    test:assertTrue(isNotFoundError(error("Error: notFound (404)")), "'notFound'/404 is recognised");
    test:assertTrue(isNotFoundError(error("The requested resource was not found")), "'not found' is recognised");
}

@test:Config {}
isolated function testIsNotFoundErrorRejectsOtherErrors() {
    test:assertFalse(isNotFoundError(error("Rate limit exceeded (429)")), "a 429 is not a not-found");
    test:assertFalse(isNotFoundError(error("Invalid credentials (401)")), "a 401 is not a not-found");
    test:assertFalse(isNotFoundError(error("some unrelated failure")), "a generic error is not a not-found");
}

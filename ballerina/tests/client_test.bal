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
    TextDataLoader _ = check new (config, [{resources: ["1FolderId"], recursive: true}]);
}

@test:Config {}
isolated function testInitConstructsForFileIdsSource() returns error? {
    drive:ConnectionConfig config = {auth: {token: "ya29.test-access-token"}};
    TextDataLoader _ = check new (config, [{resources: ["1File", "2File"]}]);
}

@test:Config {}
isolated function testInitConstructsForMixedFileAndFolderResources() returns error? {
    // `resources` draws no distinction between the two: which entry is a file and which is a
    // folder is settled at load time from the Drive MIME type, so construction accepts any mix.
    drive:ConnectionConfig config = {auth: {token: "ya29.test-access-token"}};
    TextDataLoader _ = check new (config, [{resources: ["1FolderId", "1FileId"], recursive: true}]);
}

// ---- init: reusing a caller-supplied client -----------------------------------

@test:Config {}
isolated function testInitAcceptsAnExistingClient() returns error? {
    // A caller that already holds a connector client can hand it to the loader instead of a
    // config, so no second HTTP connection pool / OAuth refresh cycle is created. The client
    // is NOT owned by the loader. (A bearer-token client constructs offline.)
    drive:ConnectionConfig config = {auth: {token: "ya29.test-access-token"}};
    drive:Client existingClient = check newDriveClient(config);
    TextDataLoader _ = check new (existingClient, [{resources: ["1FolderId"], recursive: true}]);
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

// ---- isNotFoundError: the typed status code is authoritative ------------------
// The connector stringifies every Drive failure, so no status code reaches this function
// today. These cover the branch that runs whenever one does.

@test:Config {}
isolated function testIsNotFoundErrorUsesTypedStatusCode() {
    http:ClientRequestError notFound =
        error("Not Found", statusCode = 404, headers = {}, body = ());
    test:assertTrue(isNotFoundError(notFound), "a typed 404 is a not-found");
}

@test:Config {}
isolated function testIsNotFoundErrorTypedStatusWinsOverMessage() {
    // The message says "not found", but the status says 403. The status is authoritative:
    // treating this as a missing file would hide a permissions problem.
    http:ClientRequestError forbidden =
        error("The requested resource was not found", statusCode = 403, headers = {}, body = ());
    test:assertFalse(isNotFoundError(forbidden), "a typed 403 is not a not-found");
}

@test:Config {}
isolated function testIsNotFoundErrorFindsStatusThroughCauseChain() {
    http:ClientRequestError cause =
        error("Not Found", statusCode = 404, headers = {}, body = ());
    test:assertTrue(isNotFoundError(error("Failed to retrieve the file", cause)),
            "a wrapped 404 is still recognised");
}

// ---- REGRESSION: a bare "404" substring must NOT be treated as a not-found -----
// `message.includes("404")` matched any message that merely contained those digits,
// producing a "file not found" diagnostic for errors that were nothing of the sort.

@test:Config {}
isolated function testIsNotFoundErrorIgnoresIncidental404InUrl() {
    test:assertFalse(
            isNotFoundError(error("Quota exceeded; see https://developers.google.com/drive/errors#404")),
            "a help-URL fragment ending in 404 is not a not-found");
}

@test:Config {}
isolated function testIsNotFoundErrorIgnores404InFileName() {
    test:assertFalse(isNotFoundError(error("Failed to download file 'Report-404.pdf'")),
            "a file name containing 404 is not a not-found");
}

// ---- describeContentFailure ---------------------------------------------------
// The connector returns a content failure as `error(<raw response body>)`, so Drive's reason
// string is the only signal left to match on.

@test:Config {}
isolated function testDescribeContentFailureNamesTheExportSizeLimit() {
    error err = error("{\"error\":{\"errors\":[{\"reason\":\"exportSizeLimitExceeded\"}],\"code\":403}}");
    string? described = describeContentFailure(err, "Huge Doc", "1Huge");
    if described is string {
        test:assertTrue(described.includes("10 MB"), described);
        test:assertTrue(described.includes("Huge Doc"), described);
    } else {
        test:assertFail("An export over Drive's 10 MB cap must be named explicitly");
    }
}

@test:Config {}
isolated function testDescribeContentFailureNamesAbusiveFileRefusal() {
    error err = error("{\"error\":{\"errors\":[{\"reason\":\"cannotDownloadAbusiveFile\"}]}}");
    string? described = describeContentFailure(err, "suspect.zip", "1Abuse");
    if described is string {
        test:assertTrue(described.includes("abusive"), described);
    } else {
        test:assertFail("Drive's abusive-file refusal must be named explicitly");
    }
}

@test:Config {}
isolated function testDescribeContentFailureLeavesOtherErrorsAlone() {
    test:assertTrue(describeContentFailure(error("some other failure"), "a.txt", "1A") is (),
            "an unrecognised failure is reported as the connector phrased it");
}

// ---- init: source validation happens up front ---------------------------------
// REGRESSION: URL parsing used to be deferred to load(), so a source naming an unparseable
// share URL only failed after some documents had been fetched and discarded.

@test:Config {}
isolated function testInitRejectsUnparseableFolderUrl() {
    drive:ConnectionConfig config = {auth: {token: "ya29.test-access-token"}};
    TextDataLoader|error loader =
        new (config, [{resources: ["https://drive.google.com/drive/my-drive"]}]);
    test:assertTrue(loader is error, "a URL with no extractable ID must fail at init");
}

@test:Config {}
isolated function testInitRejectsUnparseableFileUrl() {
    drive:ConnectionConfig config = {auth: {token: "ya29.test-access-token"}};
    TextDataLoader|error loader =
        new (config, [{resources: ["1GoodId", "https://drive.google.com/drive/my-drive"]}]);
    test:assertTrue(loader is error, "an unparseable entry in 'resources' must fail at init");
}

@test:Config {}
isolated function testInitResolvesFolderUrlUpFront() returns error? {
    drive:ConnectionConfig config = {auth: {token: "ya29.test-access-token"}};
    TextDataLoader _ = check new (config,
            [{resources: ["https://drive.google.com/drive/folders/1Fff?usp=drive_link"]}]);
}

@test:Config {}
isolated function testInitAcceptsSourceThatSelectsNothing() returns error? {
    // Legal but pointless: it warns rather than failing, since an empty selection is not
    // ambiguous the way a contradictory one is.
    drive:ConnectionConfig config = {auth: {token: "ya29.test-access-token"}};
    TextDataLoader _ = check new (config, [{}]);
}

// ---- childrenQuery -----------------------------------------------------------

@test:Config {}
isolated function testChildrenQueryExcludesTrashed() {
    test:assertEquals(childrenQuery("1Folder"), "'1Folder' in parents and trashed = false");
}

@test:Config {}
isolated function testChildrenQueryEscapesQuotes() {
    // A quote in the ID would close the single-quoted literal early and malform the query.
    test:assertEquals(childrenQuery("a'b"), "'a\\'b' in parents and trashed = false");
}

@test:Config {}
isolated function testChildrenQueryEscapesBackslashes() {
    // Drive escapes `\` as well as `'`; leaving it raw lets an ID smuggle in its own escape.
    test:assertEquals(childrenQuery("a\\b"), "'a\\\\b' in parents and trashed = false");
}

@test:Config {}
isolated function testChildrenQueryEscapesTrailingBackslash() {
    // The regression the ordering guards: escaping quotes first would emit `'a\'`, whose closing
    // quote is itself escaped, so the literal never terminates.
    test:assertEquals(childrenQuery("a\\"), "'a\\\\' in parents and trashed = false");
}

// ---- newDriveClient: retry/response-limit defaults -----------------------------
// The connector leaves both unset, which means no retry over Drive's 403/429 throttling and an
// unbounded response body. The loader fills them in — without touching the caller's record.

@test:Config {}
isolated function testNewDriveClientLeavesCallerConfigUnmutated() returns error? {
    drive:ConnectionConfig config = {auth: {token: "ya29.test-access-token"}};
    drive:Client _ = check newDriveClient(config);
    test:assertTrue(config.retryConfig is (), "the caller's retryConfig is left as they set it");
    test:assertTrue(config.responseLimits is (), "the caller's responseLimits is left as they set it");
}

@test:Config {}
isolated function testRetryDefaultsCoverDriveThrottling() {
    test:assertEquals(DEFAULT_RETRY_CONFIG.count, 4, "a retry policy is configured by default");
    test:assertTrue(DEFAULT_RETRY_CONFIG.statusCodes.indexOf(429) !is (), "429 is retried");
    test:assertTrue(DEFAULT_RETRY_CONFIG.statusCodes.indexOf(403) !is (),
            "403 throttling is retried — Drive reports rateLimitExceeded as a 403");
    test:assertEquals(DEFAULT_RESPONSE_LIMITS.maxEntityBodySize, 104857600,
            "the entity body is bounded, not unlimited");
}

@test:Config {}
isolated function testExplicitRetryConfigIsNotOverridden() returns error? {
    // A caller who deliberately disables retrying must keep that, not silently get the default.
    drive:ConnectionConfig config = {auth: {token: "ya29.test-access-token"}, retryConfig: {count: 0}};
    drive:Client _ = check newDriveClient(config);
    http:RetryConfig? retryConfig = config.retryConfig;
    if retryConfig is http:RetryConfig {
        test:assertEquals(retryConfig.count, 0, "an explicit retryConfig survives");
    } else {
        test:assertFail("The explicitly supplied retryConfig was discarded");
    }
}

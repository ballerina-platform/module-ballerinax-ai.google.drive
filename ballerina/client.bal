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
import ballerina/http;
import ballerinax/googleapis.drive;

// Google documents exponential backoff as the required response to rate limiting
// (https://developers.google.com/workspace/drive/api/guides/handle-errors). Drive reports
// throttling as 403 `rateLimitExceeded`/`userRateLimitExceeded` as well as 429, and
// `http:RetryConfig` can only match on the status code, not the `reason` — so 403 is included
// here. The cost is that a genuine permissions 403 is retried before it fails; the alternative
// (no retry on the most common throttle signal) fails whole bulk loads.
final http:RetryConfig & readonly DEFAULT_RETRY_CONFIG = {
    interval: 1,
    count: 4,
    backOffFactor: 2.0,
    maxWaitInterval: 20,
    statusCodes: [403, 429, 500, 502, 503, 504]
};

// A backstop for content whose size Drive does not report up front (notably Workspace exports,
// which carry no `size`). Unset, `maxEntityBodySize` defaults to -1, i.e. unlimited, so a single
// huge file would be read wholly into memory.
final http:ResponseLimitConfigs & readonly DEFAULT_RESPONSE_LIMITS = {
    maxEntityBodySize: 104857600
};

// Constructs the Google Drive `Client` from the connector's own `ConnectionConfig`
// (OAuth2 refresh-token grant or a bearer token), wrapping any construction failure as an
// `ai:Error`. The loader consumes the connector's config type directly rather than
// re-declaring one, so callers configure auth exactly as they would for the connector, and a
// caller who already holds a `drive:Client` can hand that over instead.
//
// `retryConfig` and `responseLimits` are optional on the connector's config and unset by
// default, which leaves a bulk load with no retry at all over Drive's throttling and an
// unbounded response body. Both are filled in here when the caller supplied neither — an
// explicit value always wins, including one that deliberately disables retrying.
isolated function newDriveClient(drive:ConnectionConfig config) returns drive:Client|ai:Error {
    // A spread copy rather than `clone()`, which returns a readonly value unchanged and would
    // make the defaulting below fail on an immutable caller config. This copy is always mutable,
    // and the caller's own record is never touched.
    drive:ConnectionConfig effective = {...config};
    if effective.retryConfig is () {
        effective.retryConfig = DEFAULT_RETRY_CONFIG;
    }
    if effective.responseLimits is () {
        effective.responseLimits = DEFAULT_RESPONSE_LIMITS;
    }
    drive:Client|error driveClient = new (effective);
    if driveClient is error {
        return error ai:Error(
            string `Failed to initialize the Google Drive client: ${driveClient.message()}`, driveClient);
    }
    return driveClient;
}

// Names the two Drive content refusals that are common and opaque enough to be worth
// translating, leaving anything else to be reported as the connector phrased it.
//
// The connector surfaces a content failure as `error(<raw response body>)` (see
// `generateRecordFileContent`), so Drive's reason string is present in the message but the
// status code and the structured JSON are both gone — matching the reason text is the only
// signal available. A file inside a folder listing is skipped with its message logged, so that
// message is all an operator sees; a wall of Drive's JSON would be unreadable at bulk-load scale.
isolated function describeContentFailure(error err, string fileName, string fileId) returns string? {
    string body = err.message();
    if body.includes("exportSizeLimitExceeded") {
        return string `Cannot export '${fileName}' (ID '${fileId}'): it exceeds the 10 MB limit ` +
            string `Google Drive applies to a single export`;
    }
    if body.includes("cannotDownloadAbusiveFile") {
        return string `Google Drive has flagged '${fileName}' (ID '${fileId}') as abusive and ` +
            string `refuses to serve it`;
    }
    return ();
}

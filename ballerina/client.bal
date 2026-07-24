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
import ballerinax/googleapis.drive;

// Constructs the Google Drive `Client` from the connector's own `ConnectionConfig`
// (OAuth2 refresh-token grant or a bearer token), wrapping any construction failure as an
// `ai:Error`. The loader consumes the connector's config type directly rather than
// re-declaring one, so callers configure auth exactly as they would for the connector.
isolated function newDriveClient(drive:ConnectionConfig config) returns drive:Client|ai:Error {
    drive:Client|error driveClient = new (config);
    if driveClient is error {
        return error ai:Error(
            string `Failed to initialize the Google Drive client: ${driveClient.message()}`, driveClient);
    }
    return driveClient;
}

// Reports whether a connector error denotes a missing file/folder. The `googleapis.drive`
// connector surfaces Drive's HTTP 404 as a generic `error` (it does not define a typed
// NotFoundError), so the loader matches on the error message. Drive's not-found responses
// carry either "File not found" / "notFound" or a bare 404 status, so those fragments are
// checked. Used to turn a mistyped file/folder ID into a clear "not found" error.
isolated function isNotFoundError(error err) returns boolean {
    string message = err.message().toLowerAscii();
    return message.includes("file not found") || message.includes("notfound")
        || message.includes("not found") || message.includes("404");
}

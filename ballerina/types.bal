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

# A rule selecting what to load from Google Drive. Several may be configured per loader.
#
# Unlike a filesystem or Azure Files share, Drive has **no path tree**: every file and
# folder is addressed by an opaque, stable **ID** (a folder is simply a file whose MIME
# type is `application/vnd.google-apps.folder`). A `Source` therefore selects content by
# ID: list the files and/or folders to load in `fileOrFolderIds`, in any combination.
#
# Because Drive draws no distinction between the two, neither does `fileOrFolderIds` — each
# entry is resolved to an ID up front, and its Drive MIME type decides at load time whether it
# is fetched as a single file or listed as a folder. A folder entry loads every supported file
# directly inside it, descending into sub-folders when `recursive`; trashed resources are
# always excluded.
#
# `recursive` shapes how a folder entry is expanded, so it has no effect on an entry that
# turns out to be a file. Every entry in `fileOrFolderIds` is named deliberately, so failing to
# load one — a missing or trashed ID, an unsupported type, or content that cannot be read —
# is reported as an error rather than skipped; a file merely *discovered* inside a folder
# entry is skipped with a warning instead, so one unreadable file does not abandon the walk.
# To traverse some folders but not others, configure one `Source` per setting — several may
# be given per loader.
#
# A source with no `fileOrFolderIds` loads nothing.
#
# Entries accept a Drive **ID or a share URL** interchangeably; a URL is resolved to its ID
# via `driveIdFromUrl`.
public type Source record {|
    # The Drive files and/or folders to load. Each entry is either an ID or a share URL
    # (e.g. `https://drive.google.com/file/d/<id>/view`, a Google Docs `.../d/<id>/edit`
    # URL, or `https://drive.google.com/drive/folders/<id>`), from which the ID is
    # extracted. A file entry is loaded as one document; a folder entry is expanded into
    # the supported files it contains. Defaults to `[]`, which selects nothing.
    @display {label: "File IDs/File URLs or Folder IDs/Folder URLs"}
    string[] fileOrFolderIds = [];
    # The recursive is applicable only when the `fileOrFolderIds` entry has a folder. It
    # determines whether to traverse sub-folders. Defaults to `false`.
    @display {label: "Include Sub-folders"}
    boolean recursive = false;
|};

// A source with its `fileOrFolderIds` entries already resolved to Drive IDs — the public field
// also accepts share URLs, so the two are not the same values. Resolution happens in `init`,
// so a source naming an unparseable URL fails immediately rather than part-way through a long
// load, after documents have already been fetched.
//
// Whether an entry is a file or a folder is NOT resolved here: that needs the Drive MIME type,
// and fetching it would turn construction into a network operation whose result could be stale
// by the time `load` runs. `loadResource` decides it from the metadata it fetches anyway.
type ResolvedSource record {|
    string[] resourceIds;
    boolean recursive;
|};


// The Drive `File` metadata fields the loader requests via `getFile`. `getAllFiles` (listing)
// returns only the default projection, so the timestamps needed for `ai:Metadata` are fetched
// explicitly per file with this field mask.
//
// `size` is deliberately NOT requested: the Drive API serialises it as a JSON string (it is an
// int64), but the `googleapis.drive` connector types `File.size` as `int`, so asking for it makes
// the connector's `cloneWithType(File)` fail with "Error occurred while constructing
// DriveResponse record." `ai:Metadata.fileSize` is instead derived from the downloaded byte
// length in `fetchAndBuild` (accurate for binary files; left unset for exported Workspace docs).
//
// `webViewLink` gives a downstream RAG pipeline a citation URL back to the source document, and
// Drive returns it in the same response, so it costs nothing to carry.
const string FILE_FIELDS = "id,name,mimeType,createdTime,modifiedTime,trashed,webViewLink";

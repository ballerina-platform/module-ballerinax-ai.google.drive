Ballerina Google Drive Data Loader
==================================

[![Build](https://github.com/ballerina-platform/module-ballerinax-ai.google.drive/actions/workflows/ci.yml/badge.svg)](https://github.com/ballerina-platform/module-ballerinax-ai.google.drive/actions/workflows/ci.yml)
[![GitHub Last Commit](https://img.shields.io/github/last-commit/ballerina-platform/module-ballerinax-ai.google.drive.svg?label=Last%20Commit)](https://github.com/ballerina-platform/module-ballerinax-ai.google.drive/commits/main)
[![License](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](https://opensource.org/licenses/Apache-2.0)
[![GitHub Issues](https://img.shields.io/github/issues/ballerina-platform/ballerina-library/module/ai.google.drive.svg?label=Open%20Issues)](https://github.com/ballerina-platform/ballerina-library/labels/module%2Fai.google.drive)

An [`ai:DataLoader`](https://central.ballerina.io/ballerina/ai/latest) implementation that loads
files from [Google Drive](https://www.google.com/drive/) and returns them as `ai:TextDocument`s,
ready to chunk, embed and index in a Ballerina AI / RAG pipeline.

Google Workspace files (Docs, Sheets, Slides) are exported to text; uploaded PDF and Microsoft
Office documents are downloaded and their text extracted with [Apache Tika](https://tika.apache.org/);
ordinary text files are downloaded and decoded. Drive access goes through the
[`ballerinax/googleapis.drive`](https://central.ballerina.io/ballerinax/googleapis.drive/latest)
connector, so an existing `drive:Client` can be reused directly.

For the `Source` model, supported file types, authentication and configuration, see the
[package documentation](ballerina/README.md).

## Issues and projects

The **Issues** and **Projects** tabs are disabled for this repository. To report a bug or request
a feature, open an issue in the [Ballerina library parent repository](https://github.com/ballerina-platform/ballerina-library/issues).

This repository only contains the source code for the package.

## Build from the source

### Prerequisites

1. Download and install Java SE Development Kit (JDK) version 21. You may use one of the
   following:

    * [Oracle JDK](https://www.oracle.com/java/technologies/downloads/)
    * [OpenJDK](https://adoptium.net/)

   > **Note:** After installation, remember to set the `JAVA_HOME` environment variable to the
   > directory where JDK was installed.

2. Download and install [Ballerina Swan Lake](https://ballerina.io/).

3. Download and install [Docker](https://www.docker.com/get-started).

4. Export your GitHub personal access token with read access to packages to the `packageUser` and
   `packagePAT` environment variables.

    ```bash
    export packageUser=<Your GitHub Username>
    export packagePAT=<GitHub Personal Access Token>
    ```

### Build options

Execute the commands below to build from the source.

1. To build the package:

    ```bash
    ./gradlew clean build
    ```

2. To run the tests:

    ```bash
    ./gradlew clean test
    ```

3. To build the package without the tests:

    ```bash
    ./gradlew clean build -x test
    ```

4. To run tests against different environments:

    ```bash
    ./gradlew clean test -Pgroups=<Comma separated groups/test cases>
    ```

5. To debug the package with a remote debugger:

    ```bash
    ./gradlew clean build -Pdebug=<port>
    ```

6. To debug with the Ballerina language:

    ```bash
    ./gradlew clean build -PbalJavaDebug=<port>
    ```

7. Publish the generated artifacts to the local Ballerina Central repository:

    ```bash
    ./gradlew clean build -PpublishToLocalCentral=true
    ```

8. Publish the generated artifacts to the Ballerina Central repository:

    ```bash
    ./gradlew clean build -PpublishToCentral=true
    ```

## Contribute to Ballerina

As an open-source project, Ballerina welcomes contributions from the community.

For more information, go to the
[contribution guidelines](https://github.com/ballerina-platform/ballerina-lang/blob/master/CONTRIBUTING.md).

## Code of conduct

All the contributors are encouraged to read the
[Ballerina Code of Conduct](https://ballerina.io/code-of-conduct).

## Useful links

* Chat live with us via our [Discord server](https://discord.gg/ballerinalang).
* Post all technical questions on Stack Overflow with the
  [#ballerina](https://stackoverflow.com/questions/tagged/ballerina) tag.
* For more information go to the [`ai.google.drive` package](https://central.ballerina.io/ballerinax/ai.google.drive/latest).
* For example demonstrations of the usage, go to [Ballerina By Examples](https://ballerina.io/learn/by-example/).

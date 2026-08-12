# Real-Media UI Testing

Muralume includes an opt-in XCUITest that imports a real local MP4, waits for
playback to become ready, starts Dynamic Desktop, returns through the menu bar
item, removes the imported source, and terminates the app.

The test complements the normal deterministic suite. It is intentionally not
part of **make test** or CI because it depends on developer-owned media and an
active macOS graphical session.

## Local configuration

Keep test videos outside the repository. Create the Git-ignored
**.env.test.local** file in the repository root:

~~~make
MURALUME_REAL_MEDIA_DIRECTORY=/absolute/path/to/local/videos
~~~

The directory must:

- be below **/Users/<name>** so the system media picker can navigate to it;
- contain at least one top-level **.mp4** file; and
- remain outside source control.

The test script chooses the smallest matching MP4 to reduce decode, memory, and
artifact overhead. It does not copy or move the media into the project.

Run the test with:

~~~bash
make test-real-media
~~~

To retain DerivedData and the result bundle at a known location:

~~~bash
make test-real-media \
  MURALUME_TEST_ARTIFACTS_DIR=/tmp/MuralumeRealMediaVerification
~~~

## Privacy and permission boundary

The shell test harness selects the fixture before XCUITest starts and injects
only the selected file path into the generated **.xctestrun** specification.
**MuralumeUITests-Runner.app** must not enumerate the configured directory or
open the video directly.

The UI test navigates the macOS system media picker from the user's home folder
and selects the file as a user would. This boundary prevents each newly built
test Runner from repeatedly requesting access to the user's Documents folder.
If a prompt says that **MuralumeUITests-Runner.app** wants to access Documents,
deny it and treat the prompt as a test regression.

The Muralume app itself receives access only after the system picker selection,
matching the production Powerbox flow.

## Isolation and cleanup

The test launches the Debug app with an empty media library and deterministic
English settings. On the success path it:

1. imports one MP4 and verifies the library summary;
2. waits until Dynamic Desktop is enabled;
3. starts Dynamic Desktop and verifies that the player window hides;
4. returns through the Muralume menu bar item;
5. removes the imported source and verifies an empty library; and
6. terminates the app.

An unconditional teardown also terminates the app after any failed step. This
releases playback, Dynamic Desktop surfaces, security-scoped access, and test
process memory. The test does not modify the production app's media library.

The regular UI suite explicitly skips this opt-in class:

~~~bash
./Scripts/verify.sh ui
~~~

This keeps normal local runs and CI independent of **.env.test.local** and
developer media.

## Troubleshooting

- “Set MURALUME_REAL_MEDIA_DIRECTORY…”: create **.env.test.local**, or pass the
  variable directly to **make**.
- “No MP4 file exists…”: place an MP4 directly inside the configured
  directory; nested folders are not scanned.
- The file is absent from the picker: confirm the path is below the current
  user's home folder and the file has an **.mp4** extension.
- XCTest cannot automate the UI: enable developer-tool automation as described
  in the project README, then rerun the test.

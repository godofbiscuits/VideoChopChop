# VideoChopChop

A macOS app that opens a video, finds its scene cuts, shows them on a timeline, previews filters, and
exports every frame as lossy JPEG XL images (one folder per scene) with statistics about the scenes.

Swift 6 (strict concurrency), SwiftUI shell, AppKit/AVFoundation for the media UI. Targets macOS 27.3.

## Building from a fresh checkout

Two third-party pieces are built from source rather than stored in git:

| Piece | Pinned version | Used for | Built by |
|---|---|---|---|
| `Vendor/libjxl.xcframework` | libjxl v0.12.0 | JPEG XL encoding (`Packages/JXLKit`) | `Scripts/build-libjxl.sh` |
| `VideoChopChop/Helpers/ffmpeg` | FFmpeg n8.1.3, LGPL only | converting MKV/WebM to a cached MP4 on import | `Scripts/build-ffmpeg.sh` |

```sh
git clone https://github.com/godofbiscuits/VideoChopChop.git
cd VideoChopChop
brew install cmake ninja            # plus nasm on an Intel Mac; Xcode and its command line tools are required
Scripts/bootstrap.sh                # builds both pieces (several minutes, needs network); safe to re-run
open VideoChopChop.xcodeproj        # or: xcodebuild build -project VideoChopChop.xcodeproj -scheme VideoChopChop
```

`Scripts/bootstrap.sh --force` rebuilds both. Xcode will fail to resolve the `JXLKit` package until
`Vendor/libjxl.xcframework` exists, so run the bootstrap before opening the project.

The app still builds and runs without the ffmpeg helper; it just can't open MKV/WebM files (the converter
reports that the helper is missing, and the MKV conversion tests fail).

## Reference videos

`Reference/` holds large sample videos (git-ignored, not in the app bundle). Put any test video there if you
want one; nothing in the build or the tests needs it.

## Tests

```sh
xcodebuild test -project VideoChopChop.xcodeproj -scheme VideoChopChop -destination 'platform=macOS'
```

Quit a running copy of the app first; a running instance makes the test run hang.

# Publishing server_native

The [Firehose workflow](../.github/workflows/publish.yaml) validates the package
version, changelog, and publish dry run on pull requests to `main`. Pushing a
package version tag invokes publishing through GitHub OIDC, without a stored
pub.dev credential.

## One-time pub.dev setup

In the [package admin settings](https://pub.dev/packages/server_native/admin),
enable automated publishing from GitHub Actions:

- Repository: `kingwill101/server_native`
- Tag pattern: `v{{version}}`
- No GitHub environment is configured by this workflow.

See [Dart automated publishing](https://dart.dev/tools/pub/automated-publishing)
for the pub.dev configuration instructions. A package administrator must finish
this setup before the first tag-triggered publish.

## Release order

1. Update `pubspec.yaml` and the matching `CHANGELOG.md` entry.
2. For native changes, run the prebuilt workflow for
   `server-native-prebuilt-v<version>`. For documentation-only updates, retain the
   existing verified manifest and `zig_prebuilt.yaml` tag. Regenerate package
   metadata with `dart tool/generate_prebuilt_release.dart`.
3. Commit its generated checksum manifest after both architecture jobs pass.
   Verify automatic downloads and execution from an extracted package without
   Zig, including a `dart build cli` bundle.
4. Wait for the release PR checks, including Firehose validation, and merge.
5. Tag the merged release commit and push the tag. For this prerelease:

   ```sh
   git tag v1.0.0-dev.1 <merged-release-commit>
   git push origin v1.0.0-dev.1
   ```

**Pushing the package tag publishes to pub.dev.** Firehose checks that the tag,
pubspec, and changelog versions agree before running `dart pub publish --force`.
Its current implementation supports explicit prerelease tags such as
`v1.0.0-dev.1`. The prebuilt tag does not trigger package publication.

After publication, keep the pinned binary assets immutable. Runtime or binary
changes require a new package version, binary release, and checksum manifest.

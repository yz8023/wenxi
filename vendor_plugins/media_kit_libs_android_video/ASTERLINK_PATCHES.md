# AsterLink build changes

This directory vendors `media_kit_libs_android_video` 1.3.8. Its original license remains in `LICENSE`.

- Android build tools use AGP 8.13.0 and compile SDK 36.
- Native artifacts remain the upstream v1.1.7 default builds with their fixed checksums.
- Artifact downloads try GitHub first and the existing mirror second. Each attempt has a 15-second connection timeout and a 30-second read timeout. Streams are closed, and a temporary download replaces the cache only after checksum verification. Failed attempts do not leave a partially downloaded JAR in the cache.

These changes affect dependency retrieval, not the contents of the native media libraries.

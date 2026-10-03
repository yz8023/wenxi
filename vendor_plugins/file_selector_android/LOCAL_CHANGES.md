# Local changes

Based on Flutter's file_selector_android 0.5.2+6, with its original licenses.
This version remains compatible with the project's Flutter/Dart SDK.

- Copy selected documents on a serial background worker, using bounded buffers.
- Return a readable cache path and a 64-bit size, without sending file bytes over
  the platform channel. Dart opens the cached file as a streamed XFile.
- Handle unavailable streams, permission errors, unknown document sizes, and
  missing metadata as picker errors instead of uncaught activity-result errors.
- Complete each picker result once, including providers returning both data and
  ClipData, and remove the result listener when launching the picker fails.
- Use separate cache directories for each selection and remove partial copies.

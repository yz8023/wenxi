# AsterLink build changes

This directory vendors `flutter_inappwebview_windows` 0.6.0 with its original license.

- The internal NuGet download target has a shorter name, avoiding MSBuild tracking-log paths beyond Windows' 260-character limit in nested checkouts.
- NuGet commands use `add_custom_target` with `VERBATIM` quoting and an explicit dependency from the plugin library. Dependencies are installed before plugin compilation, without the unsupported `DEPENDS` argument on `add_custom_command(TARGET ...)`.

The exported plugin target and DLL name remain the names required by Flutter. NuGet dependency versions are unchanged.

// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

package dev.flutter.packages.file_selector_android;

import android.app.Activity;
import android.content.ClipData;
import android.content.Intent;
import android.net.Uri;
import android.os.Build;
import android.provider.DocumentsContract;
import android.util.Log;
import android.webkit.MimeTypeMap;
import androidx.annotation.ChecksSdkIntAtLeast;
import androidx.annotation.NonNull;
import androidx.annotation.Nullable;
import androidx.annotation.VisibleForTesting;
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding;
import io.flutter.plugin.common.PluginRegistry;
import java.io.File;
import android.content.Context;
import android.os.Handler;
import android.os.Looper;
import java.util.LinkedHashSet;
import java.util.concurrent.Executor;
import java.util.concurrent.Executors;
import java.util.function.Consumer;
import java.io.IOException;
import java.util.ArrayList;
import java.util.Collections;
import java.util.HashSet;
import java.util.List;
import java.util.Set;
import kotlin.Result;
import kotlin.Unit;
import kotlin.jvm.functions.Function1;
import org.jetbrains.annotations.NotNull;

public class FileSelectorApiImpl implements FileSelectorApi {
  private static final String TAG = "FileSelectorApiImpl";
  // Request code for selecting a file.
  private static final int OPEN_FILE = 221;
  // Request code for selecting files.
  private static final int OPEN_FILES = 222;
  // Request code for selecting a directory.
  private static final int OPEN_DIR = 223;

  private final @NonNull NativeObjectFactory objectFactory;
  private final @NonNull AndroidSdkChecker sdkChecker;
  @Nullable ActivityPluginBinding activityPluginBinding;

  private abstract static class OnResultListener {
    public abstract void onResult(int resultCode, @Nullable Intent data);
  }

  // Handles instantiating class objects that are needed by this class. This is provided to be
  // overridden for tests.
  @VisibleForTesting
  static class NativeObjectFactory {
    private static final Executor FILE_WORKER = Executors.newSingleThreadExecutor();

    void runInBackground(@NonNull Runnable action) { FILE_WORKER.execute(action); }
    void onMainThread(@NonNull Runnable action) {
      new Handler(Looper.getMainLooper()).post(action);
    }

    @NonNull
    Intent newIntent(@NonNull String action) {
      return new Intent(action);
    }

  }

  // Interface for an injectable SDK version checker.
  @VisibleForTesting
  interface AndroidSdkChecker {
    @ChecksSdkIntAtLeast(parameter = 0)
    boolean sdkIsAtLeast(int version);
  }

  public FileSelectorApiImpl(@NonNull ActivityPluginBinding activityPluginBinding) {
    this(
        activityPluginBinding,
        new NativeObjectFactory(),
        (int version) -> Build.VERSION.SDK_INT >= version);
  }

  @VisibleForTesting
  FileSelectorApiImpl(
      @NonNull ActivityPluginBinding activityPluginBinding,
      @NonNull NativeObjectFactory objectFactory,
      @NonNull AndroidSdkChecker sdkChecker) {
    this.activityPluginBinding = activityPluginBinding;
    this.objectFactory = objectFactory;
    this.sdkChecker = sdkChecker;
  }

  @Override
  public void openFile(
      @Nullable String initialDirectory,
      @NonNull FileTypes allowedTypes,
      @NonNull Function1<? super Result<FileResponse>, Unit> callback) {
    final Intent intent = objectFactory.newIntent(Intent.ACTION_OPEN_DOCUMENT);
    intent.addCategory(Intent.CATEGORY_OPENABLE);
    setMimeTypes(intent, allowedTypes);
    trySetInitialDirectory(intent, initialDirectory);
    try {
      startActivityForResult(intent, OPEN_FILE, new OnResultListener() {
        @Override
        public void onResult(int resultCode, @Nullable Intent data) {
          if (resultCode != Activity.RESULT_OK) {
            ResultUtilsKt.completeWithValue(callback, null);
            return;
          }
          try {
            final List<Uri> uris = selectedUris(data);
            readFiles(uris.isEmpty() ? uris : Collections.singletonList(uris.get(0)),
                files -> ResultUtilsKt.completeWithValue(callback, files.get(0)),
                error -> ResultUtilsKt.completeWithError(callback, error));
          } catch (Exception error) {
            ResultUtilsKt.completeWithError(callback,
                new IOException("Unable to access the selected document."));
          }
        }
      });
    } catch (Exception error) {
      ResultUtilsKt.completeWithError(callback, error);
    }
  }

  @Override
  public void openFiles(
      @Nullable String initialDirectory,
      @NonNull FileTypes allowedTypes,
      @NonNull Function1<? super Result<? extends List<FileResponse>>, Unit> callback) {
    final Intent intent = objectFactory.newIntent(Intent.ACTION_OPEN_DOCUMENT);
    intent.addCategory(Intent.CATEGORY_OPENABLE);
    intent.putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true);
    setMimeTypes(intent, allowedTypes);
    trySetInitialDirectory(intent, initialDirectory);
    try {
      startActivityForResult(intent, OPEN_FILES, new OnResultListener() {
        @Override
        public void onResult(int resultCode, @Nullable Intent data) {
          if (resultCode != Activity.RESULT_OK) {
            ResultUtilsKt.completeWithValue(callback, new ArrayList<>());
            return;
          }
          try {
            readFiles(selectedUris(data),
                files -> ResultUtilsKt.completeWithValue(callback, files),
                error -> ResultUtilsKt.completeWithError(callback, error));
          } catch (Exception error) {
            ResultUtilsKt.completeWithError(callback,
                new IOException("Unable to access the selected documents."));
          }
        }
      });
    } catch (Exception error) {
      ResultUtilsKt.completeWithError(callback, error);
    }
  }

  private List<Uri> selectedUris(@Nullable Intent data) {
    final Set<Uri> uris = new LinkedHashSet<>();
    if (data != null) {
      if (data.getData() != null) uris.add(data.getData());
      final ClipData clips = data.getClipData();
      if (clips != null) {
        for (int i = 0; i < clips.getItemCount(); i++) {
          final Uri uri = clips.getItemAt(i).getUri();
          if (uri != null) uris.add(uri);
        }
      }
    }
    return new ArrayList<>(uris);
  }

  private void readFiles(List<Uri> uris, Consumer<List<FileResponse>> success,
      Consumer<Exception> failure) {
    final ActivityPluginBinding binding = activityPluginBinding;
    if (binding == null || uris.isEmpty()) {
      failure.accept(new IOException("No readable document was selected."));
      return;
    }
    final Context context = binding.getActivity().getApplicationContext();
    objectFactory.runInBackground(() -> {
      final List<FileResponse> files = new ArrayList<>();
      try {
        for (Uri uri : uris) {
          final FileResponse file = toFileResponse(context, uri);
          if (file == null) throw new IOException("The selected document could not be read.");
          files.add(file);
        }
      } catch (Exception error) {
        objectFactory.onMainThread(() -> failure.accept(
            new IOException("Unable to read selected files. Check access and free storage.")));
        return;
      }
      objectFactory.onMainThread(() -> success.accept(files));
    });
  }

  @Override
  public void getDirectoryPath(
      @Nullable String initialDirectory,
      @NonNull Function1<? super @NotNull Result<String>, @NotNull Unit> callback) {
    final Intent intent = objectFactory.newIntent(Intent.ACTION_OPEN_DOCUMENT_TREE);
    trySetInitialDirectory(intent, initialDirectory);

    try {
      startActivityForResult(
          intent,
          OPEN_DIR,
          new OnResultListener() {
            @Override
            public void onResult(int resultCode, @Nullable Intent data) {
              if (resultCode == Activity.RESULT_OK && data != null) {
                final Uri uri = data.getData();
                if (uri == null) {
                  // No data retrieved from opening directory.
                  ResultUtilsKt.completeWithError(
                      callback, new Exception("Failed to retrieve data from opening directory."));
                  return;
                }

                final Uri docUri =
                    DocumentsContract.buildDocumentUriUsingTree(
                        uri, DocumentsContract.getTreeDocumentId(uri));
                try {
                  final String path =
                      FileUtils.getPathFromUri(activityPluginBinding.getActivity(), docUri);
                  ResultUtilsKt.completeWithValue(callback, path);
                } catch (UnsupportedOperationException exception) {
                  ResultUtilsKt.completeWithError(callback, exception);
                }
              } else {
                ResultUtilsKt.<String>completeWithValue(callback, null);
              }
            }
          });
    } catch (Exception exception) {
      ResultUtilsKt.completeWithError(callback, exception);
    }
  }

  public void setActivityPluginBinding(@Nullable ActivityPluginBinding activityPluginBinding) {
    this.activityPluginBinding = activityPluginBinding;
  }

  // Setting the mimeType with `setType` is required when opening files. This handles setting the
  // mimeType based on the `mimeTypes` list and converts extensions to mimeTypes.
  // See https://developer.android.com/guide/components/intents-common#OpenFile
  private void setMimeTypes(@NonNull Intent intent, @NonNull FileTypes allowedTypes) {
    final Set<String> allMimetypes = new HashSet<>();
    allMimetypes.addAll(allowedTypes.getMimeTypes());
    allMimetypes.addAll(tryConvertExtensionsToMimetypes(allowedTypes.getExtensions()));

    if (allMimetypes.isEmpty()) {
      intent.setType("*/*");
    } else if (allMimetypes.size() == 1) {
      intent.setType(allMimetypes.iterator().next());
    } else {
      intent.setType("*/*");
      intent.putExtra(Intent.EXTRA_MIME_TYPES, allMimetypes.toArray(new String[0]));
    }
  }

  // Attempts to convert each extension to Android compatible mimeType. Logs a warning if an
  // extension could not be converted.
  @NonNull
  private List<String> tryConvertExtensionsToMimetypes(@NonNull List<String> extensions) {
    if (extensions.isEmpty()) {
      return Collections.emptyList();
    }

    final MimeTypeMap mimeTypeMap = MimeTypeMap.getSingleton();
    final Set<String> mimeTypes = new HashSet<>();
    for (String extension : extensions) {
      final String mimetype = mimeTypeMap.getMimeTypeFromExtension(extension);
      if (mimetype != null) {
        mimeTypes.add(mimetype);
      } else {
        Log.w(TAG, "Extension not supported: " + extension);
      }
    }

    return new ArrayList<>(mimeTypes);
  }

  private void trySetInitialDirectory(@NonNull Intent intent, @Nullable String initialDirectory) {
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && initialDirectory != null) {
      intent.putExtra(DocumentsContract.EXTRA_INITIAL_URI, Uri.parse(initialDirectory));
    }
  }

  private void startActivityForResult(
      @NonNull Intent intent, int attemptRequestCode, @NonNull OnResultListener resultListener)
      throws Exception {
    final ActivityPluginBinding binding = activityPluginBinding;
    if (binding == null) throw new IOException("No activity is available.");
    final PluginRegistry.ActivityResultListener listener = new PluginRegistry.ActivityResultListener() {
      private boolean handled;
      @Override
      public boolean onActivityResult(int requestCode, int resultCode, @Nullable Intent data) {
        if (requestCode != attemptRequestCode || handled) return false;
        handled = true;
        binding.removeActivityResultListener(this);
        resultListener.onResult(resultCode, data);
        return true;
      }
    };
    binding.addActivityResultListener(listener);
    try {
      binding.getActivity().startActivityForResult(intent, attemptRequestCode);
    } catch (Exception error) {
      binding.removeActivityResultListener(listener);
      throw error;
    }
  }

  @Nullable
  FileResponse toFileResponse(@NonNull Context context, @NonNull Uri uri) throws IOException {
    final String path = FileUtils.getPathFromCopyOfFileFromUri(context, uri);
    if (path == null) return null;
    final File file = new File(path);
    if (!file.isFile() || !file.canRead()) return null;
    return new FileResponse(path, context.getContentResolver().getType(uri),
        file.getName(), file.length(), new byte[0], null);
  }
}

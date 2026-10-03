enum FileKind {
  folder,
  image,
  video,
  audio,
  text,
  pdf,
  archive,
  android,
  other,
}

FileKind fileKind(String name, {bool directory = false}) {
  if (directory) return FileKind.folder;
  final ext = name.split('.').last.toLowerCase();
  if ({'jpg', 'jpeg', 'png', 'gif', 'webp', 'bmp', 'avif'}.contains(ext)) {
    return FileKind.image;
  }
  if ({
    'mp4',
    'mkv',
    'avi',
    'mov',
    'flv',
    'ts',
    'm3u8',
    'm4v',
    'webm',
    'wmv',
  }.contains(ext)) {
    return FileKind.video;
  }
  if ({'mp3', 'm4a', 'aac', 'flac', 'wav', 'ogg', 'opus'}.contains(ext)) {
    return FileKind.audio;
  }
  if ({
    'txt',
    'md',
    'json',
    'log',
    'csv',
    'srt',
    'lrc',
    'xml',
    'yaml',
    'yml',
    'ini',
    'conf',
    'vtt',
    'ass',
    'ssa',
  }.contains(ext)) {
    return FileKind.text;
  }
  if ({'zip', 'rar', '7z', 'gz', 'tar', 'iso'}.contains(ext)) {
    return FileKind.archive;
  }
  if (ext == 'apk') return FileKind.android;
  if (ext == 'pdf') return FileKind.pdf;
  return FileKind.other;
}

/// What a received file is, for choosing its public home.
enum SaveKind { image, video, audio, file }

/// Where a [SaveKind] is stored: the media library, the Downloads folder, or the folder
/// the person chose.
enum SaveTarget { gallery, downloads, tree }

/// Kind from a MIME type; unknown or empty means a plain file.
SaveKind kindForMime(String mime) {
  final m = mime.toLowerCase();
  if (m.startsWith('image/')) return SaveKind.image;
  if (m.startsWith('video/')) return SaveKind.video;
  if (m.startsWith('audio/')) return SaveKind.audio;
  return SaveKind.file;
}

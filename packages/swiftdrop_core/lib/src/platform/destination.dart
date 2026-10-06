import 'io_kind.dart';

/// Where received files end up on a phone. Plain data so it crosses isolates.
///
/// Photos, videos and audio go to the public media library (Gallery / Photos / Music) when
/// [mediaToGallery] is on. Everything else goes to the folder the person picked once
/// ([treeUri], an Android Storage Access Framework tree), or to Downloads/SwiftDrop.
class SaveDestination {
  const SaveDestination({this.mediaToGallery = true, this.treeUri, this.treeName});

  static const standard = SaveDestination();

  final bool mediaToGallery;
  final String? treeUri;

  /// What the picker reported, shown instead of the raw URI.
  final String? treeName;

  bool get custom => treeUri != null;

  /// Which public place a file of this kind lands in.
  SaveTarget targetFor(SaveKind kind) {
    if (kind != SaveKind.file && mediaToGallery) return SaveTarget.gallery;
    return treeUri != null ? SaveTarget.tree : SaveTarget.downloads;
  }

  SaveDestination copyWith({bool? mediaToGallery, String? treeUri, String? treeName, bool clearTree = false}) => SaveDestination(
        mediaToGallery: mediaToGallery ?? this.mediaToGallery,
        treeUri: clearTree ? null : (treeUri ?? this.treeUri),
        treeName: clearTree ? null : (treeName ?? this.treeName),
      );

  Map<String, Object?> toMap() => {'gallery': mediaToGallery, 'tree': treeUri, 'treeName': treeName};

  factory SaveDestination.fromMap(Map<Object?, Object?> m) =>
      SaveDestination(mediaToGallery: m['gallery'] != false, treeUri: m['tree'] as String?, treeName: m['treeName'] as String?);

  @override
  bool operator ==(Object other) =>
      other is SaveDestination && other.mediaToGallery == mediaToGallery && other.treeUri == treeUri && other.treeName == treeName;

  @override
  int get hashCode => Object.hash(mediaToGallery, treeUri, treeName);
}

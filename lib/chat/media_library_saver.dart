import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:photo_manager/photo_manager.dart';

import '../tdlib/td_image_loader.dart';
import '../tdlib/td_models.dart';

enum MediaLibrarySaveResult { saved, permissionDenied, unsupported, failed }

class MediaLibrarySaveTarget {
  const MediaLibrarySaveTarget({
    required this.fileId,
    required this.file,
    required this.isVideo,
    required this.creationDate,
  });

  final int fileId;
  final TdFileRef file;
  final bool isVideo;
  final DateTime creationDate;

  static MediaLibrarySaveTarget? fromMessage(ChatMessage message) {
    final video = message.video;
    if (video != null) {
      return MediaLibrarySaveTarget(
        fileId: video.id,
        file: video,
        isVideo: true,
        creationDate: _messageDate(message),
      );
    }
    final image = message.image;
    if (message.isPhoto && image != null) {
      return MediaLibrarySaveTarget(
        fileId: image.id,
        file: image,
        isVideo: false,
        creationDate: _messageDate(message),
      );
    }
    return null;
  }

  static DateTime _messageDate(ChatMessage message) =>
      DateTime.fromMillisecondsSinceEpoch(message.date * 1000);
}

/// Picks a video container extension that iOS Photos will accept for import.
///
/// TDLib downloads Telegram videos to extension-less hashed paths (e.g.
/// `files/0/12/12345_0`). `PHAssetChangeRequest` on iOS infers the media kind
/// from the file extension, so a missing/invalid one makes `saveVideo` silently
/// produce a broken (unplayable) asset. We derive a safe extension from either
/// the original file name or the MIME type, falling back to `.mp4`.
String _videoExtension(String? fileName, String? mimeType) {
  final fn = fileName ?? '';
  final dot = fn.lastIndexOf('.');
  if (dot > 0) {
    final ext = fn.substring(dot).toLowerCase();
    if (const {
      '.mp4',
      '.mov',
      '.m4v',
      '.avi',
      '.mkv',
      '.webm',
    }.contains(ext)) {
      return ext;
    }
  }
  switch (mimeType) {
    case 'video/quicktime':
      return '.mov';
    case 'video/x-matroska':
      return '.mkv';
    case 'video/webm':
      return '.webm';
    case 'video/x-msvideo':
      return '.avi';
    default:
      return '.mp4';
  }
}

class MediaLibrarySaver {
  const MediaLibrarySaver._();

  static Future<MediaLibrarySaveResult> save(ChatMessage message) async {
    final target = MediaLibrarySaveTarget.fromMessage(message);
    if (target == null || (!Platform.isIOS && !Platform.isAndroid)) {
      return MediaLibrarySaveResult.unsupported;
    }

    try {
      if (!await _requestWritePermission()) {
        return MediaLibrarySaveResult.permissionDenied;
      }

      final path = await TdFileCenter.shared.pathFor(target.file);
      if (path == null || path.isEmpty) return MediaLibrarySaveResult.failed;
      final file = File(path);
      if (!await file.exists()) return MediaLibrarySaveResult.failed;

      return await _savePreparedFile(
        file,
        isVideo: target.isVideo,
        creationDate: target.creationDate,
        // TDLib's local file name is often extension-less; pass metadata so we
        // can reconstruct a valid extension for iOS video import.
        fileName: target.file.fileName,
        mimeType: target.file.mimeType,
        permissionAlreadyGranted: true,
      );
    } catch (e, st) {
      // Surface the real failure instead of swallowing it, so export problems
      // are debuggable rather than appearing as a silent no-op.
      FlutterError.reportError(FlutterErrorDetails(
        exception: e,
        stack: st,
        library: 'media_library_saver',
        context: ErrorDescription('saving media to Photos library'),
      ));
      return MediaLibrarySaveResult.failed;
    }
  }

  /// Saves an already-downloaded or generated image/video. Sticker export uses
  /// this so GIF/APNG/MOV output follows the same add-only Photos permission
  /// path as ordinary chat media.
  static Future<MediaLibrarySaveResult> savePreparedFile(
    File file, {
    required bool isVideo,
    DateTime? creationDate,
    String? fileName,
    String? mimeType,
  }) async {
    if (!Platform.isIOS && !Platform.isAndroid) {
      return MediaLibrarySaveResult.unsupported;
    }
    try {
      return await _savePreparedFile(
        file,
        isVideo: isVideo,
        creationDate: creationDate,
        fileName: fileName,
        mimeType: mimeType,
      );
    } catch (e, st) {
      FlutterError.reportError(FlutterErrorDetails(
        exception: e,
        stack: st,
        library: 'media_library_saver',
        context: ErrorDescription('saving prepared media to Photos library'),
      ));
      return MediaLibrarySaveResult.failed;
    }
  }

  static Future<MediaLibrarySaveResult> _savePreparedFile(
    File file, {
    required bool isVideo,
    DateTime? creationDate,
    bool permissionAlreadyGranted = false,
    String? fileName,
    String? mimeType,
  }) async {
    if (!permissionAlreadyGranted && !await _requestWritePermission()) {
      return MediaLibrarySaveResult.permissionDenied;
    }
    if (!await file.exists()) return MediaLibrarySaveResult.failed;

    File toSave = file;
    // On iOS, Photos imports video by file extension. TDLib's local path is
    // usually extension-less, which yields a broken asset. Copy to a temp file
    // with a correct extension before handing it to PhotoManager.
    if (isVideo && Platform.isIOS) {
      final ext = _videoExtension(fileName, mimeType);
      final dir = await getTemporaryDirectory();
      final tmp = File('${dir.path}/mithka_export_${file.path.hashCode}$ext');
      await file.copy(tmp.path);
      toSave = tmp;
    }

    final title = toSave.uri.pathSegments.isEmpty
        ? null
        : toSave.uri.pathSegments.last;
    if (isVideo) {
      await PhotoManager.editor.saveVideo(
        toSave,
        title: title,
        creationDate: creationDate,
      );
    } else {
      await PhotoManager.editor.saveImageWithPath(
        toSave.path,
        title: title,
        creationDate: creationDate,
      );
    }
    return MediaLibrarySaveResult.saved;
  }

  static Future<bool> _requestWritePermission() async {
    if (Platform.isIOS) {
      final state = await PhotoManager.requestPermissionExtend(
        requestOption: const PermissionRequestOption(
          iosAccessLevel: IosAccessLevel.addOnly,
        ),
      );
      return state.isAuth;
    }

    final sdk = int.tryParse(await PhotoManager.systemVersion()) ?? 29;
    if (sdk > 28) return true;
    return (await Permission.storage.request()).isGranted;
  }
}

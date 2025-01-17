import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:clipboard/clipboard.dart';
import 'package:dio/dio.dart';
import 'package:extended_image/extended_image.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:get/get_core/src/get_main.dart';
import 'package:get/get_instance/get_instance.dart';
import 'package:get/get_navigation/get_navigation.dart';
import 'package:get/get_rx/get_rx.dart';
import 'package:get/get_state_manager/get_state_manager.dart';
import 'package:get/get_utils/get_utils.dart';
import 'package:jhentai/src/extension/get_logic_extension.dart';
import 'package:jhentai/src/network/eh_request.dart';
import 'package:jhentai/src/service/gallery_download_service.dart';
import 'package:jhentai/src/setting/download_setting.dart';
import 'package:jhentai/src/setting/user_setting.dart';
import 'package:jhentai/src/utils/permission_util.dart';
import 'package:jhentai/src/utils/toast_util.dart';
import 'package:path/path.dart';
import 'package:photo_view/photo_view.dart';
import 'package:saver_gallery/saver_gallery.dart';
import 'package:share_plus/share_plus.dart';
import '../../../../exception/eh_image_exception.dart';
import '../../../../model/gallery_image.dart';
import '../../../../service/path_service.dart';
import '../../../../setting/read_setting.dart';
import '../../../../service/log.dart';
import '../../../../utils/route_util.dart';
import '../../../../utils/screen_size_util.dart';
import '../../read_page_logic.dart';
import '../../read_page_state.dart';

abstract class BaseLayoutLogic extends GetxController with GetTickerProviderStateMixin {
  static const String pageId = 'pageId';

  final ReadPageLogic readPageLogic = Get.find<ReadPageLogic>();
  final ReadPageState readPageState = Get.find<ReadPageLogic>().state;

  Timer? autoModeTimer;
  Worker? doubleTapGestureSwitcherListener;
  Worker? tapDragGestureSwitcherListener;
  Worker? showScrollBarListener;

  @override
  void onInit() {
    doubleTapGestureSwitcherListener = ever(readSetting.enableDoubleTapToScaleUp, (value) => updateSafely([pageId]));
    tapDragGestureSwitcherListener = ever(readSetting.enableTapDragToScaleUp, (value) => updateSafely([pageId]));
    showScrollBarListener = ever(readSetting.showScrollBar, (value) => updateSafely([pageId]));
    super.onInit();
  }

  @override
  void onClose() {
    autoModeTimer?.cancel();
    doubleTapGestureSwitcherListener?.dispose();
    tapDragGestureSwitcherListener?.dispose();
    showScrollBarListener?.dispose();
    super.onClose();
  }

  /// Tap left region or click right arrow key. If read direction is right-to-left, we should call [toNext], otherwise [toPrev]
  void toLeft();

  /// Tap right region or click right arrow key. If read direction is right-to-left, we should call [toPrev], otherwise [toNext]
  void toRight();

  /// to prev image or screen
  void toPrev();

  /// to next image or screen
  void toNext();

  void toImageIndex(int imageIndex) {
    if (readSetting.enablePageTurnAnime.isFalse) {
      jump2ImageIndex(imageIndex);
    } else {
      scroll2ImageIndex(imageIndex);
    }
  }

  @mustCallSuper
  void scroll2ImageIndex(int imageIndex, [Duration? duration]) {
    readPageLogic.update([readPageLogic.sliderId]);
  }

  @mustCallSuper
  void jump2ImageIndex(int imageIndex) {
    readPageLogic.syncThumbnails(imageIndex);
    readPageLogic.update([readPageLogic.sliderId]);
  }

  PhotoViewScaleState scaleStateCycle(PhotoViewScaleState actual) {
    switch (actual) {
      case PhotoViewScaleState.initial:
        return PhotoViewScaleState.zoomedIn;
      default:
        return PhotoViewScaleState.initial;
    }
  }

  void toggleDisplayFirstPageAlone() {}

  void enterAutoMode();

  @mustCallSuper
  void closeAutoMode() {
    autoModeTimer?.cancel();
  }

  void onPointerScroll(PointerScrollEvent value) {
    if (value.scrollDelta.dy > 0) {
      toNext();
    } else if (value.scrollDelta.dy < 0) {
      toPrev();
    }
  }

  void showBottomMenuInOnlineMode(int index, BuildContext context) {
    showCupertinoModalPopup(
      context: context,
      builder: (_) => CupertinoActionSheet(
        actions: <CupertinoActionSheetAction>[
          CupertinoActionSheetAction(
            child: Text('reload'.tr),
            onPressed: () {
              backRoute();
              readPageLogic.reloadImage(index);
            },
          ),
          CupertinoActionSheetAction(
            child: Text('share'.tr),
            onPressed: () async {
              backRoute();
              shareOnlineImage(index);
            },
          ),
          CupertinoActionSheetAction(
            child: Text('${'save'.tr}(${'resampleImage'.tr})'),
            onPressed: () async {
              backRoute();
              saveOnlineImage(index);
            },
          ),
          if (readPageState.images[index]!.originalImageUrl != null && userSetting.hasLoggedIn())
            CupertinoActionSheetAction(
              child: Text('${'save'.tr}(${'originalImage'.tr})'),
              onPressed: () async {
                backRoute();
                saveOriginalOnlineImage(index);
              },
            ),
        ],
        cancelButton: CupertinoActionSheetAction(child: Text('cancel'.tr), onPressed: backRoute),
      ),
    );
  }

  void showBottomMenuInLocalMode(int index, BuildContext context) {
    if (galleryDownloadService.galleryDownloadInfos[readPageState.readPageInfo.gid]?.images[index]?.downloadStatus != DownloadStatus.downloaded) {
      return;
    }

    showCupertinoModalPopup(
      context: context,
      builder: (_) => CupertinoActionSheet(
        actions: <CupertinoActionSheetAction>[
          CupertinoActionSheetAction(
            child: Text('share'.tr),
            onPressed: () {
              backRoute();
              shareLocalImage(index);
            },
          ),
          CupertinoActionSheetAction(
            child: Text('save'.tr),
            onPressed: () {
              backRoute();
              saveLocalImage(index);
            },
          ),
          CupertinoActionSheetAction(
            child: Text('reDownload'.tr),
            onPressed: () {
              backRoute();
              galleryDownloadService.reDownloadImage(readPageState.readPageInfo.gid!, index);
            },
          ),
        ],
        cancelButton: CupertinoActionSheetAction(child: Text('cancel'.tr), onPressed: backRoute),
      ),
    );
  }

  void shareOnlineImage(int index) async {
    if (readPageState.images[index] == null) {
      return;
    }

    if (GetPlatform.isDesktop) {
      await FlutterClipboard.copy(readPageState.images[index]!.url);
      toast('hasCopiedToClipboard'.tr);
      return;
    }

    Uint8List? data = await getNetworkImageData(readPageState.images[index]!.url);
    if (data == null) {
      return;
    }

    String fileName = '${readPageState.readPageInfo.gid!}_${readPageState.readPageInfo.token!}_$index${extension(readPageState.images[index]!.url)}';

    Share.shareXFiles(
      [XFile.fromData(data)],
      sharePositionOrigin: Rect.fromLTWH(0, 0, fullScreenWidth, readPageState.displayRegionSize.height * 2 / 3),
      // fileNameOverrides: [fileName],
    );
  }

  void shareLocalImage(int index) {
    if (GetPlatform.isDesktop) {
      FlutterClipboard.copy(readPageState.images[index]!.url).then((_) => toast('hasCopiedToClipboard'.tr));
      return;
    }

    Share.shareXFiles(
      [
        XFile(
          GalleryDownloadService.computeImageDownloadAbsolutePathFromRelativePath(
            galleryDownloadService.galleryDownloadInfos[readPageState.readPageInfo.gid!]!.images[index]!.path!,
          ),
        )
      ],
      sharePositionOrigin: Rect.fromLTWH(0, 0, fullScreenWidth, readPageState.displayRegionSize.height * 2 / 3),
    );
  }

  Future<void> saveOnlineImage(int index) async {
    if (readPageState.images[index] == null) {
      return;
    }

    Uint8List? data = await getNetworkImageData(readPageState.images[index]!.url);
    if (data == null) {
      return;
    }

    String fileName = '${readPageState.readPageInfo.gid!}_${readPageState.readPageInfo.token!}_$index${extension(readPageState.images[index]!.url)}';

    if (GetPlatform.isDesktop) {
      File file = File(join(downloadSetting.singleImageSavePath.value, fileName));
      try {
        await file.create(recursive: true);
        await file.writeAsBytes(data);
        toast('saveSuccess'.tr);
      } catch (e) {
        log.error('Save online image failed: $e');
        toast('saveFailed'.tr);
        file.delete().ignore();
        return;
      }
    } else {
      File file = File(join(downloadSetting.tempDownloadPath.value, fileName));
      try {
        await file.create(recursive: true);
        await file.writeAsBytes(data);
        bool success = await _saveFile2Album(file.path, fileName);
        toast(success ? 'saveSuccess'.tr : 'saveFailed'.tr);
      } catch (e) {
        log.error('Save online image failed: $e');
        toast('saveFailed'.tr);
        file.delete().ignore();
        return;
      }
    }
  }

  Future<void> saveOriginalOnlineImage(int index) async {
    if (readPageState.images[index] == null) {
      return;
    }

    if (readPageState.images[index]!.originalImageUrl == null || !userSetting.hasLoggedIn()) {
      return saveOnlineImage(index);
    }

    String fileName =
        '${readPageState.readPageInfo.gid!}_${readPageState.readPageInfo.token!}_${index}_original${extension(readPageState.images[index]!.originalImageUrl!)}';
    String downloadPath = join(downloadSetting.tempDownloadPath.value, fileName);
    File file = File(downloadPath);

    toast('downloading'.tr);
    Response response = await ehRequest.download(url: readPageState.images[index]!.originalImageUrl!, path: downloadPath);

    /// what we downloaded is not an image
    if (!response.isRedirect && (response.headers[Headers.contentTypeHeader]?.contains("text/html; charset=UTF-8") ?? false)) {
      File file = File(downloadPath);
      String data = file.readAsStringSync();
      file.delete().ignore();

      EHImageException? exception = GalleryDownloadService.imageData2Exception(data);
      log.error('Save ${readPageState.readPageInfo.galleryTitle} image: $index failed, invalid reason: $exception');

      if (exception != null) {
        if (exception.operation == EHImageExceptionAfterOperation.pause) {
          toast(exception.message, isShort: false);
          return;
        } else if (exception.operation == EHImageExceptionAfterOperation.pauseAll) {
          toast(exception.message, isShort: false);
          return;
        } else if (exception.operation == EHImageExceptionAfterOperation.reParse) {
          GalleryImage image;
          try {
            image = await readPageLogic.requestImage(index, true, null);
          } catch (e) {
            log.error('Save original image failed: $e');
            toast('saveFailed'.tr);
            return;
          }

          readPageState.images[index]!.originalImageUrl = image.originalImageUrl;

          return saveOriginalOnlineImage(index);
        }
      } else {
        toast('saveFailed'.tr, isShort: false);
        return;
      }
    }

    try {
      if (GetPlatform.isDesktop) {
        await file.copy(join(downloadSetting.singleImageSavePath.value, fileName));
        toast('saveSuccess'.tr);
      } else {
        bool success = await _saveFile2Album(downloadPath, fileName);
        toast(success ? 'saveSuccess'.tr : 'saveFailed'.tr);
      }
    } catch (e) {
      log.error('Save original online image failed: $e');
      toast('saveFailed'.tr);
    } finally {
      file.delete().ignore();
    }
  }

  void saveLocalImage(int index) {
    String filePath = GalleryDownloadService.computeImageDownloadAbsolutePathFromRelativePath(
      galleryDownloadService.galleryDownloadInfos[readPageState.readPageInfo.gid!]!.images[index]!.path!,
    );
    File image = File(filePath);

    String fileName = basename(image.path);
    if (readPageState.readPageInfo.gid != null && readPageState.readPageInfo.token != null) {
      fileName = '${readPageState.readPageInfo.gid!}_${readPageState.readPageInfo.token!}_$index${extension(image.path)}';
    }

    if (GetPlatform.isDesktop) {
      image.copy(join(downloadSetting.singleImageSavePath.value, fileName)).then((_) => toast('success'.tr));
    } else {
      _saveFile2Album(filePath, fileName).then((_) => toast('success'.tr));
    }
  }

  /// Compute image container size when we haven't parsed image's size
  Size getPlaceHolderSize(int imageIndex) {
    if (readPageState.imageContainerSizes[imageIndex] != null) {
      return readPageState.imageContainerSizes[imageIndex]!;
    }
    return Size(double.infinity, readPageState.displayRegionSize.height / 2);
  }

  /// Compute image container size
  FittedSizes getImageFittedSize(Size imageSize) {
    return applyBoxFit(
      BoxFit.contain,
      Size(imageSize.width, imageSize.height),
      Size(readPageState.displayRegionSize.width, double.infinity),
    );
  }

  Alignment _computeAlignmentByTapOffset(Offset offset) {
    return Alignment((offset.dx - Get.size.width / 2) / (Get.size.width / 2), (offset.dy - Get.size.height / 2) / (Get.size.height / 2));
  }

  Future<bool> _saveImage2Album(Uint8List imageData, String fileName) async {
    await requestAlbumPermission();

    SaveResult saveResult = await SaverGallery.saveImage(
      imageData,
      name: fileName,
      androidRelativePath: "Pictures/JHenTai",
      androidExistNotSave: false,
    );

    log.info('Save image to album: $saveResult');

    return saveResult.isSuccess;
  }

  Future<bool> _saveFile2Album(String filePath, String fileName) async {
    await requestAlbumPermission();

    SaveResult saveResult = await SaverGallery.saveFile(
      file: filePath,
      name: fileName,
      androidRelativePath: "Pictures/JHenTai",
      androidExistNotSave: false,
    );

    log.info('Save image to album: $saveResult');

    return saveResult.isSuccess;
  }
}

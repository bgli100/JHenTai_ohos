import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:jhentai/src/network/eh_request.dart';
import 'package:jhentai/src/pages/home/tab_view/gallerys/gallerys_view.dart';
import 'package:jhentai/src/pages/home/tab_view/gallerys/gallerys_view_logic.dart';
import 'package:jhentai/src/setting/advanced_setting.dart';
import 'package:jhentai/src/utils/eh_spider_parser.dart';
import 'package:jhentai/src/utils/log.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:retry/retry.dart';

import '../../config/global_config.dart';
import '../../widget/update_dialog.dart';
import 'home_page_state.dart';

class HomePageLogic extends GetxController {
  final HomePageState state = HomePageState();

  @override
  void onReady() {
    _checkUpdate();
    super.onReady();
  }

  /// tap another bar -> change index
  /// at gallery bar and tap gallery bar again -> scroll to top
  /// at gallery bar and tap gallery bar twice -> scroll to top and refresh
  void handleTapNavigationBar(int index) {
    int prevIndex = state.currentIndex;
    state.currentIndex = index;

    if (prevIndex != index) {
      return;
    }
    if (index != 0) {
      return;
    }

    ScrollController? scrollController = galleryListKey.currentState?.innerController;

    /// no gallerys data
    if (scrollController?.hasClients == false) {
      return;
    }

    /// scroll to top
    if ((scrollController?.positions as List<ScrollPosition>).any((position) => position.pixels != 0)) {
      scrollController?.animateTo(
        0,
        duration: const Duration(milliseconds: 400),
        curve: Curves.ease,
      );
    }

    if (state.lastTapTime == null) {
      state.lastTapTime = DateTime.now();
      return;
    }

    if (DateTime.now().difference(state.lastTapTime!).inMilliseconds <= 200) {
      /// reset [prevPageIndexToLoad] to refresh rather than load prev page
      GallerysViewLogic gallerysViewLogic = Get.find<GallerysViewLogic>();
      gallerysViewLogic.state.prevPageIndexToLoad[gallerysViewLogic.tabController.index] = null;

      Future.delayed(
        const Duration(milliseconds: 0),

        /// default value equals to CupertinoSliverRefreshControl._defaultRefreshTriggerPullDistance
        () => scrollController?.animateTo(
          -GlobalConfig.refreshTriggerPullDistance,
          duration: const Duration(milliseconds: 400),
          curve: Curves.ease,
        ),
      );
    }

    state.lastTapTime = DateTime.now();
  }

  Future<void> _checkUpdate() async {
    if (AdvancedSetting.enableCheckUpdate.isFalse) {
      return;
    }

    String url = 'https://api.github.com/repos/jiangtian616/JHenTai/releases';
    String latestVersion;

    try {
      latestVersion = (await retry(
        () => EHRequest.request(
          url: url,
          useCacheIfAvailable: false,
          parser: EHSpiderParser.githubReleasePage2LatestVersion,
        ),
        maxAttempts: 3,
      ))
          .trim()
          .split('+')[0];
    } on Exception catch (_) {
      Log.info('check update failed');
      return;
    }

    PackageInfo packageInfo = await PackageInfo.fromPlatform();
    String currentVersion = 'v${packageInfo.version}'.trim();
    Log.info('Latest version:[$latestVersion], current version: [$currentVersion]');

    if (latestVersion == currentVersion) {
      return;
    }

    Get.dialog(UpdateDialog(currentVersion: currentVersion, latestVersion: latestVersion));
  }
}

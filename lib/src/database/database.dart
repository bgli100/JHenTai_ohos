import 'dart:convert';
import 'dart:io' as io;
import 'dart:io';

import 'package:drift/drift.dart';

import 'package:drift/native.dart';
import 'package:get/get_core/src/get_main.dart';
import 'package:get/get_instance/src/extension_instance.dart';
import 'package:get/get_utils/get_utils.dart';
import 'package:jhentai/src/database/dao/gallery_group_dao.dart';
import 'package:jhentai/src/database/dao/gallery_history_dao.dart';
import 'package:jhentai/src/database/dao/super_resolution_info_dao.dart';
import 'package:jhentai/src/database/table/archive_downloaded.dart';
import 'package:jhentai/src/database/table/archive_group.dart';
import 'package:jhentai/src/database/table/block_rule.dart';
import 'package:jhentai/src/database/table/dio_cache.dart';
import 'package:jhentai/src/database/table/gallery_downloaded.dart';
import 'package:jhentai/src/database/table/gallery_group.dart';
import 'package:jhentai/src/database/table/gallery_history.dart';
import 'package:jhentai/src/database/table/image.dart';
import 'package:jhentai/src/database/table/super_resolution_info.dart';
import 'package:jhentai/src/database/table/tag.dart';
import 'package:jhentai/src/database/table/tag_count.dart';
import 'package:jhentai/src/exception/upload_exception.dart';
import 'package:jhentai/src/extension/directory_extension.dart';
import 'package:jhentai/src/setting/path_setting.dart';
import 'package:jhentai/src/utils/log.dart';
import 'package:path/path.dart';
import 'package:sqlite3_flutter_libs/sqlite3_flutter_libs.dart';
import 'package:sqlite3/sqlite3.dart';

import '../model/gallery.dart';
import '../service/archive_download_service.dart';
import '../service/storage_service.dart';
import 'dao/archive_dao.dart';
import 'dao/archive_group_dao.dart';
import 'dao/gallery_dao.dart';

part 'database.g.dart';

@DriftDatabase(
  tables: [
    OldSuperResolutionInfo,
    SuperResolutionInfo,
    Tag,
    ArchiveDownloaded,
    ArchiveDownloadedOld,
    ArchiveGroup,
    GalleryDownloaded,
    GalleryDownloadedOld,
    GalleryGroup,
    Image,
    GalleryHistory,
    TagCount,
    DioCache,
    BlockRule,
  ],
)
class AppDb extends _$AppDb {
  AppDb() : super(_openConnection());

  @override
  int get schemaVersion => 21;

  @override
  MigrationStrategy get migration {
    return MigrationStrategy(
      onUpgrade: (Migrator m, int from, int to) async {
        Log.warning('Database version: $from -> $to');
        if (from > to) {
          return;
        }

        try {
          if (from < 2) {
            await m.alterTable(TableMigration(image));
          }
          if (from < 3) {
            await m.addColumn(galleryDownloaded, galleryDownloaded.downloadOriginalImage);
          }
          if (from < 4) {
            await m.addColumn(galleryDownloaded, galleryDownloaded.priority);
          }
          if (from < 11) {
            await m.addColumn(galleryDownloaded, galleryDownloaded.sortOrder);
            await m.addColumn(galleryGroup, galleryGroup.sortOrder);
            await m.addColumn(archiveDownloaded, archiveDownloaded.sortOrder);
            await m.addColumn(archiveGroup, archiveGroup.sortOrder);
          }
          if (from < 5) {
            await m.addColumn(galleryDownloaded, galleryDownloaded.groupName);
            await m.addColumn(archiveDownloaded, archiveDownloaded.groupName);
            await _updateArchive(m);
          }
          if (from < 6) {
            await _updateHistory(m);
          }
          if (5 <= from && from < 7) {
            await m.addColumn(galleryDownloaded, galleryDownloaded.groupName);
            await m.addColumn(archiveDownloaded, archiveDownloaded.groupName);
          }
          if (from < 8) {
            await _createGroupTable(m);
          }
          if (from < 9) {
            await _updateConfigFileLocation();
          }
          if (from < 10) {
            await _deleteImageSizeColumn(m);
          }
          if (from < 13) {
            await m.createTable(superResolutionInfo);
          }
          if (from < 14) {
            await m.createTable(tagCount);
            await m.createTable(dioCache);
            await m.createIndex(idxExpireDate);
            await m.createIndex(idxUrl);
          }
          if (from < 15) {
            await _migrateSuperResolutionInfo(m);
          }
          if (from < 16) {
            await m.createIndex(idxKey);
            await m.createIndex(idxTagName);
          }
          if (from < 17) {
            await _migrateDownloadedInfo(m);
          }
          if (from < 18) {
            await m.createIndex(idxLastReadTime);
          }
          if (from < 19) {
            await _migrateArchiveStatus(m);
          }
          if (from < 20) {
            await m.createTable(blockRule);
          }
          if (from < 21) {
            await m.addColumn(galleryDownloaded, galleryDownloaded.tags);
            await m.addColumn(galleryDownloaded, galleryDownloaded.tagRefreshTime);
            await m.createIndex(gIdxTagRefreshTime);
            await m.addColumn(archiveDownloaded, archiveDownloaded.tags);
            await m.addColumn(archiveDownloaded, archiveDownloaded.tagRefreshTime);
            await m.createIndex(aIdxTagRefreshTime);
          }
        } on Exception catch (e) {
          Log.error(e);
          Log.uploadError(e, extraInfos: {'from': from, 'to': to});
          throw NotUploadException(e);
        }
      },
    );
  }

  Future<void> _updateArchive(Migrator m) async {
    try {
      List<ArchiveDownloadedOldData> archives = await ArchiveDao.selectOldArchives();

      await appDb.transaction(() async {
        for (ArchiveDownloadedOldData a in archives) {
          await ArchiveDao.updateOldArchive(
            ArchiveDownloadedOldCompanion(
              gid: Value(a.gid),
              archiveStatusIndex: Value(a.archiveStatusIndex + 1),
            ),
          );
        }
      });
    } on Exception catch (e) {
      Log.error('Update archive failed!', e);
      Log.uploadError(e);
    }
  }

  Future<void> _updateHistory(Migrator m) async {
    try {
      await m.createTable(galleryHistory);

      if (Get.isRegistered<StorageService>()) {
        List<Gallery>? gallerys = Get.find<StorageService>().read<List>('history')?.map((e) => Gallery.fromJson(e)).toList();

        if (gallerys != null) {
          await appDb.transaction(() async {
            for (Gallery g in gallerys.reversed) {
              await GalleryHistoryDao.insertHistory(
                GalleryHistoryData(
                  gid: g.gid,
                  jsonBody: json.encode(g),
                  lastReadTime: DateTime.now().toString(),
                ),
              );
            }
          });
        }

        Get.find<StorageService>().remove('history');
      }
    } on Exception catch (e) {
      Log.error('Update history failed!', e);
      Log.uploadError(e);
    }
  }

  Future<void> _createGroupTable(Migrator m) async {
    try {
      await m.createTable(galleryGroup);
      await m.createTable(archiveGroup);

      Set<String> galleryGroups = (await GalleryDao.selectOldGallerys()).map((g) => g.groupName ?? 'default'.tr).toSet();
      Set<String> archiveGroups = (await ArchiveDao.selectOldArchives()).map((g) => g.groupName ?? 'default'.tr).toSet();

      Log.info('Migrate gallery groups: $galleryGroups');
      Log.info('Migrate archive groups: $archiveGroups');

      await appDb.transaction(() async {
        for (String groupName in galleryGroups) {
          await GalleryGroupDao.insertGalleryGroup(GalleryGroupData(groupName: groupName, sortOrder: 0));
        }
        for (String groupName in archiveGroups) {
          await ArchiveGroupDao.insertArchiveGroup(ArchiveGroupData(groupName: groupName, sortOrder: 0));
        }
      });
    } on Exception catch (e) {
      Log.error('Create Group Table failed!', e);
      Log.uploadError(e);
    }
  }

  /// copy files
  Future<void> _updateConfigFileLocation() async {
    await PathSetting.appSupportDir?.copy(PathSetting.getVisibleDir().path);
  }

  Future<void> _deleteImageSizeColumn(Migrator m) async {
    await m.alterTable(TableMigration(archiveDownloaded));
    await m.alterTable(TableMigration(image));
  }

  Future<void> _migrateSuperResolutionInfo(Migrator m) async {
    try {
      await m.createTable(superResolutionInfo);

      List<OldSuperResolutionInfoData> oldSuperResolutionInfo = await SuperResolutionInfoDao.selectAllOldSuperResolutionInfo();

      await appDb.transaction(() async {
        for (OldSuperResolutionInfoData old in oldSuperResolutionInfo) {
          await SuperResolutionInfoDao.insertSuperResolutionInfo(
            SuperResolutionInfoData(
              gid: old.gid,
              type: old.type,
              status: old.status,
              imageStatuses: old.imageStatuses,
            ),
          );
        }
      });
    } on Exception catch (e) {
      Log.error('Migrate super resolution info failed!', e);
      Log.uploadError(e);
    }
  }

  Future<void> _migrateDownloadedInfo(Migrator m) async {
    try {
      await m.createTable(galleryDownloaded);
      await m.createTable(archiveDownloaded);

      List<GalleryDownloadedOldData> gallerys = await GalleryDao.selectOldGallerys();
      await appDb.transaction(() async {
        for (GalleryDownloadedOldData g in gallerys) {
          await GalleryDao.insertGallery(
            GalleryDownloadedCompanion.insert(
              gid: Value(g.gid),
              token: g.token,
              title: g.title,
              category: g.category,
              pageCount: g.pageCount,
              galleryUrl: g.galleryUrl,
              oldVersionGalleryUrl: Value(g.oldVersionGalleryUrl),
              uploader: Value(g.uploader),
              publishTime: g.publishTime,
              downloadStatusIndex: g.downloadStatusIndex,
              insertTime: g.insertTime!,
              downloadOriginalImage: Value(g.downloadOriginalImage),
              priority: g.priority ?? 0,
              sortOrder: Value(g.sortOrder),
              groupName: g.groupName!,
              tagRefreshTime: Value(DateTime.now().toString()),
            ),
          );
        }
      });

      List<ArchiveDownloadedOldData> archives = await ArchiveDao.selectOldArchives();
      await appDb.transaction(() async {
        for (ArchiveDownloadedOldData a in archives) {
          await ArchiveDao.insertArchive(
            ArchiveDownloadedCompanion.insert(
              gid: Value(a.gid),
              token: a.token,
              title: a.title,
              category: a.category,
              pageCount: a.pageCount,
              galleryUrl: a.galleryUrl,
              coverUrl: a.coverUrl,
              uploader: Value(a.uploader),
              size: a.size,
              publishTime: a.publishTime,
              archiveStatusCode: a.archiveStatusIndex,
              archivePageUrl: a.archivePageUrl,
              downloadPageUrl: Value(a.downloadPageUrl),
              downloadUrl: Value(a.downloadUrl),
              isOriginal: a.isOriginal,
              insertTime: a.insertTime!,
              sortOrder: Value(a.sortOrder),
              groupName: a.groupName!,
              tagRefreshTime: Value(DateTime.now().toString()),
            ),
          );
        }
      });
    } catch (e) {
      Log.error('Migrate downloaded info failed!', e);
      Log.uploadError(e);
    }
  }

  Future<void> _migrateArchiveStatus(Migrator m) async {
    await ArchiveDao.updateArchiveStatus(OldArchiveStatus.none.index, ArchiveStatus.unlocking.code);
    await ArchiveDao.updateArchiveStatus(OldArchiveStatus.needReUnlock.index, ArchiveStatus.needReUnlock.code);
    await ArchiveDao.updateArchiveStatus(OldArchiveStatus.paused.index, ArchiveStatus.paused.code);
    await ArchiveDao.updateArchiveStatus(OldArchiveStatus.unlocking.index, ArchiveStatus.unlocking.code);
    await ArchiveDao.updateArchiveStatus(OldArchiveStatus.parsingDownloadPageUrl.index, ArchiveStatus.parsingDownloadPageUrl.code);
    await ArchiveDao.updateArchiveStatus(OldArchiveStatus.parsingDownloadUrl.index, ArchiveStatus.parsingDownloadUrl.code);
    await ArchiveDao.updateArchiveStatus(OldArchiveStatus.downloading.index, ArchiveStatus.downloading.code);
    await ArchiveDao.updateArchiveStatus(OldArchiveStatus.downloaded.index, ArchiveStatus.downloaded.code);
    await ArchiveDao.updateArchiveStatus(OldArchiveStatus.unpacking.index, ArchiveStatus.unpacking.code);
    await ArchiveDao.updateArchiveStatus(OldArchiveStatus.completed.index, ArchiveStatus.completed.code);
  }
}

LazyDatabase _openConnection() {
  return LazyDatabase(() async {
    final file = io.File(join(PathSetting.getVisibleDir().path, 'db.sqlite'));

    if (Platform.isAndroid) {
      await applyWorkaroundToOpenSqlite3OnOldAndroidVersions();
    }

    sqlite3.tempDirectory = PathSetting.tempDir.path;

    return NativeDatabase(file);
  });
}

AppDb appDb = AppDb();

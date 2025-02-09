@import WMF;
#import "Wikipedia-Swift.h"
#import "WMFArticleFetcher.h"
#import "MWKImageInfoFetcher.h"

NSString *const WMFArticleSaveToDiskDidFailNotification = @"WMFArticleSavedToDiskWithErrorNotification";
NSString *const WMFArticleSaveToDiskDidFailArticleURLKey = @"WMFArticleSavedToDiskWithArticleURLKey";
NSString *const WMFArticleSaveToDiskDidFailErrorKey = @"WMFArticleSavedToDiskWithErrorKey";

static DDLogLevel const WMFSavedArticlesFetcherLogLevel = DDLogLevelDebug;

NSString *const WMFSavedPageErrorDomain = @"WMFSavedPageErrorDomain";
NSInteger const WMFSavePageImageDownloadError = 1;

#undef LOG_LEVEL_DEF
#define LOG_LEVEL_DEF WMFSavedArticlesFetcherLogLevel

NS_ASSUME_NONNULL_BEGIN

@interface NSError (SavedArticlesFetcherErrors)

/**
 *  @return Generic error used to indicate one or more images failed to download for the article or its gallery.
 */
+ (instancetype)wmf_savedPageImageDownloadErrorWithUnderlyingError:(nullable NSError *)error;

@end


@interface SavedArticlesFetcher ()

@property (nonatomic, strong, readwrite) dispatch_queue_t accessQueue;

@property (nonatomic, strong) MWKDataStore *dataStore;
@property (nonatomic, strong) WMFArticleFetcher *articleFetcher;
@property (nonatomic, strong) WMFImageController *imageController;
@property (nonatomic, strong) MWKImageInfoFetcher *imageInfoFetcher;
@property (nonatomic, strong) WMFSavedPageSpotlightManager *spotlightManager;

@property (nonatomic, getter=isUpdating) BOOL updating;
@property (nonatomic, getter=isRunning) BOOL running;

@property (nonatomic, strong) NSMutableDictionary<NSURL *, NSURLSessionTask *> *fetchOperationsByArticleTitle;
@property (nonatomic, strong) NSMutableDictionary<NSURL *, NSError *> *errorsByArticleTitle;

@property (nonatomic, strong) NSNumber *fetchesInProcessCount;

@property (nonatomic, strong) SavedArticlesFetcherProgressManager *savedArticlesFetcherProgressManager;

@property (nonatomic) UIBackgroundTaskIdentifier backgroundTaskIdentifier;

@end

@implementation SavedArticlesFetcher

#pragma mark - NSObject

static SavedArticlesFetcher *_articleFetcher = nil;

- (void)dealloc {
    [self stop];
}

- (instancetype)initWithDataStore:(MWKDataStore *)dataStore
                   articleFetcher:(WMFArticleFetcher *)articleFetcher
                  imageController:(WMFImageController *)imageController
                 imageInfoFetcher:(MWKImageInfoFetcher *)imageInfoFetcher {
    NSParameterAssert(dataStore);
    NSParameterAssert(articleFetcher);
    NSParameterAssert(imageController);
    NSParameterAssert(imageInfoFetcher);
    self = [super init];
    if (self) {
        self.backgroundTaskIdentifier = UIBackgroundTaskInvalid;
        self.fetchesInProcessCount = @0;
        self.accessQueue = dispatch_queue_create("org.wikipedia.savedarticlesarticleFetcher.accessQueue", DISPATCH_QUEUE_SERIAL);
        self.fetchOperationsByArticleTitle = [NSMutableDictionary new];

        [self updateFetchesInProcessCount];

        self.errorsByArticleTitle = [NSMutableDictionary new];
        self.dataStore = dataStore;
        self.articleFetcher = articleFetcher;
        self.imageController = imageController;
        self.imageInfoFetcher = imageInfoFetcher;
        self.spotlightManager = [[WMFSavedPageSpotlightManager alloc] initWithDataStore:self.dataStore];
        self.savedArticlesFetcherProgressManager = [[SavedArticlesFetcherProgressManager alloc] initWithDelegate:self];
    }
    return self;
}

- (instancetype)initWithDataStore:(MWKDataStore *)dataStore {
    return [self initWithDataStore:dataStore
                    articleFetcher:[[WMFArticleFetcher alloc] initWithDataStore:dataStore]
                   imageController:[WMFImageController sharedInstance]
                  imageInfoFetcher:[[MWKImageInfoFetcher alloc] init]];
}

#pragma mark - Progress

// Reminder: due to the internal structure of this class and how it is presently being used, we can't simply check the 'count' of 'fetchOperationsByArticleTitle' dictionary for the total. (It doesn't reflect the actual total.) Could re-plumb this class later.
- (NSUInteger)calculateTotalArticlesToFetchCount {
    NSAssert([NSThread isMainThread], @"Must be called on the main thread");
    NSManagedObjectContext *moc = self.dataStore.viewContext;
    NSFetchRequest *request = [WMFArticle fetchRequest];
    request.includesSubentities = NO;
    request.predicate = [NSPredicate predicateWithFormat:@"savedDate != NULL && isDownloaded != YES"];
    NSError *fetchError = nil;
    NSUInteger count = [moc countForFetchRequest:request error:&fetchError];
    if (fetchError) {
        DDLogError(@"Error counting number of article to be downloaded: %@", fetchError);
    }
    return count;
}

- (void)updateFetchesInProcessCount {
    NSUInteger count = [self calculateTotalArticlesToFetchCount];
    if (count == NSNotFound) {
        return;
    }
    self.fetchesInProcessCount = @(count);
}

#pragma mark - Public

- (void)start {
    self.running = YES;
    [self observeSavedPages];
    [self update];
}

- (void)cancelAllRequests {
    [self.imageController cancelPermanentCacheRequests];
    dispatch_async(dispatch_get_main_queue(), ^{
        NSArray *allKeys = [self.fetchOperationsByArticleTitle.allKeys copy];
        for (NSURL *articleURL in allKeys) {
            [self cancelFetchForArticleURL:articleURL];
        }
    });
}

- (void)stop {
    self.running = NO;
    [self unobserveSavedPages];
}

#pragma mark - Observing

- (void)articleWasUpdated:(NSNotification *)note {
    id object = [note object];
    if (![object isKindOfClass:[WMFArticle class]]) {
        return;
    }
    WMFArticle *article = object;
    if (![article hasChangedValuesForCurrentEventThatAffectSavedArticlesFetch]) {
        return;
    }
    [self update];
}

- (void)syncDidFinish:(NSNotification *)note {
    [self update];
}

- (void)_update {
    if (self.isUpdating || !self.isRunning) {
        [self updateFetchesInProcessCount];
        return;
    }
    self.updating = YES;
    dispatch_block_t endBackgroundTask = ^{
        if (self.backgroundTaskIdentifier != UIBackgroundTaskInvalid) {
            [UIApplication.sharedApplication endBackgroundTask:self.backgroundTaskIdentifier];
            self.backgroundTaskIdentifier = UIBackgroundTaskInvalid;
        }
    };
    if (self.backgroundTaskIdentifier == UIBackgroundTaskInvalid) {
        self.backgroundTaskIdentifier = [UIApplication.sharedApplication beginBackgroundTaskWithName:@"SavedArticlesFetch"
                                                                                   expirationHandler:^{
                                                                                       [self cancelAllRequests];
                                                                                       [self stop];
                                                                                       endBackgroundTask();
                                                                                   }];
    }
    NSAssert([NSThread isMainThread], @"Update must be called on the main thread");
    NSManagedObjectContext *moc = self.dataStore.viewContext;

    NSFetchRequest *request = [WMFArticle fetchRequest];
    request.predicate = [NSPredicate predicateWithFormat:@"savedDate != NULL && isDownloaded != YES"];
    request.sortDescriptors = @[[NSSortDescriptor sortDescriptorWithKey:@"savedDate" ascending:YES]];
    request.fetchLimit = 1;
    NSError *fetchError = nil;
    WMFArticle *article = [[moc executeFetchRequest:request error:&fetchError] firstObject];
    if (fetchError) {
        DDLogError(@"Error fetching next article to download: %@", fetchError);
    }
    dispatch_block_t updateAgain = ^{
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            self.updating = NO;
            [self update];
        });
    };
    if (article) {
        NSURL *articleURL = article.URL;
        if (articleURL) {
            [self fetchArticleURL:articleURL
                priority:NSURLSessionTaskPriorityLow
                failure:^(NSError *error) {
                    [self updateFetchesInProcessCount];
                    updateAgain();
                }
                success:^{
                    [self.spotlightManager addToIndexWithUrl:articleURL];
                    [self updateFetchesInProcessCount];
                    updateAgain();
                }];
        } else {
            self.updating = NO;
            endBackgroundTask();
        }
    } else {
        NSFetchRequest *downloadedRequest = [WMFArticle fetchRequest];
        downloadedRequest.predicate = [NSPredicate predicateWithFormat:@"savedDate == nil && isDownloaded == YES"];
        downloadedRequest.fetchLimit = 1;
        downloadedRequest.sortDescriptors = @[[NSSortDescriptor sortDescriptorWithKey:@"savedDate" ascending:YES]];
        NSError *downloadedFetchError = nil;
        WMFArticle *articleToDelete = [[self.dataStore.viewContext executeFetchRequest:downloadedRequest error:&downloadedFetchError] firstObject];
        if (downloadedFetchError) {
            DDLogError(@"Error fetching downloaded unsaved articles: %@", downloadedFetchError);
        }
        if (articleToDelete) {
            NSURL *articleURL = article.URL;
            if (!articleURL) {
                self.updating = NO;
                [self updateFetchesInProcessCount];
                endBackgroundTask();
                return;
            }
            [self cancelFetchForArticleURL:articleURL];
            [self removeArticleWithURL:articleURL
                            completion:^{
                                updateAgain();
                                [self updateFetchesInProcessCount];
                            }];
            [self.spotlightManager removeFromIndexWithUrl:articleURL];
        } else {
            self.updating = NO;
            [self updateFetchesInProcessCount];
            endBackgroundTask();
        }
    }
}

- (void)update {
    NSAssert([NSThread isMainThread], @"Update must be called on the main thread");
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(_update) object:nil];
    [self performSelector:@selector(_update) withObject:nil afterDelay:0.5];
}

- (void)observeSavedPages {
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(articleWasUpdated:) name:WMFArticleUpdatedNotification object:nil];
    // WMFArticleUpdatedNotification aren't coming through when the articles are created from a background sync, so observe syncDidFinish as well to download articles synced down from the server
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(syncDidFinish:) name:WMFReadingListsController.syncDidFinishNotification object:nil];
}

- (void)unobserveSavedPages {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

#pragma mark - Fetch

- (void)fetchArticleURL:(NSURL *)articleURL priority:(float)priority failure:(WMFErrorHandler)failure success:(WMFSuccessHandler)success {
    WMFAssertMainThread(@"must be called on the main thread");
    if (!articleURL.wmf_title) {
        DDLogError(@"Attempted to save articleURL without title: %@", articleURL);
        failure([WMFFetcher invalidParametersError]);
        return;
    }

    if (self.fetchOperationsByArticleTitle[articleURL]) { // Protect against duplicate fetches & infinite fetch loops
        failure([WMFFetcher invalidParametersError]);
        return;
    }

    // NOTE: must check isCached to determine that all article data has been downloaded
    MWKArticle *articleFromDisk = [self.dataStore articleWithURL:articleURL];
    if (articleFromDisk.isCached) {
        // only fetch images if article was cached
        [self downloadImageDataForArticle:articleFromDisk
            failure:^(NSError *_Nonnull error) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    [self didFetchArticle:articleFromDisk url:articleURL error:error];
                    failure(error);
                });
            }
            success:^{
                dispatch_async(dispatch_get_main_queue(), ^{
                    [self didFetchArticle:articleFromDisk url:articleURL error:nil];
                    success();
                });
            }];
    } else {
        self.fetchOperationsByArticleTitle[articleURL] =
            [self.articleFetcher fetchArticleForURL:articleURL
                saveToDisk:YES
                priority:priority
                failure:^(NSError *_Nonnull error) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        [self didFetchArticle:nil url:articleURL error:error];
                        failure(error);
                    });
                }
                success:^(MWKArticle *_Nonnull article, NSURL *_Nonnull fetchedURL) {
                    dispatch_async(self.accessQueue, ^{
                        [self downloadImageDataForArticle:article
                            failure:^(NSError *error) {
                                dispatch_async(dispatch_get_main_queue(), ^{
                                    [self didFetchArticle:article url:articleURL error:error];
                                    failure(error);
                                });
                            }
                            success:^{
                                dispatch_async(dispatch_get_main_queue(), ^{
                                    [self didFetchArticle:article url:articleURL error:nil];
                                    success();
                                });
                            }];
                    });
                }];

        [self updateFetchesInProcessCount];
    }
}

- (void)downloadImageDataForArticle:(MWKArticle *)article failure:(WMFErrorHandler)failure success:(WMFSuccessHandler)success {
    dispatch_block_t doneMigration = ^{
        [self fetchAllImagesInArticle:article
            failure:^(NSError *error) {
                failure([NSError wmf_savedPageImageDownloadErrorWithUnderlyingError:error]);
            }
            success:^{
                if (success) {
                    success();
                }
            }];
    };
    if (![[NSUserDefaults wmf] wmf_didFinishLegacySavedArticleImageMigration]) {
        WMF_TECH_DEBT_TODO(This legacy migration can be removed after enough users upgrade to 5.5.0)
            [self migrateLegacyImagesInArticle:article
                                    completion:doneMigration];
    } else {
        doneMigration();
    }
}

- (void)migrateLegacyImagesInArticle:(MWKArticle *)article completion:(dispatch_block_t)completion {
    WMFImageController *imageController = [WMFImageController sharedInstance];
    NSArray<NSURL *> *legacyImageURLs = [article imageURLsForSaving];
    NSString *group = article.url.wmf_databaseKey;
    if (!group || !legacyImageURLs.count) {
        if (completion) {
            completion();
        }
        return;
    }
    [imageController migrateLegacyImageURLs:legacyImageURLs intoGroup:group completion:completion];
}

- (void)fetchAllImagesInArticle:(MWKArticle *)article failure:(WMFErrorHandler)failure success:(WMFSuccessHandler)success {
    dispatch_block_t doneMigration = ^{
        NSArray *imageURLsForSaving = [article imageURLsForSaving];
        NSString *articleKey = article.url.wmf_databaseKey;
        if (!articleKey || imageURLsForSaving.count == 0) {
            success();
            return;
        }
        [self cacheImagesForArticleKey:articleKey withURLsInBackground:imageURLsForSaving failure:failure success:success];
    };
    if (![[NSUserDefaults wmf] wmf_didFinishLegacySavedArticleImageMigration]) {
        WMF_TECH_DEBT_TODO(This legacy migration can be removed after enough users upgrade to 5.0 .5)
            [self migrateLegacyImagesInArticle:article
                                    completion:doneMigration];
    } else {
        doneMigration();
    }
}

- (void)fetchGalleryDataForArticle:(MWKArticle *)article failure:(WMFErrorHandler)failure success:(WMFSuccessHandler)success {
    WMF_TECH_DEBT_TODO(check whether on - disk image info matches what we are about to fetch)
    @weakify(self);

    [self fetchImageInfoForImagesInArticle:article
        failure:^(NSError *error) {
            failure(error);
        }
        success:^(NSArray *info) {
            @strongify(self);
            if (!self) {
                failure([WMFFetcher cancelledError]);
                return;
            }
            if (info.count == 0) {
                DDLogVerbose(@"No gallery images to fetch.");
                success();
                return;
            }

            NSArray *URLs = [info valueForKey:@"imageThumbURL"];
            [self cacheImagesForArticleKey:article.url.wmf_databaseKey withURLsInBackground:URLs failure:failure success:success];
        }];
}

- (void)fetchImageInfoForImagesInArticle:(MWKArticle *)article failure:(WMFErrorHandler)failure success:(WMFSuccessNSArrayHandler)success {
    NSArray<NSString *> *imageFileTitles =
        [MWKImage mapFilenamesFromImages:[article imagesForGallery]];

    if (imageFileTitles.count == 0) {
        DDLogVerbose(@"No image info to fetch.");
        success(imageFileTitles);
        return;
    }

    NSMutableArray *infoObjects = [NSMutableArray arrayWithCapacity:imageFileTitles.count];
    WMFTaskGroup *group = [WMFTaskGroup new];
    for (NSString *canonicalFilename in imageFileTitles) {
        [group enter];
        [self.imageInfoFetcher fetchGalleryInfoForImage:canonicalFilename
            fromSiteURL:article.url
            failure:^(NSError *_Nonnull error) {
                [group leave];
            }
            success:^(id _Nonnull object) {
                if (!object || [object isEqual:[NSNull null]]) {
                    [group leave];
                    return;
                }
                [infoObjects addObject:object];
                [group leave];
            }];
    }

    @weakify(self);
    [group waitInBackgroundAndNotifyOnQueue:self.accessQueue
                                  withBlock:^{
                                      @strongify(self);
                                      if (!self) {
                                          failure([WMFFetcher cancelledError]);
                                          return;
                                      }
                                      [self.dataStore saveImageInfo:infoObjects forArticleURL:article.url];
                                      success(infoObjects);
                                  }];
}

- (void)cacheImagesForArticleKey:(NSString *)articleKey withURLsInBackground:(NSArray<NSURL *> *)imageURLs failure:(void (^_Nonnull)(NSError *_Nonnull error))failure success:(void (^_Nonnull)(void))success {
    imageURLs = [imageURLs wmf_select:^BOOL(id obj) {
        return [obj isKindOfClass:[NSURL class]];
    }];

    if (!articleKey || [imageURLs count] == 0) {
        success();
        return;
    }

    [self.imageController permanentlyCacheInBackgroundWithUrls:imageURLs groupKey:articleKey failure:failure success:success];
}

#pragma mark - Cancellation

- (void)removeArticleWithURL:(NSURL *)URL completion:(dispatch_block_t)completion {
    [self.dataStore removeArticleWithURL:URL fromDiskWithCompletion:completion];
}

- (void)cancelFetchForArticleURL:(NSURL *)URL {
    WMFAssertMainThread(@"must be called on the main thread");
    DDLogVerbose(@"Canceling saved page download for title: %@", URL);
    [self.articleFetcher cancelFetchForArticleURL:URL];
    [self.fetchOperationsByArticleTitle removeObjectForKey:URL];
}

#pragma mark - Delegate Notification

/// Only invoke within accessQueue
- (void)didFetchArticle:(MWKArticle *__nullable)fetchedArticle
                    url:(NSURL *)url
                  error:(NSError *__nullable)error {
    WMFAssertMainThread(@"must be called on the main thread");

    //Uncomment when dropping iOS 9
    if (error) {
        // store errors for later reporting
        DDLogError(@"Failed to download saved page %@ due to error: %@", url, error);
        self.errorsByArticleTitle[url] = error;
    } else {
        DDLogInfo(@"Downloaded saved page: %@", url);
    }

    // stop tracking operation, effectively advancing the progress
    [self.fetchOperationsByArticleTitle removeObjectForKey:url];

    [self updateFetchesInProcessCount];

    NSError *fetchError = nil;
    NSArray<WMFArticle *> *articles = [self.dataStore.viewContext fetchArticlesWithKey:[url wmf_databaseKey] error:&fetchError];
    for (WMFArticle *article in articles) {
        [article updatePropertiesForError:error];
        if (error) {
            if ([error.domain isEqualToString:NSCocoaErrorDomain] && error.code == NSFileWriteOutOfSpaceError) {
                NSDictionary *userInfo = @{WMFArticleSaveToDiskDidFailErrorKey: error, WMFArticleSaveToDiskDidFailArticleURLKey: url};
                [NSNotificationCenter.defaultCenter postNotificationName:WMFArticleSaveToDiskDidFailNotification object:nil userInfo:userInfo];
                [self stop];
                article.isDownloaded = NO;
            } else if ([error.domain isEqualToString:WMFNetworkingErrorDomain] && error.code == WMFNetworkingError_APIError && [error.userInfo[NSLocalizedFailureReasonErrorKey] isEqualToString:@"missingtitle"]) {
                article.isDownloaded = YES; // skip missing titles
            } else if ([error.domain isEqualToString:WMFSavedPageErrorDomain]) {
                NSError *underlyingError = error.userInfo[NSUnderlyingErrorKey];
                if (error.code == WMFSavePageImageDownloadError && [NSPOSIXErrorDomain isEqualToString:underlyingError.domain]) {
                    article.isDownloaded = YES; // skip image download errors
                    // This image is failing with POSIX error 100 causing stuck downloading bug, could be more widespread: https://upload.wikimedia.org/wikipedia/commons/thumb/4/4d/Odakyu_odawara.svg/18px-Odakyu_odawara.svg.png
                } else {
                    article.isDownloaded = NO;
                }
            } else {
                article.isDownloaded = NO;
            }
        } else {
            article.isDownloaded = YES;
        }
    }

    NSError *saveError = nil;
    [self.dataStore save:&saveError];
    if (saveError) {
        DDLogError(@"Error saving after saved articles fetch: %@", saveError);
    }
}

@end

@implementation NSError (SavedArticlesFetcherErrors)

+ (instancetype)wmf_savedPageImageDownloadErrorWithUnderlyingError:(nullable NSError *)underlyingError {
    NSMutableDictionary *userInfo = [NSMutableDictionary dictionaryWithCapacity:2];
    userInfo[NSLocalizedDescriptionKey] = WMFLocalizedStringWithDefaultValue(@"saved-pages-image-download-error", nil, nil, @"Failed to download images for this saved page.", @"Error message shown when one or more images fails to save for offline use.");
    if (underlyingError) {
        userInfo[NSUnderlyingErrorKey] = underlyingError;
    }
    return [NSError errorWithDomain:WMFSavedPageErrorDomain
                               code:WMFSavePageImageDownloadError
                           userInfo:userInfo];
}

@end

NS_ASSUME_NONNULL_END

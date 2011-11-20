//
//  MKNetworkEngine.m
//  MKNetworkKit
//
//  Created by Mugunth Kumar on 7/11/11.
//  Copyright 2011 Steinlogic. All rights reserved.

#import "MKNetworkEngine.h"
#import "Reachability.h"
#define kFreezableOperationExtension @"mknetworkkitfrozenoperation"

@interface MKNetworkEngine (/*Private Methods*/)

@property (strong, nonatomic) NSString *hostName;
@property (strong, nonatomic) Reachability *reachability;
@property (strong, nonatomic) NSDictionary *customHeaders;

@property (nonatomic, strong) NSMutableDictionary *memoryCache;
@property (nonatomic, strong) NSMutableArray *memoryCacheKeys;

-(void) saveCache;
-(void) saveCacheData:(NSData*) data forKey:(NSString*) cacheDataKey;

-(void) freezeOperations;
-(void) checkAndRestoreFrozenOperations;

@end

static NSOperationQueue *_sharedNetworkQueue;

@implementation MKNetworkEngine
@synthesize hostName = _hostName;
@synthesize reachability = _reachability;
@synthesize customHeaders = _customHeaders;

@synthesize memoryCache = _memoryCache;
@synthesize memoryCacheKeys = _memoryCacheKeys;

// Network Queue is a shared singleton object.
// no matter how many instances of MKNetworkEngine is created, there is one and only one network queue
// In theory any app contains as many network engines as domains

#pragma mark -
#pragma mark Initialization

+(void) initialize {
    
    if(!_sharedNetworkQueue) {
        static dispatch_once_t oncePredicate;
        dispatch_once(&oncePredicate, ^{
            _sharedNetworkQueue = [[NSOperationQueue alloc] init];
            [_sharedNetworkQueue addObserver:[self self] forKeyPath:@"operationCount" options:0 context:NULL];
            [_sharedNetworkQueue setMaxConcurrentOperationCount:6];
        });
    }        
    
}
- (id) initWithHostName:(NSString*) hostName customHeaderFields:(NSDictionary*) headers {
    
    if((self = [super init])) {        
    
        [[NSNotificationCenter defaultCenter] addObserver:self 
                                                 selector:@selector(reachabilityChanged:) 
                                                     name:kReachabilityChangedNotification 
                                                   object:nil];
        
        self.hostName = hostName;
        self.customHeaders = headers;
        self.reachability = [Reachability reachabilityWithHostName:self.hostName];
        [self.reachability startNotifier];
    }

    return self;
}

#pragma mark -
#pragma mark Memory Mangement

-(void) dealloc {
    
    [[NSNotificationCenter defaultCenter] removeObserver:self name:kReachabilityChangedNotification object:nil];
    [[NSNotificationCenter defaultCenter] removeObserver:self name:UIApplicationDidReceiveMemoryWarningNotification object:nil];
}

+(void) dealloc {
    
    [_sharedNetworkQueue removeObserver:[self self] forKeyPath:@"operationCount"];
}

#pragma mark -
#pragma mark KVO for network Queue

+ (void) observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object 
                         change:(NSDictionary *)change context:(void *)context
{
    if (object == _sharedNetworkQueue && [keyPath isEqualToString:@"operationCount"]) {
        
        [UIApplication sharedApplication].networkActivityIndicatorVisible = 
        ([_sharedNetworkQueue.operations count] > 0);        
    }
    else {
        [super observeValueForKeyPath:keyPath ofObject:object 
                               change:change context:context];
    }
}

#pragma mark -
#pragma mark Reachability related

-(void) reachabilityChanged:(NSNotification*) notification
{
    if([self.reachability currentReachabilityStatus] == ReachableViaWiFi)
    {
        DLog(@"Server [%@] is reachable via Wifi", self.hostName);
        [_sharedNetworkQueue setMaxConcurrentOperationCount:6];
        [self checkAndRestoreFrozenOperations];
    }
    else if([self.reachability currentReachabilityStatus] == ReachableViaWWAN)
    {
        DLog(@"Server [%@] is reachable only via cellular data", self.hostName);
        [_sharedNetworkQueue setMaxConcurrentOperationCount:2];
        [self checkAndRestoreFrozenOperations];
    }
    else if([self.reachability currentReachabilityStatus] == NotReachable)
    {
        DLog(@"Server [%@] is not reachable", self.hostName);
        
        [_sharedNetworkQueue setMaxConcurrentOperationCount:0];
        [self freezeOperations];
    }        
}

#pragma Freezing operations (Called when network connectivity fails)
-(void) freezeOperations {
    
    for(MKNetworkOperation *operation in _sharedNetworkQueue.operations) {
        
        if(![operation freezable]) continue; // freeze only freeable operations.
        
        NSString *archivePath = [[[self cacheDirectoryName] stringByAppendingPathComponent:[operation uniqueIdentifier]] 
                                 stringByAppendingPathExtension:kFreezableOperationExtension];
        [NSKeyedArchiver archiveRootObject:operation toFile:archivePath];
    }
}

-(void) checkAndRestoreFrozenOperations {
    
    NSError *error = nil;
    NSArray *files = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:[self cacheDirectoryName] error:&error];
    if(error)
        DLog(@"%@", error);
    
    NSArray *pendingOperations = [files filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(id evaluatedObject, NSDictionary *bindings) {
        
        NSString *thisFile = (NSString*) evaluatedObject;
        return ([thisFile rangeOfString:kFreezableOperationExtension].location != NSNotFound);             
    }]];
    
    for(NSString *pendingOperationFile in pendingOperations) {
        
        NSString *archivePath = [[self cacheDirectoryName] stringByAppendingPathComponent:pendingOperationFile];
        MKNetworkOperation *pendingOperation = [NSKeyedUnarchiver unarchiveObjectWithFile:archivePath];
        [self queueRequest:pendingOperation];
        NSError *error = nil;
        [[NSFileManager defaultManager] removeItemAtPath:archivePath error:&error];
        if(error)
            DLog(@"%@", error);
    }
}

-(BOOL) isReachable {
    
    return ([self.reachability currentReachabilityStatus] != NotReachable);
}

#pragma -
#pragma Request related

-(MKNetworkOperation*) requestWithPath:(NSString*) path {
    
    return [self requestWithPath:path body:nil];
}

-(MKNetworkOperation*) requestWithPath:(NSString*) path
                         body:(NSMutableDictionary*) body {

    return [self requestWithPath:path 
                     body:body 
               httpMethod:@"GET"];
}

-(MKNetworkOperation*) requestWithPath:(NSString*) path
                         body:(NSMutableDictionary*) body
                   httpMethod:(NSString*)method  {
    
    return [self requestWithPath:path body:body httpMethod:method ssl:NO];
}

-(MKNetworkOperation*) requestWithPath:(NSString*) path
                         body:(NSMutableDictionary*) body
                   httpMethod:(NSString*)method 
                          ssl:(BOOL) useSSL {
    
    NSString *urlString = [NSString stringWithFormat:@"%@://%@/%@", useSSL ? @"https" : @"http", self.hostName, path];
    
    return [self requestWithURLString:urlString body:body httpMethod:method];
}

-(MKNetworkOperation*) requestWithURLString:(NSString*) urlString {

    return [self requestWithURLString:urlString body:nil httpMethod:@"GET"];
}

-(MKNetworkOperation*) requestWithURLString:(NSString*) urlString
                                       body:(NSMutableDictionary*) body {

    return [self requestWithURLString:urlString body:body httpMethod:@"GET"];
}


-(MKNetworkOperation*) requestWithURLString:(NSString*) urlString
                         body:(NSMutableDictionary*) body
                   httpMethod:(NSString*)method {

    MKNetworkOperation *operation = [MKNetworkOperation operationWithURLString:urlString body:body httpMethod:method];
    [operation addHeaders:self.customHeaders];
    return operation;
}

-(NSData*) cachedDataForOperation:(MKNetworkOperation*) operation {
    
    NSData *cachedData = [self.memoryCache objectForKey:[operation uniqueIdentifier]];
    if(cachedData) return cachedData;
    
    NSString *filePath = [[self cacheDirectoryName] stringByAppendingPathComponent:[operation uniqueIdentifier]];    

    if([[NSFileManager defaultManager] fileExistsAtPath:filePath]) {

        NSData *cachedData = [NSData dataWithContentsOfFile:filePath];
        [self saveCacheData:cachedData forKey:[operation uniqueIdentifier]];
        return cachedData;
    }
    
    return nil;
}

-(void) queueRequest:(MKNetworkOperation*) request {
    
    [request setCacheHandler:^(MKNetworkOperation* completedCacheableRequest) {
        
        // if this is not called, the request would have been a non cacheable request
        [self saveCacheData:[completedCacheableRequest responseData] 
                     forKey:[completedCacheableRequest uniqueIdentifier]];
    }];
    
    NSUInteger index = [_sharedNetworkQueue.operations indexOfObject:request];
    if(index == NSNotFound) {
        [_sharedNetworkQueue addOperation:request];
    }
    else {
        // This operation is already being processed
        MKNetworkOperation *queuedOperation = (MKNetworkOperation*) [_sharedNetworkQueue.operations objectAtIndex:index];
        [queuedOperation updateHandlersFromOperation:request];
    }
    
    NSData *cachedData = [self cachedDataForOperation:request];
    if(cachedData) {
        [request setCachedData:cachedData];
    }
        
}

#pragma -
#pragma Cache related

-(NSString*) cacheDirectoryName {
    
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES);
    NSString *documentsDirectory = [paths objectAtIndex:0];
    NSString *cacheDirectoryName = [documentsDirectory stringByAppendingPathComponent:MKNETWORKCACHE_DEFAULT_DIRECTORY];
    return cacheDirectoryName;
}

-(int) cacheMemoryCost {
    
    return MKNETWORKCACHE_DEFAULT_COST;
}
     
-(void) saveCache {
   
    for(NSString *cacheKey in [self.memoryCache allKeys])
    {
        NSString *filePath = [[self cacheDirectoryName] stringByAppendingPathComponent:cacheKey];
        
        if(![[NSFileManager defaultManager] fileExistsAtPath:filePath])
            [[self.memoryCache objectForKey:cacheKey] writeToFile:filePath atomically:YES];        
    }
    
    [self.memoryCache removeAllObjects];
    [self.memoryCacheKeys removeAllObjects];
}

-(void) saveCacheData:(NSData*) data forKey:(NSString*) cacheDataKey
{    
    [self.memoryCache setObject:data forKey:cacheDataKey];
    
    NSUInteger index = [self.memoryCacheKeys indexOfObject:cacheDataKey];
    if(index != NSNotFound)
        [self.memoryCacheKeys removeObjectAtIndex:index];    
    
    [self.memoryCacheKeys insertObject:data atIndex:0]; // remove it and insert it at start
    
    if([self.memoryCacheKeys count] > [self cacheMemoryCost])
    {
        NSString *lastKey = [self.memoryCacheKeys lastObject];        
        NSData *data = [self.memoryCache objectForKey:lastKey];        
        NSString *filePath = [[self cacheDirectoryName] stringByAppendingPathComponent:lastKey];
        
        if(![[NSFileManager defaultManager] fileExistsAtPath:filePath])
            [data writeToFile:filePath atomically:YES];
        
        [self.memoryCacheKeys removeLastObject];
        [self.memoryCache removeObjectForKey:lastKey];        
    }
}

/*
- (BOOL) dataOldness:(NSString*) imagePath
{
    NSDictionary *attributes = [[NSFileManager defaultManager] attributesOfItemAtPath:imagePath error:nil];
    NSDate *creationDate = [attributes valueForKey:NSFileCreationDate];
    
    return abs([creationDate timeIntervalSinceNow]);
}*/

-(void) useCache {
    
    self.memoryCache = [NSMutableDictionary dictionaryWithCapacity:[self cacheMemoryCost]];
    self.memoryCacheKeys = [NSMutableArray arrayWithCapacity:[self cacheMemoryCost]];
    
    NSString *cacheDirectory = [self cacheDirectoryName];
    BOOL isDirectory = NO;
    BOOL folderExists = [[NSFileManager defaultManager] fileExistsAtPath:cacheDirectory isDirectory:&isDirectory] && isDirectory;
    
    if (!folderExists)
    {
        NSError *error = nil;
        [[NSFileManager defaultManager] createDirectoryAtPath:cacheDirectory withIntermediateDirectories:YES attributes:nil error:&error];
    }
    
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(saveCache)
                                                 name:UIApplicationDidReceiveMemoryWarningNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(saveCache)
                                                 name:UIApplicationDidEnterBackgroundNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(saveCache)
                                                 name:UIApplicationWillTerminateNotification
                                               object:nil];
}

@end

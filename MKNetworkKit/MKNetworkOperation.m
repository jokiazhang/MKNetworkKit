//
//  MKRequest.m
//  MKNetworkKit
//
//  Created by Mugunth on 25/2/11
//  Copyright 2011 Steinlogic. All rights reserved.
//

#import "MKNetworkOperation.h"
#import "NSDictionary+RequestEncoding.h"
#import "NSString+MKNetworkKitAdditions.h"

typedef enum {
    MKRequestOperationStateReady = 1,
    MKRequestOperationStateExecuting = 2,
    MKRequestOperationStateFinished = 3
} MKRequestOperationState;

@interface MKNetworkOperation (/*Private Methods*/)
@property (strong, nonatomic) NSURLConnection *connection;
@property (strong, nonatomic) NSString *uniqueId;
@property (strong, nonatomic) NSMutableURLRequest *request;
@property (strong, nonatomic) NSMutableDictionary *requestDictionary;
@property (strong, nonatomic) NSHTTPURLResponse *response;

@property (strong, nonatomic) NSMutableDictionary *fieldsToBePosted;
@property (strong, nonatomic) NSMutableArray *filesToBePosted;
@property (strong, nonatomic) NSMutableArray *dataToBePosted;

@property (strong, nonatomic) NSString *username;
@property (strong, nonatomic) NSString *password;

@property (nonatomic, retain) NSMutableArray *responseBlocks;
@property (nonatomic, retain) NSMutableArray *errorBlocks;

@property (nonatomic, assign) MKRequestOperationState state;
@property (nonatomic, assign) BOOL isCancelled;

@property (strong, nonatomic) NSMutableData *mutableData;

@property (nonatomic, retain) NSMutableArray *uploadProgressChangedHandlers;
@property (nonatomic, retain) NSMutableArray *downloadProgressChangedHandlers;
@property (nonatomic, retain) NSMutableArray *downloadStreams;
@property (nonatomic, retain) NSData *cachedResponse;
@property (nonatomic, copy) ResponseBlock cacheHandlingBlock;
@property (nonatomic, assign) UIBackgroundTaskIdentifier backgroundTaskId;

- (id)initWithURLString:(NSString *)aURLString
                   body:(NSMutableDictionary *)body
             httpMethod:(NSString *)method;
-(NSData*) bodyData;
@end

@implementation MKNetworkOperation

@synthesize stringEncoding = _stringEncoding;
@dynamic freezable;
@synthesize uniqueId = _uniqueId; // freezable operations have a unique id

@synthesize connection = _connection;

@synthesize request = _request;
@synthesize requestDictionary = _requestDictionary;
@synthesize response = _response;

@synthesize fieldsToBePosted = _fieldsToBePosted;
@synthesize filesToBePosted = _filesToBePosted;
@synthesize dataToBePosted = _dataToBePosted;

@synthesize username = _username;
@synthesize password = _password;

@synthesize responseBlocks = _responseBlocks;
@synthesize errorBlocks = _errorBlocks;

@synthesize isCancelled = _isCancelled;
@synthesize mutableData = _mutableData;

@synthesize uploadProgressChangedHandlers = _uploadProgressChangedHandlers;
@synthesize downloadProgressChangedHandlers = _downloadProgressChangedHandlers;

@synthesize downloadStreams = _downloadStreams;

@synthesize cachedResponse = _cachedResponse;
@synthesize cacheHandlingBlock = _cacheHandlingBlock;
@synthesize backgroundTaskId = _backgroundTaskId;


// A RESTful service should always return the same response for a given URL and it's parameters.
// this means if these values are correct, you can cache the responses
// This is another reason why we check only GET methods.
// even if URL and others are same, POST, DELETE, PUT methods should not be cached and should not be treated equal.

-(BOOL) isCacheable {
    
    return [self.request.HTTPMethod isEqualToString:@"GET"];
}

//=========================================================== 
//  freezable 
//=========================================================== 
- (BOOL)freezable
{
    return _freezable;
}

- (void)setFreezable:(BOOL)flag
{
    // get method cannot be frozen. 
    // No point in freezing a method that doesn't change server state.
    if([self.request.HTTPMethod isEqualToString:@"GET"] && flag) return;
    _freezable = flag;
    
    if(_freezable && self.uniqueId == nil)
        self.uniqueId = [NSString uniqueString];
}


-(BOOL) isEqual:(id)object {

    if([self isCacheable]) {

        MKNetworkOperation *anotherObject = (MKNetworkOperation*) object;
        return ([[self uniqueIdentifier] isEqualToString:[anotherObject uniqueIdentifier]]);
    }
    
    return NO;
}


-(NSString*) uniqueIdentifier {

    NSString *str = [NSString stringWithFormat:@"%@ %@", 
                     self.request.HTTPMethod,
                     [self.request.URL absoluteString]];

    if(self.username || self.password) {

        str = [str stringByAppendingFormat:@" [%@:%@]",
                     self.username ? self.username : @"",
                     self.password ? self.password : @""];
    }
    
    if(self.freezable) {
        
        str = [str stringByAppendingString:self.uniqueId];
    }
    return [str md5];
}

-(BOOL) isCachedResponse {
    
    return self.cachedResponse != nil;
}

-(void) notifySuccess {
    
    if(![self isCacheable]) return;
    if(!([self.response statusCode] >= 200 && [self.response statusCode] < 300)) return;
    
    self.cacheHandlingBlock(self);
}

-(void) notifyFailure {
    
    if(![self isCacheable]) return;
    if(!([self.response statusCode] >= 200 && [self.response statusCode] < 300)) return;
    
    self.cacheHandlingBlock(self);
}

-(void) notifyCache {
    
    if(![self isCacheable]) return;
    if(!([self.response statusCode] >= 200 && [self.response statusCode] < 300)) return;
    
    self.cachedResponse = nil; // remove cached data
    self.cacheHandlingBlock(self);
}

-(MKRequestOperationState) state {
    
    return _state;
}

-(void) setState:(MKRequestOperationState)newState {
    
    switch (newState) {
        case MKRequestOperationStateReady:
            [self willChangeValueForKey:@"isReady"];
            break;
        case MKRequestOperationStateExecuting:
            [self willChangeValueForKey:@"isReady"];
            [self willChangeValueForKey:@"isExecuting"];
            break;
        case MKRequestOperationStateFinished:
            [self willChangeValueForKey:@"isExecuting"];
            [self willChangeValueForKey:@"isFinished"];
            break;
    }
    
    _state = newState;
    
    switch (newState) {
        case MKRequestOperationStateReady:
            [self didChangeValueForKey:@"isReady"];
            break;
        case MKRequestOperationStateExecuting:
            [self didChangeValueForKey:@"isReady"];
            [self didChangeValueForKey:@"isExecuting"];
            break;
        case MKRequestOperationStateFinished:
            [self didChangeValueForKey:@"isExecuting"];
            [self didChangeValueForKey:@"isFinished"];
            
            dispatch_async(dispatch_get_main_queue(), ^{
                if (self.backgroundTaskId != UIBackgroundTaskInvalid) {
                    [[UIApplication sharedApplication] endBackgroundTask:self.backgroundTaskId];
                    self.backgroundTaskId = UIBackgroundTaskInvalid;
                }
            });

            break;
    }
}

- (void)encodeWithCoder:(NSCoder *)encoder 
{
    [encoder encodeInteger:self.stringEncoding forKey:@"stringEncoding"];
    [encoder encodeObject:self.uniqueId forKey:@"uniqueId"];
    [encoder encodeObject:self.request forKey:@"request"];
    [encoder encodeObject:self.requestDictionary forKey:@"requestDictionary"];
    [encoder encodeObject:self.response forKey:@"response"];
    [encoder encodeObject:self.fieldsToBePosted forKey:@"fieldsToBePosted"];
    [encoder encodeObject:self.filesToBePosted forKey:@"filesToBePosted"];
    [encoder encodeObject:self.dataToBePosted forKey:@"dataToBePosted"];
    [encoder encodeObject:self.username forKey:@"username"];
    [encoder encodeObject:self.password forKey:@"password"];
        
    self.state = MKRequestOperationStateReady;
    [encoder encodeInteger:_state forKey:@"state"];
    [encoder encodeBool:self.isCancelled forKey:@"isCancelled"];
    [encoder encodeObject:self.mutableData forKey:@"mutableData"];

    [encoder encodeObject:self.downloadStreams forKey:@"downloadStreams"];
}

- (id)initWithCoder:(NSCoder *)decoder 
{
    self = [super init];
    if (self) {
        [self setStringEncoding:[decoder decodeIntegerForKey:@"stringEncoding"]];
        self.request = [decoder decodeObjectForKey:@"request"];
        self.uniqueId = [decoder decodeObjectForKey:@"uniqueId"];

        self.requestDictionary = [decoder decodeObjectForKey:@"requestDictionary"];
        self.response = [decoder decodeObjectForKey:@"response"];
        self.fieldsToBePosted = [decoder decodeObjectForKey:@"fieldsToBePosted"];
        self.filesToBePosted = [decoder decodeObjectForKey:@"filesToBePosted"];
        self.dataToBePosted = [decoder decodeObjectForKey:@"dataToBePosted"];
        self.username = [decoder decodeObjectForKey:@"username"];
        self.password = [decoder decodeObjectForKey:@"password"];

        [self setState:[decoder decodeIntegerForKey:@"state"]];
        self.isCancelled = [decoder decodeBoolForKey:@"isCancelled"];
        self.mutableData = [decoder decodeObjectForKey:@"mutableData"];

        self.downloadStreams = [decoder decodeObjectForKey:@"downloadStreams"];
    }
    return self;
}

- (id)copyWithZone:(NSZone *)zone
{
    id theCopy = [[[self class] allocWithZone:zone] init];  // use designated initializer
    
    [theCopy setStringEncoding:self.stringEncoding];
    [theCopy setUniqueId:[self.uniqueId copy]];

    [theCopy setConnection:[self.connection copy]];
    [theCopy setRequest:[self.request copy]];
    [theCopy setRequestDictionary:[self.requestDictionary copy]];
    [theCopy setResponse:[self.response copy]];
    [theCopy setFieldsToBePosted:[self.fieldsToBePosted copy]];
    [theCopy setFilesToBePosted:[self.filesToBePosted copy]];
    [theCopy setDataToBePosted:[self.dataToBePosted copy]];
    [theCopy setUsername:[self.username copy]];
    [theCopy setPassword:[self.password copy]];
    [theCopy setResponseBlocks:[self.responseBlocks copy]];
    [theCopy setErrorBlocks:[self.errorBlocks copy]];
    [theCopy setState:self.state];
    [theCopy setIsCancelled:self.isCancelled];
    [theCopy setMutableData:[self.mutableData copy]];
    [theCopy setUploadProgressChangedHandlers:[self.uploadProgressChangedHandlers copy]];
    [theCopy setDownloadProgressChangedHandlers:[self.downloadProgressChangedHandlers copy]];
    [theCopy setDownloadStreams:[self.downloadStreams copy]];
    [theCopy setCachedResponse:[self.cachedResponse copy]];
    [theCopy setCacheHandlingBlock:self.cacheHandlingBlock];
    
    return theCopy;
}

-(void) dealloc {
    
    [_connection cancel];
    _connection = nil;
}

-(void) updateHandlersFromOperation:(MKNetworkOperation*) operation {

    [self.responseBlocks addObjectsFromArray:operation.responseBlocks];
    [self.errorBlocks addObjectsFromArray:operation.errorBlocks];
    [self.uploadProgressChangedHandlers addObjectsFromArray:operation.uploadProgressChangedHandlers];
    [self.downloadProgressChangedHandlers addObjectsFromArray:operation.downloadProgressChangedHandlers];
    [self.downloadStreams addObjectsFromArray:operation.downloadStreams];
}

-(void) setCachedData:(NSData*) cachedData {
    
    self.cachedResponse = cachedData;

    for(ResponseBlock responseBlock in self.responseBlocks)
        responseBlock(self);    
}

+ (id)operationWithURLString:(NSString *)urlString
                      body:(NSMutableDictionary *)body
				httpMethod:(NSString *)method
{
	return [[self alloc] initWithURLString:urlString
                                      body:body 
                                httpMethod:method];
}

-(void) setUsername:(NSString*) username password:(NSString*) password {
    
    self.username = username;
    self.password = password;
}

-(void) onCompletion:(ResponseBlock) response onError:(ErrorBlock) error {
    
    [self.responseBlocks addObject:[response copy]];
    [self.errorBlocks addObject:[error copy]];
}

-(void) onUploadProgressChanged:(ProgressBlock) uploadProgressBlock {
    
    [self.uploadProgressChangedHandlers addObject:[uploadProgressBlock copy]];
}

-(void) onDownloadProgressChanged:(ProgressBlock) downloadProgressBlock {
    
    [self.downloadProgressChangedHandlers addObject:[downloadProgressBlock copy]];
}

-(void) setDownloadStream:(NSOutputStream*) outputStream {
    
    [self.downloadStreams addObject:outputStream];
}

- (id)initWithURLString:(NSString *)aURLString
                   body:(NSMutableDictionary *)body
             httpMethod:(NSString *)method

{	
    if((self = [super init])) {
        
        self.responseBlocks = [NSMutableArray array];
        self.errorBlocks = [NSMutableArray array];        
        self.filesToBePosted = [NSMutableArray array];
        self.dataToBePosted = [NSMutableArray array];
        self.uploadProgressChangedHandlers = [NSMutableArray array];
        self.downloadProgressChangedHandlers = [NSMutableArray array];
        self.downloadStreams = [NSMutableArray array];

        NSURL *finalURL = nil;
        self.requestDictionary = body;
        self.fieldsToBePosted = body;
        self.stringEncoding = NSUTF8StringEncoding; // use a delegate to get these values later

        if (([method isEqualToString:@"GET"] ||
             [method isEqualToString:@"DELETE"]) && (body && [body count] > 0)) {
            
            finalURL = [NSURL URLWithString:[NSString stringWithFormat:@"%@?%@", aURLString, 
                                             [body urlEncodedKeyValueString]]];
        } else {
            finalURL = [NSURL URLWithString:aURLString];
        }
        
        self.request = [NSMutableURLRequest requestWithURL:finalURL                                                           
                                               cachePolicy:NSURLRequestReloadIgnoringLocalAndRemoteCacheData                                            
                                           timeoutInterval:30.0f];
        
        [self.request setHTTPMethod:method];
        
        NSString *charset = (__bridge NSString *)CFStringConvertEncodingToIANACharSetName(CFStringConvertNSStringEncodingToEncoding(self.stringEncoding));
        
        [self.request addValue:
         [NSString stringWithFormat:@"application/x-www-form-urlencoded; charset=%@", charset]
            forHTTPHeaderField:@"Content-Type"];
        
        if ([method isEqualToString:@"POST"] || [method isEqualToString:@"PUT"]) {
            
            // in case of multi-part form request, 
            // this will be automatically over written later
            self.request.HTTPBody = [[[body urlEncodedKeyValueString] dataUsingEncoding:self.stringEncoding] mutableCopy];
        }
        
        self.state = MKRequestOperationStateReady;
    }
    
	return self;
}

-(void) addHeaders:(NSDictionary*) headersDictionary {
    
    [headersDictionary enumerateKeysAndObjectsUsingBlock:^(id key, id obj, BOOL *stop) {
        [self.request addValue:obj forHTTPHeaderField:key];
    }];
}

/*
 Printing a MKNetworkOperation object is printed in curl syntax
 */
-(NSString*) description
{
    __block NSMutableString *displayString = [NSMutableString stringWithFormat:@"%@\nRequest\n-------\ncurl -X %@", 
                                              [[NSDate date] descriptionWithLocale:[NSLocale currentLocale]],
                                              self.request.HTTPMethod];
    
    if([self.filesToBePosted count] == 0 && [self.dataToBePosted count] == 0) {
    [[self.request allHTTPHeaderFields] enumerateKeysAndObjectsUsingBlock:^(id key, id val, BOOL *stop)
     {
         [displayString appendFormat:@" -H \"%@: %@\"", key, val];
     }];
    }
    
    [displayString appendFormat:@" \"%@\"",  [self.request.URL absoluteString]];
    
    if ([self.request.HTTPMethod isEqualToString:@"POST"] || [self.request.HTTPMethod isEqualToString:@"PUT"]) {

        NSString *option = [self.filesToBePosted count] == 0 ? @"-d" : @"-F";
        [self.requestDictionary enumerateKeysAndObjectsUsingBlock:^(id key, id obj, BOOL *stop) {
            
            [displayString appendFormat:@" %@ \"%@=%@\"", option, key, obj];
        }];
         
        [self.filesToBePosted enumerateObjectsUsingBlock:^(id obj, NSUInteger idx, BOOL *stop) {
            
            NSDictionary *thisFile = (NSDictionary*) obj;
            [displayString appendFormat:@" -F \"%@=@%@;type=%@\"", [thisFile objectForKey:@"name"],
             [thisFile objectForKey:@"filepath"], [thisFile objectForKey:@"mimetype"]];
        }];
        
        /* Not sure how to do this via curl
        [self.dataToBePosted enumerateObjectsUsingBlock:^(id obj, NSUInteger idx, BOOL *stop) {
            
            NSDictionary *thisData = (NSDictionary*) obj;
            [displayString appendFormat:@" --data-binary \"%@\"", [thisData objectForKey:@"data"]];
        }];*/
    }
    
    if(self.mutableData && [self responseString]) {
        [displayString appendFormat:@"\n--------\nResponse\n--------\n%@\n", [self responseString]];
    }
    
    return displayString;
}

-(void) addData:(NSData*) data forKey:(NSString*) key {
    
    [self addData:data forKey:key mimeType:@"application/octet-stream"];
}

-(void) addData:(NSData*) data forKey:(NSString*) key mimeType:(NSString*) mimeType {
    
    [self.request setHTTPMethod:@"POST"];
    
    NSDictionary *dict = [NSDictionary dictionaryWithObjectsAndKeys:
                          data, @"data",
                          key, @"name",
                          mimeType, @"mimetype",     
                          nil];
    
    [self.dataToBePosted addObject:dict];    
}

-(void) addFile:(NSString*) filePath forKey:(NSString*) key {
    
    [self addFile:filePath forKey:key mimeType:@"application/octet-stream"];
}

-(void) addFile:(NSString*) filePath forKey:(NSString*) key mimeType:(NSString*) mimeType {

    [self.request setHTTPMethod:@"POST"];

    NSDictionary *dict = [NSDictionary dictionaryWithObjectsAndKeys:
     filePath, @"filepath",
     key, @"name",
     mimeType, @"mimetype",     
     nil];
    
    [self.filesToBePosted addObject:dict];    
}

-(NSData*) bodyData {

    NSString *boundary = @"0xKhTmLbOuNdArY";
    NSMutableData *body = [NSMutableData data];

    [self.fieldsToBePosted enumerateKeysAndObjectsUsingBlock:^(id key, id obj, BOOL *stop) {
        
        NSString *thisFieldString = [NSString stringWithFormat:
                                     @"--%@\r\nContent-Disposition: form-data; name=\"%@\"\r\n\r\n%@\r\n",
                                     boundary, key, obj];
        
        [body appendData:[thisFieldString dataUsingEncoding:[self stringEncoding]]];        
    }];
     
     
    [self.filesToBePosted enumerateObjectsUsingBlock:^(id obj, NSUInteger idx, BOOL *stop) {
        
        NSDictionary *thisFile = (NSDictionary*) obj;
        NSString *thisFieldString = [NSString stringWithFormat:
                                     @"--%@\r\nContent-Disposition: form-data; name=\"%@\"; filename=\"%@\"\r\nContent-Type: %@\r\nContent-Transfer-Encoding: binary\r\n\r\n",
                                     boundary, 
                                     [thisFile objectForKey:@"name"], 
                                     [[thisFile objectForKey:@"filepath"] lastPathComponent], 
                                     [thisFile objectForKey:@"mimetype"]];
        
        [body appendData:[thisFieldString dataUsingEncoding:[self stringEncoding]]];         
        [body appendData: [NSData dataWithContentsOfFile:[thisFile objectForKey:@"filepath"]]];
    }];
    
    [self.dataToBePosted enumerateObjectsUsingBlock:^(id obj, NSUInteger idx, BOOL *stop) {
        
        NSDictionary *thisDataObject = (NSDictionary*) obj;
        NSString *thisFieldString = [NSString stringWithFormat:
                                     @"--%@\r\nContent-Disposition: form-data; name=\"%@\"; filename=\"%@\"\r\nContent-Type: %@\r\nContent-Transfer-Encoding: binary\r\n\r\n",
                                     boundary, 
                                     [thisDataObject objectForKey:@"name"], 
                                     [thisDataObject objectForKey:@"name"], 
                                     [thisDataObject objectForKey:@"mimetype"]];
        
        [body appendData:[thisFieldString dataUsingEncoding:[self stringEncoding]]];         
        [body appendData:[thisDataObject objectForKey:@"data"]];
    }];
   
    [body appendData: [[NSString stringWithFormat:@"\r\n--%@--\r\n", boundary] dataUsingEncoding:self.stringEncoding]];

    NSLog(@"%@", [[NSString alloc] initWithData:body encoding:NSUTF8StringEncoding]);
    
        NSString *charset = (__bridge NSString *)CFStringConvertEncodingToIANACharSetName(CFStringConvertNSStringEncodingToEncoding(self.stringEncoding));

    if(([self.filesToBePosted count] > 0) || ([self.dataToBePosted count] > 0))
     [self.request setValue:[NSString stringWithFormat:@"multipart/form-data; charset=%@; boundary=%@", charset, boundary] 
         forHTTPHeaderField:@"Content-Type"];
     
    return body;
}

-(void) setCacheHandler:(ResponseBlock) cacheHandler {
    
    self.cacheHandlingBlock = cacheHandler;
}

#pragma mark -
#pragma Main method
-(void) main {
    
    @autoreleasepool {
        [self start];
    }
}

- (void) start
{
    
    self.backgroundTaskId = [[UIApplication sharedApplication] beginBackgroundTaskWithExpirationHandler:^{

        dispatch_async(dispatch_get_main_queue(), ^{
            if (self.backgroundTaskId != UIBackgroundTaskInvalid)
            {
                [[UIApplication sharedApplication] endBackgroundTask:self.backgroundTaskId];
                self.backgroundTaskId = UIBackgroundTaskInvalid;
                [self cancel];
            }
        });
    }];

    if(![NSThread isMainThread]){
        [self performSelectorOnMainThread:@selector(start) withObject:nil waitUntilDone:NO];
        return;
    }
    if(!self.isCancelled) {
        
        if ([self.request.HTTPMethod isEqualToString:@"POST"] || [self.request.HTTPMethod isEqualToString:@"PUT"]) {            
            
            [self.request setHTTPBody:[self bodyData]];
        }

        self.connection = [[NSURLConnection alloc] initWithRequest:self.request 
                                                          delegate:self 
                                                  startImmediately:YES]; 
        self.state = MKRequestOperationStateExecuting;
    }
    else {
        self.state = MKRequestOperationStateFinished;
    }
}

#pragma -
#pragma mark NSOperation stuff

- (BOOL)isConcurrent
{
    return YES;
}

- (BOOL)isReady {
    
    return (self.state == MKRequestOperationStateReady);
}

- (BOOL)isFinished 
{
	return (self.state == MKRequestOperationStateFinished);
}

- (BOOL)isExecuting {
    
	return (self.state == MKRequestOperationStateExecuting);
}

-(void) cancel {
    
    if([self isFinished]) return;
    
    [super cancel];
    [self.connection cancel];
    
    self.mutableData = nil;
    self.isCancelled = YES;    
}

#pragma mark -
#pragma mark NSURLConnection delegates

- (void)connection:(NSURLConnection *)connection didFailWithError:(NSError *)error {
    
    self.mutableData = nil;
    for(NSOutputStream *stream in self.downloadStreams)
        [stream close];
    self.state = MKRequestOperationStateFinished;
    
    for(ErrorBlock errorBlock in self.errorBlocks)
        errorBlock(error);    
}

- (void)connection:(NSURLConnection *)connection 
willSendRequestForAuthenticationChallenge:(NSURLAuthenticationChallenge *)challenge {
    
    if(!(self.username && self.password)) {
        [[challenge sender] continueWithoutCredentialForAuthenticationChallenge:challenge];
    }
    else {
        NSURLCredential *credential = [NSURLCredential credentialWithUser:self.username 
                                                                 password:self.password
                                                              persistence:NSURLCredentialPersistenceForSession];
        
        [[challenge sender] useCredential:credential forAuthenticationChallenge:challenge];
    }
}

- (void)connection:(NSURLConnection *)connection didReceiveResponse:(NSURLResponse *)response {
    
    NSUInteger size = [self.response expectedContentLength] < 0 ? 0 : [self.response expectedContentLength];
    self.response = (NSHTTPURLResponse*) response;
    self.mutableData = [NSMutableData dataWithCapacity:size];
    
    for(NSOutputStream *stream in self.downloadStreams)
        [stream open];
}

- (void)connection:(NSURLConnection *)connection didReceiveData:(NSData *)data {
    
    [self.mutableData appendData:data];
    
    for(NSOutputStream *stream in self.downloadStreams) {

        if ([stream hasSpaceAvailable]) {
            const uint8_t *dataBuffer = [data bytes];
            [stream write:&dataBuffer[0] maxLength:[data length]];
        }
    }
    
    for(ProgressBlock downloadProgressBlock in self.downloadProgressChangedHandlers) {

        if([self.response expectedContentLength] > 0) {
            
            double progress = (double)[self.mutableData length] / (double)[self.response expectedContentLength];
            downloadProgressBlock(progress);
        }        
    }
}

- (void)connection:(NSURLConnection *)connection didSendBodyData:(NSInteger)bytesWritten 
 totalBytesWritten:(NSInteger)totalBytesWritten
totalBytesExpectedToWrite:(NSInteger)totalBytesExpectedToWrite {
    
    for(ProgressBlock uploadProgressBlock in self.uploadProgressChangedHandlers) {

        if(totalBytesExpectedToWrite > 0) {
            uploadProgressBlock(((double)totalBytesWritten/(double)totalBytesExpectedToWrite));
        }
    }
}

- (void)connectionDidFinishLoading:(NSURLConnection *)connection {
    
    for(NSOutputStream *stream in self.downloadStreams)
        [stream close];
    
    self.state = MKRequestOperationStateFinished;

    for(ResponseBlock responseBlock in self.responseBlocks)
        responseBlock(self);    

    [self notifyCache];
}

#pragma mark -
#pragma mark Our methods to get data

-(NSData*) responseData {
    
    if([self isFinished])
        return [self.mutableData copy];
    else if(self.cachedResponse)
        return self.cachedResponse;
    else
        return nil;
}

-(NSString*)responseString {
    
    return [self responseStringWithEncoding:self.stringEncoding];
}

-(NSString*) responseStringWithEncoding:(NSStringEncoding) encoding {
    
    return [[NSString alloc] initWithData:[self responseData] encoding:encoding];
}

#ifdef __IPHONE_5_0
-(id) responseJSON {
    
    NSError *error = nil;
    id returnValue = [NSJSONSerialization JSONObjectWithData:[self mutableData] options:0 error:&error];    
    DLog(@"JSON Parsing Error: %@", error);
    return returnValue;
}
#endif

@end

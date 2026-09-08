#import <XCTest/XCTest.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import "GLManager.h"
#import "LOLDatabase.h"
#import "FMDatabase.h"

@interface GLManager (Testing)
- (void)setupHTTPClient;
- (void)sendQueueIfTimeElapsed;
- (void)processLocations:(NSArray *)locations;
- (void)updateSettingsFromResponse:(id)response;
- (NSDictionary *)owntracksDictionaryFromLocation:(CLLocation *)location;
- (void)writeTripToDB:(BOOL)autopause steps:(NSInteger)steps;
@end

@interface OverlandTestProtocol : NSURLProtocol
@end

static void (^requestHandler)(OverlandTestProtocol *);
@implementation OverlandTestProtocol
+ (BOOL)canInitWithRequest:(NSURLRequest *)request { return [request.URL.host isEqualToString:@"overland.test"]; }
+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)request { return request; }
- (void)startLoading { if(requestHandler) requestHandler(self); }
- (void)stopLoading {}
- (void)respond:(NSString *)body status:(NSInteger)status {
    NSHTTPURLResponse *response = [[NSHTTPURLResponse alloc] initWithURL:self.request.URL statusCode:status HTTPVersion:@"HTTP/1.1" headerFields:@{@"Content-Type": @"application/json"}];
    [self.client URLProtocol:self didReceiveResponse:response cacheStoragePolicy:NSURLCacheStorageNotAllowed];
    [self.client URLProtocol:self didLoadData:[body dataUsingEncoding:NSUTF8StringEncoding]];
    [self.client URLProtocolDidFinishLoading:self];
}
@end

@interface NSURLSessionConfiguration (OverlandTests)
+ (NSURLSessionConfiguration *)overland_testConfiguration;
@end

@implementation NSURLSessionConfiguration (OverlandTests)
+ (NSURLSessionConfiguration *)overland_testConfiguration {
    NSURLSessionConfiguration *config = [self overland_testConfiguration];
    config.protocolClasses = [@[OverlandTestProtocol.class] arrayByAddingObjectsFromArray:config.protocolClasses ?: @[]];
    return config;
}
@end

@interface OverlandTests : XCTestCase
@property GLManager *manager;
@property LOLDatabase *db;
@property NSDictionary *defaults;
@end

@implementation OverlandTests
+ (void)setUp {
    [super setUp];
    method_exchangeImplementations(class_getClassMethod(NSURLSessionConfiguration.class, @selector(defaultSessionConfiguration)), class_getClassMethod(NSURLSessionConfiguration.class, @selector(overland_testConfiguration)));
}
+ (void)tearDown {
    method_exchangeImplementations(class_getClassMethod(NSURLSessionConfiguration.class, @selector(defaultSessionConfiguration)), class_getClassMethod(NSURLSessionConfiguration.class, @selector(overland_testConfiguration)));
    [super tearDown];
}
- (void)setUp {
    [super setUp];
    [[GLManager sharedManager] stopAllUpdates];
    NSString *domain = NSBundle.mainBundle.bundleIdentifier;
    self.defaults = [[NSUserDefaults standardUserDefaults] persistentDomainForName:domain] ?: @{};
    [[NSUserDefaults standardUserDefaults] removePersistentDomainForName:domain];
    self.manager = [[GLManager alloc] init];
    [self.manager setValue:@(UIBackgroundTaskInvalid) forKey:@"sendBackgroundTask"];
    self.db = [[LOLDatabase alloc] initWithPath:@":memory:"];
    self.db.serializer = ^NSData *(id object) {
        if(![NSJSONSerialization isValidJSONObject:object]) return nil;
        return [NSJSONSerialization dataWithJSONObject:object options:0 error:NULL];
    };
    self.db.deserializer = ^id(NSData *data) { return [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL]; };
    [self.manager setValue:self.db forKey:@"db"];
    self.manager.sendingInterval = @-1;
    [NSURLProtocol registerClass:OverlandTestProtocol.class];
}
- (void)tearDown {
    requestHandler = nil;
    [self.manager stopAllUpdates];
    [self.manager saveNewAPIEndpoint:nil andAccessToken:nil];
    [NSURLProtocol unregisterClass:OverlandTestProtocol.class];
    [[NSUserDefaults standardUserDefaults] setPersistentDomain:self.defaults forName:NSBundle.mainBundle.bundleIdentifier];
    self.manager = nil;
    [super tearDown];
}
- (void)queue:(NSDictionary *)value key:(NSString *)key {
    [self.db accessCollection:@"GLLocationQueue" withBlock:^(id<LOLDatabaseAccessor> accessor) { [accessor setDictionary:value forKey:key]; }];
}
- (NSDictionary *)queued:(NSString *)key {
    __block NSDictionary *value;
    [self.db accessCollection:@"GLLocationQueue" withBlock:^(id<LOLDatabaseAccessor> accessor) { value = [accessor dictionaryForKey:key]; }];
    return value;
}
- (long)count {
    __block long count = -1;
    [self.manager numberOfLocationsInQueue:^(long num) { count = num; }];
    return count;
}
- (CLLocation *)location:(double)latitude time:(NSTimeInterval)time {
    return [[CLLocation alloc] initWithCoordinate:CLLocationCoordinate2DMake(latitude, -122.67) altitude:10 horizontalAccuracy:5 verticalAccuracy:5 course:0 speed:2 timestamp:[NSDate dateWithTimeIntervalSince1970:time]];
}
- (void)waitForSend {
    NSPredicate *done = [NSPredicate predicateWithBlock:^BOOL(id object, NSDictionary *bindings) { return !self.manager.sendInProgress; }];
    [self expectationForPredicate:done evaluatedWithObject:self.manager handler:nil];
    [self waitForExpectationsWithTimeout:5 handler:nil];
}
- (void)testFailedSerializationRollsBackDeletion {
    [self queue:@{@"saved": @YES} key:@"original"];
    [self.db accessCollection:@"GLLocationQueue" withBlock:^(id<LOLDatabaseAccessor> accessor) {
        [accessor deleteAllData];
        [accessor setDictionary:@{@"bad": NSDate.date} forKey:@"replacement"];
    }];
    XCTAssertEqual(self.count, 1);
    XCTAssertEqualObjects([self queued:@"original"][@"saved"], @YES);
}
- (void)testPrepareFailureDoesNotLeaveTransactionOpen {
    [self.db accessCollection:@"invalid'" withBlock:^(id<LOLDatabaseAccessor> accessor) { XCTFail(@"Invalid table must not run its block"); }];
    [self queue:@{@"ok": @YES} key:@"next"];
    XCTAssertEqual(self.count, 1);
}
- (void)testExceptionRollsBackTransaction {
    @try {
        [self.db accessCollection:@"GLLocationQueue" withBlock:^(id<LOLDatabaseAccessor> accessor) {
            [accessor setDictionary:@{@"ok": @YES} forKey:@"lost"];
            @throw [NSException exceptionWithName:@"Test" reason:nil userInfo:nil];
        }];
    } @catch(NSException *exception) {}
    XCTAssertNil([self queued:@"lost"]);
    [self queue:@{@"ok": @YES} key:@"kept"];
    XCTAssertEqual(self.count, 1);
}
- (void)testRepeatedCountAndEarlyEnumeration {
    [self queue:@{@"ok": @YES} key:@"one"];
    [self queue:@{@"ok": @YES} key:@"two"];
    [self.db accessCollection:@"GLLocationQueue" withBlock:^(id<LOLDatabaseAccessor> accessor) {
        for(int i = 0; i < 2; i++) {
            [accessor countObjectsUsingBlock:^(long count) { XCTAssertEqual(count, 2); }];
            __block int visits = 0;
            [accessor enumerateKeysAndObjectsUsingBlock:^BOOL(NSString *key, NSDictionary *object) { visits++; return YES; }];
            XCTAssertEqual(visits, 1);
        }
    }];
}
- (void)testFirstPointSurvivesFiltersAndBatchUsesLastAcceptedPoint {
    [self.manager setValue:@YES forKey:@"trackingEnabled"];
    self.manager.discardPointsWithinDistance = 20;
    self.manager.discardPointsWithinSeconds = 10;
    [self.manager processLocations:@[[self location:45.5 time:1000], [self location:45.501 time:1011], [self location:45.502 time:1012]]];
    XCTAssertEqual(self.count, 2);
}
- (void)testSameSecondLocationsKeepDistinctKeys {
    [self.manager setValue:@YES forKey:@"trackingEnabled"];
    self.manager.discardPointsWithinSeconds = 0;
    [self.manager processLocations:@[[self location:45.5 time:1000.1], [self location:45.501 time:1000.2]]];
    XCTAssertEqual(self.count, 2);
}
- (void)testStoppedTrackerIgnoresLocationAndRegionCallbacks {
    self.manager.trackingMode = kGLTrackingModeStandardAndSignificant;
    self.manager.visitTrackingEnabled = YES;
    XCTAssertFalse(self.manager.trackingEnabled);
    [self.manager processLocations:@[[self location:45.5 time:1000]]];
    CLCircularRegion *region = [[CLCircularRegion alloc] initWithCenter:CLLocationCoordinate2DMake(45.5, -122.67) radius:100 identifier:@"resume-from-pause"];
    [self.manager locationManager:self.manager.locationManager didExitRegion:region];
    XCTAssertFalse(self.manager.trackingEnabled);
    XCTAssertEqual(self.count, 0);
}
- (void)testRemoteSettingsAcceptNumbersAndOffAndRejectMalformedValues {
    [self.manager updateSettingsFromResponse:@[@"not an object"]];
    [self.manager updateSettingsFromResponse:@{@"set": @{@"main": @[], @"trip": NSNull.null}}];
    [self.manager updateSettingsFromResponse:@{@"set": @{@"send_interval": @"off", @"main": @{@"batch_size": @50, @"visit_tracking": NSNull.null}}}];
    XCTAssertEqual(self.manager.sendingInterval.integerValue, -1);
    XCTAssertEqual(self.manager.pointsPerBatch, 50);
}
- (void)testOwntracksTimestampIsPointTime {
    NSDictionary *point = [self.manager owntracksDictionaryFromLocation:[self location:45.5 time:1700000000]];
    XCTAssertEqualObjects(point[@"tst"], @1700000000);
}
- (void)testEmptyOwntracksQueueDoesNotStartSend {
    self.manager.loggingMode = kGLLoggingModeOwntracks;
    [self.manager saveNewAPIEndpoint:@"https://overland.test/" andAccessToken:nil];
    [self.manager sendQueueNow];
    XCTAssertFalse(self.manager.sendInProgress);
}
- (void)testOwntracksResponseRemovesOnlyTheSentPointAfterModeChanges {
    [self queue:@{@"_type": @"location", @"tst": @1} key:@"one"];
    [self queue:@{@"_type": @"location", @"tst": @2} key:@"two"];
    [self.manager saveNewAPIEndpoint:@"https://overland.test/" andAccessToken:nil];
    __block OverlandTestProtocol *pending;
    XCTestExpectation *received = [self expectationWithDescription:@"Request received"];
    requestHandler = ^(OverlandTestProtocol *request) { pending = request; [received fulfill]; };
    [self.manager sendQueueNow];
    [self waitForExpectationsWithTimeout:5 handler:nil];
    [[NSUserDefaults standardUserDefaults] setInteger:kGLLoggingModeAllData forKey:GLLoggingModeDefaultsName];
    [self queue:@{@"_type": @"location", @"tst": @3} key:@"three"];
    [pending respond:@"{\"result\":\"ok\",\"geocode\":123}" status:200];
    [self waitForSend];
    XCTAssertNil([self queued:@"one"]);
    XCTAssertNotNil([self queued:@"two"]);
    XCTAssertNotNil([self queued:@"three"]);
}
- (void)testMalformedAcknowledgementKeepsQueue {
    [self queue:@{@"properties": @{}} key:@"one"];
    [self.manager saveNewAPIEndpoint:@"https://overland.test/" andAccessToken:nil];
    requestHandler = ^(OverlandTestProtocol *request) { [request respond:@"{\"result\":123}" status:200]; };
    [self.manager sendQueueNow];
    [self waitForSend];
    XCTAssertEqual(self.count, 1);
}
- (void)testPlainHTTPResponseCanAcknowledgeUpload {
    [self queue:@{@"properties": @{}} key:@"one"];
    [[NSUserDefaults standardUserDefaults] setBool:YES forKey:GLConsiderHTTP200SuccessDefaultsName];
    [self.manager saveNewAPIEndpoint:@"https://overland.test/" andAccessToken:nil];
    requestHandler = ^(OverlandTestProtocol *request) { [request respond:@"accepted" status:200]; };
    [self.manager sendQueueNow];
    [self waitForSend];
    XCTAssertEqual(self.count, 0);
}
- (void)testCustomHeadersValidateAndReachRequest {
    self.manager.customHTTPHeaders = @{@"CF-Access-Client-Id": @"test", @"Bad\r\nName": @"invalid", @"X-Bad": @"a\nb", @"Host": @"other", @"Authorization": @"override"};
    XCTAssertEqual(self.manager.customHTTPHeaders.count, 1);
    [self queue:@{@"properties": @{}} key:@"one"];
    [self.manager saveNewAPIEndpoint:@"https://overland.test/" andAccessToken:@"token"];
    requestHandler = ^(OverlandTestProtocol *request) {
        XCTAssertEqualObjects([request.request valueForHTTPHeaderField:@"CF-Access-Client-Id"], @"test");
        XCTAssertEqualObjects([request.request valueForHTTPHeaderField:@"Authorization"], @"Bearer token");
        [request respond:@"{\"result\":\"ok\"}" status:200];
    };
    [self.manager sendQueueNow];
    [self waitForSend];
    XCTAssertEqual(self.count, 0);
}
- (void)testWifiBSSIDDisambiguatesSameSSID {
    [self.manager addWifiZoneWithName:@"Home" latitude:@"1" longitude:@"2" bssid:nil];
    [self.manager addWifiZoneWithName:@"Home" latitude:@"3" longitude:@"4" bssid:@"aa:bb:cc:dd:ee:ff"];
    XCTAssertEqual(self.manager.wifiZones.count, 2);
    CLLocation *exact = [self.manager currentLocationFromWifiName:@"Home" bssid:@"AA:BB:CC:DD:EE:FF"];
    XCTAssertEqual(exact.coordinate.latitude, 3);
    CLLocation *fallback = [self.manager currentLocationFromWifiName:@"Home" bssid:nil];
    XCTAssertEqual(fallback.coordinate.latitude, 1);
    XCTAssertNil([self.manager currentLocationFromWifiName:@"Other" bssid:@"aa:bb:cc:dd:ee:ff"]);
}
- (void)testUsageProfilesApplyAndRecognizeCustomEdits {
    for(NSInteger profile = 1; profile <= 5; profile++) {
        [self.manager applyUsageProfile:profile];
        XCTAssertEqual(self.manager.usageProfile, profile);
        XCTAssertFalse(self.manager.trackingEnabled);
        XCTAssertFalse(self.manager.visitTrackingEnabled);
        XCTAssertEqual(self.manager.discardPointsWithinDistance, -1);
        XCTAssertEqual(self.manager.discardPointsWithinSeconds, 0);
        XCTAssertEqual(self.manager.discardPointsOutsideAccuracy, -1);
    }
    XCTAssertEqual(self.manager.activityType, CLActivityTypeAutomotiveNavigation);
    XCTAssertEqual(self.manager.desiredAccuracy, kCLLocationAccuracyBestForNavigation);
    self.manager.discardPointsWithinDistance = 25;
    XCTAssertEqual(self.manager.usageProfile, 0);
    [self.manager applyUsageProfile:4];
    XCTAssertEqual(self.manager.activityType, CLActivityTypeFitness);
    XCTAssertEqual(self.manager.desiredAccuracy, kCLLocationAccuracyBest);
}

- (void)testLowPowerAndBalancedProfileThresholds {
    [self.manager applyUsageProfile:2];
    XCTAssertEqual(self.manager.trackingMode, kGLTrackingModeSignificant);
    XCTAssertTrue(self.manager.pausesAutomatically);
    XCTAssertEqual(self.manager.resumesAfterDistance, 500);
    XCTAssertEqual(self.manager.stopsAutomaticallyRadius, -1);
    [self.manager applyUsageProfile:3];
    XCTAssertEqual(self.manager.trackingMode, kGLTrackingModeStandardAndSignificant);
    XCTAssertEqual(self.manager.desiredAccuracy, 100);
    XCTAssertEqual(self.manager.stopsAutomaticallyRadius, 50);
    XCTAssertEqual(self.manager.stopsAutomaticallyAfterSeconds, 180);
    XCTAssertFalse(self.manager.pausesAutomatically);
    XCTAssertEqual(self.manager.resumesAfterDistance, -1);
    XCTAssertTrue(self.manager.showBackgroundLocationIndicator);
}

- (void)testUsageProfilePreservesUploadTripAndQueuedData {
    [self.manager saveNewAPIEndpoint:@"https://overland.test/" andAccessToken:@"test-token"];
    self.manager.loggingMode = kGLLoggingModeOwntracks;
    self.manager.sendingInterval = @900;
    self.manager.pointsPerBatch = 37;
    self.manager.desiredAccuracyDuringTrip = 23;
    [self queue:@{@"saved": @YES} key:@"saved"];
    [self.manager applyUsageProfile:1];
    XCTAssertEqualObjects(self.manager.apiEndpointURL, @"https://overland.test/");
    XCTAssertEqualObjects([NSUserDefaults.standardUserDefaults objectForKey:GLAPIAccessTokenDefaultsName], @"test-token");
    XCTAssertEqual(self.manager.loggingMode, kGLLoggingModeOwntracks);
    XCTAssertEqualObjects(self.manager.sendingInterval, @900);
    XCTAssertEqual(self.manager.pointsPerBatch, 37);
    XCTAssertEqual(self.manager.desiredAccuracyDuringTrip, 23);
    XCTAssertEqual(self.count, 1);
    XCTAssertEqualObjects([self queued:@"saved"][@"saved"], @YES);
    XCTAssertFalse(self.manager.trackingEnabled);
}

- (void)testInvalidProfilesAndActiveTripDoNotChangeSettings {
    [self.manager applyUsageProfile:1];
    NSDictionary *before = [NSUserDefaults.standardUserDefaults persistentDomainForName:NSBundle.mainBundle.bundleIdentifier];
    [self.manager applyUsageProfile:0];
    [self.manager applyUsageProfile:-1];
    [self.manager applyUsageProfile:6];
    XCTAssertEqualObjects(before, [NSUserDefaults.standardUserDefaults persistentDomainForName:NSBundle.mainBundle.bundleIdentifier]);
    [NSUserDefaults.standardUserDefaults setObject:NSDate.date forKey:GLTripStartTimeDefaultsName];
    [self.manager applyUsageProfile:2];
    XCTAssertEqual(self.manager.usageProfile, 1);
    XCTAssertTrue(self.manager.tripInProgress);
}

- (void)testEndpointRequiresHTTPAndHost {
    XCTAssertTrue([GLManager isValidEndpoint:@"https://example.com:8443/track"]);
    XCTAssertTrue([GLManager isValidEndpoint:@"http://localhost/track?lat=%LAT"]);
    XCTAssertFalse([GLManager isValidEndpoint:@"https:"]);
    XCTAssertFalse([GLManager isValidEndpoint:@"file:///tmp/data"]);
}
- (void)testFirstAutomaticSendAndFailureDoNotClaimSuccess {
    [self queue:@{@"properties": @{}} key:@"one"];
    [self.manager saveNewAPIEndpoint:@"https://overland.test/" andAccessToken:nil];
    self.manager.sendingInterval = @60;
    requestHandler = ^(OverlandTestProtocol *request) { [request respond:@"unavailable" status:503]; };
    [self.manager sendQueueIfTimeElapsed];
    XCTAssertTrue(self.manager.sendInProgress);
    [self waitForSend];
    XCTAssertNil(self.manager.lastSentDate);
    XCTAssertEqual(self.count, 1);
    XCTAssertEqualObjects(self.manager.recentSendResults.lastObject[@"status"], @1);
    [self.manager sendQueueIfTimeElapsed];
    XCTAssertFalse(self.manager.sendInProgress);
}

- (void)testTripRecordsPointsWithNormalTrackingModeOff {
    self.manager.trackingMode = kGLTrackingModeOff;
    [self.manager setValue:@YES forKey:@"trackingEnabled"];
    FMDatabase *trip = [FMDatabase databaseWithPath:@":memory:"];
    [trip open];
    [trip executeUpdate:@"CREATE TABLE trips (id INTEGER PRIMARY KEY, timestamp REAL, latitude REAL, longitude REAL)"];
    [self.manager setValue:trip forKey:@"tripdb"];
    [[NSUserDefaults standardUserDefaults] setObject:[NSDate dateWithTimeIntervalSince1970:900] forKey:GLTripStartTimeDefaultsName];
    [self.manager processLocations:@[[self location:45.5 time:1000], [self location:45.501 time:1010]]];
    XCTAssertEqual(self.count, 2);
    XCTAssertEqual(self.manager.currentTripPoints.count, 2);
    double distance = self.manager.currentTripDistance;
    XCTAssertGreaterThan(distance, 100);
    XCTAssertEqual(self.manager.currentTripDistance, distance);
    [self.manager writeTripToDB:NO steps:0];
    XCTAssertFalse(self.manager.tripInProgress);
    XCTAssertFalse(self.manager.trackingEnabled);
    XCTAssertFalse(trip.isOpen);
    XCTAssertEqual(self.count, 3);
}

- (void)testSendCannotBeStartedTwice {
    [self queue:@{@"properties": @{}} key:@"one"];
    [self.manager saveNewAPIEndpoint:@"https://overland.test/" andAccessToken:nil];
    __block int requests = 0;
    requestHandler = ^(OverlandTestProtocol *request) {
        requests++;
        [request respond:@"{\"result\":\"ok\"}" status:200];
    };
    [self.manager sendQueueNow];
    [self.manager sendQueueNow];
    [self waitForSend];
    XCTAssertEqual(requests, 1);
    XCTAssertEqual(self.count, 0);
}
- (void)testAccountLookupUsesAuthenticationAndCustomHeaders {
    self.manager.customHTTPHeaders = @{@"X-Client": @"overland"};
    [self.manager saveNewAPIEndpoint:@"https://overland.test/" andAccessToken:@"token"];
    requestHandler = ^(OverlandTestProtocol *request) {
        XCTAssertEqualObjects([request.request valueForHTTPHeaderField:@"Authorization"], @"Bearer token");
        XCTAssertEqualObjects([request.request valueForHTTPHeaderField:@"X-Client"], @"overland");
        [request respond:@"{\"name\":\"Test Account\"}" status:200];
    };
    XCTestExpectation *done = [self expectationWithDescription:@"Account lookup"];
    [self.manager accountInfo:^(NSString *name) {
        XCTAssertEqualObjects(name, @"Test Account");
        [done fulfill];
    }];
    [self waitForExpectationsWithTimeout:5 handler:nil];
}

- (void)testPayloadCountsTheActualSentBatch {
    [self queue:@{@"properties": @{@"locations_in_payload": @1}} key:@"one"];
    [self queue:@{@"properties": @{@"locations_in_payload": @1}} key:@"two"];
    [self queue:@{@"properties": @{@"locations_in_payload": @1}} key:@"three"];
    self.manager.pointsPerBatch = 2;
    [self.manager saveNewAPIEndpoint:@"https://overland.test/" andAccessToken:nil];
    requestHandler = ^(OverlandTestProtocol *request) {
        NSData *body = request.request.HTTPBody;
        if(!body) {
            NSInputStream *stream = request.request.HTTPBodyStream;
            NSMutableData *data = [NSMutableData data];
            [stream open];
            uint8_t buffer[1024];
            NSInteger count;
            while((count = [stream read:buffer maxLength:sizeof(buffer)]) > 0) [data appendBytes:buffer length:count];
            [stream close];
            body = data;
        }
        NSDictionary *payload = [NSJSONSerialization JSONObjectWithData:body options:0 error:NULL];
        XCTAssertEqual([payload[@"locations"] count], 2);
        for(NSDictionary *point in payload[@"locations"]) XCTAssertEqualObjects(point[@"properties"][@"locations_in_payload"], @2);
        [request respond:@"{\"result\":\"ok\"}" status:200];
    };
    [self.manager sendQueueNow];
    [self waitForSend];
    XCTAssertEqual(self.count, 1);
    XCTAssertNotNil([self queued:@"three"]);
}
@end

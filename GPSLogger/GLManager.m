//
//  GLManager.m
//  GPSLogger
//
//  Created by Aaron Parecki on 9/17/15.
//  Copyright © 2015 Esri. All rights reserved.
//  Copyright © 2017 Aaron Parecki. All rights reserved.
//

#import "GLManager.h"
#import "AFHTTPSessionManager.h"
#import "LOLDatabase.h"
#import "FMDatabase.h"
#import "SystemConfiguration/CaptiveNetwork.h"
#import <Security/Security.h>
#import <sqlite3.h>
#import "Overland-Swift.h"
@import UserNotifications;

@interface GLManager()

@property (strong, nonatomic) CLLocationManager *locationManager;
@property (strong, nonatomic) CMMotionActivityManager *motionActivityManager;
@property (strong, nonatomic) CMPedometer *pedometer;

@property BOOL trackingEnabled;
@property BOOL sendInProgress;
@property BOOL batchInProgress;
@property (strong, nonatomic) CLLocation *lastLocation;
@property (strong, nonatomic) CMMotionActivity *lastMotion;
@property (strong, nonatomic) NSDate *lastSentDate;
@property (strong, nonatomic) NSString *lastLocationName;

@property (strong, nonatomic) NSDictionary *lastLocationDictionary;
@property (strong, nonatomic) NSDictionary *tripStartLocationDictionary;

@property (strong, nonatomic) LOLDatabase *db;
@property (strong, nonatomic) FMDatabase *tripdb;

@property (strong, nonatomic) NSDate *lastScheduledNotificationDate;

@property (strong, nonatomic) NSMutableArray<NSDictionary *> *sendResultsLog;
@property (nonatomic, assign) UIBackgroundTaskIdentifier sendBackgroundTask;
@property (strong, nonatomic) NSURLSessionDataTask *sendTask;
@property NSUInteger sendGeneration;
@property BOOL endingTrip;
@property BOOL engineStationary;
@property (strong, nonatomic) NSDate *lastSendAttempt;

@end

@implementation GLManager

static NSString *const GLLocationQueueName = @"GLLocationQueue";
static NSString *const GLNotificationCategoryTripName = @"TRIP";
static NSString *const GLCustomHTTPHeadersDefaultsName = @"GLCustomHTTPHeadersDefaults";

static NSNumber *_sendingInterval;
static NSArray *_tripModes;
static bool _currentTripHasNewData;
static bool _storeNextLocationAsTripStart = NO;
static long _currentPointsInQueue;
static NSString *_deviceId;
static CLLocationDistance _currentTripDistanceCached;
static AFHTTPSessionManager *_httpClient;

static dispatch_queue_t GLNotificationQueue(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ queue = dispatch_queue_create("app.overland.notifications", DISPATCH_QUEUE_SERIAL); });
    return queue;
}

+ (GLManager *)sharedManager {
    static GLManager *_instance = nil;
    
    @synchronized (self) {
        if (_instance == nil) {
            _instance = [[self alloc] init];
            _instance.sendBackgroundTask = UIBackgroundTaskInvalid;
            
            _instance.db = [[LOLDatabase alloc] initWithPath:[self cacheDatabasePath]];
            _instance.db.serializer = ^(id object){
                NSError *error;
                NSData *data = [self dataWithJSONObject:object error:&error];
                if(!data) NSLog(@"Queue serialization failed: %@", error.localizedDescription);
                return data;
            };
            _instance.db.deserializer = ^(NSData *data) {
                return [self objectFromJSONData:data error:NULL];
            };
            
            _instance.tripdb = [FMDatabase databaseWithPath:[self tripDatabasePath]];
            [_instance setUpTripDB];
            
            [_instance setupHTTPClient];
            [_instance restoreTrackingState];
            dispatch_async(GLNotificationQueue(), ^{ [_instance initializeNotifications]; });
            [_instance numberOfLocationsInQueue:^(long num) {}];
            
            _instance.pedometer = [[CMPedometer alloc] init];
        }
    }
    
    return _instance;
}

#pragma mark - GLManager control (public)

+ (BOOL)isValidEndpoint:(NSString *)endpoint {
    if(endpoint.length == 0) return NO;
    NSURLComponents *url = [NSURLComponents componentsWithString:endpoint];
    NSString *scheme = url.scheme.lowercaseString;
    return ([scheme isEqualToString:@"https"] || [scheme isEqualToString:@"http"]) && url.host.length > 0 && url.URL != nil;
}

- (NSDictionary<NSString *, NSString *> *)customHTTPHeaders {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSDictionary *headers = [defaults dictionaryForKey:GLCustomHTTPHeadersDefaultsName];
    if(headers) return headers;
    NSMutableDictionary *legacy = [NSMutableDictionary dictionary];
    for(id header in [defaults arrayForKey:@"GLCustomHeadersDefaults"]) {
        if([header isKindOfClass:[NSDictionary class]] && [header[@"key"] isKindOfClass:[NSString class]] && [header[@"value"] isKindOfClass:[NSString class]]) {
            legacy[header[@"key"]] = header[@"value"];
        }
    }
    if(legacy.count == 0) return @{};
    self.customHTTPHeaders = legacy;
    return [defaults dictionaryForKey:GLCustomHTTPHeadersDefaultsName] ?: @{};
}

- (void)setCustomHTTPHeaders:(NSDictionary<NSString *, NSString *> *)headers {
    NSCharacterSet *invalidName = [[NSCharacterSet characterSetWithCharactersInString:@"!#$%&'*+-.^_`|~0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"] invertedSet];
    NSMutableDictionary *valid = [NSMutableDictionary dictionary];
    NSMutableSet *names = [NSMutableSet set];
    for(NSString *name in headers) {
        NSString *value = headers[name];
        if(![name isKindOfClass:[NSString class]] || ![value isKindOfClass:[NSString class]]) continue;
        NSString *lower = name.lowercaseString;
        if(name.length == 0 || [name rangeOfCharacterFromSet:invalidName].location != NSNotFound) continue;
        if([value rangeOfCharacterFromSet:[NSCharacterSet controlCharacterSet]].location != NSNotFound) continue;
        if([@[@"host", @"content-length", @"connection", @"transfer-encoding", @"authorization"] containsObject:lower] || [names containsObject:lower]) continue;
        [names addObject:lower];
        valid[[lower isEqualToString:@"authorization"] ? @"Authorization" : name] = value;
    }
    [[NSUserDefaults standardUserDefaults] setObject:valid forKey:GLCustomHTTPHeadersDefaultsName];
    [[NSNotificationCenter defaultCenter] postNotificationName:GLSettingsChangedNotification object:self];
}

- (void)saveNewAPIEndpoint:(NSString *)endpoint andAccessToken:(NSString *)accessToken {
    if(endpoint.length > 0 && ![GLManager isValidEndpoint:endpoint]) return;
    [[NSUserDefaults standardUserDefaults] setObject:endpoint.length > 0 ? endpoint : nil forKey:GLAPIEndpointDefaultsName];
    [[NSUserDefaults standardUserDefaults] setObject:accessToken forKey:GLAPIAccessTokenDefaultsName];
    [self setupHTTPClient];
}

- (NSString *)apiEndpointURL {
    return [[NSUserDefaults standardUserDefaults] stringForKey:GLAPIEndpointDefaultsName];
}

- (NSString *)apiAccessToken {
    return [[NSUserDefaults standardUserDefaults] stringForKey:GLAPIAccessTokenDefaultsName];
}

- (void)saveNewDeviceId:(NSString *)deviceId {
    _deviceId = deviceId;
    [[NSUserDefaults standardUserDefaults] setObject:deviceId forKey:GLDeviceIdDefaultsName];
    [[NSNotificationCenter defaultCenter] postNotificationName:GLSettingsChangedNotification object:self];
}

- (NSString *)deviceId {
    NSString *d = [[NSUserDefaults standardUserDefaults] stringForKey:GLDeviceIdDefaultsName];
    if(d == nil) {
        d = @"";
    }
    return d;
}

#pragma mark - Usage profiles

static NSDictionary *GLUsageProfileSettings(NSInteger profile) {
    if(profile < 1 || profile > 5) return nil;
    BOOL lowPower = profile == 2;
    BOOL balanced = profile == 3;
    CLLocationAccuracy accuracy = lowPower || balanced ? kCLLocationAccuracyHundredMeters : kCLLocationAccuracyBest;
    CLActivityType activity = CLActivityTypeOther;
    if(profile == 4) activity = CLActivityTypeFitness;
    if(profile == 5) {
        activity = CLActivityTypeAutomotiveNavigation;
        accuracy = kCLLocationAccuracyBestForNavigation;
    }
    return @{
        GLSignificantLocationModeDefaultsName: @(lowPower ? kGLTrackingModeSignificant : balanced ? kGLTrackingModeStandardAndSignificant : kGLTrackingModeStandard),
        GLDesiredAccuracyDefaultsName: @(accuracy),
        GLActivityTypeDefaultsName: @(activity),
        GLPausesAutomaticallyDefaultsName: @(lowPower),
        GLResumesAutomaticallyDefaultsName: @(lowPower ? 500 : -1),
        GLStopsAutomaticallyDefaultsName: @(balanced ? 50 : -1),
        GLStopsAutomaticallyAfterDefaultsName: @180,
        GLDiscardPointsWithinDistanceDefaultsName: @-1,
        GLDiscardPointsWithinSecondsDefaultsName: @0,
        GLDiscardPointsOutsideAccuracyDefaultsName: @-1,
        GLBackgroundIndicatorDefaultsName: @(!lowPower),
        GLVisitTrackingEnabledDefaultsName: @NO
    };
}

- (NSInteger)usageProfile {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    for(NSInteger profile = 1; profile <= 5; profile++) {
        NSDictionary *settings = GLUsageProfileSettings(profile);
        BOOL matches = YES;
        for(NSString *key in settings) {
            if(![[defaults objectForKey:key] isEqual:settings[key]]) {
                matches = NO;
                break;
            }
        }
        if(matches) return profile;
    }
    return 0;
}

- (void)applyUsageProfile:(NSInteger)profile {
    NSDictionary *settings = GLUsageProfileSettings(profile);
    if(!settings || self.tripInProgress) return;
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    for(NSString *key in settings) {
        [defaults setObject:settings[key] forKey:key];
    }
    [defaults removeObjectForKey:GLLastTimeMovedBeyondStopThresholdDefaultsName];
    for(CLRegion *region in self.locationManager.monitoredRegions) {
        if([region.identifier isEqualToString:@"resume-from-pause"]) {
            [self.locationManager stopMonitoringForRegion:region];
        }
    }
    if(self.trackingEnabled) [self enableTracking];
}

#pragma mark - Tracking

- (void)startAllUpdates {
    [[NSUserDefaults standardUserDefaults] setBool:YES forKey:GLTrackingStateDefaultsName];
    if(self.locationManager.authorizationStatus == kCLAuthorizationStatusNotDetermined) {
        [self requestAuthorizationPermission];
    }
    [self enableTracking];
}

- (void)stopAllUpdates {
    [[NSUserDefaults standardUserDefaults] setBool:NO forKey:GLTrackingStateDefaultsName];
    [self disableTracking];
}

- (void)refreshLocation {
    NSLog(@"Trying to update location now");
    if(!self.trackingEnabled) {
        return;
    }
    [[OverlandLocationEngine shared] stopLiveUpdates];
    [self performSelector:@selector(runEngineStandardUpdates) withObject:nil afterDelay:1.0];
}

- (void)runEngineStandardUpdates {
    if(!self.trackingEnabled || (!self.tripInProgress && self.trackingMode != kGLTrackingModeStandard && self.trackingMode != kGLTrackingModeStandardAndSignificant)) return;

    CLActivityType activity = self.tripInProgress ? self.activityTypeDuringTrip : self.activityType;
    CLLocationAccuracy accuracy = self.tripInProgress ? self.desiredAccuracyDuringTrip : self.desiredAccuracy;
    BOOL pauses = self.tripInProgress ? self.pausesAutomaticallyDuringTrip : self.pausesAutomatically;
    self.locationManager.activityType = activity;
    self.locationManager.desiredAccuracy = accuracy;
    self.locationManager.pausesLocationUpdatesAutomatically = pauses;

    // liveUpdates has no custom accuracy or pause-policy parameter.
    if(accuracy != kCLLocationAccuracyBest || !pauses) {
        [[OverlandLocationEngine shared] stopLiveUpdates];
        [self.locationManager startUpdatingLocation];
    } else {
        [self.locationManager stopUpdatingLocation];
        [[OverlandLocationEngine shared] runLiveUpdatesWithActivityType:activity];
    }
}

- (void)processEngineStationary:(BOOL)stationary {
    if(!self.trackingEnabled || stationary == self.engineStationary) return;
    self.engineStationary = stationary;
    if(stationary) {
        [self locationManagerDidPauseLocationUpdates:self.locationManager];
    } else {
        [self locationManagerDidResumeLocationUpdates:self.locationManager];
    }
}

- (void)processEngineLocation:(CLLocation *)location {
    if(self.trackingEnabled) {
        [self processLocations:@[location]];
    }
}

- (void)sendQueueNow {
    if(self.sendInProgress) {
        return;
    }

    NSMutableArray *syncedUpdates = [NSMutableArray array];
    NSMutableArray *locationUpdates = [NSMutableArray array];
    
    NSString *endpoint = [[NSUserDefaults standardUserDefaults] stringForKey:GLAPIEndpointDefaultsName];
    
    if(![GLManager isValidEndpoint:endpoint]) {
        NSLog(@"No API endpoint is set, not sending data");
        return;
    }
    
    __block long _numInQueue = 0;
    __block BOOL owntracks = NO;
    int batchSize = MAX(1, self.pointsPerBatchCurrentValue);
    BOOL acceptHTTP = self.shouldConsiderHTTP200Success;
    
    [self.db accessCollection:GLLocationQueueName withBlock:^(id<LOLDatabaseAccessor> accessor) {
        
        [accessor enumerateKeysAndObjectsUsingBlock:^(NSString *key, NSDictionary *object) {
            if(key && [object isKindOfClass:[NSDictionary class]]) {
                BOOL isOwntracks = [object[@"_type"] isEqual:@"location"];
                if(locationUpdates.count == 0) owntracks = isOwntracks;
                if(isOwntracks != owntracks) return YES;
                [syncedUpdates addObject:key];
                [locationUpdates addObject:object];
            } else if(key) {
                // Remove nil objects
                [accessor removeDictionaryForKey:key];
            }
            return (BOOL)(owntracks || locationUpdates.count >= batchSize);
        }];
        
        [accessor countObjectsUsingBlock:^(long num) {
            _numInQueue = num;
        }];
    }];
    
    NSDictionary *postData;

    if(locationUpdates.count == 0) {
        self.batchInProgress = NO;
        return;
    }

    if(owntracks) {
        postData = locationUpdates[0];
    } else {
        NSMutableDictionary *payload = [NSMutableDictionary dictionaryWithDictionary:@{@"locations": locationUpdates}];
        postData = payload;

        // Recount the outgoing batch; the stored count describes the original callback.
        // Database records need mutable copies before their metadata can change.
        for(int i=0; i<(int)locationUpdates.count; i++) {
            NSDictionary *update = locationUpdates[i];
            NSDictionary *properties = [update objectForKey:@"properties"];
            if(![properties isKindOfClass:[NSDictionary class]]) continue;
            NSMutableDictionary *newProperties = [properties mutableCopy];
            [newProperties setValue:[NSNumber numberWithLong:locationUpdates.count] forKey:@"locations_in_payload"];
            NSMutableDictionary *newUpdate = [update mutableCopy];
            [newUpdate setValue:newProperties forKey:@"properties"];
            [locationUpdates replaceObjectAtIndex:i withObject:newUpdate];
        }
        
        // Include the latest fix separately so a backlog does not hide the current location.
        if(_numInQueue > batchSize && self.lastLocation) {
            [payload setObject:[self currentDictionaryFromLocation:self.lastLocation] forKey:@"current"];
        }
        
        if(self.tripInProgress) {
            NSDictionary *currentTripInfo = [self currentTripDictionary];
            [payload setObject:currentTripInfo forKey:@"trip"];
        }
    }
    
    // If there are any template strings in the URL, replace the values with the data from the most recent location
    // TS, LAT, LON, ACC, SPD, ALT, BAT
    NSMutableString *endpointURL = [endpoint mutableCopy];
    [endpointURL replaceOccurrencesOfString:@"%TS"
                                 withString:[self stringForProperty:kGLLocationPropertyTimestamp ofLocation:self.lastLocation] options:NSLiteralSearch
                                      range:NSMakeRange(0, endpointURL.length)];
    [endpointURL replaceOccurrencesOfString:@"%LAT"
                                 withString:[self stringForProperty:kGLLocationPropertyLatitude ofLocation:self.lastLocation] options:NSLiteralSearch
                                      range:NSMakeRange(0, endpointURL.length)];
    [endpointURL replaceOccurrencesOfString:@"%LON"
                                 withString:[self stringForProperty:kGLLocationPropertyLongitude ofLocation:self.lastLocation] options:NSLiteralSearch
                                      range:NSMakeRange(0, endpointURL.length)];
    [endpointURL replaceOccurrencesOfString:@"%ACC"
                                 withString:[self stringForProperty:kGLLocationPropertyAccuracy ofLocation:self.lastLocation] options:NSLiteralSearch
                                      range:NSMakeRange(0, endpointURL.length)];
    [endpointURL replaceOccurrencesOfString:@"%SPD"
                                 withString:[self stringForProperty:kGLLocationPropertySpeed ofLocation:self.lastLocation] options:NSLiteralSearch
                                      range:NSMakeRange(0, endpointURL.length)];
    [endpointURL replaceOccurrencesOfString:@"%ALT"
                                 withString:[self stringForProperty:kGLLocationPropertyAltitude ofLocation:self.lastLocation] options:NSLiteralSearch
                                      range:NSMakeRange(0, endpointURL.length)];
    [endpointURL replaceOccurrencesOfString:@"%BAT"
                                 withString:[self stringForProperty:kGLLocationPropertyBattery ofLocation:self.lastLocation] options:NSLiteralSearch
                                      range:NSMakeRange(0, endpointURL.length)];

    
    NSLog(@"Updates in post: %lu", (unsigned long)locationUpdates.count);
    
    [self sendingStarted];
    
    self.lastSendAttempt = NSDate.date;
    NSUInteger generation = ++self.sendGeneration;
    NSDictionary *headers = [self requestHeadersForOwntracks:owntracks];
    self.sendTask = [_httpClient POST:endpointURL parameters:postData headers:headers progress:NULL success:^(NSURLSessionDataTask * _Nonnull task, id  _Nullable responseObject) {
        if(generation != self.sendGeneration) return;
        if([responseObject isKindOfClass:[NSData class]]) {
            responseObject = [GLManager objectFromJSONData:responseObject error:NULL];
        }
        BOOL requestWasSuccessfullySent = NO;
        if(acceptHTTP) {
            // Any non-200 response would have been caught by the error callback instead
            requestWasSuccessfullySent = YES;
        } else {
            // Response must be JSON
            if(![responseObject respondsToSelector:@selector(objectForKey:)]) {
                self.batchInProgress = NO;
                [self recordSendResult:GLSendStatusServerError];
                [self notify:@"Server did not return a JSON object" withTitle:@"Server Error"];
                [self sendingFinished];
                return;
            }

            // Response JSON must include {"result":"ok"}
            requestWasSuccessfullySent = [[responseObject objectForKey:@"result"] isEqual:@"ok"];
        }
        
        
        if(requestWasSuccessfullySent) {
            [self recordSendResult:GLSendStatusSuccess];
            self.lastSentDate = NSDate.date;
            NSDictionary *geocode = [responseObject isKindOfClass:[NSDictionary class]] ? responseObject[@"geocode"] : nil;
            id name = [geocode isKindOfClass:[NSDictionary class]] ? geocode[@"full_name"] : nil;
            self.lastLocationName = [name isKindOfClass:[NSString class]] ? name : @"";

            [self.db accessCollection:GLLocationQueueName withBlock:^(id<LOLDatabaseAccessor> accessor) {
                for(NSString *key in syncedUpdates) {
                    [accessor removeDictionaryForKey:key];
                }
            }];

            [self.db accessCollection:GLLocationQueueName withBlock:^(id<LOLDatabaseAccessor> accessor) {
                [accessor countObjectsUsingBlock:^(long num) {
                    _currentPointsInQueue = num;
                    NSLog(@"Number remaining: %ld", num);
                    if(num >= batchSize) {
                        self.batchInProgress = YES;
                    } else {
                        self.batchInProgress = NO;
                    }
                }];

            }];

            [self sendingFinished];
            [self updateSettingsFromResponse:responseObject];
        } else {

            self.batchInProgress = NO;
            [self recordSendResult:GLSendStatusServerError];

            if([[responseObject objectForKey:@"error"] isKindOfClass:[NSString class]]) {
                [self notify:[responseObject objectForKey:@"error"] withTitle:@"Server Error"];
            } else {
                [self notify:@"Server did not acknowledge the data was received, and did not return an error message" withTitle:@"Server Error"];
            }

            [self sendingFinished];
        }
    } failure:^(NSURLSessionDataTask * _Nullable task, NSError * _Nonnull error) {
        if(generation != self.sendGeneration) return;
        self.batchInProgress = NO;
        NSInteger status = [(NSHTTPURLResponse *)task.response statusCode];
        [self recordSendResult:status >= 400 ? GLSendStatusServerError : GLSendStatusNetworkError];
        NSLog(@"Send failed (%@, %ld), HTTP %ld", error.domain, (long)error.code, (long)status);
        if(error.code == NSURLErrorServerCertificateUntrusted
           || error.code == NSURLErrorServerCertificateHasUnknownRoot
           || error.code == NSURLErrorServerCertificateHasBadDate
           || error.code == NSURLErrorClientCertificateRejected) {
            NSString *certMessage = [GLManager certificateFailureExplanation:error];
            NSLog(@"%@", certMessage);
            [self notify:certMessage withTitle:@"Certificate Error"];
        } else {
            [self notify:error.localizedDescription withTitle:@"HTTP Error"];
        }
        [self sendingFinished];
    }];

}

// Include trust-evaluation errors to help diagnose the server's certificate setup.
+ (NSString *)certificateFailureExplanation:(NSError *)error {
    NSMutableString *message = [NSMutableString stringWithString:@"The server's certificate could not be verified."];

    SecTrustRef trust = (__bridge SecTrustRef)error.userInfo[NSURLErrorFailingURLPeerTrustErrorKey];
    if(trust) {
        CFErrorRef evaluateError = NULL;
        if(!SecTrustEvaluateWithError(trust, &evaluateError) && evaluateError) {
            NSError *current = (__bridge NSError *)evaluateError;
            int depth = 0;
            while(current && depth < 5) {
                NSString *reason = current.localizedDescription;
                if(reason.length > 0 && ![message containsString:reason]) {
                    [message appendFormat:@" %@", reason];
                }
                current = current.userInfo[NSUnderlyingErrorKey];
                depth++;
            }
            CFRelease(evaluateError);
        }
    } else {
        [message appendFormat:@" %@", error.localizedDescription];
    }

    [message appendString:@" iOS does not download missing intermediate certificates, so the server must present the complete chain with a certificate that matches the domain and is not expired."];
    return message;
}

- (void)updateSettingsFromResponse:(id _Nullable)responseObject {
    if(![responseObject respondsToSelector:@selector(objectForKey:)]) {
        return;
    }
    NSDictionary *settings = [responseObject objectForKey:@"set"];
    if(settings == nil) {
        return;
    }
    
    if(![settings respondsToSelector:@selector(objectForKey:)]) {
        return;
    }
    

    
    NSDictionary *sendIntervalBlocks = @{
        @"1s": ^{ self.sendingInterval = @1; },
        @"5s": ^{ self.sendingInterval = @5; },
        @"10s": ^{ self.sendingInterval = @10; },
        @"15s": ^{ self.sendingInterval = @15; },
        @"30s": ^{ self.sendingInterval = @30; },
        @"1m": ^{ self.sendingInterval = @60; },
        @"2m": ^{ self.sendingInterval = @120; },
        @"5m": ^{ self.sendingInterval = @300; },
        @"10m": ^{ self.sendingInterval = @600; },
        @"30m": ^{ self.sendingInterval = @1800; },
        @"off": ^{ self.sendingInterval = @-1; },
    };
    [self runBlock:sendIntervalBlocks fromDictionary:settings forKey:@"send_interval"];

    NSString *tripMode = [settings objectForKey:@"trip_mode"];
    if([tripMode respondsToSelector:@selector(isEqualToString:)]) {
        for(int i=0; i<[GLManager GLTripModes].count; i++) {
            if([tripMode isEqualToString:[GLManager GLTripModes][i]]) {
                self.currentTripMode = [GLManager GLTripModes][i];
            }
        }
    }
    
    NSDictionary *main = [settings objectForKey:@"main"];
    if([main isKindOfClass:[NSDictionary class]]) {
        
        NSDictionary *trackingModeBlocks = @{
            @"off": ^{ self.trackingMode = kGLTrackingModeOff; },
            @"standard": ^{ self.trackingMode = kGLTrackingModeStandard; },
            @"significant": ^{ self.trackingMode = kGLTrackingModeSignificant; },
            @"both": ^{ self.trackingMode = kGLTrackingModeStandardAndSignificant; },
        };
        [self runBlock:trackingModeBlocks fromDictionary:main forKey:@"tracking_mode"];

        if([[main objectForKey:@"visit_tracking"] respondsToSelector:@selector(boolValue)]) {
            self.visitTrackingEnabled = [[main objectForKey:@"visit_tracking"] boolValue];
        }
        
        NSDictionary *desiredAccuracyBlocks = @{
            @"nav": ^{ self.desiredAccuracy = kCLLocationAccuracyBestForNavigation; },
            @"best": ^{ self.desiredAccuracy = kCLLocationAccuracyBest; },
            @"10m": ^{ self.desiredAccuracy = kCLLocationAccuracyNearestTenMeters; },
            @"100m": ^{ self.desiredAccuracy = kCLLocationAccuracyHundredMeters; },
            @"1km": ^{ self.desiredAccuracy = kCLLocationAccuracyKilometer; },
            @"3km": ^{ self.desiredAccuracy = kCLLocationAccuracyThreeKilometers; },
        };
        [self runBlock:desiredAccuracyBlocks fromDictionary:main forKey:@"desired_accuracy"];

        NSDictionary *activityTypeBlocks = @{
            @"other": ^{ self.activityType = CLActivityTypeOther; },
            @"car": ^{ self.activityType = CLActivityTypeAutomotiveNavigation; },
            @"fitness": ^{ self.activityType = CLActivityTypeFitness; },
            @"nav": ^{ self.activityType = CLActivityTypeOtherNavigation; },
            @"air": ^{ self.activityType = CLActivityTypeAirborne; },
        };
        [self runBlock:activityTypeBlocks fromDictionary:main forKey:@"activity_type"];

        if([[main objectForKey:@"background_indicator"] respondsToSelector:@selector(boolValue)]) {
            self.showBackgroundLocationIndicator = [[main objectForKey:@"background_indicator"] boolValue];
        }

        if([[main objectForKey:@"pause_automatically"] respondsToSelector:@selector(boolValue)]) {
            self.pausesAutomatically = [[main objectForKey:@"pause_automatically"] boolValue];
        }

        NSDictionary *loggingModeBlocks = @{
            @"all": ^{ self.loggingMode = kGLLoggingModeAllData; },
            @"latest": ^{ self.loggingMode = kGLLoggingModeOnlyLatest; },
            @"owntracks": ^{ self.loggingMode = kGLLoggingModeOwntracks; },
        };
        [self runBlock:loggingModeBlocks fromDictionary:main forKey:@"logging_mode"];
        
        NSDictionary *batchSizeBlocks = @{
            @50: ^{ self.pointsPerBatch = 50; },
            @100: ^{ self.pointsPerBatch = 100; },
            @200: ^{ self.pointsPerBatch = 200; },
            @500: ^{ self.pointsPerBatch = 500; },
            @1000: ^{ self.pointsPerBatch = 1000; },
        };
        [self runBlock:batchSizeBlocks fromDictionary:main forKey:@"batch_size"];

        NSDictionary *resumeWithGeofenceBlocks = @{
            @"off": ^{ self.resumesAfterDistance = -1; },
            @"100m": ^{ self.resumesAfterDistance = 100; },
            @"200m": ^{ self.resumesAfterDistance = 200; },
            @"500m": ^{ self.resumesAfterDistance = 500; },
            @"1km": ^{ self.resumesAfterDistance = 1000; },
            @"2km": ^{ self.resumesAfterDistance = 2000; },
        };
        [self runBlock:resumeWithGeofenceBlocks fromDictionary:main forKey:@"resume_with_geofence"];

        NSDictionary *minDistanceBlocks = @{
            @"off": ^{ self.discardPointsWithinDistance = -1; },
            @"1m": ^{ self.discardPointsWithinDistance = 1; },
            @"10m": ^{ self.discardPointsWithinDistance = 10; },
            @"50m": ^{ self.discardPointsWithinDistance = 50; },
            @"100m": ^{ self.discardPointsWithinDistance = 100; },
            @"500m": ^{ self.discardPointsWithinDistance = 500; },
        };
        [self runBlock:minDistanceBlocks fromDictionary:main forKey:@"min_distance"];

        NSDictionary *minTimeBlocks = @{
            @"1s": ^{ self.discardPointsWithinSeconds = 1; },
            @"5s": ^{ self.discardPointsWithinSeconds = 5; },
            @"10s": ^{ self.discardPointsWithinSeconds = 10; },
            @"30s": ^{ self.discardPointsWithinSeconds = 30; },
            @"1m": ^{ self.discardPointsWithinSeconds = 60; },
            @"5m": ^{ self.discardPointsWithinSeconds = 300; },
        };
        [self runBlock:minTimeBlocks fromDictionary:main forKey:@"min_time"];
        
        NSDictionary *maxAccuracyBlocks = @{
            @"off": ^{ self.discardPointsOutsideAccuracy = -1; },
            @"10m": ^{ self.discardPointsOutsideAccuracy = 10; },
            @"50m": ^{ self.discardPointsOutsideAccuracy = 50; },
            @"100m": ^{ self.discardPointsOutsideAccuracy = 100; },
            @"500m": ^{ self.discardPointsOutsideAccuracy = 500; },
            @"1000m": ^{ self.discardPointsOutsideAccuracy = 1000; },
        };
        [self runBlock:maxAccuracyBlocks fromDictionary:main forKey:@"max_accuracy"];
        
        NSDictionary *stopsRadiusBlocks = @{
            @"off": ^{ self.stopsAutomaticallyRadius = -1; },
            @"10m": ^{ self.stopsAutomaticallyRadius = 10; },
            @"20m": ^{ self.stopsAutomaticallyRadius = 20; },
            @"50m": ^{ self.stopsAutomaticallyRadius = 50; },
            @"100m": ^{ self.stopsAutomaticallyRadius = 100; },
            @"200m": ^{ self.stopsAutomaticallyRadius = 200; },
        };
        [self runBlock:stopsRadiusBlocks fromDictionary:main forKey:@"stop_radius"];

        NSDictionary *stopsTimeBlocks = @{
            @"1min": ^{ self.stopsAutomaticallyAfterSeconds = 60; },
            @"2min": ^{ self.stopsAutomaticallyAfterSeconds = 60*2; },
            @"5min": ^{ self.stopsAutomaticallyAfterSeconds = 60*5; },
            @"10min": ^{ self.stopsAutomaticallyAfterSeconds = 60*10; },
            @"20min": ^{ self.stopsAutomaticallyAfterSeconds = 60*20; },
        };
        [self runBlock:stopsTimeBlocks fromDictionary:main forKey:@"stop_time"];

    }

    NSDictionary *trip = [settings objectForKey:@"trip"];
    if(trip != nil && [trip respondsToSelector:@selector(objectForKey:)]) {
        
        NSDictionary *desiredAccuracyDuringTripBlocks = @{
            @"nav": ^{ self.desiredAccuracyDuringTrip = kCLLocationAccuracyBestForNavigation; },
            @"best": ^{ self.desiredAccuracyDuringTrip = kCLLocationAccuracyBest; },
            @"10m": ^{ self.desiredAccuracyDuringTrip = kCLLocationAccuracyNearestTenMeters; },
            @"100m": ^{ self.desiredAccuracyDuringTrip = kCLLocationAccuracyHundredMeters; },
            @"1km": ^{ self.desiredAccuracyDuringTrip = kCLLocationAccuracyKilometer; },
            @"3km": ^{ self.desiredAccuracyDuringTrip = kCLLocationAccuracyThreeKilometers; },
        };
        [self runBlock:desiredAccuracyDuringTripBlocks fromDictionary:trip forKey:@"desired_accuracy"];

        NSDictionary *activityTypeDuringTripBlocks = @{
            @"other": ^{ self.activityTypeDuringTrip = CLActivityTypeOther; },
            @"car": ^{ self.activityTypeDuringTrip = CLActivityTypeAutomotiveNavigation; },
            @"fitness": ^{ self.activityTypeDuringTrip = CLActivityTypeFitness; },
            @"nav": ^{ self.activityTypeDuringTrip = CLActivityTypeOtherNavigation; },
            @"air": ^{ self.activityTypeDuringTrip = CLActivityTypeAirborne; },
        };
        [self runBlock:activityTypeDuringTripBlocks fromDictionary:trip forKey:@"activity_type"];

        if([[trip objectForKey:@"background_indicator"] respondsToSelector:@selector(boolValue)]) {
            self.showBackgroundLocationIndicatorDuringTrip = [[trip objectForKey:@"background_indicator"] boolValue];
        }

        if([[trip objectForKey:@"prevent_screen_lock"] respondsToSelector:@selector(boolValue)]) {
            [[NSUserDefaults standardUserDefaults] setBool:[[trip objectForKey:@"prevent_screen_lock"] boolValue] forKey:GLScreenLockEnabledDefaultsName];
        }

        NSDictionary *loggingModeDuringTripBlocks = @{
            @"all": ^{ self.loggingModeDuringTrip = kGLLoggingModeAllData; },
            @"latest": ^{ self.loggingModeDuringTrip = kGLLoggingModeOnlyLatest; },
            @"owntracks": ^{ self.loggingModeDuringTrip = kGLLoggingModeOwntracks; },
        };
        [self runBlock:loggingModeDuringTripBlocks fromDictionary:trip forKey:@"logging_mode"];
        
        NSDictionary *batchSizeDuringTripBlocks = @{
            @50: ^{ self.pointsPerBatchDuringTrip = 50; },
            @100: ^{ self.pointsPerBatchDuringTrip = 100; },
            @200: ^{ self.pointsPerBatchDuringTrip = 200; },
            @500: ^{ self.pointsPerBatchDuringTrip = 500; },
            @1000: ^{ self.pointsPerBatchDuringTrip = 1000; },
        };
        [self runBlock:batchSizeDuringTripBlocks fromDictionary:trip forKey:@"batch_size"];

        NSDictionary *minDistanceDuringTripBlocks = @{
            @"off": ^{ self.discardPointsWithinDistanceDuringTrip = -1; },
            @"1m": ^{ self.discardPointsWithinDistanceDuringTrip = 1; },
            @"10m": ^{ self.discardPointsWithinDistanceDuringTrip = 10; },
            @"50m": ^{ self.discardPointsWithinDistanceDuringTrip = 50; },
            @"100m": ^{ self.discardPointsWithinDistanceDuringTrip = 100; },
            @"500m": ^{ self.discardPointsWithinDistanceDuringTrip = 500; },
        };
        [self runBlock:minDistanceDuringTripBlocks fromDictionary:trip forKey:@"min_distance"];

        NSDictionary *minTimeDuringTripBlocks = @{
            @"1s": ^{ self.discardPointsWithinSecondsDuringTrip = 1; },
            @"5s": ^{ self.discardPointsWithinSecondsDuringTrip = 5; },
            @"10s": ^{ self.discardPointsWithinSecondsDuringTrip = 10; },
            @"30s": ^{ self.discardPointsWithinSecondsDuringTrip = 30; },
            @"1m": ^{ self.discardPointsWithinSecondsDuringTrip = 60; },
            @"5m": ^{ self.discardPointsWithinSecondsDuringTrip = 300; },
        };
        [self runBlock:minTimeDuringTripBlocks fromDictionary:trip forKey:@"min_time"];

    }
    
    id headers = [settings objectForKey:@"custom_headers"];
    if([headers isKindOfClass:[NSDictionary class]]) self.customHTTPHeaders = headers;
    [UIApplication sharedApplication].idleTimerDisabled = self.tripInProgress && [[NSUserDefaults standardUserDefaults] boolForKey:GLScreenLockEnabledDefaultsName];
    [[NSNotificationCenter defaultCenter] postNotificationName:GLSettingsChangedNotification object:self];
}

- (void)runBlock:(NSDictionary *)blocks fromDictionary:(NSDictionary *)dictionary forKey:(NSString *)key {
    id property = [dictionary objectForKey:key];
    if([property isKindOfClass:[NSString class]] || [property isKindOfClass:[NSNumber class]]) {
        if([blocks objectForKey:property] != nil) {
            ((CaseBlock)blocks[property])();
        }
    }
}

- (NSString *)stringForProperty:(GLLocationProperty)prop ofLocation:(CLLocation *)location {
    if(!location && prop != kGLLocationPropertyBattery) return @"";
    NSString *string;
    switch(prop) {
        case kGLLocationPropertyTimestamp:
            string = [GLManager iso8601DateStringFromDate:location.timestamp];
            break;
        case kGLLocationPropertyLatitude:
            string = [[NSNumber numberWithDouble:((int)(location.coordinate.latitude * 10000000)) / 10000000.0] stringValue];
            break;
        case kGLLocationPropertyLongitude:
            string = [[NSNumber numberWithDouble:((int)(location.coordinate.longitude * 10000000)) / 10000000.0] stringValue];
            break;
            
        case kGLLocationPropertyAccuracy:
            string = [[NSNumber numberWithInt:(int)round(location.horizontalAccuracy)] stringValue];
            break;
        case kGLLocationPropertySpeed:
            string = [[NSNumber numberWithInt:(int)round(location.speed)] stringValue];
            break;
        case kGLLocationPropertyAltitude:
            string = [[NSNumber numberWithInt:(int)round(location.altitude)] stringValue];
            break;
        case kGLLocationPropertyBattery:
            string = [[self currentBatteryLevel] stringValue];
            break;
    }
    return string;
}

- (void)logAction:(NSString *)action {
    if(!self.includeTrackingStats || self.loggingModeCurrentValue == kGLLoggingModeOwntracks) {
        return;
    }

    [self.db accessCollection:GLLocationQueueName withBlock:^(id<LOLDatabaseAccessor> accessor) {
        NSString *timestamp = [GLManager iso8601DateStringFromDate:[NSDate date]];
        NSMutableDictionary *update = [NSMutableDictionary dictionaryWithDictionary:@{
                                                                                      @"type": @"Feature",
                                                                                      @"properties": [NSMutableDictionary dictionaryWithDictionary:@{
                                                                                              @"timestamp": timestamp,
                                                                                              @"action": action,
                                                                                              }]
                                                                                      }];
        [self addMetadataToUpdate:update];
        
        if(self.lastLocation) {
            [update setObject:@{
                                @"type": @"Point",
                                @"coordinates": @[
                                        [NSNumber numberWithDouble:self.lastLocation.coordinate.longitude],
                                        [NSNumber numberWithDouble:self.lastLocation.coordinate.latitude]
                                        ]
                                } forKey:@"geometry"];
        }
        [accessor setDictionary:update forKey:[NSString stringWithFormat:@"%@-log-%@", timestamp, NSUUID.UUID.UUIDString]];
    }];
}

- (NSDictionary *)requestHeadersForOwntracks:(BOOL)owntracks {
    NSMutableDictionary *headers = [NSMutableDictionary dictionaryWithDictionary:self.customHTTPHeaders];
    if(self.apiAccessToken.length > 0) {
        headers[@"Authorization"] = [(owntracks ? @"Basic " : @"Bearer ") stringByAppendingString:self.apiAccessToken];
    }
    return headers;
}

- (void)accountInfo:(void(^)(NSString *name))block {
    NSString *endpoint = [[NSUserDefaults standardUserDefaults] stringForKey:GLAPIEndpointDefaultsName];
    if(![GLManager isValidEndpoint:endpoint]) { block(nil); return; }
    [_httpClient GET:endpoint parameters:nil headers:[self requestHeadersForOwntracks:self.loggingModeCurrentValue == kGLLoggingModeOwntracks] progress:NULL success:^(NSURLSessionDataTask *task, id responseObject) {
        id response = [responseObject isKindOfClass:[NSData class]] ? [GLManager objectFromJSONData:responseObject error:NULL] : responseObject;
        id name = [response isKindOfClass:[NSDictionary class]] ? response[@"name"] : nil;
        block([name isKindOfClass:[NSString class]] ? name : nil);
    } failure:^(NSURLSessionDataTask *task, NSError *error) {
        block(nil);
    }];
}

- (void)numberOfLocationsInQueue:(void(^)(long num))callback {
    [self.db accessCollection:GLLocationQueueName withBlock:^(id<LOLDatabaseAccessor> accessor) {
        [accessor countObjectsUsingBlock:^(long num) {
            _currentPointsInQueue = num;
            callback(num);
        }];
    }];
}

- (void)numberOfObjectsInQueue:(void(^)(long locations, long trips, long stats))callback {
    [self.db accessCollection:GLLocationQueueName withBlock:^(id<LOLDatabaseAccessor> accessor) {
        __block long locations = 0;
        __block long trips = 0;
        __block long stats = 0;
        [accessor enumerateKeysAndObjectsUsingBlock:^(NSString *key, NSDictionary *object) {
            NSDictionary *properties = [object objectForKey:@"properties"];
            if([properties objectForKey:@"action"]) {
                stats++;
            } else if([[properties objectForKey:@"type"] isEqualToString:@"trip"]) {
                trips++;
            } else {
                locations++;
            }
            return NO;
        }];
        //NSLog(@"Queue stats: %ld %ld %ld", locations, trips, stats);
        callback(locations, trips, stats);
    }];
}


- (void)requestAuthorizationPermission {
    bool isFirstRequest = false;
    if (@available(iOS 14.0, *)) {
        if(self.locationManager.authorizationStatus == kCLAuthorizationStatusNotDetermined) {
            isFirstRequest = true;
        }
    }
    if(isFirstRequest) {
        NSLog(@"Requesting WhenInUse Permission");
        [self.locationManager requestWhenInUseAuthorization];
    } else {
        NSLog(@"Requesting Always Permission");
        [self.locationManager requestAlwaysAuthorization];
    }
}


#pragma mark - GLManager control (private)

- (void)setupHTTPClient {
    self.sendGeneration++;
    [self.sendTask cancel];
    if(self.sendInProgress) [self sendingFinished];
    self.batchInProgress = NO;
    [_httpClient invalidateSessionCancelingTasks:YES resetSession:NO];
    _httpClient = [AFHTTPSessionManager manager];
    _httpClient.requestSerializer = [AFJSONRequestSerializer serializer];
    _httpClient.responseSerializer = [AFHTTPResponseSerializer serializer];
    _httpClient.requestSerializer.timeoutInterval = 30;
    _deviceId = [self deviceId];
    [[NSNotificationCenter defaultCenter] postNotificationName:GLSettingsChangedNotification object:self];
}

- (void)restoreTrackingState {
    if(self.tripInProgress) {
        [self.tripdb open];
        _currentTripHasNewData = YES;
        _storeNextLocationAsTripStart = self.currentTripStartLocationDictionary == nil;
    }
    [UIApplication sharedApplication].idleTimerDisabled = self.tripInProgress && [[NSUserDefaults standardUserDefaults] boolForKey:GLScreenLockEnabledDefaultsName];
    if([[NSUserDefaults standardUserDefaults] boolForKey:GLTrackingStateDefaultsName]) {
        [self enableTracking];
    } else {
        [self disableTracking];
    }
}

- (void)locationManagerDidChangeAuthorization:(CLLocationManager *)manager {
    [[NSNotificationCenter defaultCenter] postNotificationName:GLAuthorizationStatusChangedNotification object:self];
    NSLog(@"Location Authorization Changed: %@", self.authorizationStatusAsString);
    if(self.trackingEnabled && (manager.authorizationStatus == kCLAuthorizationStatusAuthorizedAlways || manager.authorizationStatus == kCLAuthorizationStatusAuthorizedWhenInUse)) {
        [self runEngineStandardUpdates];
    }
}

- (void)enableTracking {
    self.trackingEnabled = YES;
    self.engineStationary = NO;
    [[OverlandLocationEngine shared] startBackgroundSession];

    if(self.tripInProgress) {
        self.locationManager.activityType = self.activityTypeDuringTrip;
        self.locationManager.desiredAccuracy = self.desiredAccuracyDuringTrip;
        self.locationManager.showsBackgroundLocationIndicator = self.showBackgroundLocationIndicatorDuringTrip;
        self.locationManager.pausesLocationUpdatesAutomatically = self.pausesAutomaticallyDuringTrip;
    } else {
        self.locationManager.activityType = self.activityType;
        self.locationManager.desiredAccuracy = self.desiredAccuracy;
        self.locationManager.showsBackgroundLocationIndicator = self.showBackgroundLocationIndicator;
        self.locationManager.pausesLocationUpdatesAutomatically = self.pausesAutomatically;
    }

    if(self.tripInProgress) {
        NSLog(@"Monitoring standard location changes during trip");
        [self runEngineStandardUpdates];
        [self.locationManager stopMonitoringSignificantLocationChanges];
    } else {
        switch(self.trackingMode) {
            case kGLTrackingModeOff:
                NSLog(@"Not monitoring continuous location");
                [[OverlandLocationEngine shared] stopLiveUpdates];
                [[OverlandLocationEngine shared] endBackgroundSession];
                [self.locationManager stopUpdatingLocation];
                [self.locationManager stopUpdatingHeading];
                [self.locationManager stopMonitoringSignificantLocationChanges];
                break;
            case kGLTrackingModeStandard:
                NSLog(@"Monitoring standard location changes");
                [self runEngineStandardUpdates];
                [self.locationManager stopMonitoringSignificantLocationChanges];
                break;
            case kGLTrackingModeSignificant:
                NSLog(@"Monitoring significant location changes");
                [self.locationManager startMonitoringSignificantLocationChanges];
                [[OverlandLocationEngine shared] stopLiveUpdates];
                [[OverlandLocationEngine shared] endBackgroundSession];
                [self.locationManager stopUpdatingLocation];
                [self.locationManager stopUpdatingHeading];
                break;
            case kGLTrackingModeStandardAndSignificant:
                NSLog(@"Monitoring both standard and significant location changes");
                [self runEngineStandardUpdates];
                [self.locationManager startMonitoringSignificantLocationChanges];
                break;
        }
    }
    
    if(self.visitTrackingEnabled) {
        [self.locationManager startMonitoringVisits];
    } else {
        [self.locationManager stopMonitoringVisits];
    }
    
    [UIDevice currentDevice].batteryMonitoringEnabled = YES;
    
    if(CMMotionActivityManager.isActivityAvailable) {
        [self.motionActivityManager startActivityUpdatesToQueue:[NSOperationQueue mainQueue] withHandler:^(CMMotionActivity *activity) {
            self.lastMotion = activity;
            [[NSNotificationCenter defaultCenter] postNotificationName:GLNewActivityNotification object:self];
        }];
    }

    NSLog(@"Location Authorization Status %@", self.authorizationStatusAsString);
    
    [self scheduleLocalNotification];
}

- (void)disableTracking {
    self.trackingEnabled = NO;
    self.didPauseByRadius = NO;
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(runEngineStandardUpdates) object:nil];
    for(CLRegion *region in self.locationManager.monitoredRegions) {
        if([region.identifier isEqualToString:@"resume-from-pause"]) [self.locationManager stopMonitoringForRegion:region];
    }
    [self.locationManager stopUpdatingLocation];
    [UIDevice currentDevice].batteryMonitoringEnabled = NO;
    [[OverlandLocationEngine shared] stopLiveUpdates];
    [[OverlandLocationEngine shared] endBackgroundSession];
    [self.locationManager stopMonitoringVisits];
    [self.locationManager stopUpdatingHeading];
    [self.locationManager stopMonitoringSignificantLocationChanges];
    if(CMMotionActivityManager.isActivityAvailable) {
        [self.motionActivityManager stopActivityUpdates];
        self.lastMotion = nil;
    }
    [self cancelLocalNotification];
}

- (void)sendingStarted {
    self.sendInProgress = YES;
    if(self.sendBackgroundTask == UIBackgroundTaskInvalid) {
        __weak typeof(self) weakSelf = self;
        self.sendBackgroundTask = [[UIApplication sharedApplication] beginBackgroundTaskWithName:@"GLSendQueue" expirationHandler:^{
            GLManager *manager = weakSelf;
            if(!manager) return;
            manager.sendGeneration++;
            [manager.sendTask cancel];
            manager.batchInProgress = NO;
            [manager recordSendResult:GLSendStatusNetworkError];
            [manager sendingFinished];
        }];
    }
    [[NSNotificationCenter defaultCenter] postNotificationName:GLSendingStartedNotification object:self];
}

- (void)endSendBackgroundTask {
    if(self.sendBackgroundTask != UIBackgroundTaskInvalid) {
        [[UIApplication sharedApplication] endBackgroundTask:self.sendBackgroundTask];
        self.sendBackgroundTask = UIBackgroundTaskInvalid;
    }
}

- (long)currentPointsInQueue {
    return _currentPointsInQueue;
}

- (void)sendingFinished {
    self.sendInProgress = NO;
    self.sendTask = nil;
    [self endSendBackgroundTask];
    [[NSNotificationCenter defaultCenter] postNotificationName:GLSendingFinishedNotification object:self];
}

#pragma mark - Send results log

- (void)recordSendResult:(GLSendStatus)status {
    if(!self.sendResultsLog) {
        self.sendResultsLog = [NSMutableArray array];
    }
    [self.sendResultsLog addObject:@{@"ts": @(NSDate.date.timeIntervalSince1970),
                                     @"status": @((NSInteger)status)}];
    if(self.sendResultsLog.count > 50) {
        [self.sendResultsLog removeObjectsInRange:NSMakeRange(0, self.sendResultsLog.count - 50)];
    }
}

- (NSArray *)recentSendResults {
    return [self.sendResultsLog copy] ?: @[];
}

- (void)sendQueueIfTimeElapsed {
    BOOL sendingEnabled = [self.sendingInterval integerValue] > -1;
    if(!sendingEnabled) {
        return;
    }

    if(self.sendInProgress) {
        NSLog(@"Send is already in progress");
        return;
    }

    NSDate *lastAttempt = self.lastSendAttempt ?: self.lastSentDate;
    BOOL timeElapsed = !lastAttempt || -lastAttempt.timeIntervalSinceNow >= self.sendingInterval.doubleValue;

    if(timeElapsed || self.batchInProgress) {
        NSLog(@"Sending a batch now");
        [self sendQueueNow];
    }
}

- (void)sendQueueIfNotInProgress {
    if(self.sendInProgress) {
        return;
    }
    
    [self sendQueueNow];
}

#pragma mark - Scheduled local notifications

- (void)scheduleLocalNotification {
    // Receiving a location reschedules this reminder for ten minutes later.

    if(!self.notificationsEnabled || self.stopsAutomaticallyActive) {
        return;
    }
    
    int scheduleRateLimit = 60;
    int reminderIntervalSeconds = 600;
    
    // Limit notification-service requests to one per minute.
    NSDate *lastScheduled = self.lastScheduledNotificationDate;
    if(lastScheduled != nil && [lastScheduled timeIntervalSinceNow] > -1 * scheduleRateLimit) {
        return;
    }
    
    [self cancelLocalNotification];
    
    UNMutableNotificationContent *content = [[UNMutableNotificationContent alloc] init];
    content.title = [NSString localizedUserNotificationStringForKey:@"Overland" arguments:nil];
    content.body = [NSString localizedUserNotificationStringForKey:@"Location updates were stopped. Launch the app to resume."
                arguments:nil];
    content.sound = [UNNotificationSound defaultSound];
    
    UNTimeIntervalNotificationTrigger* trigger = [UNTimeIntervalNotificationTrigger
                triggerWithTimeInterval:reminderIntervalSeconds repeats:NO];
    UNNotificationRequest* request = [UNNotificationRequest requestWithIdentifier:@"reminder"
                content:content trigger:trigger];
     
    UNUserNotificationCenter* center = [UNUserNotificationCenter currentNotificationCenter];
    dispatch_async(GLNotificationQueue(), ^{
        [center addNotificationRequest:request withCompletionHandler:^(NSError *error) {
            if(!error) self.lastScheduledNotificationDate = NSDate.now;
        }];
    });
}

- (void)cancelLocalNotification {
    UNUserNotificationCenter* center = [UNUserNotificationCenter currentNotificationCenter];
    dispatch_async(GLNotificationQueue(), ^{
        [center removePendingNotificationRequestsWithIdentifiers:@[@"reminder"]];
    });
}

- (NSDate *)lastScheduledNotificationDate {
    if([self defaultsKeyExists:GLLastScheduledNotificationDateDefaultsName]) {
        return (NSDate *)[[NSUserDefaults standardUserDefaults] objectForKey:GLLastScheduledNotificationDateDefaultsName];
    } else {
        return nil;
    }
}
- (void)setLastScheduledNotificationDate:(NSDate *)date {
    [[NSUserDefaults standardUserDefaults] setObject:date forKey:GLLastScheduledNotificationDateDefaultsName];
}


#pragma mark - Trips

+ (NSArray *)GLTripModes {
    if(!_tripModes) {
        _tripModes = @[GLTripModeWalk, GLTripModeRun, GLTripModeBicycle,
                       GLTripModeCar, GLTripModeTaxi, GLTripModeBus,
                       GLTripModeTram, GLTripModeTrain, GLTripModeMetro,
                       GLTripModeGondola, GLTripModeMonorail, GLTripModeSleigh,
                       GLTripModePlane, GLTripModeBoat, GLTripModeScooter];
        }
    return _tripModes;
}

- (BOOL)tripInProgress {
    return [[NSUserDefaults standardUserDefaults] objectForKey:GLTripStartTimeDefaultsName] != nil;
}

- (NSString *)currentTripMode {
    NSString *mode = [[NSUserDefaults standardUserDefaults] stringForKey:GLTripModeDefaultsName];
    if(!mode) {
        mode = @"bicycle";
    }
    return mode;
}

- (void)setCurrentTripMode:(NSString *)mode {
    [[NSUserDefaults standardUserDefaults] setObject:mode forKey:GLTripModeDefaultsName];
}

- (NSDate *)currentTripStart {
    if(!self.tripInProgress) {
        return nil;
    }
    return (NSDate *)[[NSUserDefaults standardUserDefaults] objectForKey:GLTripStartTimeDefaultsName];
}

- (NSTimeInterval)currentTripDuration {
    if(!self.tripInProgress) {
        return -1;
    }
    
    NSDate *startDate = self.currentTripStart;
    return [startDate timeIntervalSinceNow] * -1.0;
}

- (CLLocationDistance)currentTripDistance {
    if(!self.tripInProgress) {
        return -1;
    }
    
    if(!_currentTripHasNewData) {
        return _currentTripDistanceCached;
    }

    CLLocationDistance distance = 0;
    CLLocation *lastLocation;
    CLLocation *loc;
    
    FMResultSet *s = [self.tripdb executeQuery:@"SELECT latitude, longitude FROM trips ORDER BY timestamp"];
    while([s next]) {
        loc = [[CLLocation alloc] initWithLatitude:[s doubleForColumnIndex:0] longitude:[s doubleForColumnIndex:1]];
        
        if(lastLocation) {
            distance += [lastLocation distanceFromLocation:loc];
        }
        
        lastLocation = loc;
    }

    [s close];
    _currentTripDistanceCached = distance;
    _currentTripHasNewData = NO;
    return distance;
}

- (NSArray *)currentTripPoints {
    NSMutableArray *points = [NSMutableArray array];
    if(!self.tripInProgress || !self.tripdb || !self.tripdb.isOpen) {
        return points;
    }

    FMResultSet *s = [self.tripdb executeQuery:@"SELECT id, timestamp, latitude, longitude FROM (SELECT id, timestamp, latitude, longitude FROM trips ORDER BY id DESC LIMIT 1000) ORDER BY id"];
    while([s next]) {
        [points addObject:@{
            @"id": @([s longLongIntForColumnIndex:0]),
            @"timestamp": @([s doubleForColumnIndex:1]),
            @"latitude": @([s doubleForColumnIndex:2]),
            @"longitude": @([s doubleForColumnIndex:3]),
        }];
    }
    [s close];
    return points;
}

- (NSDictionary *)currentTripStartLocationDictionary {
    if(!self.tripInProgress) {
        self.tripStartLocationDictionary = nil;
        return nil;
    }
    if(self.tripStartLocationDictionary == nil) {
        NSDictionary *startLocation = (NSDictionary *)[[NSUserDefaults standardUserDefaults] objectForKey:GLTripStartLocationDefaultsName];
        self.tripStartLocationDictionary = startLocation;
    }
    return self.tripStartLocationDictionary;
}

- (NSDictionary *)currentTripDictionary {
    return @{
            @"mode": self.currentTripMode,
            @"start": [GLManager iso8601DateStringFromDate:self.currentTripStart],
            @"distance": [NSNumber numberWithDouble:self.currentTripDistance],
            @"start_location": (self.currentTripStartLocationDictionary ?: [NSNull null]),
            @"current_location": (self.lastLocationDictionary ?: [NSNull null]),
    };
}

- (void)startTrip {
    if(self.tripInProgress) {
        return;
    }
    
    [self sendQueueNow];

    if(![self.tripdb open]) return;
    [self clearTripDB];
    [[NSUserDefaults standardUserDefaults] setBool:self.trackingEnabled forKey:GLTripTrackingEnabledDefaultsName];
    _currentTripDistanceCached = 0;
    _currentTripHasNewData = NO;
    
    NSDate *startDate = [NSDate date];
    [[NSUserDefaults standardUserDefaults] setObject:startDate forKey:GLTripStartTimeDefaultsName];
    
    _storeNextLocationAsTripStart = YES;
    NSLog(@"Store next location as trip start. Current trip start: %@", self.tripStartLocationDictionary);

    [self startAllUpdates];
    [UIApplication sharedApplication].idleTimerDisabled = [[NSUserDefaults standardUserDefaults] boolForKey:GLScreenLockEnabledDefaultsName];

    NSLog(@"Started a trip at %@", startDate);
    
    [self incrementTripMode:self.currentTripMode];
}

- (void)endTrip {
    [self endTripFromAutopause:NO];
}

- (void)endTripFromAutopause:(BOOL)autopause {
    if(!self.tripInProgress || self.endingTrip) return;
    self.endingTrip = YES;
    _storeNextLocationAsTripStart = NO;
    if([CMPedometer isStepCountingAvailable]) {
        [self.pedometer queryPedometerDataFromDate:self.currentTripStart toDate:NSDate.date withHandler:^(CMPedometerData *data, NSError *error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self writeTripToDB:autopause steps:data.numberOfSteps.integerValue];
            });
        }];
    } else {
        [self writeTripToDB:autopause steps:0];
    }
}

- (void)incrementTripMode:(NSString *)tripMode {
    NSMutableDictionary *currentStats = [[[NSUserDefaults standardUserDefaults] dictionaryForKey:GLTripModeStatsDefaultsName] mutableCopy];
    if(currentStats == nil) {
        currentStats = [[NSMutableDictionary alloc] init];
    }
    NSNumber *count = [currentStats valueForKey:tripMode];
    NSNumber *newCount;
    if(count != nil) {
        newCount = [NSNumber numberWithInt:[count intValue] + 1];
    } else {
        newCount = @1;
    }
    [currentStats setValue:newCount forKey:tripMode];
    [[NSUserDefaults standardUserDefaults] setValue:currentStats forKey:GLTripModeStatsDefaultsName];
}

- (NSArray *)tripModesByFrequency {
    NSDictionary *currentStats = [[NSUserDefaults standardUserDefaults] dictionaryForKey:GLTripModeStatsDefaultsName];
    NSArray *tripModes = [currentStats keysSortedByValueUsingComparator:^NSComparisonResult(id  _Nonnull obj1, id  _Nonnull obj2) {
        return [(NSNumber*)obj2 compare:(NSNumber*)obj1];
    }];
    return tripModes;
}

- (void)writeTripToDB:(BOOL)autopause steps:(NSInteger)numberOfSteps {

    if(!self.tripInProgress) { self.endingTrip = NO; return; }
    [self.db accessCollection:GLLocationQueueName withBlock:^(id<LOLDatabaseAccessor> accessor) {
        NSString *timestamp = [GLManager iso8601DateStringFromDate:[NSDate date]];
        NSDictionary *currentTrip = @{
                                      @"type": @"Feature",
                                      @"geometry": self.lastLocation ? @{
                                              @"type": @"Point",
                                              @"coordinates": @[@(self.lastLocation.coordinate.longitude), @(self.lastLocation.coordinate.latitude)]
                                              } : (id)[NSNull null],
                                      @"properties": [NSMutableDictionary dictionaryWithDictionary:@{
                                              @"timestamp": timestamp,
                                              @"type": @"trip",
                                              @"mode": self.currentTripMode,
                                              @"start": [GLManager iso8601DateStringFromDate:self.currentTripStart],
                                              @"end": timestamp,
                                              @"start_location": (self.tripStartLocationDictionary ?: [NSNull null]),
                                              @"end_location":(self.lastLocationDictionary ?: [NSNull null]),
                                              @"duration": [NSNumber numberWithDouble:self.currentTripDuration],
                                              @"distance": [NSNumber numberWithDouble:self.currentTripDistance],
                                              @"stopped_automatically": @(autopause),
                                              @"steps": [NSNumber numberWithInteger:numberOfSteps],
                                              }]
                                      };
        [self addMetadataToUpdate:currentTrip];
        if(autopause) {
            [self notify:@"Trip ended automatically" withTitle:@"Tracker"];
        }
        [accessor setDictionary:currentTrip forKey:[NSString stringWithFormat:@"%@-trip-%@", timestamp, NSUUID.UUID.UUIDString]];
    }];

    self.tripStartLocationDictionary = nil;
    [[NSUserDefaults standardUserDefaults] setObject:nil forKey:GLTripStartTimeDefaultsName];
    [[NSUserDefaults standardUserDefaults] setObject:nil forKey:GLTripStartLocationDefaultsName];

    _currentTripDistanceCached = 0;
    [self clearTripDB];
    [self.tripdb close];
    
    [[NSUserDefaults standardUserDefaults] removeObjectForKey:GLTripStartTimeDefaultsName];
    self.endingTrip = NO;
    [UIApplication sharedApplication].idleTimerDisabled = NO;
    if(self.trackingEnabled) {
        if([[NSUserDefaults standardUserDefaults] boolForKey:GLTripTrackingEnabledDefaultsName]) [self enableTracking];
        else [self stopAllUpdates];
    }
    [self numberOfLocationsInQueue:^(long num) {}];
    [[NSNotificationCenter defaultCenter] postNotificationName:GLNewDataNotification object:self];
    [self sendQueueNow];
    NSLog(@"Ended a %@ trip", self.currentTripMode);
}

#pragma mark - Properties

- (CLLocationManager *)locationManager {
    if (!_locationManager) {
        _locationManager = [[CLLocationManager alloc] init];
        _locationManager.delegate = self;
        _locationManager.distanceFilter = kCLDistanceFilterNone;
        _locationManager.allowsBackgroundLocationUpdates = YES;
        if(self.tripInProgress) {
            _locationManager.pausesLocationUpdatesAutomatically = self.pausesAutomaticallyDuringTrip;
            _locationManager.desiredAccuracy = self.desiredAccuracyDuringTrip;
            _locationManager.activityType = self.activityTypeDuringTrip;
        } else {
            _locationManager.pausesLocationUpdatesAutomatically = self.pausesAutomatically;
            _locationManager.desiredAccuracy = self.desiredAccuracy;
            _locationManager.activityType = self.activityType;
        }
    }
    
    return _locationManager;
}

- (CMMotionActivityManager *)motionActivityManager {
    if (!_motionActivityManager) {
        _motionActivityManager = [[CMMotionActivityManager alloc] init];
    }
    
    return _motionActivityManager;
}

- (NSString *)currentBatteryState {
    switch([UIDevice currentDevice].batteryState) {
        case UIDeviceBatteryStateUnknown:
            return @"unknown";
        case UIDeviceBatteryStateCharging:
            return @"charging";
        case UIDeviceBatteryStateFull:
            return @"full";
        case UIDeviceBatteryStateUnplugged:
            return @"unplugged";
    }
}

- (NSNumber *)currentBatteryLevel {
    return [NSNumber numberWithDouble:((int)([UIDevice currentDevice].batteryLevel * 100)) / 100.0];
}

- (NSString *)authorizationStatusAsString {
    if (@available(iOS 14.0, *)) {
        switch(self.locationManager.authorizationStatus) {
            case kCLAuthorizationStatusNotDetermined:
                return @"Not Determined";
            case kCLAuthorizationStatusRestricted:
                return @"Restricted";
            case kCLAuthorizationStatusDenied:
                return @"Denied";
            case kCLAuthorizationStatusAuthorizedWhenInUse:
                return @"When in Use";
            case kCLAuthorizationStatusAuthorizedAlways:
                return @"Always";
        }
    } else {
        return @"Unknown";
    }
}

- (BOOL)shouldConsiderHTTP200Success {
    NSUserDefaults *standardUserDefaults = [NSUserDefaults standardUserDefaults];
    return [standardUserDefaults boolForKey:GLConsiderHTTP200SuccessDefaultsName];
}

- (CLLocationDistance)resumesAfterDistance {
    if([self defaultsKeyExists:GLResumesAutomaticallyDefaultsName]) {
        return [[NSUserDefaults standardUserDefaults] doubleForKey:GLResumesAutomaticallyDefaultsName];
    } else {
        return -1;
    }
}
- (void)setResumesAfterDistance:(CLLocationDistance)resumesAfterDistance {
    [[NSUserDefaults standardUserDefaults] setDouble:resumesAfterDistance forKey:GLResumesAutomaticallyDefaultsName];
}

- (CLLocationDistance)discardPointsWithinDistance {
    if([self defaultsKeyExists:GLDiscardPointsWithinDistanceDefaultsName]) {
        return [[NSUserDefaults standardUserDefaults] doubleForKey:GLDiscardPointsWithinDistanceDefaultsName];
    } else {
        return -1;
    }
}
- (void)setDiscardPointsWithinDistance:(CLLocationDistance)distance {
    [[NSUserDefaults standardUserDefaults] setDouble:distance forKey:GLDiscardPointsWithinDistanceDefaultsName];
}

- (CLLocationAccuracy)discardPointsOutsideAccuracy {
    if([self defaultsKeyExists:GLDiscardPointsOutsideAccuracyDefaultsName]) {
        return [[NSUserDefaults standardUserDefaults] doubleForKey:GLDiscardPointsOutsideAccuracyDefaultsName];
    } else {
        return -1;
    }
}
- (void)setDiscardPointsOutsideAccuracy:(CLLocationAccuracy)distance {
    [[NSUserDefaults standardUserDefaults] setDouble:distance forKey:GLDiscardPointsOutsideAccuracyDefaultsName];
}

- (CLLocationDistance)discardPointsWithinDistanceDuringTrip {
    if([self defaultsKeyExists:GLTripDiscardPointsWithinDistanceDefaultsName]) {
        return [[NSUserDefaults standardUserDefaults] doubleForKey:GLTripDiscardPointsWithinDistanceDefaultsName];
    } else {
        return -1;
    }
}
- (void)setDiscardPointsWithinDistanceDuringTrip:(CLLocationDistance)distance {
    [[NSUserDefaults standardUserDefaults] setDouble:distance forKey:GLTripDiscardPointsWithinDistanceDefaultsName];
}

- (CLLocationDistance)discardPointsWithinDistanceCurrentValue {
    if(self.tripInProgress) {
        return self.discardPointsWithinDistanceDuringTrip;
    } else {
        return self.discardPointsWithinDistance;
    }
}

- (int)discardPointsWithinSeconds {
    if([self defaultsKeyExists:GLDiscardPointsWithinSecondsDefaultsName]) {
        return (int)[[NSUserDefaults standardUserDefaults] integerForKey:GLDiscardPointsWithinSecondsDefaultsName];
    } else {
        return 1;
    }
}
- (void)setDiscardPointsWithinSeconds:(int)seconds {
    [[NSUserDefaults standardUserDefaults] setInteger:seconds forKey:GLDiscardPointsWithinSecondsDefaultsName];
}

- (int)discardPointsWithinSecondsDuringTrip {
    if([self defaultsKeyExists:GLTripDiscardPointsWithinSecondsDefaultsName]) {
        return (int)[[NSUserDefaults standardUserDefaults] integerForKey:GLTripDiscardPointsWithinSecondsDefaultsName];
    } else {
        return 1;
    }
}
- (void)setDiscardPointsWithinSecondsDuringTrip:(int)seconds {
    [[NSUserDefaults standardUserDefaults] setInteger:seconds forKey:GLTripDiscardPointsWithinSecondsDefaultsName];
}

- (int)discardPointsWithinSecondsCurrentValue {
    if(self.tripInProgress) {
        return self.discardPointsWithinSecondsDuringTrip;
    } else {
        return self.discardPointsWithinSeconds;
    }
}

- (CLLocationDistance)stopsAutomaticallyRadius {
    if([self defaultsKeyExists:GLStopsAutomaticallyDefaultsName]) {
        return [[NSUserDefaults standardUserDefaults] doubleForKey:GLStopsAutomaticallyDefaultsName];
    } else {
        return -1;
    }
}
- (void)setStopsAutomaticallyRadius:(CLLocationDistance)distance {
    [[NSUserDefaults standardUserDefaults] setDouble:distance forKey:GLStopsAutomaticallyDefaultsName];
}

- (BOOL)stopsAutomaticallyActive {
    return self.trackingMode == kGLTrackingModeStandardAndSignificant
        && self.stopsAutomaticallyRadius != -1
        && !self.pausesAutomatically;
}

- (int)stopsAutomaticallyAfterSeconds {
    if([self defaultsKeyExists:GLStopsAutomaticallyAfterDefaultsName]) {
        return (int)[[NSUserDefaults standardUserDefaults] integerForKey:GLStopsAutomaticallyAfterDefaultsName];
    } else {
        return 60;
    }
}
- (void)setStopsAutomaticallyAfterSeconds:(int)seconds {
    [[NSUserDefaults standardUserDefaults] setInteger:seconds forKey:GLStopsAutomaticallyAfterDefaultsName];
}

- (BOOL)didPauseByRadius {
    return [[NSUserDefaults standardUserDefaults] boolForKey:GLDidPauseByRadiusDefaultsName];
}

- (void)setDidPauseByRadius:(BOOL)didPause {
    [[NSUserDefaults standardUserDefaults] setBool:didPause forKey:GLDidPauseByRadiusDefaultsName];
}


#pragma mark CLLocationManager

- (NSSet *)monitoredRegions {
    return self.locationManager.monitoredRegions;
}

- (BOOL)pausesAutomatically {
    if([self defaultsKeyExists:GLPausesAutomaticallyDefaultsName]) {
        return [[NSUserDefaults standardUserDefaults] boolForKey:GLPausesAutomaticallyDefaultsName];
    } else {
        return NO;
    }
}
- (void)setPausesAutomatically:(BOOL)pausesAutomatically {
    BOOL prevValue = self.pausesAutomatically;
    if(prevValue != pausesAutomatically) {
        [[NSUserDefaults standardUserDefaults] setBool:pausesAutomatically forKey:GLPausesAutomaticallyDefaultsName];
        if(!self.tripInProgress) {
            NSLog(@"Setting pausesLocationUpdatesAutomatically %d", pausesAutomatically);
            self.locationManager.pausesLocationUpdatesAutomatically = pausesAutomatically;
            [self runEngineStandardUpdates];
        }
    }
}

- (BOOL)pausesAutomaticallyDuringTrip {
    if([self defaultsKeyExists:GLTripPausesAutomaticallyDefaultsName]) {
        return [[NSUserDefaults standardUserDefaults] boolForKey:GLTripPausesAutomaticallyDefaultsName];
    } else {
        return NO;
    }
}
- (void)setPausesAutomaticallyDuringTrip:(BOOL)pausesAutomatically {
    BOOL prevValue = self.pausesAutomaticallyDuringTrip;
    if(prevValue != pausesAutomatically) {
        [[NSUserDefaults standardUserDefaults] setBool:pausesAutomatically forKey:GLTripPausesAutomaticallyDefaultsName];
        if(self.tripInProgress) {
            NSLog(@"Setting pausesLocationUpdatesAutomatically while trip is in progress %d", pausesAutomatically);
            self.locationManager.pausesLocationUpdatesAutomatically = pausesAutomatically;
            [self runEngineStandardUpdates];
        }
    }
}

- (BOOL)includeTrackingStats {
    if([self defaultsKeyExists:GLIncludeTrackingStatsDefaultsName]) {
        return [[NSUserDefaults standardUserDefaults] boolForKey:GLIncludeTrackingStatsDefaultsName];
    } else {
        return NO;
    }
}
- (void)setIncludeTrackingStats:(BOOL)enabled {
    [[NSUserDefaults standardUserDefaults] setBool:enabled forKey:GLIncludeTrackingStatsDefaultsName];
}

- (GLTrackingMode)trackingMode {
    if([self defaultsKeyExists:GLSignificantLocationModeDefaultsName]) {
        return (int)[[NSUserDefaults standardUserDefaults] integerForKey:GLSignificantLocationModeDefaultsName];
    } else {
        return kGLTrackingModeStandard;
    }
}
- (void)setTrackingMode:(GLTrackingMode)trackingMode {
    GLTrackingMode previousTrackingMode = self.trackingMode;
    if(previousTrackingMode != trackingMode) {
        [[NSUserDefaults standardUserDefaults] setInteger:trackingMode forKey:GLSignificantLocationModeDefaultsName];
        if(self.trackingEnabled) [self enableTracking];
    }
}

- (BOOL)visitTrackingEnabled {
    if([self defaultsKeyExists:GLVisitTrackingEnabledDefaultsName]) {
        return [[NSUserDefaults standardUserDefaults] boolForKey:GLVisitTrackingEnabledDefaultsName];
    } else {
        return NO;
    }
}
- (void)setVisitTrackingEnabled:(BOOL)enabled {
    BOOL previousEnabled = self.visitTrackingEnabled;
    if(previousEnabled != enabled) {
        [[NSUserDefaults standardUserDefaults] setBool:enabled forKey:GLVisitTrackingEnabledDefaultsName];
        if(self.trackingEnabled) [self enableTracking];
    }
}

- (GLLoggingMode)loggingMode {
    if([self defaultsKeyExists:GLLoggingModeDefaultsName]) {
        return (int)[[NSUserDefaults standardUserDefaults] integerForKey:GLLoggingModeDefaultsName];
    } else {
        return kGLLoggingModeAllData;
    }
}
- (void)setLoggingMode:(GLLoggingMode)loggingMode {
    GLLoggingMode previousLoggingMode = self.loggingMode;
    if(previousLoggingMode != loggingMode) {
        [[NSUserDefaults standardUserDefaults] setInteger:loggingMode forKey:GLLoggingModeDefaultsName];
        [self setupHTTPClient];
    }
}

- (GLLoggingMode)loggingModeDuringTrip {
    if([self defaultsKeyExists:GLTripLoggingModeDefaultsName]) {
        return (int)[[NSUserDefaults standardUserDefaults] integerForKey:GLTripLoggingModeDefaultsName];
    } else {
        return kGLLoggingModeAllData;
    }
}
- (void)setLoggingModeDuringTrip:(GLLoggingMode)loggingMode {
    [[NSUserDefaults standardUserDefaults] setInteger:loggingMode forKey:GLTripLoggingModeDefaultsName];
}

- (GLLoggingMode)loggingModeCurrentValue {
    if(self.tripInProgress) {
        return self.loggingModeDuringTrip;
    } else {
        return self.loggingMode;
    }
}

- (BOOL)showBackgroundLocationIndicator {
    if([self defaultsKeyExists:GLBackgroundIndicatorDefaultsName]) {
        return [[NSUserDefaults standardUserDefaults] boolForKey:GLBackgroundIndicatorDefaultsName];
    } else {
        return NO;
    }
}
- (void)setShowBackgroundLocationIndicator:(BOOL)mode {
    BOOL previousMode = self.showBackgroundLocationIndicator;
    if(previousMode != mode) {
        [[NSUserDefaults standardUserDefaults] setBool:mode forKey:GLBackgroundIndicatorDefaultsName];
        if(self.trackingEnabled && !self.tripInProgress) {
            self.locationManager.showsBackgroundLocationIndicator = mode;
        }
    }
}

- (BOOL)showBackgroundLocationIndicatorDuringTrip {
    if([self defaultsKeyExists:GLTripBackgroundIndicatorDefaultsName]) {
        return [[NSUserDefaults standardUserDefaults] boolForKey:GLTripBackgroundIndicatorDefaultsName];
    } else {
        return YES;
    }
}
- (void)setShowBackgroundLocationIndicatorDuringTrip:(BOOL)mode {
    BOOL previousMode = self.showBackgroundLocationIndicatorDuringTrip;
    if(previousMode != mode) {
        [[NSUserDefaults standardUserDefaults] setBool:mode forKey:GLTripBackgroundIndicatorDefaultsName];
        if(self.tripInProgress) {
            self.locationManager.showsBackgroundLocationIndicator = mode;
        }
    }
}

- (CLActivityType)activityType {
    if([self defaultsKeyExists:GLActivityTypeDefaultsName]) {
        // Map back to CLActivityType constants
        long activityInt = [[NSUserDefaults standardUserDefaults] integerForKey:GLActivityTypeDefaultsName];
        CLActivityType activityType;
        switch(activityInt) {
            case 1:
                activityType = CLActivityTypeOther;
                break;
            case 2:
                activityType = CLActivityTypeAutomotiveNavigation;
                break;
            case 3:
                activityType = CLActivityTypeFitness;
                break;
            case 4:
                activityType = CLActivityTypeOtherNavigation;
                break;
            case 5:
                if (@available(iOS 12.0, *)) {
                    activityType = CLActivityTypeAirborne;
                } else {
                    activityType = CLActivityTypeOther;
                }
                break;
            default:
                activityType = CLActivityTypeOther;
                break;
        }
        return activityType;
    } else {
        return CLActivityTypeOther;
    }
}
- (void)setActivityType:(CLActivityType)activityType {
    // Store these as integers, in the same order as the UI control
    int activityInt;
    switch(activityType) {
        case CLActivityTypeOther:
            activityInt = 1;
            break;
        case CLActivityTypeAutomotiveNavigation:
            activityInt = 2;
            break;
        case CLActivityTypeFitness:
            activityInt = 3;
            break;
        case CLActivityTypeOtherNavigation:
            activityInt = 4;
            break;
        case CLActivityTypeAirborne:
            if (@available(iOS 12.0, *)) {
                activityInt = 5;
            } else {
                activityInt = 1;
            }
            break;
        default:
            activityInt = 1;
            break;
    }
    [[NSUserDefaults standardUserDefaults] setInteger:activityInt forKey:GLActivityTypeDefaultsName];
    if(!self.tripInProgress) [self runEngineStandardUpdates];
}

- (CLActivityType)activityTypeDuringTrip {
    if([self defaultsKeyExists:GLTripActivityTypeDefaultsName]) {
        // Map back to CLActivityType constants
        long activityInt = [[NSUserDefaults standardUserDefaults] integerForKey:GLTripActivityTypeDefaultsName];
        CLActivityType activityType;
        switch(activityInt) {
            case 1:
                activityType = CLActivityTypeOther;
                break;
            case 2:
                activityType = CLActivityTypeAutomotiveNavigation;
                break;
            case 3:
                activityType = CLActivityTypeFitness;
                break;
            case 4:
                activityType = CLActivityTypeOtherNavigation;
                break;
            case 5:
                if (@available(iOS 12.0, *)) {
                    activityType = CLActivityTypeAirborne;
                } else {
                    activityType = CLActivityTypeOther;
                }
                break;
            default:
                activityType = CLActivityTypeOther;
                break;
        }
        return activityType;
    } else {
        return CLActivityTypeOther;
    }
}
- (void)setActivityTypeDuringTrip:(CLActivityType)activityType {
    // Store these as integers, in the same order as the UI control
    int activityInt;
    switch(activityType) {
        case CLActivityTypeOther:
            activityInt = 1;
            break;
        case CLActivityTypeAutomotiveNavigation:
            activityInt = 2;
            break;
        case CLActivityTypeFitness:
            activityInt = 3;
            break;
        case CLActivityTypeOtherNavigation:
            activityInt = 4;
            break;
        case CLActivityTypeAirborne:
            if (@available(iOS 12.0, *)) {
                activityInt = 5;
            } else {
                activityInt = 1;
            }
            break;
        default:
            activityInt = 1;
            break;
    }
    [[NSUserDefaults standardUserDefaults] setInteger:activityInt forKey:GLTripActivityTypeDefaultsName];
    if(self.tripInProgress) [self runEngineStandardUpdates];
}

- (CLLocationAccuracy)desiredAccuracy {
    if([self defaultsKeyExists:GLDesiredAccuracyDefaultsName]) {
        return [[NSUserDefaults standardUserDefaults] doubleForKey:GLDesiredAccuracyDefaultsName];
    } else {
        return kCLLocationAccuracyHundredMeters;
    }
}
- (void)setDesiredAccuracy:(CLLocationAccuracy)desiredAccuracy {
    [[NSUserDefaults standardUserDefaults] setDouble:desiredAccuracy forKey:GLDesiredAccuracyDefaultsName];
    if(!self.tripInProgress) {
        self.locationManager.desiredAccuracy = desiredAccuracy;
        [self runEngineStandardUpdates];
    }
}

- (CLLocationAccuracy)desiredAccuracyDuringTrip {
    if([self defaultsKeyExists:GLTripDesiredAccuracyDefaultsName]) {
        return [[NSUserDefaults standardUserDefaults] doubleForKey:GLTripDesiredAccuracyDefaultsName];
    } else {
        return kCLLocationAccuracyHundredMeters;
    }
}
- (void)setDesiredAccuracyDuringTrip:(CLLocationAccuracy)desiredAccuracy {
    [[NSUserDefaults standardUserDefaults] setDouble:desiredAccuracy forKey:GLTripDesiredAccuracyDefaultsName];
    if(self.tripInProgress) {
        self.locationManager.desiredAccuracy = desiredAccuracy;
        [self runEngineStandardUpdates];
    }
}

- (int)pointsPerBatch {
    if([self defaultsKeyExists:GLPointsPerBatchDefaultsName]) {
        return (int)[[NSUserDefaults standardUserDefaults] integerForKey:GLPointsPerBatchDefaultsName];
    } else {
        return 200;
    }
}
- (void)setPointsPerBatch:(int)points {
    [[NSUserDefaults standardUserDefaults] setInteger:MAX(1, points) forKey:GLPointsPerBatchDefaultsName];
}

- (int)pointsPerBatchDuringTrip {
    if([self defaultsKeyExists:GLTripPointsPerBatchDefaultsName]) {
        return (int)[[NSUserDefaults standardUserDefaults] integerForKey:GLTripPointsPerBatchDefaultsName];
    } else {
        return 200;
    }
}
- (void)setPointsPerBatchDuringTrip:(int)points {
    [[NSUserDefaults standardUserDefaults] setInteger:MAX(1, points) forKey:GLTripPointsPerBatchDefaultsName];
}

- (int)pointsPerBatchCurrentValue {
    if(self.tripInProgress) {
        return self.pointsPerBatchDuringTrip;
    } else {
        return self.pointsPerBatch;
    }
}

#pragma mark GLManager

- (NSNumber *)sendingInterval {
    if(_sendingInterval)
        return _sendingInterval;
    
    _sendingInterval = (NSNumber *)[[NSUserDefaults standardUserDefaults] valueForKey:GLSendIntervalDefaultsName];
    if(_sendingInterval == nil) {
        _sendingInterval = [NSNumber numberWithInteger:300];
    }
    return _sendingInterval;
}

- (void)setSendingInterval:(NSNumber *)newValue {
    [[NSUserDefaults standardUserDefaults] setValue:newValue forKey:GLSendIntervalDefaultsName];
    _sendingInterval = newValue;
}

- (NSDate *)lastSentDate {
    return (NSDate *)[[NSUserDefaults standardUserDefaults] objectForKey:GLLastSentDateDefaultsName];
}

- (void)setLastSentDate:(NSDate *)lastSentDate {
    [[NSUserDefaults standardUserDefaults] setObject:lastSentDate forKey:GLLastSentDateDefaultsName];
}

#pragma mark - CLLocationManager Delegate Methods

- (void)locationManager:(CLLocationManager *)manager didVisit:(CLVisit *)visit {

    if(!self.trackingEnabled) return;
    if(self.visitTrackingEnabled) {
        [[NSNotificationCenter defaultCenter] postNotificationName:GLNewDataNotification object:self];
        [self.db accessCollection:GLLocationQueueName withBlock:^(id<LOLDatabaseAccessor> accessor) {
            NSString *timestamp = [GLManager iso8601DateStringFromDate:[NSDate date]];
            NSDictionary *update = @{
                                      @"type": @"Feature",
                                      @"geometry": @{
                                              @"type": @"Point",
                                              @"coordinates": @[
                                                      [NSNumber numberWithDouble:visit.coordinate.longitude],
                                                      [NSNumber numberWithDouble:visit.coordinate.latitude]
                                                      ]
                                              },
                                      @"properties": [NSMutableDictionary dictionaryWithDictionary:@{
                                              @"timestamp": timestamp,
                                              @"action": @"visit",
                                              @"arrival_date": ([visit.arrivalDate isEqualToDate:[NSDate distantPast]] ? [NSNull null] : [GLManager iso8601DateStringFromDate:visit.arrivalDate]),
                                              @"departure_date": ([visit.departureDate isEqualToDate:[NSDate distantFuture]] ? [NSNull null] : [GLManager iso8601DateStringFromDate:visit.departureDate]),
                                              @"horizontal_accuracy": [NSNumber numberWithInt:visit.horizontalAccuracy],
                                              }]
                                    };
            [self addMetadataToUpdate:update];
            [accessor setDictionary:update forKey:[NSString stringWithFormat:@"%@-visit-%@", timestamp, NSUUID.UUID.UUIDString]];
        }];

    }
    
    // If a trip is active, ask if they would like to end the trip
    if(self.tripInProgress) {
        [self askToEndTrip];
    }
    
    [self sendQueueIfTimeElapsed];
}

- (void)deleteAllData {
    [self.db accessCollection:GLLocationQueueName withBlock:^(id<LOLDatabaseAccessor> accessor) {
        [accessor deleteAllData];
    }];
    [self numberOfLocationsInQueue:^(long num) {}];
    [[NSNotificationCenter defaultCenter] postNotificationName:GLNewDataNotification object:self];
}

- (void)locationManager:(CLLocationManager *)manager didUpdateLocations:(NSArray *)locations {
    [self processLocations:locations];
}

- (void)processLocations:(NSArray *)locations {

    if(!self.trackingEnabled || locations.count == 0 || (!self.tripInProgress && self.trackingMode == kGLTrackingModeOff)) {
        return;
    }

    if(self.didPauseByRadius) {
        self.didPauseByRadius = NO;
        self.lastLocationMovedBeyondStopThreshold = nil;
        self.lastTimeMovedBeyondStopThreshold = nil;
        NSLog(@"Continuing loc updates");
        [self notify:@"Location updates resumed." withTitle:@"Resumed"];
    }

    // Significant-change events restart standard updates after a stationary stop.
    if (!self.tripInProgress && self.trackingMode == kGLTrackingModeStandardAndSignificant) {
        [self runEngineStandardUpdates];
        [self.locationManager startMonitoringSignificantLocationChanges];
    }
        
    // A matching WiFi zone replaces the delivered fixes with its saved coordinates.
    if([GLManager currentWifiHotSpotName]) {
        NSDictionary *wifiInfo = [GLManager currentWifiNetworkInfo];
        CLLocation *wifiLocation = [self currentLocationFromWifiName:wifiInfo[@"SSID"] bssid:wifiInfo[@"BSSID"]];
        if(wifiLocation) {
            locations = @[wifiLocation];
        }
    }
    
    
    NSString *activityType = @"";
    switch(self.tripInProgress ? self.activityTypeDuringTrip : self.activityType) {
        case CLActivityTypeOther:
            activityType = @"other";
            break;
        case CLActivityTypeAutomotiveNavigation:
            activityType = @"automotive_navigation";
            break;
        case CLActivityTypeFitness:
            activityType = @"fitness";
            break;
        case CLActivityTypeOtherNavigation:
            activityType = @"other_navigation";
            break;
        case CLActivityTypeAirborne:
            activityType = @"airborne";
    }
    
    CLLocation *lastLocationSeen = self.lastLocation; // Grab the last known location from the previous batch
    
    int startIndex = 0;
    if(self.loggingModeCurrentValue == kGLLoggingModeOnlyLatest || self.loggingModeCurrentValue == kGLLoggingModeOwntracks) {
        // Only grab the latest point in this batch
        startIndex = ((int)locations.count) - 1;
    }
    
    BOOL didAddData = NO;
    
    for(int i=startIndex; i<locations.count; i++) {
        CLLocation *loc = locations[i];
        if(loc.horizontalAccuracy < 0 || !CLLocationCoordinate2DIsValid(loc.coordinate)) continue;
        if(lastLocationSeen && [loc.timestamp compare:lastLocationSeen.timestamp] == NSOrderedAscending) continue;

        // If Discard is enabled, check if this point is too close to the previous
        if(lastLocationSeen && self.discardPointsWithinDistanceCurrentValue > 0) {
            CLLocationDistance distanceBetweenPoints = [lastLocationSeen distanceFromLocation:loc];
            if(distanceBetweenPoints < self.discardPointsWithinDistanceCurrentValue) {
                continue;
            }
        }

        if(lastLocationSeen && self.discardPointsWithinSecondsCurrentValue > 0) {
            NSTimeInterval timeInterval = [loc.timestamp timeIntervalSinceDate:lastLocationSeen.timestamp];
            if(timeInterval < self.discardPointsWithinSecondsCurrentValue) {
                continue;
            }
        }
        
        if(self.discardPointsOutsideAccuracy > 0) {
            if(loc.horizontalAccuracy > self.discardPointsOutsideAccuracy) {
                continue;
            }
        }
        
        NSString *timestamp = [GLManager iso8601DateStringFromDate:loc.timestamp];
        NSDictionary *update;
        if(self.loggingModeCurrentValue == kGLLoggingModeOwntracks) {
            update = [self owntracksDictionaryFromLocation:loc];
        } else {
            update = [self currentDictionaryFromLocation:loc];
            NSMutableDictionary *properties = [update objectForKey:@"properties"];
            if(self.includeTrackingStats) {
                [properties setValue:[NSNumber numberWithBool:self.locationManager.pausesLocationUpdatesAutomatically] forKey:@"pauses"];
                [properties setValue:activityType forKey:@"activity"];
                [properties setValue:[NSNumber numberWithDouble:self.locationManager.desiredAccuracy] forKey:@"desired_accuracy"];
                [properties setValue:[NSNumber numberWithInt:self.trackingMode] forKey:@"tracking_mode"];
                [properties setValue:[NSNumber numberWithLong:locations.count] forKey:@"locations_in_payload"];
            }
            // Add the trip start time as trip_id in the location update
            if(self.tripInProgress) {
                [properties setValue:[GLManager iso8601DateStringFromDate:self.currentTripStart] forKey:@"trip_id"];
                [properties setValue:self.currentTripMode forKey:@"trip_mode"];
            }
        }

        // Queue the point in the database
        [self.db accessCollection:GLLocationQueueName withBlock:^(id<LOLDatabaseAccessor> accessor) {
            if(self.loggingModeCurrentValue == kGLLoggingModeOnlyLatest) {
                // Only Latest intentionally replaces queued records, including unsent ones.
                [accessor deleteAllData];
            }
            [accessor setDictionary:update forKey:[NSString stringWithFormat:@"%@-%@", timestamp, NSUUID.UUID.UUIDString]];
        }];
        [RecentLocationHistory recordUpdate:update];
        didAddData = YES;
        
        if(self.tripInProgress && [loc.timestamp timeIntervalSinceDate:self.currentTripStart] >= 0  // only if the location is newer than the trip start
           && loc.horizontalAccuracy <= 200 // only if the location is accurate enough
           ) {

            if(_storeNextLocationAsTripStart) {
                [[NSUserDefaults standardUserDefaults] setObject:update forKey:GLTripStartLocationDefaultsName];
                self.tripStartLocationDictionary = update;
                _storeNextLocationAsTripStart = NO;
            }
            
            // If a trip is in progress, add to the trip's list too (for calculating trip distance)
            if(self.tripInProgress) {
                [self.tripdb executeUpdate:@"INSERT INTO trips (timestamp, latitude, longitude) VALUES (?, ?, ?)", [NSNumber numberWithDouble:loc.timestamp.timeIntervalSince1970], [NSNumber numberWithDouble:loc.coordinate.latitude], [NSNumber numberWithDouble:loc.coordinate.longitude]];
                _currentTripHasNewData = YES;
            }
        }

        self.lastLocation = loc;
        lastLocationSeen = loc;
        self.lastLocationDictionary = [self currentDictionaryFromLocation:self.lastLocation];

    }
    
    // Reset the stationary anchor after movement. Ignore delayed fixes older than
    // 20 seconds once an anchor exists.
    if (!self.tripInProgress && self.lastLocation && self.stopsAutomaticallyActive && ([self.lastLocation.timestamp timeIntervalSinceNow] > -20 || !self.lastTimeMovedBeyondStopThreshold)) {
        if ([self.lastLocationMovedBeyondStopThreshold distanceFromLocation:self.lastLocation] > self.stopsAutomaticallyRadius || !self.lastTimeMovedBeyondStopThreshold) {
            self.lastLocationMovedBeyondStopThreshold = self.lastLocation;
            self.lastTimeMovedBeyondStopThreshold = NSDate.now;
        }
    }
    
    
    // Keep significant-change monitoring active so movement can restart standard
    // updates. iOS controls when that event arrives.
    if (!self.tripInProgress && self.stopsAutomaticallyActive \
        && self.lastTimeMovedBeyondStopThreshold \
        && [self.lastTimeMovedBeyondStopThreshold timeIntervalSinceNow] < -self.stopsAutomaticallyAfterSeconds) {
        
        [[OverlandLocationEngine shared] stopLiveUpdates];
        [self.locationManager stopUpdatingLocation];
        [self.locationManager stopUpdatingHeading];
        [self.locationManager startMonitoringSignificantLocationChanges];

        self.didPauseByRadius = YES;
        
        NSLog(@"Stopping loc updates");
        [self notify:@"Location updates paused. Waiting for significant movement." withTitle:@"Paused"];
    }

    if(didAddData) {
        [self numberOfLocationsInQueue:^(long num) {}];
        [[NSNotificationCenter defaultCenter] postNotificationName:GLNewDataNotification object:self];
    }

    [self sendQueueIfTimeElapsed];
    
    [self scheduleLocalNotification];
}

- (void)addMetadataToUpdate:(NSDictionary *) update {
    NSMutableDictionary *properties = [update objectForKey:@"properties"];
    if(_deviceId && _deviceId.length > 0) {
        [properties setValue:_deviceId forKey:@"device_id"];
    }
    [properties setValue:[GLManager currentWifiHotSpotName] forKey:@"wifi"];
    [properties setValue:[self currentBatteryState] forKey:@"battery_state"];
    [properties setValue:[self currentBatteryLevel] forKey:@"battery_level"];
    if([[NSUserDefaults standardUserDefaults] boolForKey:GLIncludeUniqueIdDefaultsName]) {
        NSString *uniqueId = [UIDevice currentDevice].identifierForVendor.UUIDString;
        [properties setValue:uniqueId forKey:@"unique_id"];
    }
}

- (NSDictionary *)currentDictionaryFromLocation:(CLLocation *)loc {
    NSString *timestamp = [GLManager iso8601DateStringFromDate:loc.timestamp];
    NSDictionary *update = @{
             @"type": @"Feature",
             @"geometry": @{
                     @"type": @"Point",
                     @"coordinates": @[
                             [NSNumber numberWithDouble:((int)(loc.coordinate.longitude * 10000000)) / 10000000.0],
                             [NSNumber numberWithDouble:((int)(loc.coordinate.latitude * 10000000)) / 10000000.0]
                             ]
                     },
             @"properties": [NSMutableDictionary dictionaryWithDictionary:@{
                     @"timestamp": timestamp,
                     @"altitude": [NSNumber numberWithDouble:((int)(loc.altitude * 1000)) / 1000.0],
                     @"speed": [NSNumber numberWithDouble:((int)(loc.speed * 1000)) / 1000.0],
                     @"course": [NSNumber numberWithDouble:((int)(loc.course * 1000)) / 1000.0],
                     @"horizontal_accuracy": [NSNumber numberWithDouble:((int)(loc.horizontalAccuracy * 1000)) / 1000.0],
                     @"vertical_accuracy": [NSNumber numberWithDouble:((int)(loc.verticalAccuracy * 1000)) / 1000.0],
                     @"speed_accuracy": [NSNumber numberWithDouble:((int)(loc.speedAccuracy * 100)) / 100.0],
                     @"course_accuracy": [NSNumber numberWithDouble:((int)(loc.courseAccuracy * 100)) / 100.0],
                     @"motion": [self motionArrayFromLastMotion],
                     }]
             };
    [self addMetadataToUpdate:update];
    return update;
}

- (NSDictionary *)owntracksDictionaryFromLocation:(CLLocation *)loc {
    NSMutableDictionary *update = [NSMutableDictionary dictionaryWithDictionary:@{
        @"_type": @"location",
        @"lat": [NSNumber numberWithDouble:((int)(loc.coordinate.latitude * 10000000)) / 10000000.0],
        @"lon": [NSNumber numberWithDouble:((int)(loc.coordinate.longitude * 10000000)) / 10000000.0],
        @"tst": [NSNumber numberWithDouble:loc.timestamp.timeIntervalSince1970],
        @"acc": [NSNumber numberWithInt:(int)round(loc.horizontalAccuracy)],
        @"batt": @((int)round(self.currentBatteryLevel.doubleValue * 100)),
    }];
    if(_deviceId && _deviceId.length > 0) {
        NSString *topic = [NSString stringWithFormat:@"owntracks/%@", _deviceId];
        [update setValue:topic forKey:@"topic"];
    }
    return update;
}

- (NSArray *)motionArrayFromLastMotion {
    NSMutableArray *motion = [[NSMutableArray alloc] init];
    CMMotionActivity *motionActivity = [GLManager sharedManager].lastMotion;
    if(motionActivity.walking)
        [motion addObject:@"walking"];
    if(motionActivity.running)
        [motion addObject:@"running"];
    if(motionActivity.cycling)
        [motion addObject:@"cycling"];
    if(motionActivity.automotive)
        [motion addObject:@"driving"];
    if(motionActivity.stationary)
        [motion addObject:@"stationary"];
    return [NSArray arrayWithArray:motion];
}

- (void)locationManagerDidPauseLocationUpdates:(CLLocationManager *)manager {
    if(!self.trackingEnabled) return;
    [self logAction:@"paused_location_updates"];
    
    [self notify:@"Location updates paused" withTitle:@"Paused"];
    
    // Create an exit geofence to help it resume automatically
    if(self.resumesAfterDistance > 0 && self.lastLocation) {
        CLCircularRegion *region = [[CLCircularRegion alloc] initWithCenter:self.lastLocation.coordinate radius:self.resumesAfterDistance identifier:@"resume-from-pause"];
        region.notifyOnEntry = NO;
        region.notifyOnExit = YES;
        [self.locationManager startMonitoringForRegion:region];
    }
    
    // Send the queue now to flush all remaining points
    [self sendQueueIfNotInProgress];
    
    // If a trip was in progress, stop it now
    if(self.tripInProgress) {
        [self endTripFromAutopause:YES];
    }
}

-(void)locationManager:(CLLocationManager *)manager didExitRegion:(CLRegion *)region {
    if(![region.identifier isEqualToString:@"resume-from-pause"]) return;
    [self.locationManager stopMonitoringForRegion:region];
    if(!self.trackingEnabled || ![[NSUserDefaults standardUserDefaults] boolForKey:GLTrackingStateDefaultsName]) return;
    NSLog(@"Did exit region");
    [self logAction:@"exited_pause_region"];
    [self notify:@"Starting updates from exiting the geofence" withTitle:@"Resumed"];
    [self.locationManager stopMonitoringForRegion:region];
    [self enableTracking];
}

- (void)locationManagerDidResumeLocationUpdates:(CLLocationManager *)manager {
    [self logAction:@"resumed_location_updates"];
    [self notify:@"Location updates resumed" withTitle:@"Resumed"];
}

#pragma mark - AppDelegate Methods

- (void)applicationDidEnterBackground {
    // [self logAction:@"did_enter_background"];
}

- (void)applicationWillTerminate {
    [self logAction:@"will_terminate"];
}

- (void)applicationWillResignActive {
    // [self logAction:@"will_resign_active"];
}

#pragma mark - Notifications

- (BOOL)notificationsEnabled {
    if([self defaultsKeyExists:GLNotificationsEnabledDefaultsName]) {
        return [[NSUserDefaults standardUserDefaults] boolForKey:GLNotificationsEnabledDefaultsName];
    } else {
        return NO;
    }
}
- (void)setNotificationsEnabled:(BOOL)enabled {
    if(enabled) {
        [self requestNotificationPermission];
    } else {
        [[NSUserDefaults standardUserDefaults] setBool:NO forKey:GLNotificationsEnabledDefaultsName];
        [[NSUserDefaults standardUserDefaults] setBool:NO forKey:GLNotificationPermissionRequestedDefaultsName];
    }
}

- (void)initializeNotifications {
    UNUserNotificationCenter *notificationCenter = [UNUserNotificationCenter currentNotificationCenter];
    notificationCenter.delegate = self;
    
    // If notifications were successfully requested previously, initialize again for this app launch
    if([[NSUserDefaults standardUserDefaults] boolForKey:GLNotificationPermissionRequestedDefaultsName]) {
        [self requestNotificationPermission];
    }
    
    UNNotificationAction *endTripAction = [UNNotificationAction actionWithIdentifier:@"END_TRIP" title:@"End Trip" options:UNNotificationActionOptionNone];
    UNNotificationCategory *actionCategory = [UNNotificationCategory categoryWithIdentifier:GLNotificationCategoryTripName
                                                                                    actions:@[endTripAction]
                                                                          intentIdentifiers:@[]
                                                                                    options:UNNotificationCategoryOptionNone];
    [notificationCenter setNotificationCategories:[NSSet setWithArray:@[actionCategory]]];
}

- (void)requestNotificationPermission {
    UNUserNotificationCenter *notificationCenter = [UNUserNotificationCenter currentNotificationCenter];

    UNAuthorizationOptions options = UNAuthorizationOptionAlert + UNAuthorizationOptionSound;
    [notificationCenter requestAuthorizationWithOptions:options
                                      completionHandler:^(BOOL granted, NSError * _Nullable error) {
                                          // If the user denies permission, set requested=NO so that if they ever enable it in settings again the permission will be requested again
                                          [[NSUserDefaults standardUserDefaults] setBool:granted forKey:GLNotificationPermissionRequestedDefaultsName];
                                          [[NSUserDefaults standardUserDefaults] setBool:granted forKey:GLNotificationsEnabledDefaultsName];
                                          if(!granted) {
                                              NSLog(@"User did not allow notifications");
                                          }
                                      }];
}

- (void)notify:(NSString *)message withTitle:(NSString *)title
{
    if([self notificationsEnabled]) {
        UNUserNotificationCenter *notificationCenter = [UNUserNotificationCenter currentNotificationCenter];
        
        UNMutableNotificationContent *content = [UNMutableNotificationContent new];
        content.title = title;
        content.body = message;
        content.sound = [UNNotificationSound defaultSound];
        
        /* UNTimeIntervalNotificationTrigger *trigger = [UNTimeIntervalNotificationTrigger triggerWithTimeInterval:1 repeats:NO]; */
        
        NSString *identifier = @"GLLocalNotification";
        UNNotificationRequest *request = [UNNotificationRequest requestWithIdentifier:identifier
                                                                              content:content
                                                                              trigger:nil];
        
        [notificationCenter addNotificationRequest:request withCompletionHandler:^(NSError * _Nullable error) {
            if (error != nil) {
                NSLog(@"Something went wrong: %@",error);
            } else {
                NSLog(@"Notification sent");
            }
        }];
    }
}

/* Force notifications to display as normal when the app is active */
- (void)userNotificationCenter:(UNUserNotificationCenter *)center
       willPresentNotification:(UNNotification *)notification
         withCompletionHandler:(void (^)(UNNotificationPresentationOptions options))completionHandler {
    
    completionHandler(UNNotificationPresentationOptionList | UNNotificationPresentationOptionBanner);
}

- (void)askToEndTrip
{
    if(self.notificationsEnabled) {
        UNUserNotificationCenter *notificationCenter = [UNUserNotificationCenter currentNotificationCenter];

        UNMutableNotificationContent *content = [UNMutableNotificationContent new];
        content.title = @"End Trip";
        content.body = @"It looks like you stopped moving, would you like to end the current trip?";
        content.sound = [UNNotificationSound defaultSound];
        content.categoryIdentifier = GLNotificationCategoryTripName;
        
        NSString *identifier = @"GLLocalNotificationEndTripPrompt";
        UNNotificationRequest *request = [UNNotificationRequest requestWithIdentifier:identifier
                                                                              content:content
                                                                              trigger:nil];

        [notificationCenter addNotificationRequest:request withCompletionHandler:^(NSError * _Nullable error) {
            if(error != nil) {
                NSLog(@"Something went wrong trying to ask to end the trip: %@", error);
            } else{
                NSLog(@"Notification sent");
            }
        }];
    }
}

- (void)userNotificationCenter:(UNUserNotificationCenter *)center didReceiveNotificationResponse:(nonnull UNNotificationResponse *)response withCompletionHandler:(nonnull void (^)(void))completionHandler
{
    dispatch_async(dispatch_get_main_queue(), ^{
        if([@"END_TRIP" isEqualToString:response.actionIdentifier]) [self endTrip];
        completionHandler();
    });
}


#pragma mark - Wifi Positioning

/*
 Allow the user to configure wifi names mapping to locations. If the phone is connected to
 one of the known wifi names, use the configured location instead of the phone's reported location.
 This should help avoid GPS drift around common locations like "home" and "work", and can
 also be used to pause location updates when the user gets home.
*/

- (CLLocation *)currentLocationFromWifiName:(NSString *)wifi bssid:(NSString *)bssid {
    if(wifi.length == 0) return nil;
    NSDictionary *match;
    for(NSDictionary *zone in self.wifiZones) {
        if(![zone[@"name"] isEqualToString:wifi]) continue;
        NSString *mac = zone[@"bssid"];
        if(mac.length == 0) {
            if(!match) match = zone;
        } else if(bssid.length > 0 && [mac caseInsensitiveCompare:bssid] == NSOrderedSame) {
            match = zone;
            break;
        }
    }
    if(!match) return nil;
    CLLocationCoordinate2D coord = CLLocationCoordinate2DMake([match[@"latitude"] doubleValue], [match[@"longitude"] doubleValue]);
    if(!CLLocationCoordinate2DIsValid(coord)) return nil;
    return [[CLLocation alloc] initWithCoordinate:coord altitude:0 horizontalAccuracy:1 verticalAccuracy:-1 course:-1 speed:0 timestamp:NSDate.date];
}

- (NSArray<NSDictionary<NSString *, NSString *> *> *)wifiZones {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSArray *zones = [defaults arrayForKey:GLWifiZonesDefaultsName];
    if(zones == nil) {
        // Preserve the saved location when migrating the legacy single-zone setting.
        NSString *name = [defaults objectForKey:@"WifiZoneName"];
        if(name) {
            NSDictionary *zone = @{@"name": name,
                                   @"latitude": [defaults objectForKey:@"WifiZoneLatitude"] ?: @"0",
                                   @"longitude": [defaults objectForKey:@"WifiZoneLongitude"] ?: @"0"};
            zones = @[zone];
            [defaults setObject:zones forKey:GLWifiZonesDefaultsName];
            [defaults removeObjectForKey:@"WifiZoneName"];
            [defaults removeObjectForKey:@"WifiZoneLatitude"];
            [defaults removeObjectForKey:@"WifiZoneLongitude"];
        } else {
            zones = @[];
        }
    }
    return zones;
}

- (void)saveWifiZones:(NSArray<NSDictionary<NSString *, NSString *> *> *)zones {
    [[NSUserDefaults standardUserDefaults] setObject:zones forKey:GLWifiZonesDefaultsName];
}

- (void)addWifiZoneWithName:(NSString *)name latitude:(NSString *)latitude longitude:(NSString *)longitude bssid:(NSString *)bssid {
    if(name.length == 0) {
        return;
    }

    NSMutableArray *zones = [NSMutableArray arrayWithArray:self.wifiZones];
    NSMutableDictionary *zone = [NSMutableDictionary dictionaryWithDictionary:@{
        @"name": name,
        @"latitude": latitude ?: @"0",
        @"longitude": longitude ?: @"0",
    }];
    if(bssid.length > 0) {
        zone[@"bssid"] = bssid;
    }
    for(int i=0; i<(int)zones.count; i++) {
        NSString *storedBSSID = zones[i][@"bssid"] ?: @"";
        if([zones[i][@"name"] isEqualToString:name] && [storedBSSID caseInsensitiveCompare:bssid ?: @""] == NSOrderedSame) {
            [zones replaceObjectAtIndex:i withObject:zone];
            [self saveWifiZones:zones];
            return;
        }
    }
    [zones addObject:zone];
    [self saveWifiZones:zones];
}

- (void)removeWifiZoneAtIndex:(NSInteger)index {
    NSMutableArray *zones = [NSMutableArray arrayWithArray:self.wifiZones];
    if(index < 0 || index >= (NSInteger)zones.count) {
        return;
    }
    [zones removeObjectAtIndex:index];
    [self saveWifiZones:zones];
}

- (void)saveNewWifiZone:(NSString *)name withLatitude:(NSString *)latitude andLongitude:(NSString *)longitude {
    if(name.length == 0) {
        return;
    }
    [self addWifiZoneWithName:name latitude:latitude longitude:longitude bssid:nil];
}
- (NSString *)wifiZoneName {
    return self.wifiZones.firstObject[@"name"];
}
- (NSString *)wifiZoneLatitude {
    return self.wifiZones.firstObject[@"latitude"];
}
- (NSString *)wifiZoneLongitude {
    return self.wifiZones.firstObject[@"longitude"];
}


#pragma mark -

- (BOOL)defaultsKeyExists:(NSString *)key {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    return [[[defaults dictionaryRepresentation] allKeys] containsObject:key];
}

+ (NSString *)currentWifiHotSpotName {
    return [self currentWifiNetworkInfo][@"SSID"];
}

// iOS redacts SSID/BSSID without location permission and the wifi-info entitlement
+ (NSDictionary *)currentWifiNetworkInfo {
    NSArray *ifs = (__bridge_transfer id)CNCopySupportedInterfaces();
    for (NSString *ifnam in ifs) {
        NSDictionary *info = (__bridge_transfer id)CNCopyCurrentNetworkInfo((__bridge CFStringRef)ifnam);
        if(info[@"SSID"]) {
            return info;
        }
    }
    return @{};
}

#pragma mark - FMDB

+ (NSString *)tripDatabasePath {
    NSString *docsPath = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES)[0];
    return [docsPath stringByAppendingPathComponent:@"trips.sqlite"];
}

- (void)setUpTripDB {
    [self.tripdb open];
    if(![self.tripdb executeUpdate:@"CREATE TABLE IF NOT EXISTS trips (\
       id INTEGER PRIMARY KEY AUTOINCREMENT, \
       timestamp INTEGER, \
       latitude REAL, \
       longitude REAL \
     )"]) {
        NSLog(@"Error creating trip DB: %@", self.tripdb.lastErrorMessage);
    }
    [self.tripdb close];
}

- (void)clearTripDB {
    [self.tripdb executeUpdate:@"DELETE FROM trips"];
}


#pragma mark - LOLDB

+ (NSString *)cacheDatabasePath
{
    NSFileManager *files = [NSFileManager defaultManager];
    NSString *caches = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).firstObject;
    NSString *oldPath = [caches stringByAppendingPathComponent:@"GLLoggerCache.sqlite"];
    NSString *support = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES).firstObject;
    NSError *error;
    if(![files createDirectoryAtPath:support withIntermediateDirectories:YES attributes:nil error:&error]) {
        NSLog(@"Unable to create queue directory: %@", error.localizedDescription);
        return oldPath;
    }
    NSString *path = [support stringByAppendingPathComponent:@"GLLoggerCache.sqlite"];
    if([files fileExistsAtPath:path] || ![files fileExistsAtPath:oldPath]) return path;

    NSString *temporary = [path stringByAppendingString:@".migration"];
    sqlite3 *source = NULL;
    sqlite3 *destination = NULL;
    BOOL copied = NO;
    if(sqlite3_open_v2(oldPath.UTF8String, &source, SQLITE_OPEN_READONLY, NULL) == SQLITE_OK &&
       sqlite3_open(temporary.UTF8String, &destination) == SQLITE_OK) {
        sqlite3_backup *backup = sqlite3_backup_init(destination, "main", source, "main");
        if(backup) {
            int status = sqlite3_backup_step(backup, -1);
            int finished = sqlite3_backup_finish(backup);
            copied = status == SQLITE_DONE && finished == SQLITE_OK;
        }
    }
    if(destination) sqlite3_close(destination);
    if(source) sqlite3_close(source);
    if(copied && [files moveItemAtPath:temporary toPath:path error:&error]) return path;
    NSLog(@"Queue migration could not finish; retaining the original database");
    return oldPath;
}

+ (id)objectFromJSONData:(NSData *)data error:(NSError **)error;
{
    if(data.length == 0) return nil;
    return [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingAllowFragments error:error];
}

+ (NSData *)dataWithJSONObject:(id)object error:(NSError **)error;
{
    if(![NSJSONSerialization isValidJSONObject:object]) return nil;
    return [NSJSONSerialization dataWithJSONObject:object options:0 error:error];
}

+ (NSString *)iso8601DateStringFromDate:(NSDate *)date {
    struct tm timeinfo;
    char buffer[80];
    
    time_t rawtime = (time_t)[date timeIntervalSince1970];
    gmtime_r(&rawtime, &timeinfo);
    
    strftime(buffer, 80, "%Y-%m-%dT%H:%M:%SZ", &timeinfo);
    
    return [NSString stringWithCString:buffer encoding:NSUTF8StringEncoding];
}

@end

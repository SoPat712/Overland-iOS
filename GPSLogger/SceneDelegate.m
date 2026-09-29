//
//  SceneDelegate.m
//  Overland
//
//  Created by Aaron Parecki on 12/10/23.
//  Copyright © 2023 Aaron Parecki. All rights reserved.
//

#import <Foundation/Foundation.h>

#import "SceneDelegate.h"
#import "GLManager.h"
#import "NSArray+map.h"
#import "Overland-Swift.h"
@import SwiftUI;

@implementation SceneDelegate

- (void)sceneWillEnterForeground:(UIScene *)scene {
    
    if([[NSUserDefaults standardUserDefaults] boolForKey:GLPurgeQueueOnNextLaunchDefaultsName]) {
        [[GLManager sharedManager] deleteAllData];
        [[NSUserDefaults standardUserDefaults] setBool:NO forKey:GLPurgeQueueOnNextLaunchDefaultsName];
    }

}


- (void)sceneDidEnterBackground:(UIScene *)scene {
    
    NSLog(@"Application is entering the background");
    [[NSUserDefaults standardUserDefaults] synchronize];
    [[GLManager sharedManager] applicationDidEnterBackground];
}


- (void)scene:(UIScene *)scene openURLContexts:(NSSet<UIOpenURLContext *> *)URLContexts {
    UIOpenURLContext *context = [URLContexts anyObject];
    NSURL *url = context.URL;
    
    if([[url host] isEqualToString:@"setup"]) {
        NSURLComponents *urlComponents = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
        NSArray *queryItems  = urlComponents.queryItems;
        NSString *endpoint = [self queryValueForKey:@"url" fromQueryItems:queryItems];
        NSString *token    = [self queryValueForKey:@"token" fromQueryItems:queryItems];
        NSString *deviceId = [self queryValueForKey:@"device_id" fromQueryItems:queryItems];
        NSString *uniqueId = [self queryValueForKey:@"unique_id" fromQueryItems:queryItems];
        if(![GLManager isValidEndpoint:endpoint]) return;
        NSLog(@"Applying server configuration");
        [[GLManager sharedManager] saveNewDeviceId:deviceId];
        [[GLManager sharedManager] saveNewAPIEndpoint:endpoint andAccessToken:token];
        [[NSUserDefaults standardUserDefaults] setBool:[uniqueId isEqualToString:@"yes"] forKey:GLIncludeUniqueIdDefaultsName];
        NSMutableDictionary *headers = [NSMutableDictionary dictionary];
        for(NSURLQueryItem *item in queryItems) {
            if([item.name hasPrefix:@"header_"] && item.name.length > 7 && item.value) {
                headers[[item.name substringFromIndex:7]] = item.value;
            }
        }
        if(headers.count > 0) [GLManager sharedManager].customHTTPHeaders = headers;
    }
}

- (NSString *)queryValueForKey:(NSString *)key fromQueryItems:(NSArray *)queryItems
{
    NSPredicate *predicate = [NSPredicate predicateWithFormat:@"name=%@", key];
    NSURLQueryItem *queryItem = [[queryItems filteredArrayUsingPredicate:predicate] firstObject];
    return queryItem.value;
}

#pragma mark - Quick Actions

// https://developer.apple.com/documentation/uikit/menus_and_shortcuts/add_home_screen_quick_actions?language=objc

- (void)sceneWillResignActive:(UIScene *)scene {
    
    [[GLManager sharedManager] applicationWillResignActive];

    UIApplication *app = UIApplication.sharedApplication;

    // Offer frequent travel modes when idle and Stop Trip while recording a trip.
    if(![GLManager sharedManager].tripInProgress) {
        NSArray *tripModes = [[GLManager sharedManager] tripModesByFrequency];
        app.shortcutItems = [tripModes mapObjectsUsingBlock:^id(id obj, NSUInteger idx) {
            UIApplicationShortcutIcon *icon = [UIApplicationShortcutIcon iconWithTemplateImageName:obj];
            return [[UIApplicationShortcutItem alloc] initWithType:obj
                                                    localizedTitle:obj
                                                 localizedSubtitle:nil
                                                              icon:icon
                                                          userInfo:nil];
        }];
    } else {
        
        UIApplicationShortcutIcon *icon = [UIApplicationShortcutIcon iconWithSystemImageName:@"stop.circle.fill"];
        UIApplicationShortcutItem *item = [[UIApplicationShortcutItem alloc] initWithType:@"stop"
                                                                           localizedTitle:@"Stop Trip"
                                                                        localizedSubtitle:nil
                                                                                     icon:icon
                                                                                 userInfo:nil];
        app.shortcutItems = @[item];
    }
}


- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session options:(UISceneConnectionOptions *)connectionOptions {
    // Cold-launch setup links and quick actions arrive in connectionOptions.

    UIWindowScene *windowScene = (UIWindowScene *)scene;
    self.window = [[UIWindow alloc] initWithWindowScene:windowScene];
    self.window.rootViewController = [OverlandRootHosting makeRoot];
    [self.window makeKeyAndVisible];

    if(connectionOptions.URLContexts.count > 0) {
        [self scene:scene openURLContexts:connectionOptions.URLContexts];
    }
    if(connectionOptions.shortcutItem != nil) {
        NSLog(@"App launched. connectionOptions = %@", connectionOptions);
        [self handleLaunchFromShortcutItem:connectionOptions.shortcutItem];
    }
}

- (void)windowScene:(UIWindowScene *)windowScene performActionForShortcutItem:(UIApplicationShortcutItem *)shortcutItem completionHandler:(void (^)(BOOL))completionHandler {
    NSLog(@"Quick Action requested when app already loaded");
    NSLog(@"shortcutItem = %@", shortcutItem);
    
    [self handleLaunchFromShortcutItem:shortcutItem];
    completionHandler(YES);
}

- (void)handleLaunchFromShortcutItem:(UIApplicationShortcutItem *)shortcutItem {
    if([shortcutItem.type isEqualToString:@"stop"]) {
        [[GLManager sharedManager] endTrip];
    } else if([[GLManager GLTripModes] containsObject:shortcutItem.type]) {
        [GLManager sharedManager].currentTripMode = shortcutItem.type;
        [[GLManager sharedManager] startTrip];
    }
}


@end

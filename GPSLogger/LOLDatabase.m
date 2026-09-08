//
//  LOLDatabase.m
//  loldb
//
//  Created by Andrew Pouliot on 12/12/11.
//  Copyright (c) 2011 Geoloqi, Inc. All rights reserved.
//

#import "LOLDatabase.h"

#import "sqlite3.h"

@interface _LOLDatabaseAccessor : NSObject <LOLDatabaseAccessor>
- (id)initWithDatabase:(LOLDatabase *)db collection:(NSString *)collection;
- (void)done;
- (void)rollbackAndFinalize;
@end

@implementation LOLDatabase {
@public
    sqlite3 *db;
}
@synthesize serializer;
@synthesize deserializer;

- (id)initWithPath:(NSString *)path;
{
    self = [super init];
    if (!self) return nil;
    
    // int status = sqlite3_open([path UTF8String], &db);
    // Open the database in serialized mode
    // https://www.sqlite.org/threadsafe.html
    int status = sqlite3_open_v2([path UTF8String], &db, SQLITE_OPEN_READWRITE|SQLITE_OPEN_FULLMUTEX|SQLITE_OPEN_CREATE, NULL);
    
    if (status != SQLITE_OK) {
        if (db) {
            sqlite3_close(db);
            db = NULL;
        }
        NSLog(@"Couldn't open database: %@", path);
        return nil;
    }
    
    NSString *sql = @"PRAGMA legacy_file_format = 0;";
    if (sqlite3_exec(db, [sql UTF8String], NULL, NULL, NULL) != SQLITE_OK) {
        sqlite3_close(db);
        db = NULL;
        NSLog(@"Unable to configure queue database");
        return nil;
    }
    
    return self;
}

- (void)dealloc {
    sqlite3_close(db);
    
}

- (void)accessCollection:(NSString *)collection withBlock:(void (^)(id <LOLDatabaseAccessor>))block;
{
    _LOLDatabaseAccessor *a = [[_LOLDatabaseAccessor alloc] initWithDatabase:self collection:collection];
    if (!a) return;

    @try {
        if (block) block(a);
    } @catch (NSException *exception) {
        [a rollbackAndFinalize];
        @throw;
    } @finally {
        [a done];
    }
}

@end


@implementation _LOLDatabaseAccessor {
    NSString *_collection;
    LOLDatabase *_d;
    sqlite3_stmt *getByKeyStatement;
    sqlite3_stmt *setByKeyStatement;
    sqlite3_stmt *removeByKeyStatement;
    sqlite3_stmt *enumerateStatement;
    sqlite3_stmt *countStatement;
    sqlite3_stmt *deleteAllStatement;
    BOOL transactionOpen;
    BOOL transactionFailed;
}

- (id)initWithDatabase:(LOLDatabase *)db collection:(NSString *)collection;
{
    self = [super init];
    if (!self) return nil;
    
    _d = db;
    
    NSString *q = nil;
    int status = SQLITE_OK;
    
    q = @"BEGIN TRANSACTION;";
    if (sqlite3_exec(_d->db, [q UTF8String], NULL, NULL, NULL) != SQLITE_OK) {
        NSLog(@"Couldn't begin a transaction!");
        return nil;
    }
    transactionOpen = YES;
    
    q = [[NSString alloc] initWithFormat:@"CREATE TABLE IF NOT EXISTS '%@' ('key' CHAR PRIMARY KEY  NOT NULL  UNIQUE, 'data' BLOB);", collection];
    if (sqlite3_exec(_d->db, [q UTF8String], NULL, NULL, NULL) != SQLITE_OK) {
        NSLog(@"table failed to be created %s", sqlite3_errmsg(_d->db));
        [self rollbackAndFinalize];
        return nil;
    }

    q = [[NSString alloc] initWithFormat:@"SELECT data FROM '%@' WHERE key = ? ;", collection];
    status = sqlite3_prepare_v2(_d->db, [q UTF8String], -1, &getByKeyStatement, NULL);
    if (status != SQLITE_OK) {
        NSLog(@"Error with get query! %s", sqlite3_errmsg(_d->db));
        [self rollbackAndFinalize];
        return nil;
    }

    q = [[NSString alloc] initWithFormat:@"SELECT key,data FROM '%@' ORDER BY rowid;", collection];
    status = sqlite3_prepare_v2(_d->db, [q UTF8String], -1, &enumerateStatement, NULL);
    if (status != SQLITE_OK) {
        NSLog(@"Error with enumerate query! %s", sqlite3_errmsg(_d->db));
        [self rollbackAndFinalize];
        return nil;
    }

    q = [[NSString alloc] initWithFormat:@"SELECT COUNT(1) FROM '%@';", collection];
    status = sqlite3_prepare_v2(_d->db, [q UTF8String], -1, &countStatement, NULL);
    if (status != SQLITE_OK) {
        NSLog(@"Error with count query! %s", sqlite3_errmsg(_d->db));
        [self rollbackAndFinalize];
        return nil;
    }

    q = [[NSString alloc] initWithFormat:@"INSERT OR REPLACE INTO '%@' ('key', 'data') VALUES (?, ?);", collection];
    status = sqlite3_prepare_v2(_d->db, [q UTF8String], -1, &setByKeyStatement, NULL);
    if (status != SQLITE_OK) {
        NSLog(@"Error with set query! %s", sqlite3_errmsg(_d->db));
        [self rollbackAndFinalize];
        return nil;
    }

    q = [[NSString alloc] initWithFormat:@"DELETE FROM '%@' WHERE key = ? ;", collection];
    status = sqlite3_prepare_v2(_d->db, [q UTF8String], -1, &removeByKeyStatement, NULL);
    if (status != SQLITE_OK) {
        NSLog(@"Error with delete query! %s", sqlite3_errmsg(_d->db));
        [self rollbackAndFinalize];
        return nil;
    }

    q = [[NSString alloc] initWithFormat:@"DELETE FROM '%@';", collection];
    status = sqlite3_prepare_v2(_d->db, [q UTF8String], -1, &deleteAllStatement, NULL);
    if (status != SQLITE_OK) {
        NSLog(@"Error with delete all query! %s", sqlite3_errmsg(_d->db));
        [self rollbackAndFinalize];
        return nil;
    }

    return self;
}

- (void)done;
{
    [self finalizeStatements];

    if (!transactionOpen) return;

    if (transactionFailed) {
        [self rollbackTransaction];
        return;
    }

    NSString *q = @"COMMIT TRANSACTION;";
    if (sqlite3_exec(_d->db, [q UTF8String], NULL, NULL, NULL) != SQLITE_OK) {
        NSLog(@"Couldn't end a transaction! %s", sqlite3_errmsg(_d->db));
        [self rollbackTransaction];
        return;
    }
    transactionOpen = NO;
}

- (void)dealloc {
    [self rollbackAndFinalize];
}

- (void)finalizeStatements {
    if (getByKeyStatement) {
        if (sqlite3_finalize(getByKeyStatement) != SQLITE_OK) [self markTransactionFailed];
        getByKeyStatement = NULL;
    }
    if (setByKeyStatement) {
        if (sqlite3_finalize(setByKeyStatement) != SQLITE_OK) [self markTransactionFailed];
        setByKeyStatement = NULL;
    }
    if (removeByKeyStatement) {
        if (sqlite3_finalize(removeByKeyStatement) != SQLITE_OK) [self markTransactionFailed];
        removeByKeyStatement = NULL;
    }
    if (deleteAllStatement) {
        if (sqlite3_finalize(deleteAllStatement) != SQLITE_OK) [self markTransactionFailed];
        deleteAllStatement = NULL;
    }
    if (enumerateStatement) {
        if (sqlite3_finalize(enumerateStatement) != SQLITE_OK) [self markTransactionFailed];
        enumerateStatement = NULL;
    }
    if (countStatement) {
        if (sqlite3_finalize(countStatement) != SQLITE_OK) [self markTransactionFailed];
        countStatement = NULL;
    }
}

- (void)rollbackTransaction {
    if (!transactionOpen) return;

    NSString *q = @"ROLLBACK TRANSACTION;";
    if (sqlite3_exec(_d->db, [q UTF8String], NULL, NULL, NULL) != SQLITE_OK) {
        NSLog(@"Couldn't roll back a transaction! %s", sqlite3_errmsg(_d->db));
    }
    transactionOpen = sqlite3_get_autocommit(_d->db) == 0;
}

- (void)rollbackAndFinalize {
    [self finalizeStatements];
    [self rollbackTransaction];
}

- (void)markTransactionFailed {
    transactionFailed = YES;
}

- (NSData *)dataForKey:(NSString *)key;
{
    if (!getByKeyStatement) return nil;

    int status = sqlite3_bind_text(getByKeyStatement, 1, [key UTF8String], -1, SQLITE_TRANSIENT);
    if (status != SQLITE_OK) {
        NSLog(@"error binding get by key: %s", sqlite3_errmsg(_d->db));
        [self markTransactionFailed];
        sqlite3_reset(getByKeyStatement);
        sqlite3_clear_bindings(getByKeyStatement);
        return nil;
    }
    
    NSData *fullData = nil;
    status = sqlite3_step(getByKeyStatement);
    if (status == SQLITE_ROW) {
        const void *data = sqlite3_column_blob(getByKeyStatement, 0);
        size_t size = sqlite3_column_bytes(getByKeyStatement, 0);
        fullData = [[NSData alloc] initWithBytes:data length:size];
    } else if (status != SQLITE_DONE) {
        NSLog(@"error getting by key: %s", sqlite3_errmsg(_d->db));
        [self markTransactionFailed];
    }
    status = sqlite3_reset(getByKeyStatement);
    if (status != SQLITE_OK) {
        NSLog(@"error resetting get by key: %s", sqlite3_errmsg(_d->db));
        [self markTransactionFailed];
    }
    sqlite3_clear_bindings(getByKeyStatement);
    
    return fullData;
}

- (void)setData:(NSData *)data forKey:(NSString *)key;
{
    if (!setByKeyStatement) return;

    int status = sqlite3_bind_text(setByKeyStatement, 1, [key UTF8String], -1, SQLITE_TRANSIENT);
    if (status == SQLITE_OK) {
        status = sqlite3_bind_blob(setByKeyStatement, 2, data.bytes, (int)data.length, SQLITE_TRANSIENT);
    }
    if (status != SQLITE_OK) {
        NSLog(@"error binding set by key: %s", sqlite3_errmsg(_d->db));
        [self markTransactionFailed];
        sqlite3_reset(setByKeyStatement);
        sqlite3_clear_bindings(setByKeyStatement);
        return;
    }
    
    status = sqlite3_step(setByKeyStatement);
    if (status != SQLITE_DONE) {
        NSLog(@"error setting by key %d: %s", status, sqlite3_errmsg(_d->db));
        [self markTransactionFailed];
    }
    int resetStatus = sqlite3_reset(setByKeyStatement);
    if (resetStatus != SQLITE_OK) {
        NSLog(@"error resetting set by key: %s", sqlite3_errmsg(_d->db));
        [self markTransactionFailed];
    }
    sqlite3_clear_bindings(setByKeyStatement);
}

- (NSDictionary *)dictionaryForKey:(NSString *)key;
{
    NSData *data = [self dataForKey:key];
    return data ? _d.deserializer(data) : nil;
}

- (void)setDictionary:(NSDictionary *)dict forKey:(NSString *)key;
{
    if (!dict) {
        [self setData:nil forKey:key];
        return;
    }

    NSData *data = _d.serializer(dict);
    if (!data) {
        NSLog(@"Unable to serialize dictionary for key %@", key);
        [self markTransactionFailed];
        return;
    }
    [self setData:data forKey:key];
}

- (void)removeDictionaryForKey:(NSString *)key;
{
    if (!removeByKeyStatement) return;

    int status = sqlite3_bind_text(removeByKeyStatement, 1, [key UTF8String], -1, SQLITE_TRANSIENT);
    if (status != SQLITE_OK) {
        NSLog(@"Error binding remove dictionary for key %@ : %s", key, sqlite3_errmsg(_d->db));
        [self markTransactionFailed];
        sqlite3_reset(removeByKeyStatement);
        sqlite3_clear_bindings(removeByKeyStatement);
        return;
    }
    
    status = sqlite3_step(removeByKeyStatement);
    if (status != SQLITE_DONE) {
        NSLog(@"Error removing dictionary for key %@ : %s", key, sqlite3_errmsg(_d->db));
        [self markTransactionFailed];
    }
    
    int resetStatus = sqlite3_reset(removeByKeyStatement);
    if (resetStatus != SQLITE_OK) {
        NSLog(@"Error resetting remove dictionary for key %@ : %s", key, sqlite3_errmsg(_d->db));
        [self markTransactionFailed];
    }
    sqlite3_clear_bindings(removeByKeyStatement);
    
}

- (void)deleteAllData
{
    if (!deleteAllStatement) return;

    int status = sqlite3_step(deleteAllStatement);
    if (status != SQLITE_DONE) {
        NSLog(@"Error deleting all data : %s", sqlite3_errmsg(_d->db));
        [self markTransactionFailed];
    }
    
    int resetStatus = sqlite3_reset(deleteAllStatement);
    if (resetStatus != SQLITE_OK) {
        NSLog(@"Error resetting delete all data : %s", sqlite3_errmsg(_d->db));
        [self markTransactionFailed];
    }
    sqlite3_clear_bindings(deleteAllStatement);
}

- (void)enumerateKeysAndObjectsUsingBlock:(BOOL(^)(NSString *key, NSDictionary *object))block;
{
    if (!block || !enumerateStatement) return;
    NSData *fullData = nil;
    int status = sqlite3_step(enumerateStatement);
    
    BOOL stop = NO;
    while (!stop && status == SQLITE_ROW) {
        NSString *key = [[NSString alloc] initWithUTF8String:(const char *)sqlite3_column_text(enumerateStatement, 0)];
        
        const void *dataPtr = sqlite3_column_blob(enumerateStatement, 1);
        size_t size = sqlite3_column_bytes(enumerateStatement, 1);
        fullData = [[NSData alloc] initWithBytes:dataPtr length:size];
        
        NSDictionary *object = fullData ? _d.deserializer(fullData) : nil;	
        
        stop = block(key, object);
        status = sqlite3_step(enumerateStatement);
    }
    if (status != SQLITE_DONE && status != SQLITE_ROW) {
        NSLog(@"Error enumerating data : %s", sqlite3_errmsg(_d->db));
        [self markTransactionFailed];
    }
    int resetStatus = sqlite3_reset(enumerateStatement);
    if (resetStatus != SQLITE_OK) {
        NSLog(@"Error resetting enumerate data : %s", sqlite3_errmsg(_d->db));
        [self markTransactionFailed];
    }
    sqlite3_clear_bindings(enumerateStatement);
}

- (void)countObjectsUsingBlock:(void (^)(long num))block {
    if (!block || !countStatement) return;
    
    long count = 0;
    int status;
    while((status = sqlite3_step(countStatement)) == SQLITE_ROW) {
        count = (long)sqlite3_column_int(countStatement, 0);
    }

    if (status != SQLITE_DONE) {
        NSLog(@"Error counting data : %s", sqlite3_errmsg(_d->db));
        [self markTransactionFailed];
    }

    int resetStatus = sqlite3_reset(countStatement);
    if (resetStatus != SQLITE_OK) {
        NSLog(@"Error resetting count data : %s", sqlite3_errmsg(_d->db));
        [self markTransactionFailed];
    }
    sqlite3_clear_bindings(countStatement);
    
    block(count);
}

@end

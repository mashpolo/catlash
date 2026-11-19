#import "SystemDNS.h"
#import <TargetConditionals.h>
#if TARGET_OS_IOS
#include <arpa/inet.h>
#include <netdb.h>
#include <resolv.h>
#include <string.h>

static BOOL usableNetworkServer(const union res_sockaddr_union *server) {
    if (server->sin.sin_family == AF_INET) {
        uint32_t address = ntohl(server->sin.sin_addr.s_addr);
        // Exclude unspecified, loopback, multicast, and the core's fake-IP range.
        return address != 0 && (address >> 24) != 127 && (address >> 28) != 14 &&
               (address & 0xfffe0000U) != 0xc6120000U;
    }
    if (server->sin.sin_family == AF_INET6) {
        const struct in6_addr *address = &server->sin6.sin6_addr;
        static const unsigned char tunnelPrefix[6] = {0xfd, 0x00, 0x01, 0x98, 0x00, 0x18};
        return !IN6_IS_ADDR_UNSPECIFIED(address) && !IN6_IS_ADDR_LOOPBACK(address) &&
               !IN6_IS_ADDR_MULTICAST(address) && memcmp(address->s6_addr, tunnelPrefix, sizeof(tunnelPrefix)) != 0;
    }
    return NO;
}
#endif

NSArray<NSString *> *FlClashSystemDNSServers(void) {
#if TARGET_OS_IOS
    struct __res_state state = {0};
    if (res_ninit(&state) != 0) return @[];
    union res_sockaddr_union servers[MAXNS] = {0};
    int count = res_getservers(&state, servers, MAXNS);
    NSMutableArray<NSString *> *result = [NSMutableArray array];
    for (int index = 0; index < count && index < MAXNS; index++) {
        if (!usableNetworkServer(&servers[index])) continue;
        socklen_t length = servers[index].sin.sin_family == AF_INET ? sizeof(struct sockaddr_in) : sizeof(struct sockaddr_in6);
        char host[NI_MAXHOST];
        if (getnameinfo((const struct sockaddr *)&servers[index], length, host, sizeof(host), NULL, 0, NI_NUMERICHOST) != 0) continue;
        NSString *address = [NSString stringWithUTF8String:host];
        if (address != nil && ![result containsObject:address]) [result addObject:address];
    }
    res_ndestroy(&state);
    return result;
#else
    return @[];
#endif
}

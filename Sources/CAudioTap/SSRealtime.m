#import "SSRealtime.h"
#import <stdatomic.h>
#import <stdlib.h>

struct SSAtomicCell {
    _Atomic(int64_t) value;
};

SSAtomicCell *SSAtomicCellCreate(int64_t initial) {
    SSAtomicCell *cell = malloc(sizeof(SSAtomicCell));
    atomic_init(&cell->value, initial);
    return cell;
}

void SSAtomicCellDestroy(SSAtomicCell *cell) { free(cell); }

int64_t SSAtomicCellLoad(const SSAtomicCell *cell) {
    return atomic_load_explicit(&((SSAtomicCell *)cell)->value, memory_order_relaxed);
}

void SSAtomicCellStore(SSAtomicCell *cell, int64_t value) {
    atomic_store_explicit(&cell->value, value, memory_order_relaxed);
}

int64_t SSAtomicCellAdd(SSAtomicCell *cell, int64_t delta) {
    return atomic_fetch_add_explicit(&cell->value, delta, memory_order_relaxed) + delta;
}

NSString *SSCatchException(NS_NOESCAPE void (^block)(void)) {
    @try {
        block();
        return nil;
    } @catch (NSException *exception) {
        return [NSString stringWithFormat:@"%@: %@", exception.name, exception.reason ?: @""];
    }
}

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// A 64-bit value that an audio thread and other threads may read and write
/// at the same time (lock-free; never blocks, never allocates after creation).
typedef struct SSAtomicCell SSAtomicCell;

SSAtomicCell *SSAtomicCellCreate(int64_t initial);
void SSAtomicCellDestroy(SSAtomicCell *cell);
int64_t SSAtomicCellLoad(const SSAtomicCell *cell);
void SSAtomicCellStore(SSAtomicCell *cell, int64_t value);
/// Adds and returns the new value.
int64_t SSAtomicCellAdd(SSAtomicCell *cell, int64_t delta);

/// Runs `block` and returns nil, or the description of the Objective-C
/// exception it raised. AVAudioEngine reports wrong formats and vanished
/// devices by raising exceptions, which Swift cannot catch.
NSString *_Nullable SSCatchException(NS_NOESCAPE void (^block)(void));

NS_ASSUME_NONNULL_END

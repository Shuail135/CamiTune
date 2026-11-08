#pragma once
#include <atomic>
#include <cstddef>
#include <cstdint>
#include <memory>

namespace CamiTunePlugins {
// Multiple publishers, one consumer. Storage is prepared with the parameter
// schema. A value is published before its bit; edits racing consumption remain
// pending for the next pass. Unchanged parameters require no atomic writes.
class ParameterChangeFlags {
    size_t wordCount;
    std::unique_ptr<std::atomic<uint64_t>[]> words;
public:
    explicit ParameterChangeFlags(size_t count)
        : wordCount((count + 63) / 64), words(new std::atomic<uint64_t>[wordCount]) {
        for (size_t i = 0; i < wordCount; ++i) words[i].store(0, std::memory_order_relaxed);
    }
    void publish(size_t index) {
        words[index / 64].fetch_or(uint64_t(1) << (index % 64), std::memory_order_release);
    }
    template<class Consumer> void consume(Consumer&& consumer) {
        for (size_t i = 0; i < wordCount; ++i) {
            if (!words[i].load(std::memory_order_relaxed)) continue;
            uint64_t pending = words[i].exchange(0, std::memory_order_acquire);
            while (pending) {
                auto bit = static_cast<size_t>(__builtin_ctzll(pending));
                consumer(i * 64 + bit);
                pending &= pending - 1;
            }
        }
    }
};
}

#include <benchmark/benchmark.h>

#include "lib.h"

static void BM_test(benchmark::State& state) {
    for (auto _ : state) {
        benchmark::DoNotOptimize(state.iterations());
    }
}
BENCHMARK(BM_test);

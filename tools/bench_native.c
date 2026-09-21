/*
 * bench_native.c — 原生基线 (绝对参照, gcc -O2)。
 * 与 src/bench.ts 使用同一组常量 (N_FIB / N_LOOP), 输出结果必须与 A/B 一致。
 *
 * 用法: bench_native <runs>   (前 1 次为 warmup; 每次执行都打印结果)
 * 时钟: CLOCK_MONOTONIC, 单位毫秒, 输出 RUN 行供 bench.sh 解析。
 */
#include <stdio.h>
#include <stdlib.h>
#include <time.h>

#define N_FIB 29
#define N_LOOP 1000000L

/* 经 volatile 指针读入, 阻止 gcc -O2 把整个计算常量折叠掉 */
static const long n_fib = N_FIB;
static const long n_loop = N_LOOP;
static volatile const long *const p_fib = &n_fib;
static volatile const long *const p_loop = &n_loop;

static long
fib(long n)
{
    return n < 2 ? n : fib(n - 1) + fib(n - 2);
}

static double
now_ms(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec * 1000.0 + (double)ts.tv_nsec / 1000000.0;
}

int
main(int argc, char *argv[])
{
    int runs = argc > 1 ? atoi(argv[1]) : 1;
    int r;
    long f;
    long long sum;

    /* warmup (含输出, 与 A/B 一致: 输出在计时区域内) */
    f = fib(*p_fib);
    sum = 0;
    for (long i = 0; i < *p_loop; i++)
        sum += i;
    printf("fib(%d) = %ld\n", N_FIB, f);
    printf("sum = %lld\n", sum);
    fflush(stdout);

    for (r = 1; r <= runs; r++) {
        double t0 = now_ms();
        f = fib(*p_fib);
        sum = 0;
        for (long i = 0; i < *p_loop; i++)
            sum += i;
        printf("RUN %d %.3f\n", r, now_ms() - t0);
        fflush(stdout);
    }
    return 0;
}

/*
 * bench_split.c — 审计实验: 把 bench_native 的 fib 与循环部分拆开计时。
 * 时钟 CLOCK_MONOTONIC, 输出 FIB/LOOP/RUN 行。gcc -O2, 与 bench_native 同一
 * volatile 读入口 (n 从 volatile const 指针读入), 防常量折叠口径一致。
 */
#include <stdio.h>
#include <time.h>

#define N_FIB 29
#define N_LOOP 1000000L

static const long n_fib = N_FIB;
static const long n_loop = N_LOOP;
static volatile const long *const p_fib = &n_fib;
static volatile const long *const p_loop = &n_loop;

static long fib(long n) { return n < 2 ? n : fib(n - 1) + fib(n - 2); }

static double now_ms(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec * 1000.0 + (double)ts.tv_nsec / 1000000.0;
}

int main(void)
{
    long f;
    long long sum;

    /* 预热 */
    f = fib(*p_fib);
    sum = 0;
    for (long i = 0; i < *p_loop; i++) sum += i;
    printf("fib(%d) = %ld\nsum = %lld\n", N_FIB, f, sum);
    fflush(stdout);

    for (int r = 1; r <= 11; r++) {
        double t0, t1, tl;
        t0 = now_ms();
        f = fib(*p_fib);
        t1 = now_ms();
        sum = 0;
        for (long i = 0; i < *p_loop; i++) sum += i;
        tl = now_ms();
        printf("FIB %d %.3f\nLOOP %d %.3f\nRUN %d %.3f\n", r, t1 - t0, r, tl - t1, r, tl - t0);
        fflush(stdout);
    }
    return 0;
}

/*
 * bench_perry_wrap.c — D 路 (perry 原生) 计时包装。
 * 重复 fork/exec build/bench_perry_native，用 CLOCK_MONOTONIC 量整个进程生命周期
 * (含启动)，取每次 real 毫秒。选 exec 而非进程内多跑: perry 产物无多轮入口，
 * 而其稳态执行 (~2 ms) 相对进程启动 (~10 ms) 不可忽略，必须整进程计时。
 * 产物本身 < 1 ms 精度的 bash time (0.000) 不可用，故用此包装。
 *
 * 用法: bench_perry_wrap <executable> <runs>
 * 输出: RUN i <ms> 行 (与 bench_native.c 同格式，供脚本解析)。
 * 注意: perry 产物每次运行都固定打印结果行到 stdout，本包装将其丢弃，
 *       正确性由外部校验步骤 (三路输出逐字节对比) 保证。
 */
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <sys/wait.h>
#include <fcntl.h>
#include <time.h>

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
    if (argc < 3) {
        fprintf(stderr, "usage: %s <executable> <runs>\n", argv[0]);
        return 1;
    }
    const char *exe = argv[1];
    int runs = atoi(argv[2]);
    int devnull = open("/dev/null", O_WRONLY);

    for (int r = 1; r <= runs; r++) {
        double t0 = now_ms();
        pid_t pid = fork();
        if (pid == 0) {
            dup2(devnull, STDOUT_FILENO);
            execl(exe, exe, (char *)NULL);
            _exit(127);
        }
        int st;
        waitpid(pid, &st, 0);
        if (!WIFEXITED(st) || WEXITSTATUS(st) != 0) {
            fprintf(stderr, "child %d failed\n", r);
            return 1;
        }
        printf("RUN %d %.3f\n", r, now_ms() - t0);
        fflush(stdout);
    }
    return 0;
}

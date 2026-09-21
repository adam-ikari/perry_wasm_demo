/*
 * bench_exec_wrap.c — 通用进程级 fork/exec 计时包装 (F 路 QuickJS 等单次执行、
 * 需 argv 的程序)。仿 tools/attribution/bench_perry_wrap.c:
 * 重复 fork/exec <exe> [argv...]，CLOCK_MONOTONIC 量整个进程生命周期 (含启动)。
 * 用法: bench_exec_wrap <exe> <arg1> [arg2...] <runs>
 * 输出: RUN i <ms> 行。
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
    if (argc < 4) {
        fprintf(stderr, "usage: %s <exe> <arg...> <runs>\n", argv[0]);
        return 1;
    }
    const char *exe = argv[1];
    int runs = atoi(argv[argc - 1]);
    int devnull = open("/dev/null", O_WRONLY);

    for (int r = 1; r <= runs; r++) {
        double t0 = now_ms();
        pid_t pid = fork();
        if (pid == 0) {
            dup2(devnull, STDOUT_FILENO);
            /* argv: [exe, arg1..argN, runs] — 去掉最后一个 runs */
            char **args = malloc(sizeof(char *) * (size_t)(argc - 1));
            int n = 0;
            for (int i = 1; i < argc - 1; i++)
                args[n++] = argv[i];
            args[n] = NULL;
            execv(exe, args);
            _exit(127);
        }
        int st;
        waitpid(pid, &st, 0);
        if (!WIFEXITED(st) || WEXITSTATUS(st) != 0) {
            fprintf(stderr, "child %d failed (status %d)\n", r, st);
            return 1;
        }
        printf("RUN %d %.3f\n", r, now_ms() - t0);
        fflush(stdout);
    }
    return 0;
}

/* 审计实验: fib 入口计数器, 实证递归执行次数 */
#include <stdio.h>
static long volatile count;
static long fib(long n) { count++; return n < 2 ? n : fib(n - 1) + fib(n - 2); }
int main(void) { long f = fib(29); printf("fib(29)=%ld calls=%ld\n", f, count); return 0; }

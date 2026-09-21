/* f64 版 C 基线: 与 perry wasm 的 f64 NaN-box 语义同型 (i64 -> double) */
#include <stdio.h>
#include <time.h>
static const double n_fib = 29;
static volatile const double *const p_fib = &n_fib;
static double fibd(double n) { return n < 2.0 ? n : fibd(n - 1.0) + fibd(n - 2.0); }
static double now_ms(void){struct timespec ts;clock_gettime(CLOCK_MONOTONIC,&ts);return ts.tv_sec*1000.0+ts.tv_nsec/1000000.0;}
int main(void){
  for(int r=1;r<=11;r++){
    double t0=now_ms(), f=fibd(*p_fib), s=0.0;
    for(long i=0;i<1000000L;i++) s+=(double)i;
    double t1=now_ms();
    printf("RUN %d %.3f  fib=%.0f sum=%.0f\n", r, t1-t0, f, s);
  }
  return 0;
}

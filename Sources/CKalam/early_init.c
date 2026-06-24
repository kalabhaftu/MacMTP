// early_init.c
// macMTP
//
// Runs at constructor priority 101, before Go runtime initializes at ~65536.
// Blocks fatal signals that Go's runtime mishandles in CGo contexts.

#include <signal.h>
#include <stddef.h>

__attribute__((constructor(101)))
static void early_signal_setup(void) {
    struct sigaction sa;
    sigemptyset(&sa.sa_mask);
    sa.sa_flags = 0;

    // Block SIGURG — Go 1.14+ uses this for goroutine preemption.
    // When async preemption fires during a CGo callback on a non-Go thread,
    // Go's sighandler panics and calls dieFromSignal -> abort().
    sa.sa_handler = SIG_IGN;
    sigaction(SIGURG, &sa, NULL);

    // Block SIGPIPE — fatal in CGo/libusb on device disconnect.
    sigaction(SIGPIPE, &sa, NULL);

    // Block SIGQUIT — occasionally delivered at CGo startup on macOS.
    sigaction(SIGQUIT, &sa, NULL);

    // Block SIGIO, SIGPROF — can also trigger spurious dieFromSignal.
    sigaction(SIGIO, &sa, NULL);
    sigaction(SIGPROF, &sa, NULL);
}

// daemon.mm - PID file management, signal handling, and event loop
#import "daemon.h"
#import <Foundation/Foundation.h>
#import <signal.h>
#import <stdio.h>
#import <stdlib.h>
#import <string.h>
#import <unistd.h>
#import <errno.h>

static volatile sig_atomic_t sKeepRunning = 1;

static void signalHandler(int sig) {
    (void)sig;
    sKeepRunning = 0;
}

bool writePIDFile(void) {
    FILE *f = fopen(PID_FILE_PATH, "w");
    if (!f) {
        fprintf(stderr, "error: cannot write PID file %s: %s\n",
                PID_FILE_PATH, strerror(errno));
        return false;
    }
    fprintf(f, "%d\n", getpid());
    fclose(f);
    return true;
}

bool removePIDFile(void) {
    if (unlink(PID_FILE_PATH) != 0 && errno != ENOENT) {
        fprintf(stderr, "warning: cannot remove PID file %s: %s\n",
                PID_FILE_PATH, strerror(errno));
        return false;
    }
    return true;
}

bool isAlreadyRunning(pid_t *existingPID) {
    FILE *f = fopen(PID_FILE_PATH, "r");
    if (!f) return false;

    pid_t pid = 0;
    if (fscanf(f, "%d", &pid) != 1 || pid <= 0) {
        fclose(f);
        return false;
    }
    fclose(f);

    // Check if the process is still alive
    if (kill(pid, 0) == 0) {
        if (existingPID) *existingPID = pid;
        return true;
    }

    // Stale PID file, clean it up
    removePIDFile();
    return false;
}

bool stopRunningDaemon(void) {
    pid_t pid = 0;
    if (!isAlreadyRunning(&pid)) {
        fprintf(stderr, "force-hidpi: no running instance found\n");
        return false;
    }

    fprintf(stdout, "force-hidpi: sending SIGTERM to pid %d\n", pid);
    if (kill(pid, SIGTERM) != 0) {
        fprintf(stderr, "error: failed to send SIGTERM to pid %d: %s\n",
                pid, strerror(errno));
        return false;
    }

    // Wait up to 5 seconds for the process to exit
    for (int i = 0; i < 10; i++) {
        usleep(500000);
        if (kill(pid, 0) != 0) {
            fprintf(stdout, "force-hidpi: stopped (pid %d)\n", pid);
            removePIDFile();
            return true;
        }
    }

    fprintf(stderr, "warning: pid %d did not exit within 5 seconds\n", pid);
    return false;
}

void installSignalHandlers(void) {
    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_handler = signalHandler;
    sigemptyset(&sa.sa_mask);
    sa.sa_flags = 0;

    sigaction(SIGINT, &sa, NULL);
    sigaction(SIGTERM, &sa, NULL);
}

bool shouldKeepRunning(void) {
    return sKeepRunning != 0;
}

void runEventLoop(void) {
    @autoreleasepool {
        while (sKeepRunning) {
            @autoreleasepool {
                [[NSRunLoop currentRunLoop] runUntilDate:
                    [NSDate dateWithTimeIntervalSinceNow:1.0]];
            }
        }
    }
}

// daemon.h - Background daemon and signal handling for force-hidpi
#ifndef DAEMON_H
#define DAEMON_H

#import <stdbool.h>
#import <sys/types.h>

#define PID_FILE_PATH "/tmp/force-hidpi.pid"

bool writePIDFile(void);
bool removePIDFile(void);
bool isAlreadyRunning(pid_t *existingPID);
bool stopRunningDaemon(void);
void installSignalHandlers(void);
bool shouldKeepRunning(void);
void runEventLoop(void);

#endif // DAEMON_H

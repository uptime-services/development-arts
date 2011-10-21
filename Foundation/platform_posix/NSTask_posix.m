/* Copyright (c) 2006-2007 Christopher J. W. Lloyd

Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE. */

// Original - David Young <daver@geeks.org>
#import <Foundation/NSTask_posix.h>
#import <Foundation/NSRunLoop-InputSource.h>
#import <Foundation/NSPlatform_posix.h>
#import <Foundation/NSFileHandle_posix.h>
#import <Foundation/NSProcessInfo.h>
#import <Foundation/Foundation.h>
#import <Foundation/NSRaiseException.h>

#include <unistd.h>
#include <sys/ioctl.h>
#include <sys/types.h>
#include <sys/resource.h>
#include <sys/wait.h>
#include <signal.h>
#include <errno.h>

static NSMutableArray *_liveTasks = nil;

@implementation NSTask_posix

void childSignalHandler(int sig) {
    if (sig == SIGCHLD) {
        NSTask_posix *task;
        pid_t pid;
        int status;

        pid = wait3(&status, WNOHANG, NULL);
        
        if (pid < 0) {
            NSCLog("Invalid wait4 result [%s] in child signal handler", strerror(errno));
        }
        else if (pid == 0) {
            // This can happen when a child is suspended (^Z'ing at the shell)
            // something got out of synch here
            // [NSException raise:NSInternalInconsistencyException format:@"wait4() returned 0, but data was fed to the pipe!"];
        }
        else {
            @synchronized(_liveTasks) {
                NSEnumerator *taskEnumerator = [_liveTasks objectEnumerator];
                while (task = [taskEnumerator nextObject]) {
                    if ([task processIdentifier] == pid) {
                        if (WIFEXITED(status))
                            [task setTerminationStatus:WEXITSTATUS(status)];
                        else
                            [task setTerminationStatus:-1];
                        
                        [task retain];
                        [task taskFinished];
                        
                        [[NSNotificationCenter defaultCenter] postNotification:[NSNotification notificationWithName:NSTaskDidTerminateNotification object:task]];
                        [task release];
                        
                        return;
                    }
                }
            }
            
            // something got out of synch here
            //[NSException raise:NSInternalInconsistencyException format:@"wait4() returned %d, but we have no matching task!", pid];
        }
    }
}

+(void)initialize {
    if (self == [NSTask_posix class]) {
        _liveTasks=[[NSMutableArray alloc] init];

        struct sigaction sa;        
        sigaction (SIGCHLD, (struct sigaction *)0, &sa);
        sa.sa_flags |= SA_RESTART;
        sa.sa_handler = childSignalHandler;
        sigaction (SIGCHLD, &sa, (struct sigaction *)0);
    }
}

-(int)processIdentifier {
   return _processID;
}

-(void)launch {
    if (isRunning) {
        [NSException raise:NSInvalidArgumentException
                    format:@"NSTask already launched"];   
    }
    
    if (launchPath==nil)
        [NSException raise:NSInvalidArgumentException
                    format:@"NSTask launchPath is nil"];
    
    NSArray *array       = arguments;
    NSInteger            i,count=[array count];
    const char          *args[count+2];
    const char          *path = [launchPath fileSystemRepresentation];
    
    if (array == nil)
        array = [NSArray array];

    args[0]=path;
    for(i=0;i<count;i++)
        args[i+1]=(char *)[[[array objectAtIndex:i] description] cString];
    args[count+1]=NULL;
    
    NSDictionary *env;
    if(environment == nil) {
        env = [[NSProcessInfo processInfo] environment];
    }
    else {
        env = environment;
    }
    const char *cenv[[env count] + 1];
    
    NSString *key;
    i = 0;
    
    for (key in env) {
        id          value = [env objectForKey:key];
        NSString    *entry;
        if (value) {
            entry = [NSString stringWithFormat:@"%@=%@", key, value];
        }
        else {
            entry = [NSString stringWithFormat:@"%@=", key];
        }      
        
        cenv[i] = [entry cString];
        i++;
    }
    
    cenv[[env count]] = NULL;    
    
    _processID = fork(); 
    if (_processID == 0) {  // child process               
        if ([standardInput isKindOfClass:[NSFileHandle class]] || [standardInput isKindOfClass:[NSPipe class]]) {
            int fd = -1;

            if ([standardInput isKindOfClass:[NSFileHandle class]])
                fd = [(NSFileHandle_posix *)standardInput fileDescriptor];
            else
                fd = [(NSFileHandle_posix *)[standardInput fileHandleForReading] fileDescriptor];
            dup2(fd, STDIN_FILENO);
        }
        else {
            close(STDIN_FILENO);
        }
        if ([standardOutput isKindOfClass:[NSFileHandle class]] || [standardOutput isKindOfClass:[NSPipe class]]) {
            int fd = -1;

            if ([standardOutput isKindOfClass:[NSFileHandle class]])
                fd = [(NSFileHandle_posix *)standardOutput fileDescriptor];
            else
                fd = [(NSFileHandle_posix *)[standardOutput fileHandleForWriting] fileDescriptor];
            
            dup2(fd, STDOUT_FILENO);
        }
        else {
            close(STDOUT_FILENO);
        }
        if ([standardError isKindOfClass:[NSFileHandle class]] || [standardError isKindOfClass:[NSPipe class]]) {
            int fd = -1;

            if ([standardError isKindOfClass:[NSFileHandle class]])
                fd = [(NSFileHandle_posix *)standardError fileDescriptor];
            else
                fd = [(NSFileHandle_posix *)[standardError fileHandleForWriting] fileDescriptor];
            dup2(fd, STDERR_FILENO);
        }
        else {
            close(STDERR_FILENO);
        }
        
        for (i = 3; i < getdtablesize(); i++) {
            close(i);
        }
        
        chdir([currentDirectoryPath fileSystemRepresentation]);
               
        execve(path, (char**)args, (char**)cenv);
        [NSException raise:NSInvalidArgumentException
                    format:@"NSTask: execve(%s) returned: %s", path, strerror(errno)];
    }
    else if (_processID != -1) {
        
        isRunning = YES;
        
        @synchronized(_liveTasks) {
            [_liveTasks addObject:self];
        }
        
        if([standardInput isKindOfClass:[NSPipe class]])
            [[standardInput fileHandleForReading] closeFile];
        if([standardOutput isKindOfClass:[NSPipe class]])
            [[standardOutput fileHandleForWriting] closeFile];
        if([standardError isKindOfClass:[NSPipe class]])
            [[standardError fileHandleForWriting] closeFile];
        
    }
    else
        [NSException raise:NSInvalidArgumentException
                    format:@"fork() failed: %s", strerror(errno)];
}

-(void)terminate {
   kill(_processID, SIGTERM);
    @synchronized(_liveTasks) {
        [_liveTasks removeObject:self];
    }
}

-(int)terminationStatus { return _terminationStatus; }			// OSX specs this
-(void)setTerminationStatus:(int)terminationStatus { _terminationStatus = terminationStatus; }

-(void)taskFinished {    
   isRunning = NO;
    @synchronized(_liveTasks) {
        [_liveTasks removeObject:self];
    }
}

@end

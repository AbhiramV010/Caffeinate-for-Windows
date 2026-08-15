// windows version of caffeinate, just keeps the machine from dozing off
#include <windows.h>
#include <cstdio>
#include <cstdlib>
#include <string>
#include <vector>

static EXECUTION_STATE g_flags = ES_CONTINUOUS;
static volatile bool g_running = true;
static volatile bool g_userActive = false;

static void printUsage() {
    printf("Usage: caffeinate [-disu] [-t seconds] [-w pid] [command [args ...]]\n");
    printf("  -d  prevent the display from sleeping\n");
    printf("  -i  prevent the system from idle sleeping\n");
    printf("  -s  prevent the system from sleeping\n");
    printf("  -u  declare that the user is active\n");
    printf("  -t  time to assert, in seconds\n");
    printf("  -w  wait for the process with this pid to exit\n");
}

// pokes windows every minute so it never thinks we went idle
static DWORD WINAPI userActivityThread(LPVOID) {
    while (g_running) {
        SetThreadExecutionState(g_flags | ES_USER_PRESENT);
        Sleep(60000);
    }
    return 0;
}

static BOOL WINAPI ctrlHandler(DWORD) {
    g_running = false;
    SetThreadExecutionState(ES_CONTINUOUS);
    return FALSE;
}

int main(int argc, char** argv) {
    bool wantDisplay = false, wantIdle = false, wantSystem = false;
    long timeoutSecs = -1;
    DWORD waitPid = 0;
    int cmdStart = -1;

    for (int i = 1; i < argc; i++) {
        std::string a = argv[i];
        if (a == "-t") {
            if (i + 1 >= argc) { printUsage(); return 1; }
            timeoutSecs = atol(argv[++i]);
        } else if (a == "-w") {
            if (i + 1 >= argc) { printUsage(); return 1; }
            waitPid = (DWORD)atol(argv[++i]);
        } else if (a.size() >= 2 && a[0] == '-') {
            for (size_t j = 1; j < a.size(); j++) {
                switch (a[j]) {
                    case 'd': wantDisplay = true; break;
                    case 'i': wantIdle = true; break;
                    case 's': wantSystem = true; break;
                    case 'u': g_userActive = true; break;
                    default: printUsage(); return 1;
                }
            }
        } else {
            cmdStart = i;
            break;
        }
    }

    // nothing passed in? default to -i, same as the real caffeinate does
    if (!wantDisplay && !wantIdle && !wantSystem) wantIdle = true;

    g_flags = ES_CONTINUOUS;
    if (wantDisplay) g_flags |= ES_DISPLAY_REQUIRED;
    if (wantIdle || wantSystem) g_flags |= ES_SYSTEM_REQUIRED;

    SetConsoleCtrlHandler(ctrlHandler, TRUE);
    SetThreadExecutionState(g_flags);

    HANDLE userThread = NULL;
    if (g_userActive) {
        userThread = CreateThread(NULL, 0, userActivityThread, NULL, 0, NULL);
    }

    HANDLE targetProcess = NULL;
    PROCESS_INFORMATION pi = {};
    bool ownsProcess = false;

    if (cmdStart != -1) {
        std::string cmdLine;
        for (int i = cmdStart; i < argc; i++) {
            if (i > cmdStart) cmdLine += " ";
            cmdLine += argv[i];
        }
        STARTUPINFOA si = { sizeof(si) };
        std::vector<char> buf(cmdLine.begin(), cmdLine.end());
        buf.push_back('\0');
        if (!CreateProcessA(NULL, buf.data(), NULL, NULL, TRUE, 0, NULL, NULL, &si, &pi)) {
            fprintf(stderr, "caffeinate: failed to launch command (%lu)\n", GetLastError());
            SetThreadExecutionState(ES_CONTINUOUS);
            return 1;
        }
        targetProcess = pi.hProcess;
        ownsProcess = true;
    } else if (waitPid != 0) {
        targetProcess = OpenProcess(SYNCHRONIZE, FALSE, waitPid);
        if (!targetProcess) {
            fprintf(stderr, "caffeinate: no such process %lu\n", waitPid);
            SetThreadExecutionState(ES_CONTINUOUS);
            return 1;
        }
    }

    DWORD waitMs = (timeoutSecs >= 0) ? (DWORD)(timeoutSecs * 1000) : INFINITE;

    if (targetProcess) {
        WaitForSingleObject(targetProcess, waitMs);
        if (ownsProcess) {
            CloseHandle(pi.hThread);
            CloseHandle(pi.hProcess);
        } else {
            CloseHandle(targetProcess);
        }
    } else if (timeoutSecs >= 0) {
        Sleep(waitMs);
    } else {
        // no command, no pid, so just sit here until someone hits ctrl+c
        while (g_running) Sleep(1000);
    }

    g_running = false;
    if (userThread) {
        WaitForSingleObject(userThread, 2000);
        CloseHandle(userThread);
    }
    SetThreadExecutionState(ES_CONTINUOUS);
    return 0;
}

#define _GNU_SOURCE

#include <unistd.h>
#include <fcntl.h>
#include <grp.h>
#include <pwd.h>
#include <sched.h>
#include <stdio.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/wait.h>
#include <stdarg.h>
#include <stdlib.h>
#include <string.h>
#include <signal.h>
#include <sys/prctl.h>

#define DEBUG

#ifdef DEBUG
#  define dprintf printf
#else
#  define dprintf
#endif

char* SUBSHELL = "./subshell";


// * * * * * * * * * * * * * * * * * File I/O * * * * * * * * * * * * * * * * *

#define CHUNK_SIZE 1024

int read_file(const char* file, char* buffer, int max_length) {
  int f = open(file, O_RDONLY);
  if (f == -1)
    return -1;
  int bytes_read = 0;
  while (1) {
    int bytes_to_read = CHUNK_SIZE;
    if (bytes_to_read > max_length - bytes_read)
      bytes_to_read = max_length - bytes_read;
    int rv = read(f, &buffer[bytes_read], bytes_to_read);
    if (rv == -1)
      return -1;
    bytes_read += rv;
    if (rv == 0)
      return bytes_read;
  }
}

static int write_file(const char* file, const char* what, ...) {
  char buf[1024];
  va_list args;
  va_start(args, what);
  vsnprintf(buf, sizeof(buf), what, args);
  va_end(args);
  buf[sizeof(buf) - 1] = 0;
  int len = strlen(buf);

  int fd = open(file, O_WRONLY | O_CLOEXEC);
  if (fd == -1)
    return -1;
  if (write(fd, buf, len) != len) {
    close(fd);
    return -1;
  }
  close(fd);
  return 0;
}


// * * * * * * * * * * * * * * * * * Map * * * * * * * * * * * * * * * * *

int get_subuid(char* output, int max_length) {
  char buffer[1024];
  char* path = "/etc/subuid";
  int length = read_file(path, &buffer[0], sizeof(buffer));
  if (length == -1)
    return -1;

  int real_uid = getuid();
  struct passwd *u = getpwuid(real_uid);

  char needle[1024];
  sprintf(needle, "%s:", u->pw_name);
  int needle_length = strlen(needle);
  char* found = memmem(&buffer[0], length, needle, needle_length);
  if (found == NULL)
    return -1;

  int i;
  for (i = 0; found[needle_length + i] != ':'; i++) {
    if (i >= max_length)
      return -1;
    if ((found - &buffer[0]) + needle_length + i >= length)
      return -1;
    output[i] = found[needle_length + i];
  }

  return 0;
}

int get_subgid(char* output, int max_length) {
  char buffer[1024];
  char* path = "/etc/subgid";
  int length = read_file(path, &buffer[0], sizeof(buffer));
  if (length == -1)
    return -1;

  int real_gid = getgid();
  struct group *g = getgrgid(real_gid);

  char needle[1024];
  sprintf(needle, "%s:", g->gr_name);
  int needle_length = strlen(needle);
  char* found = memmem(&buffer[0], length, needle, needle_length);
  if (found == NULL)
    return -1;

  int i;
  for (i = 0; found[needle_length + i] != ':'; i++) {
    if (i >= max_length)
      return -1;
    if ((found - &buffer[0]) + needle_length + i >= length)
      return -1;
    output[i] = found[needle_length + i];
  }

  return 0;
}


// * * * * * * * * * * * * * * * * * Main * * * * * * * * * * * * * * * * *

int main(int argc, char** argv) {
  if (argc > 1) SUBSHELL = argv[1];

  dprintf("[.] starting\n");

  dprintf("[.] setting up namespace\n");

  int sync_pipe[2];
  char dummy;

  if (socketpair(AF_UNIX, SOCK_STREAM, 0, sync_pipe)) {
    dprintf("[-] pipe\n");
    exit(EXIT_FAILURE);
  }

  pid_t child = fork();

  if (child == -1) {
    dprintf("[-] fork");
    exit(EXIT_FAILURE);
  }

  if (child == 0) {
    prctl(PR_SET_PDEATHSIG, SIGKILL);
    close(sync_pipe[1]);

    if (unshare(CLONE_NEWUSER) != 0) {
      dprintf("[-] unshare(CLONE_NEWUSER)\n");
      exit(EXIT_FAILURE);
    }

    if (unshare(CLONE_NEWNET) != 0) {
      dprintf("[-] unshare(CLONE_NEWNET)\n");
      exit(EXIT_FAILURE);
    }

    if (write(sync_pipe[0], "X", 1) != 1) {
      dprintf("write to sock\n");
      exit(EXIT_FAILURE);
    }

    if (read(sync_pipe[0], &dummy, 1) != 1) {
      dprintf("[-] read from sock\n");
      exit(EXIT_FAILURE);
    }

    if (setgid(0)) {
      dprintf("[-] setgid");
      exit(EXIT_FAILURE);
    }

    if (setuid(0)) {
      printf("[-] setuid");
      exit(EXIT_FAILURE);
    }

    execl(SUBSHELL, "", NULL);

    dprintf("[-] executing subshell failed\n");
  }

  close(sync_pipe[0]);

  if (read(sync_pipe[1], &dummy, 1) != 1) {
    dprintf("[-] read from sock\n");
    exit(EXIT_FAILURE);
  }

  char path[256];
  sprintf(path, "/proc/%d/setgroups", (int)child);

  if (write_file(path, "deny") == -1) {
    dprintf("[-] denying setgroups failed\n");
    exit(EXIT_FAILURE);
  }

  dprintf("[~] done, namespace sandbox set up\n");

  dprintf("[.] mapping subordinate ids\n");
  char subuid[64];
  char subgid[64];

  if (get_subuid(&subuid[0], sizeof(subuid))) {
    dprintf("[-] couldn't find subuid map in /etc/subuid\n");
    exit(EXIT_FAILURE);
  }

  if (get_subgid(&subgid[0], sizeof(subgid))) {
    dprintf("[-] couldn't find subgid map in /etc/subgid\n");
    exit(EXIT_FAILURE);
  }

  dprintf("[.] subuid: %s\n", subuid);
  dprintf("[.] subgid: %s\n", subgid);

  char cmd[256];

  sprintf(cmd, "newuidmap %d 0 %s 1000", (int)child, subuid);
  if (system(cmd))  {
    dprintf("[-] newuidmap failed");
    exit(EXIT_FAILURE);
  }

  sprintf(cmd, "newgidmap %d 0 %s 1000", (int)child, subgid);
  if (system(cmd)) {
    dprintf("[-] newgidmap failed");
    exit(EXIT_FAILURE);
  }

  dprintf("[~] done, mapped subordinate ids\n");

  dprintf("[.] executing subshell\n");

  if (write(sync_pipe[1], "X", 1) != 1) {
    dprintf("[-] write to sock");
    exit(EXIT_FAILURE);
  }

  int status;
  if (wait(&status) != child) {
    dprintf("[-] wait");
    exit(EXIT_FAILURE);
  }

  return 0;
}
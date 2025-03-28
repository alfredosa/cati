#include <errno.h>
#include <fcntl.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/select.h>
#include <sys/time.h>
#include <termios.h>
#include <unistd.h>

bool detect_kitty_graphics_protocol() {
  struct termios old_term, new_term;
  bool supports_kitty = false;
  unsigned char buf[256] = {0};
  int total_read = 0;
  int result;

  // Save current terminal settings
  if (tcgetattr(STDIN_FILENO, &old_term) < 0) {
    perror("tcgetattr");
    return false;
  }

  // Set terminal to raw mode (minimal changes)
  new_term = old_term;
  new_term.c_lflag &= ~(ICANON | ECHO);
  new_term.c_cc[VMIN] = 0;
  new_term.c_cc[VTIME] = 1; // 0.1 second timeout

  if (tcsetattr(STDIN_FILENO, TCSANOW, &new_term) < 0) {
    perror("tcsetattr");
    return false;
  }

  // Set stdin to non-blocking mode
  int flags = fcntl(STDIN_FILENO, F_GETFL, 0);
  fcntl(STDIN_FILENO, F_SETFL, flags | O_NONBLOCK);

  // Send query sequence for Kitty graphics protocol
  write(STDOUT_FILENO, "\x1B_Gi=31,s=1,v=1,a=q,t=d,f=24;AAAA\x1B\\", 36);
  fflush(stdout);

  // Set up timeout with select
  fd_set readfds;
  struct timeval timeout;
  timeout.tv_sec = 0;
  timeout.tv_usec = 500000; // 500ms timeout

  FD_ZERO(&readfds);
  FD_SET(STDIN_FILENO, &readfds);

  // Continue reading until timeout or buffer full
  while ((result = select(STDIN_FILENO + 1, &readfds, NULL, NULL, &timeout)) >
         0) {
    int bytes_read =
        read(STDIN_FILENO, buf + total_read, sizeof(buf) - total_read - 1);

    if (bytes_read <= 0) {
      if (errno == EAGAIN || errno == EWOULDBLOCK) {
        // No data available right now, wait a bit more
        printf("currently retrying as input is blocked");
        usleep(10000); // 10ms
        continue;
      }
      break;
    }

    total_read += bytes_read;

    // Search for protocol markers without using string functions
    bool found_marker = false;
    for (int i = 0; i < total_read - 3; i++) {
      // Check for _Gi pattern
      if (buf[i] == '_' && buf[i + 1] == 'G' && buf[i + 2] == 'i') {
        supports_kitty = true;
        found_marker = true;
        break;
      }
    }

    // Display hex values of all bytes received (truncate if too many)
    printf("Read %d bytes. Raw data in hex:", total_read);
    int display_limit = (total_read > 32) ? 32 : total_read;
    for (int i = 0; i < display_limit; i++) {
      printf(" %02X", buf[i]);
    }
    if (total_read > display_limit) {
      printf(" ...");
    }
    printf("\n");

    if (found_marker) {
      break;
    }

    // If buffer is full or we've got a complete response
    if (total_read >= sizeof(buf) - 1) {
      break;
    }

    // Reset the fd_set and timeout for the next iteration
    FD_ZERO(&readfds);
    FD_SET(STDIN_FILENO, &readfds);
    timeout.tv_sec = 0;
    timeout.tv_usec = 50000; // Shorter timeout for subsequent reads
  }

  // Drain any remaining input before restoring terminal
  while (read(STDIN_FILENO, buf, sizeof(buf)) > 0) {
    // Just discard the data
  }

  // Restore terminal settings
  tcsetattr(STDIN_FILENO, TCSANOW, &old_term);
  fcntl(STDIN_FILENO, F_SETFL, flags); // Restore original flags

  return supports_kitty;
}

int main() {
  bool has_kitty = detect_kitty_graphics_protocol();

  if (has_kitty) {
    printf("Terminal supports Kitty graphics protocol!\n");
  } else {
    printf("Terminal does not support Kitty graphics protocol.\n");
  }

  return 0;
}

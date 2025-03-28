#include <errno.h>
#include <fcntl.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/select.h>
#include <sys/time.h>
#include <termios.h>
#include <unistd.h>

struct winsize query_window_size() {
  struct winsize w;
  if (ioctl(0, TIOCGWINSZ, &w) != 0) {
    printf("failed to query window size \n");
    return w;
  }

  printf("number of rows: %i, number of columns: %i, screen width: %i, screen "
         "height: %i\n",
         w.ws_row, w.ws_col, w.ws_xpixel, w.ws_ypixel);

  return w;
}

int print_png(char *payload) { return 0; }

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
  }

  // Restore terminal settings
  tcsetattr(STDIN_FILENO, TCSANOW, &old_term);
  fcntl(STDIN_FILENO, F_SETFL, flags); // Restore original flags

  return supports_kitty;
}

// Base64 encoding function
static char base64_table[] =
    "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

size_t base64_encode(const unsigned char *data, size_t input_length,
                     char *encoded_data) {
  size_t output_length = 4 * ((input_length + 2) / 3);

  for (size_t i = 0, j = 0; i < input_length;) {
    uint32_t octet_a = i < input_length ? data[i++] : 0;
    uint32_t octet_b = i < input_length ? data[i++] : 0;
    uint32_t octet_c = i < input_length ? data[i++] : 0;

    uint32_t triple = (octet_a << 16) + (octet_b << 8) + octet_c;

    encoded_data[j++] = base64_table[(triple >> 18) & 0x3F];
    encoded_data[j++] = base64_table[(triple >> 12) & 0x3F];
    encoded_data[j++] = base64_table[(triple >> 6) & 0x3F];
    encoded_data[j++] = base64_table[triple & 0x3F];
  }

  // Add padding if necessary
  size_t mod_table[] = {0, 2, 1};
  for (size_t i = 0; i < mod_table[input_length % 3]; i++)
    encoded_data[output_length - 1 - i] = '=';

  return output_length;
}

// Function to serialize graphics command
void serialize_gr_command(FILE *output, const char *cmd,
                          const unsigned char *payload, size_t payload_size) {
  fprintf(output, "\033_G%s", cmd);

  if (payload && payload_size > 0) {
    fputc(';', output);
    fwrite(payload, 1, payload_size, output);
  }

  fprintf(output, "\033\\");
  fflush(output);
}

// Function to write chunked data
void write_chunked(FILE *output, const unsigned char *data, size_t data_size,
                   const char *params) {
  // Calculate base64 encoded size
  size_t encoded_size = 4 * ((data_size + 2) / 3);
  char *encoded_data = (char *)malloc(encoded_size + 1);
  if (!encoded_data) {
    perror("Memory allocation failed");
    return;
  }

  base64_encode(data, data_size, encoded_data);
  encoded_data[encoded_size] = '\0';

  size_t offset = 0;
  const size_t chunk_size = 4096;
  char cmd_buffer[4096];

  while (offset < encoded_size) {
    size_t remaining = encoded_size - offset;
    size_t current_chunk = remaining > chunk_size ? chunk_size : remaining;
    int more = (offset + current_chunk < encoded_size) ? 1 : 0;

    if (offset == 0) {
      snprintf(cmd_buffer, sizeof(cmd_buffer), "%s,m=%d", params, more);
    } else {
      snprintf(cmd_buffer, sizeof(cmd_buffer), "m=%d", more);
    }

    serialize_gr_command(output, cmd_buffer,
                         (unsigned char *)encoded_data + offset, current_chunk);
    offset += current_chunk;
  }

  free(encoded_data);
}

int main(int argc, char *argv[]) {
  if (argc < 2) {
    fprintf(stderr, "Usage: %s <filename>\n", argv[0]);
    return 1;
  }

  bool has_kitty = detect_kitty_graphics_protocol();
  struct winsize s = query_window_size();

  if (has_kitty) {
    printf("Terminal supports Kitty graphics protocol!\n");
  } else {
    printf("Terminal does not support Kitty graphics protocol.\n");
    return 1;
  }

  for (int i = 1; i < argc; i++) {

    FILE *file = fopen(argv[i], "rb");
    if (!file) {
      perror("Failed to open file");
      return 1;
    }

    // Get file size
    fseek(file, 0, SEEK_END);
    long file_size = ftell(file);
    fseek(file, 0, SEEK_SET);

    // Read file content
    unsigned char *file_data = (unsigned char *)malloc(file_size);
    if (!file_data) {
      perror("Memory allocation failed");
      fclose(file);
      return 1;
    }

    if (fread(file_data, 1, file_size, file) != (size_t)file_size) {
      perror("Failed to read file");
      free(file_data);
      fclose(file);
      return 1;
    }

    // Write chunked data
    write_chunked(stdout, file_data, file_size, "a=T,f=100");

    // Clean up
    free(file_data);
    fclose(file);
  }

  return 0;
}

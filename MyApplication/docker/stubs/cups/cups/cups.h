/* Stub cups/cups.h for headless cross-compilation */
#ifndef _CUPS_CUPS_H_
#define _CUPS_CUPS_H_

typedef void *http_t;
typedef int ipp_status_t;

#define HTTP_ENCRYPT_IF_REQUESTED 0
#define CUPS_PRINTER_CLASS 0

typedef struct {
    char *name;
    char *instance;
    int is_default;
    int num_options;
    void *options;
} cups_dest_t;

typedef struct {
    char *name;
    char *value;
} cups_option_t;

#endif /* _CUPS_CUPS_H_ */

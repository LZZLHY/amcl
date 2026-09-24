/* Stub cups/ppd.h for headless cross-compilation */
#ifndef _CUPS_PPD_H_
#define _CUPS_PPD_H_

typedef struct {
    int marked;
    char choice[41];
    char text[81];
} ppd_choice_t;

typedef struct {
    char keyword[41];
    int num_choices;
    ppd_choice_t *choices;
    ppd_choice_t *defchoice;
} ppd_option_t;

typedef struct {
    int marked;
    char name[41];
    float width;
    float length;
    float left;
    float bottom;
    float right;
    float top;
} ppd_size_t;

typedef struct {
    int num_sizes;
    ppd_size_t *sizes;
    /* minimal fields needed */
} ppd_file_t;

#endif /* _CUPS_PPD_H_ */

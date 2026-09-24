/* Stub fontconfig/fontconfig.h for headless cross-compilation */
#ifndef _FONTCONFIG_H_
#define _FONTCONFIG_H_

typedef int FcBool;
typedef unsigned char FcChar8;
typedef unsigned short FcChar16;
typedef unsigned int FcChar32;

typedef struct _FcConfig FcConfig;
typedef struct _FcPattern FcPattern;
typedef struct _FcCharSet FcCharSet;
typedef struct _FcObjectSet FcObjectSet;
typedef struct _FcFontSet FcFontSet;
typedef struct _FcLangSet FcLangSet;
typedef struct _FcStrList FcStrList;
typedef struct _FcStrSet FcStrSet;
typedef struct _FcValue FcValue;
typedef struct _FcBlanks FcBlanks;
typedef struct _FcMatrix FcMatrix;
typedef struct _FcRange FcRange;
typedef struct _FcCache FcCache;

typedef enum {
    FcResultMatch,
    FcResultNoMatch,
    FcResultTypeMismatch,
    FcResultNoId,
    FcResultOutOfMemory
} FcResult;

typedef enum {
    FcMatchPattern,
    FcMatchFont,
    FcMatchScan
} FcMatchKind;

typedef enum {
    FcTypeUnknown = -1,
    FcTypeVoid,
    FcTypeInteger,
    FcTypeDouble,
    FcTypeString,
    FcTypeBool,
    FcTypeMatrix,
    FcTypeCharSet,
    FcTypeFTFace,
    FcTypeLangSet,
    FcTypeRange
} FcType;

typedef enum {
    FcLangEqual = 0,
    FcLangDifferentCountry = 1,
    FcLangDifferentLang = 2
} FcLangResult;

typedef enum {
    FcSetSystem = 0,
    FcSetApplication = 1
} FcSetName;

struct _FcFontSet {
    int nfont;
    int sfont;
    FcPattern **fonts;
};

struct _FcObjectSet {
    int nobject;
    int sobject;
    const char **objects;
};

struct _FcMatrix {
    double xx, xy, yx, yy;
};

struct _FcValue {
    FcType type;
    union {
        const FcChar8 *s;
        int i;
        FcBool b;
        double d;
        const FcMatrix *m;
        const FcCharSet *c;
        void *f;
        const FcLangSet *l;
        const FcRange *r;
    } u;
};

#define FcTrue 1
#define FcFalse 0

/* Property names */
#define FC_FAMILY "family"
#define FC_STYLE "style"
#define FC_FILE "file"
#define FC_SPACING "spacing"
#define FC_FULLNAME "fullname"
#define FC_CHARSET "charset"
#define FC_FONTFORMAT "fontformat"
#define FC_LANG "lang"
#define FC_WEIGHT "weight"
#define FC_SLANT "slant"
#define FC_WIDTH "width"
#define FC_SIZE "size"
#define FC_OUTLINE "outline"
#define FC_SCALABLE "scalable"
#define FC_ANTIALIAS "antialias"
#define FC_RGBA "rgba"
#define FC_HINTING "hinting"
#define FC_HINTSTYLE "hintstyle"
#define FC_INDEX "index"
#define FC_PIXEL_SIZE "pixelsize"

/* Weight constants */
#define FC_WEIGHT_THIN 0
#define FC_WEIGHT_EXTRALIGHT 40
#define FC_WEIGHT_ULTRALIGHT FC_WEIGHT_EXTRALIGHT
#define FC_WEIGHT_LIGHT 50
#define FC_WEIGHT_DEMILIGHT 55
#define FC_WEIGHT_SEMILIGHT FC_WEIGHT_DEMILIGHT
#define FC_WEIGHT_BOOK 75
#define FC_WEIGHT_REGULAR 80
#define FC_WEIGHT_NORMAL FC_WEIGHT_REGULAR
#define FC_WEIGHT_MEDIUM 100
#define FC_WEIGHT_DEMIBOLD 180
#define FC_WEIGHT_SEMIBOLD FC_WEIGHT_DEMIBOLD
#define FC_WEIGHT_BOLD 200
#define FC_WEIGHT_EXTRABOLD 205
#define FC_WEIGHT_ULTRABOLD FC_WEIGHT_EXTRABOLD
#define FC_WEIGHT_BLACK 210
#define FC_WEIGHT_HEAVY FC_WEIGHT_BLACK

/* Slant constants */
#define FC_SLANT_ROMAN 0
#define FC_SLANT_ITALIC 100
#define FC_SLANT_OBLIQUE 110

/* Width constants */
#define FC_WIDTH_ULTRACONDENSED 50
#define FC_WIDTH_EXTRACONDENSED 63
#define FC_WIDTH_CONDENSED 75
#define FC_WIDTH_SEMICONDENSED 87
#define FC_WIDTH_NORMAL 100
#define FC_WIDTH_SEMIEXPANDED 113
#define FC_WIDTH_EXPANDED 125
#define FC_WIDTH_EXTRAEXPANDED 150
#define FC_WIDTH_ULTRAEXPANDED 200

/* Spacing constants */
#define FC_PROPORTIONAL 0
#define FC_DUAL 90
#define FC_MONO 100
#define FC_CHARCELL 110

/* RGBA sub-pixel order */
#define FC_RGBA_UNKNOWN 0
#define FC_RGBA_RGB 1
#define FC_RGBA_BGR 2
#define FC_RGBA_VRGB 3
#define FC_RGBA_VBGR 4
#define FC_RGBA_NONE 5

/* Hint style */
#define FC_HINT_NONE 0
#define FC_HINT_SLIGHT 1
#define FC_HINT_MEDIUM 2
#define FC_HINT_FULL 3

#endif /* _FONTCONFIG_H_ */

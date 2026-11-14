/* AMCL 字体补全的真实 C ABI 行为验证。
 * 每次只 dlopen 本轮编译的明确路径，不链接系统 FreeType。补前库必须仍能
 * 解码原有 TrueType 字形，且 BDF/PCF 驱动和查询入口确实缺席，才返回专用负控码。
 * 补后库分别验证位图、编码、属性类型/值及 SFNT 的 BDF strike 服务。
 */
#include <ft2build.h>
#include FT_FREETYPE_H
#include FT_BDF_H
#include FT_FONT_FORMATS_H
#include <dlfcn.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define CHECK(condition) do { if (!(condition)) { \
    fprintf(stderr, "FAIL line %d: %s\n", __LINE__, #condition); exit(1); \
} } while (0)

/* 入口通过同一个本轮 DSO 解析，避免测试程序先链接其他版本后发生符号抢占。 */
static FT_Error (*init_library)(FT_Library*);
static FT_Error (*done_library)(FT_Library);
static void (*library_version)(FT_Library, FT_Int*, FT_Int*, FT_Int*);
static FT_Error (*new_face)(FT_Library, const char*, FT_Long, FT_Face*);
static FT_Error (*done_face)(FT_Face);
static FT_Error (*select_size)(FT_Face, FT_Int);
static FT_Error (*set_pixels)(FT_Face, FT_UInt, FT_UInt);
static FT_UInt (*char_index)(FT_Face, FT_ULong);
static FT_Error (*load_glyph)(FT_Face, FT_UInt, FT_Int32);
static const char* (*font_format)(FT_Face);
static FT_Error (*get_property)(FT_Face, const char*, BDF_PropertyRec*);
static FT_Error (*get_charset)(FT_Face, const char**, const char**);

#define REQUIRED(name, symbol) do { \
    *(void**)(&(name)) = dlsym(handle, (symbol)); CHECK((name) != NULL); \
} while (0)

static void path_for(char* path, size_t size, const char* root, const char* name)
{
    /* 测试路径也必须完整；截断路径导致另一个文件被打开时不能获得资格。 */
    int count = snprintf(path, size, "%s/%s", root, name);
    CHECK(count > 0 && (size_t)count < size);
}

static void string_property(FT_Face face, const char* name, const char* expected)
{
    BDF_PropertyRec value;
    CHECK(get_property(face, name, &value) == 0);
    CHECK(value.type == BDF_PROPERTY_TYPE_ATOM && value.u.atom != NULL);
    CHECK(strcmp(value.u.atom, expected) == 0);
}

static void integer_property(FT_Face face, const char* name, FT_Int32 expected)
{
    BDF_PropertyRec value;
    CHECK(get_property(face, name, &value) == 0);
    CHECK(value.type == BDF_PROPERTY_TYPE_INTEGER && value.u.integer == expected);
}

static void cardinal_property(FT_Face face, const char* name, FT_UInt32 expected)
{
    BDF_PropertyRec value;
    CHECK(get_property(face, name, &value) == 0);
    CHECK(value.type == BDF_PROPERTY_TYPE_CARDINAL && value.u.cardinal == expected);
}

static void bitmap_case(FT_Library library, const char* root, const char* name, const char* format)
{
    /* 核对真实字符映射和逐行像素；空驱动或恒定成功桩无法满足此正例。 */
    char path[4096];
    FT_Face face = NULL;
    path_for(path, sizeof(path), root, name);
    CHECK(new_face(library, path, 0, &face) == 0 && face != NULL);
    CHECK(strcmp(font_format(face), format) == 0);
    CHECK(face->num_fixed_sizes == 1 && select_size(face, 0) == 0);
    FT_UInt glyph = char_index(face, 65);
    CHECK(glyph != 0 && char_index(face, 66) == 0);
    CHECK(load_glyph(face, glyph, FT_LOAD_DEFAULT) == 0);
    FT_Bitmap* bitmap = &face->glyph->bitmap;
    CHECK(bitmap->pixel_mode == FT_PIXEL_MODE_MONO && bitmap->width == 4 && bitmap->rows == 4);
    CHECK(bitmap->buffer != NULL && bitmap->pitch > 0);
    const unsigned char expected[] = {0x60, 0x90, 0xf0, 0x90};
    for (unsigned row = 0; row != 4; ++row)
        CHECK((bitmap->buffer[row * (unsigned)bitmap->pitch] & 0xf0) == expected[row]);
    string_property(face, "FAMILY_NAME", "AMCLFixture");
    integer_property(face, "FONT_ASCENT", 4);
    if (strcmp(format, "BDF") == 0) cardinal_property(face, "DEFAULT_CHAR", 65);
    else integer_property(face, "DEFAULT_CHAR", 65); /* PCF 上游契约将数值属性作为 signed integer。 */
    const char *encoding = NULL, *registry = NULL;
    CHECK(get_charset(face, &encoding, &registry) == 0);
    CHECK(encoding && registry && strcmp(encoding, "1") == 0 && strcmp(registry, "ISO10646") == 0);
    BDF_PropertyRec missing;
    CHECK(get_property(face, "AMCL_NOT_PRESENT", &missing) != 0 && missing.type == BDF_PROPERTY_TYPE_NONE);
    CHECK(done_face(face) == 0);
    printf("PASS %s: Unicode mapping, 16 actual pixels, atom/integer properties, charset, missing property\n", format);
}

static void sfnt_case(FT_Library library, const char* root, int with_properties)
{
    /* 同一个 TrueType 正例在补前/补后都必须可渲染，避免负控使用损坏库或字体。 */
    char path[4096];
    FT_Face face = NULL;
    path_for(path, sizeof(path), root, "fixture.ttf");
    CHECK(new_face(library, path, 0, &face) == 0 && face != NULL);
    CHECK(strcmp(font_format(face), "TrueType") == 0 && set_pixels(face, 16, 16) == 0);
    FT_UInt glyph = char_index(face, 65);
    CHECK(glyph != 0 && load_glyph(face, glyph, FT_LOAD_RENDER) == 0);
    FT_Bitmap* bitmap = &face->glyph->bitmap;
    CHECK(bitmap->pixel_mode == FT_PIXEL_MODE_GRAY && bitmap->rows == 16 && bitmap->width == 16);
    CHECK(bitmap->buffer != NULL && bitmap->pitch >= 16);
    for (unsigned row = 0; row != 16; ++row)
        for (unsigned column = 0; column != 16; ++column)
            CHECK(bitmap->buffer[row * (unsigned)bitmap->pitch + column] == 255);
    if (with_properties) {
        string_property(face, "FAMILY_NAME", "AMCLFixture");
        integer_property(face, "SIGNED_TEST", -7);
        cardinal_property(face, "CARDINAL_TEST", UINT32_C(0x80000001));
        CHECK(set_pixels(face, 17, 17) == 0);
        BDF_PropertyRec missing;
        CHECK(get_property(face, "FAMILY_NAME", &missing) != 0 && missing.type == BDF_PROPERTY_TYPE_NONE);
        CHECK(set_pixels(face, 16, 16) == 0);
        string_property(face, "FAMILY_NAME", "AMCLFixture");
    }
    CHECK(done_face(face) == 0);
    printf("PASS TrueType: 256 actual pixels%s\n", with_properties ? ", SFNT BDF atom/signed/cardinal and ppem selection" : " (unchanged baseline behavior)");
}

int main(int argc, char** argv)
{
    CHECK(argc == 5);
    int negative = strcmp(argv[4], "before") == 0;
    CHECK(negative || strcmp(argv[4], "after") == 0);
    void* handle = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
    if (!handle) fprintf(stderr, "dlopen: %s\n", dlerror());
    CHECK(handle != NULL);
    REQUIRED(init_library, "FT_Init_FreeType"); REQUIRED(done_library, "FT_Done_FreeType");
    REQUIRED(library_version, "FT_Library_Version"); REQUIRED(new_face, "FT_New_Face");
    REQUIRED(done_face, "FT_Done_Face"); REQUIRED(select_size, "FT_Select_Size");
    REQUIRED(set_pixels, "FT_Set_Pixel_Sizes"); REQUIRED(char_index, "FT_Get_Char_Index");
    REQUIRED(load_glyph, "FT_Load_Glyph"); REQUIRED(font_format, "FT_Get_Font_Format");
    *(void**)(&get_property) = dlsym(handle, "FT_Get_BDF_Property");
    *(void**)(&get_charset) = dlsym(handle, "FT_Get_BDF_Charset_ID");
    FT_Library library = NULL;
    CHECK(init_library(&library) == 0 && library != NULL);
    FT_Int major, minor, patch;
    library_version(library, &major, &minor, &patch);
    char actual[64];
    CHECK(snprintf(actual, sizeof(actual), "%d.%d.%d", major, minor, patch) > 0);
    CHECK(strcmp(actual, argv[3]) == 0);
    if (negative) {
        CHECK(get_property == NULL && get_charset == NULL);
        sfnt_case(library, argv[2], 0);
        for (unsigned i = 0; i != 2; ++i) {
            char path[4096];
            FT_Face face = NULL;
            path_for(path, sizeof(path), argv[2], i ? "fixture.pcf" : "fixture.bdf");
            FT_Error error = new_face(library, path, 0, &face);
            CHECK(error == FT_Err_Unknown_File_Format && face == NULL);
        }
        CHECK(done_library(library) == 0 && dlclose(handle) == 0);
        puts("REPRO: valid original FreeType lacks BDF query exports and both bitmap drivers");
        return 77;
    }
    CHECK(get_property != NULL && get_charset != NULL);
    bitmap_case(library, argv[2], "fixture.bdf", "BDF");
    bitmap_case(library, argv[2], "fixture.pcf", "PCF");
    sfnt_case(library, argv[2], 1);
    CHECK(done_library(library) == 0 && dlclose(handle) == 0);
    printf("PASS complete font service behavior FreeType %s\n", actual);
    return 0;
}
